defmodule ParrotMedia.ForkSink do
  @moduledoc """
  Membrane Sink element for forwarding RTP packets to external services.

  ForkSink receives encoded RTP packets from a Tee element and sends them
  via UDP to a configured destination address and port. This enables media
  forking for use cases like:

  - Real-time transcription services
  - Call recording servers
  - Audio analysis systems
  - AI-powered conversation analysis

  ## Pipeline Integration

  ForkSink is designed to be dynamically added to a pipeline that includes
  a Membrane.Tee element. When a fork is requested:

  1. ForkSink is spawned as a new child element
  2. It's linked to a `push_output` pad on the Tee
  3. It opens a UDP socket and forwards all received buffers
  4. Network errors are logged but don't crash the pipeline

  ## Example

      # In a pipeline handle_info callback
      def handle_info({:add_fork, fork_config}, _ctx, state) do
        fork_spec = [
          child({:fork_sink, fork_config.id}, %ForkSink{
            destination_address: fork_config.destination_address,
            destination_port: fork_config.destination_port,
            fork_id: fork_config.id
          }),
          get_child(:media_tee)
          |> via_out(Pad.ref(:push_output, fork_config.id))
          |> get_child({:fork_sink, fork_config.id})
        ]
        {[spec: fork_spec], state}
      end

  ## Error Handling

  Network errors during transmission are logged at warning level but do not
  cause the sink to crash. This ensures that temporary network issues don't
  affect the primary call's media flow.
  """

  use Membrane.Sink

  require Logger

  alias ParrotMedia.ForkConfig

  def_input_pad(:input,
    flow_control: :push,
    accepted_format: _any
  )

  def_options(
    destination_address: [
      spec: :inet.ip4_address() | String.t(),
      description: "Destination IP address for RTP packets"
    ],
    destination_port: [
      spec: pos_integer(),
      description: "Destination UDP port"
    ],
    fork_id: [
      spec: String.t() | nil,
      default: nil,
      description: "Unique identifier for this fork (for logging)"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    destination_address = ForkConfig.parse_address(opts.destination_address)

    state = %{
      destination_address: destination_address,
      destination_port: opts.destination_port,
      fork_id: opts.fork_id || "anonymous",
      socket: nil,
      packets_sent: 0,
      errors: 0
    }

    Logger.info(
      "ForkSink [#{state.fork_id}]: Initializing for #{format_address(destination_address)}:#{opts.destination_port}"
    )

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    # Open UDP socket for sending
    case :gen_udp.open(0, [:binary, {:active, false}]) do
      {:ok, socket} ->
        Logger.debug("ForkSink [#{state.fork_id}]: UDP socket opened")
        {[], %{state | socket: socket}}

      {:error, reason} ->
        Logger.error("ForkSink [#{state.fork_id}]: Failed to open UDP socket: #{inspect(reason)}")
        {[], state}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case state.socket do
      nil ->
        # No socket available, skip sending
        Logger.warning("ForkSink [#{state.fork_id}]: No socket available, dropping packet")
        {[], %{state | errors: state.errors + 1}}

      socket ->
        case :gen_udp.send(
               socket,
               state.destination_address,
               state.destination_port,
               buffer.payload
             ) do
          :ok ->
            {[], %{state | packets_sent: state.packets_sent + 1}}

          {:error, reason} ->
            # Log but don't crash - network errors shouldn't affect main call
            if state.errors < 10 or rem(state.errors, 100) == 0 do
              Logger.warning(
                "ForkSink [#{state.fork_id}]: Send error (#{state.errors + 1} total): #{inspect(reason)}"
              )
            end

            {[], %{state | errors: state.errors + 1}}
        end
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    Logger.info(
      "ForkSink [#{state.fork_id}]: End of stream. Sent #{state.packets_sent} packets, #{state.errors} errors"
    )

    {[], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    cleanup(state)
    {[terminate: :normal], state}
  end

  # Private helpers

  defp cleanup(state) do
    if state.socket do
      :gen_udp.close(state.socket)
      Logger.debug("ForkSink [#{state.fork_id}]: Socket closed")
    end
  end

  defp format_address(address) when is_tuple(address) do
    address |> Tuple.to_list() |> Enum.join(".")
  end

  defp format_address(address) when is_binary(address), do: address
end
