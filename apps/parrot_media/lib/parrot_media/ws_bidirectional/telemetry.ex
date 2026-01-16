defmodule ParrotMedia.WsBidirectional.Telemetry do
  @moduledoc """
  Telemetry events for bidirectional WebSocket connections.

  ## Events

  ### Connection Events
  - `[:parrot_media, :ws_bidirectional, :connect, :start]` - Connection attempt started
  - `[:parrot_media, :ws_bidirectional, :connect, :stop]` - Connection established
  - `[:parrot_media, :ws_bidirectional, :disconnect]` - Connection closed

  ### Audio Events
  - `[:parrot_media, :ws_bidirectional, :audio, :stats]` - Periodic audio statistics
  - `[:parrot_media, :ws_bidirectional, :audio, :frame_dropped]` - Frame(s) dropped

  ## Usage

  Attach handlers to these events to collect metrics and logs:

      :telemetry.attach(
        "my-handler",
        [:parrot_media, :ws_bidirectional, :connect, :stop],
        fn name, measurements, metadata, config ->
          # Handle the event
        end,
        nil
      )

  ## Measurements

  ### connect:start
  - `monotonic_time` - System monotonic time at connection start
  - `system_time` - System time at connection start

  ### connect:stop
  - `duration` - Time elapsed since connect:start in native time units

  ### disconnect
  - `duration` - Total connection duration in native time units

  ### audio:stats
  - `frames_sent` - Total frames sent to WebSocket
  - `frames_received` - Total frames received from WebSocket
  - `frames_dropped` - Total frames dropped due to buffer overflow
  - `buffer_size` - Current buffer size

  ### audio:frame_dropped
  - `count` - Number of frames dropped in this event

  ## Metadata

  All events include:
  - `connection_id` - Unique identifier for the connection

  Additional metadata by event:
  - `connect:start` - `url` (WebSocket URL)
  - `connect:stop` - `status` (`:ok` or `:connected`)
  - `disconnect` - `reason` (disconnect reason)
  """

  @prefix [:parrot_media, :ws_bidirectional]

  @doc """
  Emit connect:start event when connection attempt begins.

  Returns the monotonic start time for use with `connect_stop/2`.
  """
  @spec connect_start(map()) :: integer()
  def connect_start(metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      @prefix ++ [:connect, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      metadata
    )

    start_time
  end

  @doc """
  Emit connect:stop event when connection is successfully established.
  """
  @spec connect_stop(map(), integer()) :: :ok
  def connect_stop(metadata, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      @prefix ++ [:connect, :stop],
      %{duration: duration},
      Map.merge(metadata, %{status: :ok, result: :connected})
    )
  end

  @doc """
  Emit disconnect event when connection is closed.
  """
  @spec disconnect(map(), integer(), term()) :: :ok
  def disconnect(metadata, duration, reason) do
    :telemetry.execute(
      @prefix ++ [:disconnect],
      %{duration: duration},
      Map.put(metadata, :reason, reason)
    )
  end

  @doc """
  Emit audio:stats event with current statistics.
  """
  @spec audio_stats(map(), map()) :: :ok
  def audio_stats(metadata, stats) do
    :telemetry.execute(
      @prefix ++ [:audio, :stats],
      stats,
      metadata
    )
  end

  @doc """
  Emit audio:frame_dropped event when frames are dropped.
  """
  @spec frame_dropped(map(), non_neg_integer()) :: :ok
  def frame_dropped(metadata, count) do
    :telemetry.execute(
      @prefix ++ [:audio, :frame_dropped],
      %{count: count},
      metadata
    )
  end
end
