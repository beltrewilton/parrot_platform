defmodule ParrotMedia.AlawPipeline do
  @moduledoc """
  Membrane pipeline for G.711 A-law RTP streaming.
  Uses the official Membrane G711 encoder (A-law) and RTP payloader.
  """

  use Membrane.Pipeline
  require Logger

  import ParrotMedia.PipelineHelpers

  @impl true
  def handle_init(_ctx, opts) do
    Logger.info("AlawPipeline: Starting for session #{opts.session_id}")
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
        # payload type 8 = G.711 A-law (static encoding uses atom format)
        fmt_mapping: %{8 => {:PCMA, 8000}},
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
    # 2. Add TimestampGenerator for proper buffer timestamps
    # 3. Use TimestampPreservingG711Encoder (preserves timestamps through encoding)
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
          child(:timestamp_generator, ParrotMedia.TimestampGenerator),
          child(:g711_encoder, ParrotMedia.TimestampPreservingG711Encoder),
          child(:g711_chunker, %ParrotMedia.AudioChunker{
            # 20ms packets at 8kHz = 160 samples
            chunk_duration_ms: 20,
            sample_rate: 8000
          }),
          child(:rtp_debug, %ParrotMedia.RTPPacketLogger{
            dest_info: "#{format_ip(opts.remote_rtp_address)}:#{opts.remote_rtp_port}"
          }),
          child(:realtimer, Membrane.Realtimer),

          # Links (using get_child to connect defined elements)
          get_child(:audio_source)
          |> get_child(:timestamp_generator)
          |> get_child(:g711_encoder)
          |> get_child(:g711_chunker)
          |> via_in(Pad.ref(:input, ssrc),
            options: [payloader: Membrane.RTP.G711.Payloader]
          )
          |> get_child(:rtp)
          |> via_out(Pad.ref(:rtp_output, ssrc), options: [encoding: :PCMA])
          |> get_child(:rtp_debug)
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
       ssrc: ssrc
     }}
  end

  @impl true
  def handle_element_start_of_stream(element, pad, _ctx, state) do
    Logger.debug(
      "AlawPipeline #{state.session_id}: Start of stream on #{inspect(element)}:#{inspect(pad)}"
    )

    case element do
      :udp_endpoint ->
        Logger.info("AlawPipeline #{state.session_id}: Started streaming")
        Logger.info("  Streaming RTP to #{inspect(get_in(state, [:udp_sink_config]))}")

      :audio_source ->
        Logger.info("AlawPipeline #{state.session_id}: Audio source started")

      :realtimer ->
        Logger.debug(
          "AlawPipeline #{state.session_id}: Realtimer ready - streaming at realtime pace"
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
      "AlawPipeline #{state.session_id}: End of stream on #{inspect(element)}:#{inspect(pad)}"
    )

    # Log specific elements for debugging
    case element do
      :audio_source ->
        Logger.info("AlawPipeline #{state.session_id}: Audio source finished (file switching handled internally)")
        {[], state}

      :realtimer ->
        Logger.info("AlawPipeline #{state.session_id}: Realtimer finished processing")
        {[], state}

      :udp_endpoint ->
        Logger.info("AlawPipeline #{state.session_id}: Finished streaming")
        {[terminate: :normal], state}

      element_name ->
        Logger.debug(
          "AlawPipeline #{state.session_id}: End of stream for #{inspect(element_name)}"
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
    Logger.info("AlawPipeline #{state.session_id}: New incoming RTP stream with SSRC: #{ssrc}")

    Logger.debug("  Full notification: #{inspect(notification)}")

    # Create a pipeline to handle incoming RTP audio
    receive_audio_spec = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc),
        options: [depayloader: Membrane.RTP.G711.Depayloader]
      )
      |> child({:g711_decoder, ssrc}, Membrane.G711.Decoder)
      |> child({:audio_sink, ssrc}, %Membrane.Debug.Sink{})
    ]

    {[spec: receive_audio_spec], state}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end
end
