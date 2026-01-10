defmodule ParrotMedia.MOS.Score do
  @moduledoc """
  A single MOS (Mean Opinion Score) measurement with contributing metrics.

  MOS scores range from 1.0 to 5.0, where:
  - 5.0: Excellent quality (imperceptible degradation)
  - 4.0: Good quality (perceptible but not annoying)
  - 3.0: Fair quality (slightly annoying)
  - 2.0: Poor quality (annoying)
  - 1.0: Bad quality (very annoying)

  Quality levels are derived from the MOS value:
  - `:excellent` when value >= 4.0
  - `:good` when value >= 3.5
  - `:fair` when value >= 3.0
  - `:poor` when value < 3.0
  - `:insufficient_data` when explicitly set (not enough samples to calculate)
  """

  @type t :: %__MODULE__{
          value: float(),
          timestamp: DateTime.t(),
          packet_loss_percent: float() | nil,
          jitter_ms: float() | nil,
          delay_ms: float() | nil,
          r_factor: float() | nil,
          quality_level: quality_level() | nil
        }

  @type quality_level :: :excellent | :good | :fair | :poor | :insufficient_data

  @enforce_keys [:value, :timestamp]
  defstruct [
    :value,
    :timestamp,
    :packet_loss_percent,
    :jitter_ms,
    :delay_ms,
    :r_factor,
    :quality_level
  ]

  @doc """
  Creates a new Score from keyword options.

  Required fields:
  - `:value` - MOS score (1.0-5.0)
  - `:timestamp` - DateTime when score was calculated

  Optional fields:
  - `:packet_loss_percent` - Packet loss percentage (0.0-100.0)
  - `:jitter_ms` - Interarrival jitter in milliseconds (>= 0)
  - `:delay_ms` - One-way delay in milliseconds (>= 0)
  - `:r_factor` - E-model R-factor (0-100)
  - `:quality_level` - Explicitly set quality level (overrides derived value)

  Returns `{:ok, score}` on success or `{:error, reason}` on validation failure.

  ## Examples

      iex> Score.new(value: 4.0, timestamp: DateTime.utc_now())
      {:ok, %Score{value: 4.0, quality_level: :excellent, ...}}

      iex> Score.new(value: 0.5, timestamp: DateTime.utc_now())
      {:error, :value_out_of_range}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, value} <- validate_value(opts),
         {:ok, timestamp} <- validate_timestamp(opts),
         {:ok, packet_loss_percent} <- validate_packet_loss_percent(opts),
         {:ok, jitter_ms} <- validate_jitter_ms(opts),
         {:ok, delay_ms} <- validate_delay_ms(opts),
         {:ok, r_factor} <- validate_r_factor(opts) do
      quality_level = get_quality_level(opts, value)

      score = %__MODULE__{
        value: value,
        timestamp: timestamp,
        packet_loss_percent: packet_loss_percent,
        jitter_ms: jitter_ms,
        delay_ms: delay_ms,
        r_factor: r_factor,
        quality_level: quality_level
      }

      {:ok, score}
    end
  end

  @doc """
  Derives quality level from a MOS value.

  Returns:
  - `:excellent` when value >= 4.0
  - `:good` when value >= 3.5
  - `:fair` when value >= 3.0
  - `:poor` when value < 3.0

  ## Examples

      iex> Score.quality_level_for(4.5)
      :excellent

      iex> Score.quality_level_for(3.7)
      :good

      iex> Score.quality_level_for(3.2)
      :fair

      iex> Score.quality_level_for(2.5)
      :poor
  """
  @spec quality_level_for(number()) :: :excellent | :good | :fair | :poor
  def quality_level_for(value) when value >= 4.0, do: :excellent
  def quality_level_for(value) when value >= 3.5, do: :good
  def quality_level_for(value) when value >= 3.0, do: :fair
  def quality_level_for(_value), do: :poor

  # Private validation functions

  defp validate_value(opts) do
    case Keyword.fetch(opts, :value) do
      {:ok, nil} ->
        {:error, :missing_value}

      {:ok, value} when is_number(value) and value >= 1.0 and value <= 5.0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, :value_out_of_range}

      :error ->
        {:error, :missing_value}
    end
  end

  defp validate_timestamp(opts) do
    case Keyword.fetch(opts, :timestamp) do
      {:ok, nil} ->
        {:error, :missing_timestamp}

      {:ok, %DateTime{} = timestamp} ->
        {:ok, timestamp}

      :error ->
        {:error, :missing_timestamp}
    end
  end

  defp validate_packet_loss_percent(opts) do
    case Keyword.fetch(opts, :packet_loss_percent) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_number(value) and value >= 0.0 and value <= 100.0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, :packet_loss_percent_out_of_range}

      :error ->
        {:ok, nil}
    end
  end

  defp validate_jitter_ms(opts) do
    case Keyword.fetch(opts, :jitter_ms) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_number(value) and value >= 0.0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, :jitter_ms_out_of_range}

      :error ->
        {:ok, nil}
    end
  end

  defp validate_delay_ms(opts) do
    case Keyword.fetch(opts, :delay_ms) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_number(value) and value >= 0.0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, :delay_ms_out_of_range}

      :error ->
        {:ok, nil}
    end
  end

  # Per ITU-T G.107, R-factor should be in the range 0-100
  defp validate_r_factor(opts) do
    case Keyword.fetch(opts, :r_factor) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_number(value) and value >= 0.0 and value <= 100.0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, :r_factor_out_of_range}

      :error ->
        {:ok, nil}
    end
  end

  defp get_quality_level(opts, value) do
    case Keyword.fetch(opts, :quality_level) do
      {:ok, :insufficient_data} -> :insufficient_data
      _ -> quality_level_for(value)
    end
  end
end
