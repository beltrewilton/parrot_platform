defmodule ParrotMedia.MOS.Telemetry do
  @moduledoc """
  Telemetry event emission for MOS scoring.

  This module provides functions to emit telemetry events for MOS scoring,
  allowing external systems to monitor call quality in real-time.

  ## Events

  ### `[:parrot_media, :mos, :score]`

  Emitted each calculation interval with the current MOS score.

  Measurements:
  - `:mos_score` - MOS value (1.0-5.0)
  - `:r_factor` - E-model R-factor (0-100)
  - `:packet_loss_percent` - Packet loss (0.0-100.0)
  - `:jitter_ms` - Jitter in milliseconds
  - `:delay_ms` - Estimated delay in milliseconds
  - `:interval_duration_ms` - Interval duration

  Metadata:
  - `:session_id` - Media session identifier
  - `:call_id` - Optional call identifier
  - `:codec` - Codec in use
  - `:direction` - Stream direction (:inbound, :outbound)

  ### `[:parrot_media, :mos, :threshold_crossed]`

  Emitted when MOS crosses a configured threshold.

  Measurements:
  - `:mos_score` - Current MOS value
  - `:previous_score` - Previous MOS value
  - `:threshold` - Threshold value crossed

  Metadata:
  - `:session_id` - Media session identifier
  - `:call_id` - Optional call identifier
  - `:threshold_name` - Threshold name (:excellent, :good, :fair)
  - `:direction` - Crossing direction (:falling, :rising)

  ### `[:parrot_media, :mos, :call_summary]`

  Emitted when a call ends with aggregate statistics.

  Measurements:
  - `:min_mos` - Minimum MOS during call
  - `:max_mos` - Maximum MOS during call
  - `:avg_mos` - Average MOS during call
  - `:total_packets` - Total packets received
  - `:total_lost` - Total packets lost
  - `:overall_loss_percent` - Overall packet loss percentage
  - `:quality_events_count` - Number of threshold crossings
  - `:call_duration_ms` - Call duration in milliseconds
  - `:intervals_calculated` - Number of MOS calculations performed

  Metadata:
  - `:session_id` - Media session identifier
  - `:call_id` - Optional call identifier
  - `:codec` - Codec used
  - `:status` - Summary status (:complete, :insufficient_data)

  ## Attaching Handlers

      :telemetry.attach(
        "my-mos-metrics",
        [:parrot_media, :mos, :score],
        fn event, measurements, metadata, _config ->
          # Export to Prometheus, StatsD, etc.
          MyMetrics.record_mos(metadata.session_id, measurements.mos_score)
        end,
        nil
      )
  """

  alias ParrotMedia.MOS.Score
  alias ParrotMedia.MOS.Interval
  alias ParrotMedia.MOS.Threshold

  @score_event [:parrot_media, :mos, :score]
  @threshold_event [:parrot_media, :mos, :threshold_crossed]
  @summary_event [:parrot_media, :mos, :call_summary]

  @doc """
  Returns all MOS telemetry event names.

  ## Example

      iex> Telemetry.events()
      [
        [:parrot_media, :mos, :score],
        [:parrot_media, :mos, :threshold_crossed],
        [:parrot_media, :mos, :call_summary]
      ]
  """
  @spec events() :: [list(atom())]
  def events, do: [@score_event, @threshold_event, @summary_event]

  @doc """
  Returns the score event name.

  ## Example

      iex> Telemetry.score_event()
      [:parrot_media, :mos, :score]
  """
  @spec score_event() :: list(atom())
  def score_event, do: @score_event

  @doc """
  Returns the threshold crossed event name.

  ## Example

      iex> Telemetry.threshold_event()
      [:parrot_media, :mos, :threshold_crossed]
  """
  @spec threshold_event() :: list(atom())
  def threshold_event, do: @threshold_event

  @doc """
  Returns the call summary event name.

  ## Example

      iex> Telemetry.summary_event()
      [:parrot_media, :mos, :call_summary]
  """
  @spec summary_event() :: list(atom())
  def summary_event, do: @summary_event

  @doc """
  Emits a MOS score telemetry event.

  Called by the Calculator each calculation interval with the computed
  MOS score and the interval metrics used for the calculation.

  ## Parameters

  - `score` - The calculated `Score` struct
  - `interval` - The `Interval` struct with aggregated metrics
  - `opts` - Keyword list with metadata:
    - `:session_id` - Required media session identifier
    - `:call_id` - Optional call identifier
    - `:codec` - Codec in use (e.g., :g711, :opus)
    - `:direction` - Stream direction (:inbound, :outbound)

  ## Example

      {:ok, score} = Score.new(value: 4.2, timestamp: DateTime.utc_now(), ...)
      interval = Interval.new() |> Interval.complete()
      Telemetry.emit_score(score, interval, session_id: "session-123", codec: :g711)
  """
  @spec emit_score(Score.t(), Interval.t(), keyword()) :: :ok
  def emit_score(%Score{} = score, %Interval{} = interval, opts \\ []) do
    measurements = %{
      mos_score: score.value,
      r_factor: score.r_factor,
      packet_loss_percent: score.packet_loss_percent,
      jitter_ms: score.jitter_ms,
      delay_ms: score.delay_ms,
      interval_duration_ms: interval.duration_ms
    }

    metadata = %{
      session_id: Keyword.get(opts, :session_id),
      call_id: Keyword.get(opts, :call_id),
      codec: Keyword.get(opts, :codec),
      direction: Keyword.get(opts, :direction)
    }

    :telemetry.execute(@score_event, measurements, metadata)
  end

  @doc """
  Emits a threshold crossed telemetry event.

  Called by the Calculator when the MOS score crosses a configured threshold,
  taking into account hysteresis to prevent event flapping.

  ## Parameters

  - `current_mos` - The current MOS score that triggered the crossing
  - `previous_mos` - The previous MOS score before the crossing
  - `threshold` - The `Threshold` struct that was crossed
  - `opts` - Keyword list with metadata:
    - `:session_id` - Required media session identifier
    - `:call_id` - Optional call identifier
    - `:direction` - Crossing direction (:falling, :rising)

  ## Example

      {:ok, threshold} = Threshold.new(name: :good, value: 3.5)
      Telemetry.emit_threshold_crossed(3.4, 3.7, threshold,
        session_id: "session-123",
        direction: :falling
      )
  """
  @spec emit_threshold_crossed(float(), float(), Threshold.t(), keyword()) :: :ok
  def emit_threshold_crossed(current_mos, previous_mos, %Threshold{} = threshold, opts \\ []) do
    measurements = %{
      mos_score: current_mos,
      previous_score: previous_mos,
      threshold: threshold.value
    }

    metadata = %{
      session_id: Keyword.get(opts, :session_id),
      call_id: Keyword.get(opts, :call_id),
      threshold_name: threshold.name,
      direction: Keyword.get(opts, :direction)
    }

    :telemetry.execute(@threshold_event, measurements, metadata)
  end

  @doc """
  Emits a call summary telemetry event.

  Called when a call ends to emit aggregate quality statistics for the
  entire call duration.

  ## Parameters

  - `summary` - Map with summary measurements:
    - `:min_mos` - Minimum MOS during call (nil if insufficient data)
    - `:max_mos` - Maximum MOS during call (nil if insufficient data)
    - `:avg_mos` - Average MOS during call (nil if insufficient data)
    - `:total_packets` - Total packets received
    - `:total_lost` - Total packets lost
    - `:overall_loss_percent` - Overall packet loss percentage
    - `:quality_events_count` - Number of threshold crossings
    - `:call_duration_ms` - Call duration in milliseconds
    - `:intervals_calculated` - Number of MOS calculations performed
  - `opts` - Keyword list with metadata:
    - `:session_id` - Required media session identifier
    - `:call_id` - Optional call identifier
    - `:codec` - Codec used during call
    - `:status` - Summary status (:complete, :insufficient_data)

  ## Example

      summary = %{
        min_mos: 3.2,
        max_mos: 4.5,
        avg_mos: 3.9,
        total_packets: 10_000,
        total_lost: 50,
        overall_loss_percent: 0.5,
        quality_events_count: 3,
        call_duration_ms: 300_000,
        intervals_calculated: 60
      }
      Telemetry.emit_call_summary(summary,
        session_id: "session-123",
        codec: :opus,
        status: :complete
      )
  """
  @spec emit_call_summary(map(), keyword()) :: :ok
  def emit_call_summary(summary, opts \\ []) when is_map(summary) do
    measurements = %{
      min_mos: Map.get(summary, :min_mos),
      max_mos: Map.get(summary, :max_mos),
      avg_mos: Map.get(summary, :avg_mos),
      total_packets: Map.get(summary, :total_packets),
      total_lost: Map.get(summary, :total_lost),
      overall_loss_percent: Map.get(summary, :overall_loss_percent),
      quality_events_count: Map.get(summary, :quality_events_count),
      call_duration_ms: Map.get(summary, :call_duration_ms),
      intervals_calculated: Map.get(summary, :intervals_calculated)
    }

    metadata = %{
      session_id: Keyword.get(opts, :session_id),
      call_id: Keyword.get(opts, :call_id),
      codec: Keyword.get(opts, :codec),
      status: Keyword.get(opts, :status)
    }

    :telemetry.execute(@summary_event, measurements, metadata)
  end
end
