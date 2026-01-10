defmodule ParrotMedia.WsBidirectional.Source do
  @moduledoc """
  Membrane Source element for receiving audio from a WsBidirectional.Connector.

  WsBidirectional.Source receives audio messages from a Connector GenServer and
  pushes them as Membrane buffers to the pipeline for playback. It includes a
  jitter buffer to smooth out network timing variations.

  ## Pipeline Integration

  The Source is designed to be part of a bidirectional audio pipeline:

      # In a pipeline spec
      child(:ws_source, %Source{connector_pid: connector_pid, jitter_buffer_ms: 60})
      |> child(:decoder, SomeDecoder)
      |> child(:sink, AudioSink)

  ## Message Format

  The Source receives audio from the Connector in the format:

      {:source_audio, payload}

  Where `payload` is the raw audio bytes (binary).

  ## Jitter Buffer

  The Source implements a jitter buffer to handle network timing variations:
  - Configurable target delay via `jitter_buffer_ms` (default: 60ms)
  - Uses Erlang :queue for FIFO buffering
  - Starts playback only after buffer reaches target delay
  - Logs warning on buffer underrun

  ## Connection State

  The Source tracks connection state changes:

      {:connection_state, :connected | :disconnected}

  ## Registration

  On initialization, the Source registers with the Connector by sending:

      {:register_source, self()}

  ## STUB IMPLEMENTATION

  This module is a stub for TDD. The implementation is incomplete.
  Tests should fail until this is properly implemented.
  """

  use Membrane.Source

  require Logger

  alias Membrane.RawAudio
  # Buffer alias will be needed for implementation:
  # alias Membrane.Buffer

  def_output_pad(:output,
    flow_control: :push,
    accepted_format: RawAudio
  )

  def_options(
    connector_pid: [
      spec: pid() | nil,
      default: nil,
      description: "PID of WsBidirectional.Connector to receive audio from"
    ],
    jitter_buffer_ms: [
      spec: pos_integer(),
      default: 60,
      description: "Jitter buffer target delay in milliseconds"
    ],
    sample_rate: [
      spec: pos_integer(),
      default: 16000,
      description: "Audio sample rate in Hz"
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    # STUB: Partially implemented - needs registration and proper state
    state = %{
      connector_pid: opts.connector_pid,
      jitter_buffer: :queue.new(),
      jitter_buffer_ms: opts.jitter_buffer_ms,
      sample_rate: opts.sample_rate,
      frames_received: 0,
      frames_pushed: 0,
      buffer_ready: false,
      pts: 0,
      frame_duration_ms: 20,
      frame_duration: 20_000_000,
      target_frames: div(opts.jitter_buffer_ms, 20),
      max_buffer_frames: 50,
      connection_state: :disconnected
    }

    Logger.debug(
      "WsBidirectional.Source: Initializing with connector #{inspect(opts.connector_pid)}"
    )

    # STUB: Should register with connector but doesn't yet
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # STUB: Not implemented - should send stream_format
    {[], state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    # STUB: Not implemented - should push buffered audio
    {[], state}
  end

  @impl true
  def handle_info({:source_audio, _audio_data}, _ctx, state) do
    # STUB: Not implemented - should queue audio in jitter buffer
    {[], state}
  end

  @impl true
  def handle_info({:connection_state, _new_state}, _ctx, state) do
    # STUB: Not implemented - should update connection state
    {[], state}
  end

  @impl true
  def handle_info(_msg, _ctx, state) do
    # Ignore unknown messages
    {[], state}
  end
end
