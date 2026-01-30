defmodule ParrotMedia.Fork.RTPSink do
  @moduledoc """
  Membrane Sink element that sends audio as RTP packets to external services.

  RTPSink receives audio buffers from a Membrane pipeline and sends them as
  properly formatted RTP packets to a configured destination. This enables
  media forking for use cases like:

  - External recording systems
  - Media servers (Asterisk, FreeSWITCH)
  - Analytics platforms that expect RTP streams
  - Telephony test equipment

  ## RTP Packet Format

  Each buffer is wrapped in an RTP packet with:
  - Version: 2
  - Payload Type: Configurable (default 0 for PCMU)
  - Sequence Number: Auto-incremented (wraps at 65535)
  - Timestamp: Auto-incremented based on sample count
  - SSRC: Random or user-specified

  ## Pipeline Integration

  RTPSink is designed to be dynamically added to a pipeline that includes
  a Membrane.Tee element:

      fork_spec = [
        child({:rtp_fork, fork_id}, %RTPSink{
          host: "192.168.1.100",
          port: 5004,
          payload_type: 0,  # PCMU
          ssrc: 0x12345678
        }),
        get_child(:media_tee)
        |> via_out(Pad.ref(:push_output, fork_id))
        |> get_child({:rtp_fork, fork_id})
      ]

  ## Payload Types

  Common payload types:
  - 0: PCMU (G.711 μ-law)
  - 8: PCMA (G.711 A-law)
  - 111: Opus (dynamic, commonly used)
  - 96-127: Dynamic payload types

  ## Timestamp Calculation

  The timestamp is incremented by the number of samples in each buffer.
  For 8kHz audio with 20ms frames, each frame contains 160 samples.
  For 48kHz Opus, each frame contains 960 samples (at 20ms).

  ## Example

      defmodule MyPipeline do
        use Membrane.Pipeline

        def handle_info({:fork_to_rtp, config}, _ctx, state) do
          spec = [
            child(:rtp_fork, %ParrotMedia.Fork.RTPSink{
              host: config.host,
              port: config.port,
              payload_type: config.payload_type,
              ssrc: config.ssrc
            }),
            get_child(:tee)
            |> via_out(Pad.ref(:push_output, :rtp_fork))
            |> get_child(:rtp_fork)
          ]
          {[spec: spec], state}
        end
      end
  """

  use Membrane.Sink

  require Logger

  alias ParrotMedia.RtpPacket

  # Standard payload types
  @payload_type_pcmu 0
  @payload_type_pcma 8
  @payload_type_opus 111

  def_input_pad(:input,
    flow_control: :push,
    accepted_format: _any
  )

  def_options(
    host: [
      spec: String.t() | :inet.ip4_address(),
      description: "Destination host (IP address or hostname)"
    ],
    port: [
      spec: pos_integer(),
      description: "Destination UDP port"
    ],
    payload_type: [
      spec: non_neg_integer(),
      default: @payload_type_pcmu,
      description: "RTP payload type (0=PCMU, 8=PCMA, 111=Opus)"
    ],
    ssrc: [
      spec: non_neg_integer() | nil,
      default: nil,
      description: "SSRC identifier (random if nil)"
    ],
    clock_rate: [
      spec: pos_integer(),
      default: 8000,
      description: "Clock rate in Hz (for timestamp calculation)"
    ],
    ptime: [
      spec: pos_integer(),
      default: 20,
      description: "Packet time in milliseconds"
    ],
    fork_id: [
      spec: String.t() | nil,
      default: nil,
      description: "Fork identifier for logging"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    # Resolve host to IP address
    destination_address = resolve_host(opts.host)

    # Generate SSRC if not provided
    ssrc = opts.ssrc || :rand.uniform(0xFFFFFFFF)

    # Calculate samples per frame for timestamp increment
    samples_per_frame = div(opts.clock_rate * opts.ptime, 1000)

    state = %{
      destination_address: destination_address,
      destination_port: opts.port,
      payload_type: opts.payload_type,
      ssrc: ssrc,
      clock_rate: opts.clock_rate,
      samples_per_frame: samples_per_frame,
      fork_id: opts.fork_id || "rtp-fork",
      socket: nil,
      sequence_number: :rand.uniform(0xFFFF),
      timestamp: :rand.uniform(0xFFFFFFFF),
      packets_sent: 0,
      errors: 0
    }

    Logger.info(
      "RTPSink [#{state.fork_id}]: Initializing for #{format_address(destination_address)}:#{opts.port} " <>
        "(PT=#{opts.payload_type}, SSRC=#{ssrc})"
    )

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    case :gen_udp.open(0, [:binary, {:active, false}]) do
      {:ok, socket} ->
        Logger.debug("RTPSink [#{state.fork_id}]: UDP socket opened")
        {[], %{state | socket: socket}}

      {:error, reason} ->
        Logger.error("RTPSink [#{state.fork_id}]: Failed to open UDP socket: #{inspect(reason)}")
        {[], state}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case state.socket do
      nil ->
        Logger.warning("RTPSink [#{state.fork_id}]: No socket available, dropping packet")
        {[], %{state | errors: state.errors + 1}}

      socket ->
        # Create RTP packet
        rtp_packet = RtpPacket.new(buffer.payload,
          payload_type: state.payload_type,
          sequence_number: state.sequence_number,
          timestamp: state.timestamp,
          ssrc: state.ssrc
        )

        # Encode and send
        encoded = RtpPacket.encode(rtp_packet)

        case :gen_udp.send(
               socket,
               state.destination_address,
               state.destination_port,
               encoded
             ) do
          :ok ->
            # Update sequence number (wrap at 65535)
            new_seq = rem(state.sequence_number + 1, 0x10000)
            # Update timestamp based on samples per frame
            new_ts = rem(state.timestamp + state.samples_per_frame, 0x100000000)

            new_state = %{
              state
              | sequence_number: new_seq,
                timestamp: new_ts,
                packets_sent: state.packets_sent + 1
            }

            {[], new_state}

          {:error, reason} ->
            if state.errors < 10 or rem(state.errors, 100) == 0 do
              Logger.warning(
                "RTPSink [#{state.fork_id}]: Send error (#{state.errors + 1} total): #{inspect(reason)}"
              )
            end

            {[], %{state | errors: state.errors + 1}}
        end
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    Logger.info(
      "RTPSink [#{state.fork_id}]: End of stream. Sent #{state.packets_sent} packets, #{state.errors} errors"
    )

    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    cleanup(state)
    {[terminate: :normal], state}
  end

  # Helper functions

  defp resolve_host(host) when is_tuple(host), do: host

  defp resolve_host(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        ip

      {:error, _} ->
        # Try DNS resolution
        case :inet.gethostbyname(String.to_charlist(host)) do
          {:ok, {:hostent, _, _, _, _, [ip | _]}} -> ip
          {:error, _} -> {127, 0, 0, 1}
        end
    end
  end

  defp format_address(address) when is_tuple(address) do
    address |> Tuple.to_list() |> Enum.join(".")
  end

  defp format_address(address) when is_binary(address), do: address

  defp cleanup(state) do
    if state.socket do
      :gen_udp.close(state.socket)
      Logger.debug("RTPSink [#{state.fork_id}]: Socket closed")
    end
  end

  # Public constants for payload types
  @doc "PCMU payload type (G.711 μ-law)"
  def payload_type_pcmu, do: @payload_type_pcmu

  @doc "PCMA payload type (G.711 A-law)"
  def payload_type_pcma, do: @payload_type_pcma

  @doc "Opus payload type (dynamic)"
  def payload_type_opus, do: @payload_type_opus
end
