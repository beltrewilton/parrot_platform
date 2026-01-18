defmodule ParrotMedia.MOS.CallSummary do
  @moduledoc """
  Per-call quality summary containing aggregate MOS statistics.

  The CallSummary struct is created at the end of a media session to provide
  a comprehensive view of call quality over the entire call duration.

  ## Fields

  - `:session_id` - Unique identifier for the media session
  - `:min_mos` - Minimum MOS score observed during the call (1.0-5.0)
  - `:max_mos` - Maximum MOS score observed during the call (1.0-5.0)
  - `:avg_mos` - Average MOS score over all calculated intervals (1.0-5.0)
  - `:total_packets` - Total number of packets expected during the call
  - `:total_lost` - Total number of packets lost during the call
  - `:overall_loss_percent` - Derived: (total_lost / total_packets) * 100
  - `:quality_events` - List of threshold crossing events with timestamps
  - `:intervals_calculated` - Number of MOS calculation intervals completed
  - `:duration_ms` - Total call duration in milliseconds
  - `:status` - Call quality status:
    - `:complete` - Normal call with sufficient data for MOS calculation
    - `:insufficient_data` - Not enough packets/samples for meaningful MOS
    - `:one_way_audio` - Only one direction of audio was received

  ## Status Values

  - `:complete` - A normal call that completed with sufficient data for MOS calculation
  - `:insufficient_data` - The call was too short or received too few packets
  - `:one_way_audio` - Only one direction of audio stream was active

  ## Example

      {:ok, summary} = CallSummary.new(
        session_id: "call-123",
        min_mos: 3.5,
        max_mos: 4.3,
        avg_mos: 3.9,
        total_packets: 5000,
        total_lost: 50,
        intervals_calculated: 10,
        duration_ms: 50_000,
        status: :complete,
        quality_events: [
          %{type: :threshold_crossed, mos: 2.9, threshold: 3.0, timestamp: ~U[...]}
        ]
      )
  """

  @type status :: :complete | :insufficient_data | :one_way_audio

  @type quality_event :: %{
          optional(:direction) => :up | :down,
          type: :threshold_crossed,
          mos: float(),
          threshold: float(),
          timestamp: DateTime.t()
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          min_mos: float(),
          max_mos: float(),
          avg_mos: float(),
          total_packets: non_neg_integer(),
          total_lost: non_neg_integer(),
          overall_loss_percent: float(),
          quality_events: [quality_event()],
          intervals_calculated: non_neg_integer(),
          duration_ms: non_neg_integer(),
          status: status()
        }

  @enforce_keys [
    :session_id,
    :min_mos,
    :max_mos,
    :avg_mos,
    :total_packets,
    :total_lost,
    :overall_loss_percent,
    :intervals_calculated,
    :duration_ms,
    :status
  ]

  defstruct [
    :session_id,
    :min_mos,
    :max_mos,
    :avg_mos,
    :total_packets,
    :total_lost,
    :overall_loss_percent,
    :intervals_calculated,
    :duration_ms,
    :status,
    quality_events: []
  ]

  @valid_statuses [:complete, :insufficient_data, :one_way_audio]

  @doc """
  Creates a new CallSummary from keyword options.

  Required fields:
  - `:session_id` - Session identifier (non-nil string)
  - `:min_mos` - Minimum MOS (1.0-5.0)
  - `:max_mos` - Maximum MOS (1.0-5.0)
  - `:avg_mos` - Average MOS (1.0-5.0)
  - `:total_packets` - Total packets (>= 0)
  - `:total_lost` - Total lost packets (>= 0)
  - `:intervals_calculated` - Number of intervals (>= 0)
  - `:duration_ms` - Call duration in milliseconds (>= 0)
  - `:status` - One of :complete, :insufficient_data, or :one_way_audio

  Optional fields:
  - `:quality_events` - List of quality events (defaults to [])

  The `overall_loss_percent` is automatically calculated from total_packets
  and total_lost.

  Returns `{:ok, summary}` on success or `{:error, reason}` on validation failure.

  ## Examples

      iex> CallSummary.new(session_id: "test-123", min_mos: 3.5, max_mos: 4.0, avg_mos: 3.8, total_packets: 1000, total_lost: 50, intervals_calculated: 5, duration_ms: 25000, status: :complete)
      {:ok, %CallSummary{session_id: "test-123", overall_loss_percent: 5.0, ...}}

      iex> CallSummary.new(session_id: nil, min_mos: 3.5, max_mos: 4.0, avg_mos: 3.8, total_packets: 1000, total_lost: 50, intervals_calculated: 5, duration_ms: 25000, status: :complete)
      {:error, :missing_session_id}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, session_id} <- validate_session_id(opts),
         {:ok, min_mos} <- validate_mos(opts, :min_mos),
         {:ok, max_mos} <- validate_mos(opts, :max_mos),
         {:ok, avg_mos} <- validate_mos(opts, :avg_mos),
         {:ok, total_packets} <- validate_non_neg_integer(opts, :total_packets),
         {:ok, total_lost} <- validate_non_neg_integer(opts, :total_lost),
         {:ok, intervals_calculated} <- validate_non_neg_integer(opts, :intervals_calculated),
         {:ok, duration_ms} <- validate_non_neg_integer(opts, :duration_ms),
         {:ok, status} <- validate_status(opts),
         {:ok, quality_events} <- validate_quality_events(opts),
         :ok <- validate_mos_ordering(min_mos, avg_mos, max_mos),
         :ok <- validate_packet_counts(total_packets, total_lost) do
      overall_loss_percent = calculate_loss_percent(total_packets, total_lost)

      summary = %__MODULE__{
        session_id: session_id,
        min_mos: min_mos,
        max_mos: max_mos,
        avg_mos: avg_mos,
        total_packets: total_packets,
        total_lost: total_lost,
        overall_loss_percent: overall_loss_percent,
        quality_events: quality_events,
        intervals_calculated: intervals_calculated,
        duration_ms: duration_ms,
        status: status
      }

      {:ok, summary}
    end
  end

  # Private validation functions

  defp validate_session_id(opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, nil} ->
        {:error, :missing_session_id}

      {:ok, session_id} when is_binary(session_id) ->
        {:ok, session_id}

      :error ->
        {:error, :missing_session_id}
    end
  end

  defp validate_mos(opts, key) do
    error_key = :"#{key}_out_of_range"

    case Keyword.fetch(opts, key) do
      {:ok, nil} ->
        {:error, error_key}

      {:ok, value} when is_number(value) and value >= 1.0 and value <= 5.0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, error_key}

      :error ->
        {:error, error_key}
    end
  end

  defp validate_non_neg_integer(opts, key) do
    error_key = :"#{key}_out_of_range"

    case Keyword.fetch(opts, key) do
      {:ok, nil} ->
        {:error, error_key}

      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, error_key}

      :error ->
        {:error, error_key}
    end
  end

  defp validate_status(opts) do
    case Keyword.fetch(opts, :status) do
      {:ok, nil} ->
        {:error, :missing_status}

      {:ok, status} when status in @valid_statuses ->
        {:ok, status}

      {:ok, _status} ->
        {:error, :invalid_status}

      :error ->
        {:error, :missing_status}
    end
  end

  defp validate_quality_events(opts) do
    case Keyword.fetch(opts, :quality_events) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, events} when is_list(events) ->
        {:ok, events}

      {:ok, _non_list} ->
        {:error, :invalid_quality_events}

      :error ->
        {:ok, []}
    end
  end

  defp validate_mos_ordering(min_mos, avg_mos, max_mos) do
    cond do
      min_mos > max_mos ->
        {:error, :min_mos_exceeds_max_mos}

      min_mos > avg_mos ->
        {:error, :min_mos_exceeds_avg_mos}

      avg_mos > max_mos ->
        {:error, :avg_mos_exceeds_max_mos}

      true ->
        :ok
    end
  end

  defp validate_packet_counts(total_packets, total_lost) do
    if total_lost > total_packets do
      {:error, :total_lost_exceeds_total_packets}
    else
      :ok
    end
  end

  defp calculate_loss_percent(0, _total_lost), do: 0.0

  defp calculate_loss_percent(total_packets, total_lost) do
    total_lost / total_packets * 100.0
  end
end
