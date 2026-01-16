defmodule ParrotMedia.WsBidirectional.Sink do
  @moduledoc """
  Membrane Sink element for forwarding audio to a WsBidirectional.Connector.

  WsBidirectional.Sink receives audio buffers from a Membrane pipeline and
  forwards them via message passing to a Connector GenServer, which handles
  WebSocket transmission to external AI services.

  ## Pipeline Integration

  The Sink is designed to be part of a bidirectional audio pipeline:

      # In a pipeline spec
      child(:source, AudioSource)
      |> child(:encoder, SomeEncoder)
      |> child(:ws_sink, %Sink{connector_pid: connector_pid})

  ## Message Format

  The Sink sends audio to the Connector in the format:

      {:sink_audio, payload}

  Where `payload` is the raw audio bytes (binary).

  ## End of Stream

  When the stream ends, the Sink sends:

      {:sink_end_of_stream, %{frames_sent: count}}

  This notifies the Connector that no more audio will be sent from this Sink.

  ## Error Handling

  The Sink handles errors gracefully:
  - If connector_pid is nil, audio is dropped (logged at debug level)
  - If connector_pid becomes unavailable, audio is still sent (Erlang semantics)
  - Pipeline errors should NOT crash the main call flow
  """

  use Membrane.Sink

  require Logger

  def_input_pad(:input,
    flow_control: :push,
    accepted_format: _any
  )

  def_options(
    connector_pid: [
      spec: pid() | nil,
      default: nil,
      description: "PID of WsBidirectional.Connector to forward audio to"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      connector_pid: opts.connector_pid,
      frames_sent: 0
    }

    Logger.debug("WsBidirectional.Sink: Initializing with connector #{inspect(opts.connector_pid)}")

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case state.connector_pid do
      nil ->
        Logger.debug("WsBidirectional.Sink: No connector_pid, dropping audio frame")
        {[], state}

      pid when is_pid(pid) ->
        send(pid, {:sink_audio, buffer.payload})
        {[], %{state | frames_sent: state.frames_sent + 1}}
    end
  end

  @impl true
  def handle_playing(_ctx, state) do
    Logger.debug("WsBidirectional.Sink: Pipeline now playing")
    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    case state.connector_pid do
      nil ->
        Logger.debug("WsBidirectional.Sink: End of stream, no connector to notify")

      pid when is_pid(pid) ->
        Logger.debug("WsBidirectional.Sink: End of stream, notifying connector")
        send(pid, {:sink_end_of_stream, %{frames_sent: state.frames_sent}})
    end

    {[], state}
  end
end
