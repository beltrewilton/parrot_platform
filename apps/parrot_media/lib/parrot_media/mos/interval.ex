defmodule ParrotMedia.MOS.Interval do
  @moduledoc """
  Metrics aggregated over a calculation interval.

  The Interval struct collects RTP metrics over a configurable time window
  (default 5 seconds). When the interval completes, the aggregated values
  are used by the Calculator with the E-Model to compute a MOS score.

  ## Lifecycle

  1. Create a new interval with `new/0` or `new/1`
  2. Add metrics samples with `add_metrics/2` as RTP packets arrive
  3. Complete the interval with `complete/1` to finalize calculations
  4. Check data sufficiency with `sufficient_data?/1` before scoring

  ## Metrics Sample Format

  The Observer sends metrics in this format:

      %{
        packets_received: 50,
        packets_expected: 50,
        jitter_ms: 12.5,
        delay_ms: 45.0
      }

  All fields are optional - partial metrics are supported.

  ## Example

      interval = Interval.new()
      |> Interval.add_metrics(%{packets_received: 50, packets_expected: 50, jitter_ms: 10.0, delay_ms: 40.0})
      |> Interval.add_metrics(%{packets_received: 48, packets_expected: 50, jitter_ms: 15.0, delay_ms: 50.0})
      |> Interval.complete()

      if Interval.sufficient_data?(interval) do
        # Use interval.jitter_ms, interval.delay_ms, interval.packet_loss_percent
        # to calculate MOS score
      end
  """

  alias ParrotMedia.MOS.Config

  @type t :: %__MODULE__{
          start_time: DateTime.t(),
          end_time: DateTime.t() | nil,
          duration_ms: non_neg_integer(),
          packets_received: non_neg_integer(),
          packets_expected: non_neg_integer(),
          packets_lost: non_neg_integer(),
          packet_loss_percent: float(),
          jitter_samples: [float()],
          jitter_ms: float(),
          delay_samples: [float()],
          delay_ms: float()
        }

  @enforce_keys [:start_time]
  defstruct start_time: nil,
            end_time: nil,
            duration_ms: 0,
            packets_received: 0,
            packets_expected: 0,
            packets_lost: 0,
            packet_loss_percent: 0.0,
            jitter_samples: [],
            jitter_ms: 0.0,
            delay_samples: [],
            delay_ms: 0.0

  @doc """
  Creates a new interval starting now.

  ## Examples

      iex> interval = Interval.new()
      iex> %Interval{} = interval
      iex> interval.start_time != nil
      true
  """
  @spec new() :: t()
  def new do
    %__MODULE__{start_time: DateTime.utc_now()}
  end

  @doc """
  Creates a new interval with a specific start time.

  Useful for testing or when you need to align intervals to specific timestamps.

  ## Examples

      iex> start = ~U[2026-01-10 12:00:00Z]
      iex> interval = Interval.new(start)
      iex> interval.start_time
      ~U[2026-01-10 12:00:00Z]
  """
  @spec new(DateTime.t()) :: t()
  def new(%DateTime{} = start_time) do
    %__MODULE__{start_time: start_time}
  end

  @doc """
  Adds a metrics sample to the interval.

  Metrics samples are accumulated over the interval period. Packet counts
  are summed, while jitter and delay values are collected for averaging
  when the interval completes.

  ## Parameters

  - `interval` - The interval to update
  - `metrics` - Map with optional keys:
    - `:packets_received` - Number of packets received
    - `:packets_expected` - Number of packets expected
    - `:jitter_ms` - Interarrival jitter in milliseconds
    - `:delay_ms` - One-way delay estimate in milliseconds

  ## Examples

      iex> interval = Interval.new()
      iex> metrics = %{packets_received: 50, packets_expected: 50, jitter_ms: 12.5, delay_ms: 45.0}
      iex> updated = Interval.add_metrics(interval, metrics)
      iex> updated.packets_received
      50
  """
  @spec add_metrics(t(), map()) :: t()
  def add_metrics(%__MODULE__{} = interval, metrics) when is_map(metrics) do
    packets_received = Map.get(metrics, :packets_received, 0)
    packets_expected = Map.get(metrics, :packets_expected, 0)

    jitter_samples =
      case Map.get(metrics, :jitter_ms) do
        nil -> interval.jitter_samples
        jitter -> [jitter | interval.jitter_samples]
      end

    delay_samples =
      case Map.get(metrics, :delay_ms) do
        nil -> interval.delay_samples
        delay -> [delay | interval.delay_samples]
      end

    %{
      interval
      | packets_received: interval.packets_received + packets_received,
        packets_expected: interval.packets_expected + packets_expected,
        jitter_samples: jitter_samples,
        delay_samples: delay_samples
    }
  end

  @doc """
  Finalizes the interval and calculates aggregates.

  Sets the end_time to now (or provided time), calculates duration,
  packet loss, and averages for jitter and delay.

  ## Examples

      iex> interval = Interval.new()
      iex> |> Interval.add_metrics(%{packets_received: 95, packets_expected: 100, jitter_ms: 10.0, delay_ms: 40.0})
      iex> |> Interval.complete()
      iex> completed.packet_loss_percent
      5.0
  """
  @spec complete(t()) :: t()
  def complete(%__MODULE__{} = interval) do
    complete(interval, DateTime.utc_now())
  end

  @doc """
  Finalizes the interval with a specific end time.

  Useful for testing or when precise timing control is needed.

  ## Examples

      iex> start = ~U[2026-01-10 12:00:00Z]
      iex> end_time = ~U[2026-01-10 12:00:05Z]
      iex> interval = Interval.new(start) |> Interval.complete(end_time)
      iex> interval.duration_ms
      5000
  """
  @spec complete(t(), DateTime.t()) :: t()
  def complete(%__MODULE__{} = interval, %DateTime{} = end_time) do
    duration_ms = DateTime.diff(end_time, interval.start_time, :millisecond)
    packets_lost = max(0, interval.packets_expected - interval.packets_received)
    loss_percent = packet_loss_percent(interval)
    avg_jitter = average_jitter(interval)
    avg_delay = average_delay(interval)

    %{
      interval
      | end_time: end_time,
        duration_ms: duration_ms,
        packets_lost: packets_lost,
        packet_loss_percent: loss_percent,
        jitter_ms: avg_jitter,
        delay_ms: avg_delay
    }
  end

  @doc """
  Calculates packet loss percentage from received/expected counts.

  Returns 0.0 if no packets were expected (prevents division by zero).

  ## Examples

      iex> interval = %Interval{start_time: DateTime.utc_now(), packets_received: 95, packets_expected: 100}
      iex> Interval.packet_loss_percent(interval)
      5.0

      iex> interval = %Interval{start_time: DateTime.utc_now(), packets_received: 0, packets_expected: 0}
      iex> Interval.packet_loss_percent(interval)
      0.0
  """
  @spec packet_loss_percent(t()) :: float()
  def packet_loss_percent(%__MODULE__{packets_expected: 0}), do: 0.0

  def packet_loss_percent(%__MODULE__{} = interval) do
    lost = max(0, interval.packets_expected - interval.packets_received)
    lost / interval.packets_expected * 100.0
  end

  @doc """
  Calculates average jitter from collected samples.

  Returns 0.0 if no samples have been collected.

  ## Examples

      iex> interval = %Interval{start_time: DateTime.utc_now(), jitter_samples: [10.0, 20.0, 30.0]}
      iex> Interval.average_jitter(interval)
      20.0

      iex> interval = %Interval{start_time: DateTime.utc_now(), jitter_samples: []}
      iex> Interval.average_jitter(interval)
      0.0
  """
  @spec average_jitter(t()) :: float()
  def average_jitter(%__MODULE__{jitter_samples: []}), do: 0.0

  def average_jitter(%__MODULE__{jitter_samples: samples}) do
    Enum.sum(samples) / length(samples)
  end

  @doc """
  Calculates average delay from collected samples.

  Returns 0.0 if no samples have been collected.

  ## Examples

      iex> interval = %Interval{start_time: DateTime.utc_now(), delay_samples: [40.0, 50.0, 60.0]}
      iex> Interval.average_delay(interval)
      50.0

      iex> interval = %Interval{start_time: DateTime.utc_now(), delay_samples: []}
      iex> Interval.average_delay(interval)
      0.0
  """
  @spec average_delay(t()) :: float()
  def average_delay(%__MODULE__{delay_samples: []}), do: 0.0

  def average_delay(%__MODULE__{delay_samples: samples}) do
    Enum.sum(samples) / length(samples)
  end

  @doc """
  Checks if the interval has enough data for a valid MOS calculation.

  By default, uses the `min_packets_per_interval` from application config.
  A custom threshold can be provided via the `:min_packets` option.

  ## Options

  - `:min_packets` - Override the minimum packets threshold

  ## Examples

      iex> interval = %Interval{start_time: DateTime.utc_now(), packets_received: 100}
      iex> Interval.sufficient_data?(interval)
      true

      iex> interval = %Interval{start_time: DateTime.utc_now(), packets_received: 5}
      iex> Interval.sufficient_data?(interval)
      false

      iex> interval = %Interval{start_time: DateTime.utc_now(), packets_received: 15}
      iex> Interval.sufficient_data?(interval, min_packets: 20)
      false
  """
  @spec sufficient_data?(t(), keyword()) :: boolean()
  def sufficient_data?(%__MODULE__{} = interval, opts \\ []) do
    min_packets = Keyword.get(opts, :min_packets, Config.get(:min_packets_per_interval))
    interval.packets_received >= min_packets
  end
end
