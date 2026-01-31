defmodule ParrotMedia.AlawPipeline do
  @moduledoc """
  Membrane pipeline for G.711 A-law RTP streaming.
  Uses the official Membrane G711 encoder (A-law) and RTP payloader.

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
  alias ParrotMedia.Elements.TelephoneEventParser
  alias ParrotMedia.Elements.DirectionGate
  alias ParrotMedia.MOS.Observer

  @type direction :: :sendrecv | :sendonly | :recvonly | :inactive

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

    # Get dynamic payload types from SDP (encoding name -> {pt, clock_rate})
    # Per RFC 3551, PTs 96-127 are dynamically assigned via SDP rtpmap
    dynamic_payload_types = Map.get(opts, :dynamic_payload_types, %{})

    # Build reverse map (PT -> encoding name) for efficient lookup when RTP streams arrive
    pt_to_encoding =
      for {encoding, {pt, _clock_rate}} <- dynamic_payload_types, into: %{} do
        {pt, encoding}
      end

    Logger.info("AlawPipeline: Dynamic payload types: #{inspect(dynamic_payload_types)}")

    # Generate SSRC once for consistency
    ssrc = :rand.uniform(0xFFFFFFFF)
    has_audio? = has_audio_file?(opts)

    # Create bidirectional UDP endpoint
    udp_endpoint_spec = build_udp_endpoint_spec(opts, has_audio?)

    # Build fmt_mapping with static PT=8 (PCMA) plus all dynamic PTs from SDP
    # Per RFC 3551, PTs 96-127 are dynamically assigned via SDP rtpmap
    # SessionBin requires ALL expected PTs in fmt_mapping to accept incoming streams
    # Uses clock_rate from SDP (not hardcoded) for proper codec handling
    base_fmt_mapping = %{8 => {:PCMA, 8000}}

    dynamic_fmt_mapping =
      for {encoding, {pt, clock_rate}} <- dynamic_payload_types, into: %{} do
        # Use encoding atom and clock_rate from SDP
        {pt, {String.to_atom(encoding), clock_rate}}
      end

    fmt_mapping = Map.merge(base_fmt_mapping, dynamic_fmt_mapping)
    Logger.info("AlawPipeline: RTP fmt_mapping: #{inspect(fmt_mapping)}")

    # Create RTP SessionBin for bidirectional RTP handling
    rtp_session_spec =
      child(:rtp, %Membrane.RTP.SessionBin{
        # Include all expected payload types (static + dynamic from SDP)
        fmt_mapping: fmt_mapping,
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

    # Create sending pipeline with Tee for media forking support:
    # 1. Define children separately (not chained)
    # 2. Add TimestampGenerator for proper buffer timestamps
    # 3. Use TimestampPreservingG711Encoder (preserves timestamps through encoding)
    # 4. Include media_tee for forking support (MUST be in pipeline from start)
    # 5. Link with get_child() references
    # 6. Realtimer AFTER RTP output for proper packet pacing
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
          # Direction gate for send path - mutes outbound audio in :recvonly/:inactive
          child(:send_gate, %DirectionGate{role: :send, initial_direction: :sendrecv}),
          # Tee element for media forking - MUST be present from pipeline start
          # Fork sinks are dynamically linked to push_output pads
          child(:media_tee, Membrane.Tee),
          child(:rtp_debug, %ParrotMedia.RTPPacketLogger{
            dest_info: "#{format_ip(opts.remote_rtp_address)}:#{opts.remote_rtp_port}"
          }),
          child(:realtimer, Membrane.Realtimer),

          # Links (using get_child to connect defined elements)
          # Audio source -> processing -> DirectionGate -> Tee -> main output -> RTP
          get_child(:audio_source)
          |> get_child(:timestamp_generator)
          |> get_child(:g711_encoder)
          |> get_child(:g711_chunker)
          |> get_child(:send_gate)
          |> get_child(:media_tee)
          |> via_out(Pad.ref(:output, :main))
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
       ssrc: ssrc,
       # Track active forks for cleanup
       active_forks: %{},
       # Dynamic payload type mapping (PT -> encoding name)
       # Per RFC 3551, PTs 96-127 are dynamically assigned via SDP
       pt_to_encoding: pt_to_encoding,
       # Optional MediaSession PID for forwarding events
       media_session_pid: Map.get(opts, :media_session_pid),
       # Media direction for hold/resume support
       # :sendrecv - Normal bidirectional audio (default)
       # :sendonly - We send, remote on hold (mute local playback)
       # :recvonly - We receive, we're on hold (send silence)
       # :inactive - Completely muted
       direction: :sendrecv,
       # Track if audio path exists (for direction gate notifications)
       has_audio: has_audio?
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
        Logger.info(
          "AlawPipeline #{state.session_id}: Audio source finished (file switching handled internally)"
        )

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
        {:new_rtp_stream, ssrc, pt, _extensions} = notification,
        :rtp,
        _ctx,
        state
      ) do
    Logger.info("AlawPipeline #{state.session_id}: New incoming RTP stream with SSRC: #{ssrc}, PT: #{pt}")
    Logger.debug("  Full notification: #{inspect(notification)}")

    # Look up dynamic payload type by PT number (RFC 3551: PTs 96-127 are dynamic)
    encoding = Map.get(state.pt_to_encoding, pt)

    handle_rtp_stream_by_encoding(ssrc, pt, encoding, state)
  end

  # Handle DTMF notification from TelephoneEventParser
  # Forward to MediaSession for handler processing
  def handle_child_notification({:dtmf, digit}, {child_type, _ssrc}, _ctx, state)
      when child_type == :dtmf_parser do
    Logger.info("AlawPipeline #{state.session_id}: DTMF digit detected: #{digit}")

    if state.media_session_pid do
      send(state.media_session_pid, {:pipeline_event, :dtmf, digit})
    end

    {[], state}
  end

  def handle_child_notification({:file_complete, filename}, :audio_source, _ctx, state) do
    # SwitchableFileSource notifies us when a file completes
    # Forward this to MediaSession if we have a reference
    Logger.info("AlawPipeline #{state.session_id}: File complete notification for #{filename}")

    if state[:media_session_pid] do
      send(state.media_session_pid, {:pipeline_event, :play_complete, filename})
    end

    {[], state}
  end

  def handle_child_notification(_notification, _child, _ctx, state) do
    {[], state}
  end

  # Handle RTP streams based on encoding name from SDP negotiation
  # Per RFC 3551, static PTs (0-95) have fixed meanings, dynamic PTs (96-127) are from SDP

  # RFC 4733 telephone-event for DTMF detection
  defp handle_rtp_stream_by_encoding(ssrc, pt, "telephone-event", state) do
    Logger.info("AlawPipeline #{state.session_id}: Detected telephone-event stream (PT=#{pt})")

    # Create pipeline to parse DTMF events
    # TelephoneEventParser emits {:dtmf, digit} notifications on end_bit=1
    dtmf_spec = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc))
      |> child({:dtmf_parser, ssrc}, %TelephoneEventParser{payload_type: pt})
      |> child({:dtmf_sink, ssrc}, %Membrane.Debug.Sink{})
    ]

    {[spec: dtmf_spec], state}
  end

  # no-op stream (used by SIPp for DTMF mode)
  defp handle_rtp_stream_by_encoding(ssrc, pt, "no-op", state) do
    Logger.info("AlawPipeline #{state.session_id}: Detected no-op stream (PT=#{pt})")

    # Route to null sink to consume the stream
    noop_spec = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc))
      |> child({:noop_sink, ssrc}, %Membrane.Debug.Sink{})
    ]

    {[spec: noop_spec], state}
  end

  # G.711 A-law audio via dynamic SDP encoding (pjsua includes pcma in offer)
  defp handle_rtp_stream_by_encoding(ssrc, pt, "pcma", state) do
    Logger.info("AlawPipeline #{state.session_id}: Detected pcma stream via SDP (PT=#{pt})")
    # Reuse the same PCMA handler logic
    handle_pcma_stream(ssrc, pt, state)
  end

  # No dynamic encoding found - check static payload types
  defp handle_rtp_stream_by_encoding(ssrc, pt, nil, state) do
    case pt do
      # G.711 A-law audio stream (PT=8 is static per RFC 3551)
      8 ->
        handle_pcma_stream(ssrc, pt, state)

      # Unknown static payload type - log and ignore
      _ ->
        Logger.warning("AlawPipeline #{state.session_id}: Unknown payload type #{pt}, ignoring stream")
        {[], state}
    end
  end

  # Other dynamic encoding we recognize but don't specifically handle
  defp handle_rtp_stream_by_encoding(ssrc, pt, encoding, state) do
    Logger.info("AlawPipeline #{state.session_id}: Detected #{encoding} stream (PT=#{pt}) - routing to sink")

    # Route to null sink to consume the stream
    other_spec = [
      get_child(:rtp)
      |> via_out(Pad.ref(:output, ssrc))
      |> child({:other_sink, ssrc}, %Membrane.Debug.Sink{})
    ]

    {[spec: other_spec], state}
  end

  # Find telephone-event payload type from pt_to_encoding map
  defp find_telephone_event_pt(pt_to_encoding) do
    Enum.find_value(pt_to_encoding, fn
      {pt, "telephone-event"} -> pt
      _ -> nil
    end)
  end

  # Common handler for PCMA streams (from both static PT and SDP encoding)
  defp handle_pcma_stream(ssrc, pt, state) do
    # Find telephone-event PT from SDP negotiation (RFC 4733 DTMF)
    # DTMF packets share the same SSRC as audio but have different PT
    telephone_event_pt = find_telephone_event_pt(state.pt_to_encoding)

    if telephone_event_pt do
      Logger.info(
        "AlawPipeline #{state.session_id}: Adding inline DTMF parser for PT=#{telephone_event_pt}"
      )

      # Insert TelephoneEventParser to detect DTMF before depayloading
      # TelephoneEventParser passes through non-DTMF packets unchanged
      # MOS Observer collects metrics for quality monitoring
      # DirectionGate controls receive path muting for hold/resume
      receive_audio_spec = [
        get_child(:rtp)
        |> via_out(Pad.ref(:output, ssrc))
        |> child({:dtmf_parser, ssrc}, %TelephoneEventParser{payload_type: telephone_event_pt})
        |> child({:g711_depayloader, ssrc}, Membrane.RTP.G711.Depayloader)
        |> child({:receive_gate, ssrc}, %DirectionGate{
          role: :receive,
          initial_direction: state.direction
        })
        |> child({:mos_observer, ssrc}, %Observer{
          session_id: state.session_id,
          stats_interval_ms: 1000
        })
        |> child({:g711_decoder, ssrc}, Membrane.G711.Decoder)
        |> child({:audio_sink, ssrc}, %Membrane.Debug.Sink{})
      ]

      # Track this SSRC so we can forward direction changes to its receive_gate
      updated_state = Map.update(state, :receive_ssrcs, [ssrc], fn ssrcs -> [ssrc | ssrcs] end)
      {[spec: receive_audio_spec], updated_state}
    else
      Logger.info("AlawPipeline #{state.session_id}: Detected G.711 A-law audio stream (PT=#{pt})")

      # No telephone-event negotiated - standard audio pipeline
      # MOS Observer collects metrics for quality monitoring
      # DirectionGate controls receive path muting for hold/resume
      receive_audio_spec = [
        get_child(:rtp)
        |> via_out(Pad.ref(:output, ssrc),
          options: [depayloader: Membrane.RTP.G711.Depayloader]
        )
        |> child({:receive_gate, ssrc}, %DirectionGate{
          role: :receive,
          initial_direction: state.direction
        })
        |> child({:mos_observer, ssrc}, %Observer{
          session_id: state.session_id,
          stats_interval_ms: 1000
        })
        |> child({:g711_decoder, ssrc}, Membrane.G711.Decoder)
        |> child({:audio_sink, ssrc}, %Membrane.Debug.Sink{})
      ]

      # Track this SSRC so we can forward direction changes to its receive_gate
      updated_state = Map.update(state, :receive_ssrcs, [ssrc], fn ssrcs -> [ssrc | ssrcs] end)
      {[spec: receive_audio_spec], updated_state}
    end
  end

  # Handle play_files_request from MediaSession
  # The MediaSession sends this message after handler returns {:play_sequence, files} or {:play_loop, files}
  # We forward to the audio_source element using notify_child ACTION (not function call)
  @impl true
  def handle_info({:play_files_request, files, opts}, _ctx, state) do
    Logger.info(
      "AlawPipeline #{state.session_id}: Received play_files_request for #{length(files)} files"
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
      "AlawPipeline #{state.session_id}: Adding fork '#{fork_config.id}' to " <>
        "#{format_address(fork_config.destination_address)}:#{fork_config.destination_port}"
    )

    # Validate the fork config
    case ForkConfig.validate(fork_config) do
      :ok ->
        # Check if fork already exists
        if Map.has_key?(state.active_forks, fork_config.id) do
          Logger.warning(
            "AlawPipeline #{state.session_id}: Fork '#{fork_config.id}' already exists, ignoring"
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
          "AlawPipeline #{state.session_id}: Invalid fork config: #{inspect(reason)}"
        )

        {[], state}
    end
  end

  # Handle remove_fork request - remove a fork sink and unlink from Tee
  @impl true
  def handle_info({:remove_fork, fork_id}, _ctx, state) do
    Logger.info("AlawPipeline #{state.session_id}: Removing fork '#{fork_id}'")

    case Map.pop(state.active_forks, fork_id) do
      {nil, _} ->
        Logger.warning(
          "AlawPipeline #{state.session_id}: Fork '#{fork_id}' not found, ignoring"
        )

        {[], state}

      {_fork_config, updated_forks} ->
        # Remove the fork sink child element
        # This will automatically unlink and clean up the pad connection
        {[remove_children: [{:fork_sink, fork_id}]], %{state | active_forks: updated_forks}}
    end
  end

  # Handle direction change for hold/resume support
  # The direction affects whether we send/receive audio
  # Per RFC 3264:
  # - :sendrecv - Normal bidirectional audio
  # - :sendonly - We send, remote on hold (mute receive path)
  # - :recvonly - We receive, we're on hold (mute send path)
  # - :inactive - Completely muted
  @impl true
  def handle_info({:set_direction, direction}, _ctx, state)
      when direction in [:sendrecv, :sendonly, :recvonly, :inactive] do
    Logger.info("AlawPipeline #{state.session_id}: Setting direction to #{direction}")

    # Build actions to notify DirectionGate children
    # The send_gate and receive_gate elements will handle the actual muting
    actions = build_direction_change_actions(direction, state)

    {actions, %{state | direction: direction}}
  end

  # Handle get_direction request for testing/debugging
  @impl true
  def handle_info({:get_direction, from}, _ctx, state) do
    send(from, {:direction, state.direction})
    {[], state}
  end

  @impl true
  def handle_info(msg, _ctx, state) do
    Logger.debug("AlawPipeline #{state.session_id}: Received unknown message: #{inspect(msg)}")
    {[], state}
  end

  # Private helpers

  # Build notify_child actions for direction gates
  defp build_direction_change_actions(direction, state) do
    send_gate_actions(direction, state) ++ receive_gate_actions(direction, state)
  end

  defp send_gate_actions(direction, %{has_audio: true}) do
    [{:notify_child, {:send_gate, {:set_direction, direction}}}]
  end

  defp send_gate_actions(_direction, _state), do: []

  defp receive_gate_actions(direction, %{receive_ssrcs: ssrcs}) when is_list(ssrcs) do
    Enum.map(ssrcs, &{:notify_child, {{:receive_gate, &1}, {:set_direction, direction}}})
  end

  defp receive_gate_actions(_direction, _state), do: []

  defp format_address(address) when is_tuple(address) do
    address |> Tuple.to_list() |> Enum.join(".")
  end

  defp format_address(address) when is_binary(address), do: address
end
