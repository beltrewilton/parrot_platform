defmodule ParrotMedia.MOS.Threshold do
  @moduledoc """
  Quality threshold configuration with hysteresis for MOS score monitoring.

  Thresholds define boundaries for quality level changes. When MOS scores cross
  these boundaries, events are emitted to notify handlers.

  ## Hysteresis

  Hysteresis prevents rapid flapping when MOS oscillates around a threshold boundary.
  For a threshold at 3.5 with hysteresis of 0.1:
  - Falling: triggers when crossing from >= 3.6 to < 3.5
  - Rising: triggers when crossing from < 3.4 to >= 3.5

  This creates a "dead zone" around the threshold where small oscillations don't
  trigger repeated events.

  ## Direction

  The `direction` field controls which threshold crossings generate events:
  - `:falling` - Only trigger when MOS drops below threshold
  - `:rising` - Only trigger when MOS rises above threshold
  - `:both` - Trigger on both falling and rising crossings

  ## Default Thresholds

  Standard quality level thresholds based on ITU-T recommendations:
  - `:excellent` at 4.0 - Imperceptible degradation
  - `:good` at 3.5 - Perceptible but not annoying
  - `:fair` at 3.0 - Slightly annoying
  """

  @type t :: %__MODULE__{
          name: atom(),
          value: float(),
          hysteresis: float(),
          direction: :falling | :rising | :both
        }

  @enforce_keys [:name, :value]
  defstruct [
    :name,
    :value,
    hysteresis: 0.1,
    direction: :both
  ]

  @valid_directions [:falling, :rising, :both]

  @doc """
  Creates a new Threshold from keyword options.

  Required fields:
  - `:name` - Atom identifier for the threshold (e.g., :excellent, :good, :fair, :poor)
  - `:value` - MOS threshold value (1.0-5.0)

  Optional fields:
  - `:hysteresis` - Buffer zone to prevent flapping (default: 0.1, must be >= 0)
  - `:direction` - Which crossings trigger events (:falling, :rising, or :both, default: :both)

  Returns `{:ok, threshold}` on success or `{:error, reason}` on validation failure.

  ## Examples

      iex> Threshold.new(name: :good, value: 3.5)
      {:ok, %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both}}

      iex> Threshold.new(name: :custom, value: 3.8, hysteresis: 0.2, direction: :falling)
      {:ok, %Threshold{name: :custom, value: 3.8, hysteresis: 0.2, direction: :falling}}

      iex> Threshold.new(name: "invalid", value: 3.5)
      {:error, :invalid_name}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, name} <- validate_name(opts),
         {:ok, value} <- validate_value(opts),
         {:ok, hysteresis} <- validate_hysteresis(opts),
         {:ok, direction} <- validate_direction(opts) do
      threshold = %__MODULE__{
        name: name,
        value: value,
        hysteresis: hysteresis,
        direction: direction
      }

      {:ok, threshold}
    end
  end

  @doc """
  Determines if a threshold was crossed between two MOS measurements.

  Takes into account the threshold value, hysteresis buffer, and direction configuration.

  Returns `{true, :falling | :rising}` if the threshold was crossed, or `false` otherwise.

  ## Hysteresis Logic

  For a threshold at value V with hysteresis H:
  - Falling crossing: previous >= (V + H) AND current < V
  - Rising crossing: previous < (V - H) AND current >= V

  ## Examples

      iex> {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)
      iex> Threshold.crossed?(threshold, 3.6, 3.4)
      {true, :falling}

      iex> {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)
      iex> Threshold.crossed?(threshold, 3.55, 3.4)
      false  # Previous was within hysteresis buffer
  """
  @spec crossed?(t(), number(), number()) :: {true, :falling | :rising} | false
  def crossed?(%__MODULE__{} = threshold, previous_mos, current_mos)
      when is_number(previous_mos) and is_number(current_mos) do
    falling_crossed = check_falling_crossing(threshold, previous_mos, current_mos)
    rising_crossed = check_rising_crossing(threshold, previous_mos, current_mos)

    cond do
      falling_crossed and direction_allows?(threshold.direction, :falling) ->
        {true, :falling}

      rising_crossed and direction_allows?(threshold.direction, :rising) ->
        {true, :rising}

      true ->
        false
    end
  end

  @doc """
  Returns the default quality level thresholds.

  These are standard ITU-T quality levels:
  - `:excellent` at 4.0
  - `:good` at 3.5
  - `:fair` at 3.0

  ## Examples

      iex> thresholds = Threshold.default_thresholds()
      iex> length(thresholds)
      3
  """
  @spec default_thresholds() :: [t()]
  def default_thresholds do
    [
      %__MODULE__{name: :excellent, value: 4.0, hysteresis: 0.1, direction: :both},
      %__MODULE__{name: :good, value: 3.5, hysteresis: 0.1, direction: :both},
      %__MODULE__{name: :fair, value: 3.0, hysteresis: 0.1, direction: :both}
    ]
  end

  # Private validation functions

  defp validate_name(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} ->
        {:error, :missing_name}

      {:ok, name} when is_atom(name) ->
        {:ok, name}

      {:ok, _name} ->
        {:error, :invalid_name}

      :error ->
        {:error, :missing_name}
    end
  end

  defp validate_value(opts) do
    case Keyword.fetch(opts, :value) do
      {:ok, nil} ->
        {:error, :missing_value}

      {:ok, value} when is_number(value) and value >= 1.0 and value <= 5.0 ->
        {:ok, value}

      {:ok, value} when is_number(value) ->
        {:error, :value_out_of_range}

      {:ok, _value} ->
        {:error, :invalid_value}

      :error ->
        {:error, :missing_value}
    end
  end

  defp validate_hysteresis(opts) do
    case Keyword.fetch(opts, :hysteresis) do
      {:ok, value} when is_number(value) and value >= 0 ->
        {:ok, value}

      {:ok, value} when is_number(value) ->
        {:error, :hysteresis_out_of_range}

      {:ok, _value} ->
        {:error, :invalid_hysteresis}

      :error ->
        # Use default value
        {:ok, 0.1}
    end
  end

  defp validate_direction(opts) do
    case Keyword.fetch(opts, :direction) do
      {:ok, direction} when direction in @valid_directions ->
        {:ok, direction}

      {:ok, _direction} ->
        {:error, :invalid_direction}

      :error ->
        # Use default value
        {:ok, :both}
    end
  end

  # Private threshold crossing logic

  defp check_falling_crossing(%__MODULE__{value: threshold_value, hysteresis: hysteresis}, previous, current) do
    # Falling: previous must be >= (threshold + hysteresis) AND current must be < threshold
    previous >= threshold_value + hysteresis and current < threshold_value
  end

  defp check_rising_crossing(%__MODULE__{value: threshold_value, hysteresis: hysteresis}, previous, current) do
    # Rising: previous must be < (threshold - hysteresis) AND current must be >= threshold
    previous < threshold_value - hysteresis and current >= threshold_value
  end

  defp direction_allows?(:both, _direction), do: true
  defp direction_allows?(direction, direction), do: true
  defp direction_allows?(_configured, _actual), do: false
end
