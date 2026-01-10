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

  ## STUB IMPLEMENTATION

  This module is a stub for TDD. The implementation is incomplete.
  Tests should fail until this is properly implemented.
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
  def handle_buffer(:input, _buffer, _ctx, state) do
    # STUB: Not implemented - should forward buffer payload to connector
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # STUB: Not implemented - may notify connector of playing state
    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    # STUB: Not implemented - should notify connector of end of stream
    {[], state}
  end
end
