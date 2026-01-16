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
  """

  use Membrane.Source

  require Logger

  alias Membrane.Buffer
  alias Membrane.RawAudio

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

  # Frame duration in milliseconds (typical for 320 bytes at 16kHz)
  @frame_duration_ms 20
  # Frame duration in nanoseconds for Membrane.Time
  @frame_duration 20_000_000
  # Maximum buffer size to prevent unbounded growth
  @max_buffer_frames 10

  @impl true
  def handle_init(_ctx, opts) do
    target_frames = max(1, div(opts.jitter_buffer_ms, @frame_duration_ms))

    state = %{
      connector_pid: opts.connector_pid,
      jitter_buffer: :queue.new(),
      jitter_buffer_ms: opts.jitter_buffer_ms,
      sample_rate: opts.sample_rate,
      frames_received: 0,
      frames_pushed: 0,
      buffer_ready: false,
      pts: 0,
      frame_duration_ms: @frame_duration_ms,
      frame_duration: @frame_duration,
      target_frames: target_frames,
      max_buffer_frames: @max_buffer_frames,
      connection_state: :disconnected
    }

    Logger.debug(
      "WsBidirectional.Source: Initializing with connector #{inspect(opts.connector_pid)}, " <>
        "target_frames=#{target_frames}"
    )

    # Register with connector if provided
    if opts.connector_pid do
      send(opts.connector_pid, {:register_source, self()})
    end

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # Send stream format to downstream elements
    stream_format = %RawAudio{
      sample_format: :s16le,
      sample_rate: state.sample_rate,
      channels: 1
    }

    {[stream_format: {:output, stream_format}], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    # Push buffered audio if buffer is ready
    if state.buffer_ready do
      push_buffers(state, size)
    else
      # Buffer not ready yet, return empty actions
      {[], state}
    end
  end

  @impl true
  def handle_info({:source_audio, audio_data}, _ctx, state) do
    # Create a frame struct with the audio payload
    frame = %{payload: audio_data}

    # Queue the frame in the jitter buffer
    new_buffer = :queue.in(frame, state.jitter_buffer)

    # Increment frames received counter
    new_frames_received = state.frames_received + 1

    # Get target_frames from state or calculate from jitter_buffer_ms
    target_frames = get_target_frames(state)

    # Get max_buffer_frames from state or use default
    max_buffer_frames = Map.get(state, :max_buffer_frames, @max_buffer_frames)

    # Check if buffer is ready (has enough frames)
    buffer_len = :queue.len(new_buffer)
    new_buffer_ready = buffer_len >= target_frames

    # Handle buffer overflow - drop oldest frames if exceeding max
    {final_buffer, dropped} = trim_buffer(new_buffer, max_buffer_frames)

    if dropped > 0 do
      Logger.warning("WsBidirectional.Source: Buffer overflow, dropped #{dropped} oldest frames")
    end

    new_state = %{
      state
      | jitter_buffer: final_buffer,
        frames_received: new_frames_received,
        buffer_ready: new_buffer_ready
    }

    {[], new_state}
  end

  @impl true
  def handle_info({:connection_state, new_connection_state}, _ctx, state) do
    Logger.debug("WsBidirectional.Source: Connection state changed to #{new_connection_state}")

    new_state = %{state | connection_state: new_connection_state}

    {[], new_state}
  end

  @impl true
  def handle_info(_msg, _ctx, state) do
    # Ignore unknown messages
    {[], state}
  end

  # Private helper functions

  # Log buffer underrun warning
  defp log_buffer_underrun do
    Logger.warning("WsBidirectional.Source: Buffer underrun - buffer empty")
  end

  # Get target_frames from state, with fallback calculation
  defp get_target_frames(state) do
    case Map.get(state, :target_frames) do
      nil ->
        jitter_buffer_ms = Map.get(state, :jitter_buffer_ms, 60)
        frame_duration_ms = Map.get(state, :frame_duration_ms, @frame_duration_ms)
        max(1, div(jitter_buffer_ms, frame_duration_ms))

      target ->
        target
    end
  end

  # Get frame_duration from state, with fallback calculation
  defp get_frame_duration(state) do
    case Map.get(state, :frame_duration) do
      nil ->
        frame_duration_ms = Map.get(state, :frame_duration_ms, @frame_duration_ms)
        frame_duration_ms * 1_000_000

      duration ->
        duration
    end
  end

  # Push up to `count` buffers from the jitter buffer
  defp push_buffers(state, count) do
    buffer_len = :queue.len(state.jitter_buffer)

    if buffer_len == 0 do
      # Buffer underrun - log warning
      log_buffer_underrun()
      {[], state}
    else
      # Determine how many buffers to actually push
      to_push = min(count, buffer_len)

      frame_duration = get_frame_duration(state)

      {actions, new_buffer, new_pts, pushed_count} =
        pop_and_create_buffers(state.jitter_buffer, state.pts, frame_duration, to_push)

      frames_pushed = Map.get(state, :frames_pushed, 0)

      new_state =
        state
        |> Map.put(:jitter_buffer, new_buffer)
        |> Map.put(:pts, new_pts)
        |> Map.put(:frames_pushed, frames_pushed + pushed_count)

      {actions, new_state}
    end
  end

  # Pop frames from queue and create buffer actions
  defp pop_and_create_buffers(queue, pts, frame_duration, count) do
    pop_and_create_buffers(queue, pts, frame_duration, count, [], 0)
  end

  defp pop_and_create_buffers(queue, pts, _frame_duration, 0, actions, pushed) do
    {Enum.reverse(actions), queue, pts, pushed}
  end

  defp pop_and_create_buffers(queue, pts, frame_duration, remaining, actions, pushed) do
    case :queue.out(queue) do
      {{:value, frame}, new_queue} ->
        buffer = %Buffer{
          payload: frame.payload,
          pts: pts
        }

        action = {:buffer, {:output, buffer}}
        new_pts = pts + frame_duration

        pop_and_create_buffers(
          new_queue,
          new_pts,
          frame_duration,
          remaining - 1,
          [action | actions],
          pushed + 1
        )

      {:empty, queue} ->
        # Queue is empty, return what we have
        {Enum.reverse(actions), queue, pts, pushed}
    end
  end

  # Trim buffer to max_size by dropping oldest frames
  defp trim_buffer(queue, max_size) do
    len = :queue.len(queue)

    if len <= max_size do
      {queue, 0}
    else
      to_drop = len - max_size
      drop_oldest(queue, to_drop)
    end
  end

  defp drop_oldest(queue, 0), do: {queue, 0}

  defp drop_oldest(queue, count) do
    case :queue.out(queue) do
      {{:value, _}, new_queue} ->
        {final_queue, dropped} = drop_oldest(new_queue, count - 1)
        {final_queue, dropped + 1}

      {:empty, queue} ->
        {queue, 0}
    end
  end
end
