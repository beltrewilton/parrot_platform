defmodule ParrotMedia.OpusPipeline do
  @moduledoc """
  Membrane pipeline for Opus RTP streaming.
  Uses the proper RTP.SessionBin approach like AlawPipeline.

  ## Media Forking Support

  This pipeline includes a Tee element (`media_tee`) in the outbound path that
  enables media forking to external services. Fork destinations can be dynamically
  added by sending `{:add_fork, fork_config}` messages to the pipeline:

      send(pipeline_pid, {:add_fork, %ForkConfig{
        id: "transcription",
        destination_address: {192, 168, 1, 100},
        destination_port: 5000
      }})

  Forks can be removed with `{:remove_fork, fork_id}`.
  """

  use Membrane.Pipeline
  require Logger

  import ParrotMedia.PipelineHelpers

  alias ParrotMedia.ForkConfig
  alias ParrotMedia.ForkSink

  @impl true
  def handle_init(_ctx, opts) do
    Logger.info("OpusPipeline: Starting for session #{opts.session_id}")
    Logger.info("  Audio file: #{inspect(opts.audio_file)}")

    # Check if file exists and get its size (only for actual file paths)
    if is_binary(opts.audio_file) do
      case File.stat(opts.audio_file) do
        {:ok, %{size: size}} ->
          Logger.info("  Audio file size: #{size} bytes")

        {:error, reason} ->
          Logger.error("  Cannot stat audio file: #{inspect(reason)}")
      end
    end

    Logger.info("  RTP destination: #{opts.remote_rtp_address}:#{opts.remote_rtp_port}")
    Logger.info("  Local RTP port: #{opts.local_rtp_port}")

    # Generate SSRC once for consistency
    ssrc = :rand.uniform(0xFFFFFFFF)
    has_audio? = has_audio_file?(opts)

    # Create bidirectional UDP endpoint
    udp_endpoint_spec = build_udp_endpoint_spec(opts, has_audio?)

    # Create RTP SessionBin for bidirectional RTP handling
    rtp_session_spec =
      child(:rtp, %Membrane.RTP.SessionBin{
        # payload type 111 = Opus (dynamic encoding)
        fmt_mapping: %{111 => {:opus, 48000}},
        # RTCP intervals per RFC 3550
        rtcp_receiver_report_interval: Membrane.Time.seconds(5),
        rtcp_sender_report_interval: Membrane.Time.seconds(5)
      })

    # Receiving pipeline: UDP -> RTP -> Decoder
    receive_spec = [
      get_child(:udp_endpoint)
      |> via_out(:output)
      |> via_in(Pad.ref(:rtp_input, make_ref()))
      |> get_child(:rtp)
    ]

    # Create sending pipeline following working PortAudioPipeline pattern:
    # 1. Define children separately (not chained)
    # 2. TimestampGenerator for proper buffer timestamps
    # 3. Include media_tee for forking support (MUST be in pipeline from start)
    # 4. Link with get_child() references
    # 5. Realtimer AFTER RTP output for proper packet pacing
    send_spec =
      if has_audio? do
        [
          # Child definitions (creates elements but doesn't link them)
          child(:audio_source, %ParrotMedia.SwitchableFileSource{
            initial_file: opts.audio_file,
            media_handler: opts.media_handler,
            handler_state: opts.handler_state,
            session_id: opts.session_id
          }),
          child(:resampler, %Membrane.FFmpeg.SWResample.Converter{
            output_stream_format: %Membrane.RawAudio{
              sample_format: :s16le,
              sample_rate: 48000,
              channels: 2
            }
          }),
          child(:timestamp_generator, ParrotMedia.TimestampGenerator),
          child(:opus_encoder, %Membrane.Opus.Encoder{
            application: :voip,
            bitrate: 32_000
          }),
          # Tee element for media forking - MUST be present from pipeline start
          # Fork sinks are dynamically linked to push_output pads
          child(:media_tee, Membrane.Tee),
          child(:realtimer, Membrane.Realtimer),

          # Links (using get_child to connect defined elements)
          # Audio source -> processing -> Tee -> main output -> RTP
          get_child(:audio_source)
          |> get_child(:resampler)
          |> get_child(:timestamp_generator)
          |> get_child(:opus_encoder)
          |> get_child(:media_tee)
          |> via_out(Pad.ref(:output, :main))
          |> via_in(Pad.ref(:input, ssrc),
            options: [payloader: Membrane.RTP.Opus.Payloader]
          )
          |> get_child(:rtp)
          |> via_out(Pad.ref(:rtp_output, ssrc), options: [payload_type: 111])
          |> get_child(:realtimer)
          |> via_in(:input)
          |> get_child(:udp_endpoint)
        ]
      else
        []
      end

    structure =
      [udp_endpoint_spec, rtp_session_spec, receive_spec] ++ send_spec

    {[spec: structure],
     %{
       session_id: opts.session_id,
       udp_sink_config: "#{format_ip(opts.remote_rtp_address)}:#{opts.remote_rtp_port}",
       ssrc: ssrc,
       # Track active forks for cleanup
       active_forks: %{}
     }}
  end

  @impl true
  def handle_element_start_of_stream(element, pad, _ctx, state) do
    Logger.debug(
      "OpusPipeline #{state.session_id}: Start of stream on #{inspect(element)}:#{inspect(pad)}"
    )

    case element do
      :udp_endpoint ->
        Logger.info("OpusPipeline #{state.session_id}: Started streaming")
        Logger.info("  Streaming RTP to #{inspect(get_in(state, [:udp_sink_config]))}")

      :audio_source ->
        Logger.info("OpusPipeline #{state.session_id}: Audio source started")

      :realtimer ->
        Logger.debug(
          "OpusPipeline #{state.session_id}: Realtimer ready - streaming at realtime pace"
        )

      _ ->
        # Handle start of stream for other elements
        {[], state}
    end

    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(element, pad, _ctx, state) do
    Logger.debug(
      "OpusPipeline #{state.session_id}: End of stream on #{inspect(element)}:#{inspect(pad)}"
    )

    # Log specific elements for debugging
    case element do
      :audio_source ->
        Logger.info(
          "OpusPipeline #{state.session_id}: Audio source finished (file switching handled internally)"
        )

        {[], state}

      :realtimer ->
        Logger.info("OpusPipeline #{state.session_id}: Realtimer finished processing")
        {[], state}

      :udp_endpoint ->
        Logger.info("OpusPipeline #{state.session_id}: Finished streaming")
        {[terminate: :normal], state}

      element_name ->
        Logger.debug(
          "OpusPipeline #{state.session_id}: End of stream for #{inspect(element_name)}"
        )

        {[], state}
    end
  end

  @impl true
  def handle_child_notification(
        {:new_rtp_stream, ssrc, _pt, _extensions} = notification,
        :rtp,
        _ctx,
        state
      ) do
    Logger.info("OpusPipeline #{state.session_id}: New incoming RTP stream with SSRC: #{ssrc}")

    Logger.debug("  Full notification: #{inspect(notification)}")

    # Create a pipeline to handle incoming RTP audio
    receive_audio_spec = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc),
        options: [depayloader: Membrane.RTP.Opus.Depayloader]
      )
      |> child({:opus_decoder, ssrc}, Membrane.Opus.Decoder)
      |> child({:audio_sink, ssrc}, %Membrane.Debug.Sink{})
    ]

    {[spec: receive_audio_spec], state}
  end

  @impl true
  def handle_child_notification({:file_complete, filename}, :audio_source, _ctx, state) do
    # SwitchableFileSource notifies us when a file completes
    # Forward this to MediaSession if we have a reference
    Logger.info("OpusPipeline #{state.session_id}: File complete notification for #{filename}")

    if state[:media_session_pid] do
      send(state.media_session_pid, {:pipeline_event, :play_complete, filename})
    end

    {[], state}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  # Handle play_files_request from MediaSession
  # The MediaSession sends this message after handler returns {:play_sequence, files} or {:play_loop, files}
  # We forward to the audio_source element using notify_child ACTION (not function call)
  @impl true
  def handle_info({:play_files_request, files, opts}, _ctx, state) do
    Logger.info(
      "OpusPipeline #{state.session_id}: Received play_files_request for #{length(files)} files"
    )

    # Determine the notification type based on options
    notification =
      case Keyword.get(opts, :loop, false) do
        true -> {:play_loop, files}
        false -> {:play_sequence, files}
      end

    # Return notify_child action - this is how Membrane pipelines communicate with children
    # CRITICAL: This is an ACTION, not a function call
    {[notify_child: {:audio_source, notification}], state}
  end

  # Handle add_fork request - dynamically add a fork sink to the Tee's push_output pad
  # This is the core of media forking: the Tee element duplicates media to all connected outputs
  @impl true
  def handle_info({:add_fork, %ForkConfig{} = fork_config}, _ctx, state) do
    Logger.info(
      "OpusPipeline #{state.session_id}: Adding fork '#{fork_config.id}' to " <>
        "#{format_address(fork_config.destination_address)}:#{fork_config.destination_port}"
    )

    # Validate the fork config
    case ForkConfig.validate(fork_config) do
      :ok ->
        # Check if fork already exists
        if Map.has_key?(state.active_forks, fork_config.id) do
          Logger.warning(
            "OpusPipeline #{state.session_id}: Fork '#{fork_config.id}' already exists, ignoring"
          )

          {[], state}
        else
          # Create the fork sink spec
          # The ForkSink receives buffers and sends them via UDP to the destination
          fork_spec = [
            child({:fork_sink, fork_config.id}, %ForkSink{
              destination_address: fork_config.destination_address,
              destination_port: fork_config.destination_port,
              fork_id: fork_config.id
            }),
            # Link from Tee's push_output pad to the fork sink
            # push_output pads push data to connected elements without backpressure
            get_child(:media_tee)
            |> via_out(Pad.ref(:push_output, fork_config.id))
            |> get_child({:fork_sink, fork_config.id})
          ]

          # Track the active fork
          updated_forks = Map.put(state.active_forks, fork_config.id, fork_config)

          {[spec: fork_spec], %{state | active_forks: updated_forks}}
        end

      {:error, reason} ->
        Logger.error(
          "OpusPipeline #{state.session_id}: Invalid fork config: #{inspect(reason)}"
        )

        {[], state}
    end
  end

  # Handle remove_fork request - remove a fork sink and unlink from Tee
  @impl true
  def handle_info({:remove_fork, fork_id}, _ctx, state) do
    Logger.info("OpusPipeline #{state.session_id}: Removing fork '#{fork_id}'")

    case Map.pop(state.active_forks, fork_id) do
      {nil, _} ->
        Logger.warning(
          "OpusPipeline #{state.session_id}: Fork '#{fork_id}' not found, ignoring"
        )

        {[], state}

      {_fork_config, updated_forks} ->
        # Remove the fork sink child element
        # This will automatically unlink and clean up the pad connection
        {[remove_children: [{:fork_sink, fork_id}]], %{state | active_forks: updated_forks}}
    end
  end

  @impl true
  def handle_info(msg, _ctx, state) do
    Logger.debug("OpusPipeline #{state.session_id}: Received unknown message: #{inspect(msg)}")
    {[], state}
  end

  # Private helpers

  defp format_address(address) when is_tuple(address) do
    address |> Tuple.to_list() |> Enum.join(".")
  end

  defp format_address(address) when is_binary(address), do: address
end
