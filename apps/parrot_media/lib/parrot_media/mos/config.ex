defmodule ParrotMedia.MOS.Config do
  @moduledoc """
  Configuration management for MOS (Mean Opinion Score) monitoring.

  This module provides a clean interface for accessing MOS configuration,
  abstracting away Application.get_env calls and handling conversion of
  raw config maps into proper Threshold structs.

  ## Application Configuration

  The default MOS configuration is defined in your application config:

      config :parrot_media, :mos,
        enabled: true,
        interval_ms: 5_000,
        min_packets_per_interval: 10,
        default_delay_ms: 50.0,
        thresholds: [
          %{name: :excellent, value: 4.0, hysteresis: 0.1},
          %{name: :good, value: 3.5, hysteresis: 0.1},
          %{name: :fair, value: 3.0, hysteresis: 0.1},
          %{name: :poor, value: 1.0, hysteresis: 0.1}
        ]

  ## Per-Session Configuration

  Session-specific configuration can override application defaults using `merge/1`:

      session_config = Config.merge(%{
        interval_ms: 10_000,
        thresholds: [%{name: :custom, value: 3.8}]
      })

  ## Configuration Options

  - `:enabled` - Whether MOS monitoring is enabled globally (default: true)
  - `:interval_ms` - Interval between MOS calculations in milliseconds (default: 5000)
  - `:min_packets_per_interval` - Minimum packets required for valid calculation (default: 10)
  - `:default_delay_ms` - Default one-way delay estimate in milliseconds (default: 50.0)
  - `:thresholds` - List of quality threshold configurations
  """

  alias ParrotMedia.MOS.Threshold

  @type t :: %__MODULE__{
          enabled: boolean(),
          interval_ms: pos_integer(),
          min_packets_per_interval: pos_integer(),
          default_delay_ms: float(),
          thresholds: [Threshold.t()]
        }

  defstruct enabled: true,
            interval_ms: 5_000,
            min_packets_per_interval: 10,
            default_delay_ms: 50.0,
            thresholds: []

  @doc """
  Returns the full MOS configuration from application environment.

  ## Examples

      iex> Config.get()
      %{
        enabled: true,
        interval_ms: 5000,
        min_packets_per_interval: 10,
        default_delay_ms: 50.0,
        thresholds: [...]
      }
  """
  @spec get() :: map()
  def get do
    Application.get_env(:parrot_media, :mos, default_config())
  end

  @doc """
  Returns a specific configuration key from MOS configuration.

  Returns `nil` if the key is not found.

  ## Examples

      iex> Config.get(:enabled)
      true

      iex> Config.get(:interval_ms)
      5000

      iex> Config.get(:unknown_key)
      nil
  """
  @spec get(atom()) :: any()
  def get(key) when is_atom(key) do
    config = get()
    config[key]
  end

  @doc """
  Returns whether MOS monitoring is enabled globally.

  This is a convenience function for quick checks.

  ## Examples

      iex> Config.enabled?()
      true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    get(:enabled) == true
  end

  @doc """
  Returns the configured thresholds as a list of Threshold structs.

  Converts the raw threshold maps from application config into
  proper `ParrotMedia.MOS.Threshold` structs, filtering out any
  invalid configurations.

  ## Examples

      iex> Config.thresholds()
      [
        %Threshold{name: :excellent, value: 4.0, hysteresis: 0.1, direction: :both},
        %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both},
        ...
      ]
  """
  @spec thresholds() :: [Threshold.t()]
  def thresholds do
    get(:thresholds)
    |> convert_thresholds()
  end

  @doc """
  Merges session-specific overrides with application defaults.

  Creates a complete `Config` struct with session overrides taking
  precedence over application configuration. Threshold maps are
  converted to `Threshold` structs and invalid configurations are
  filtered out.

  ## Parameters

  - `overrides` - Map or keyword list of configuration overrides

  ## Examples

      iex> Config.merge(%{enabled: false})
      %Config{enabled: false, interval_ms: 5000, ...}

      iex> Config.merge(interval_ms: 10_000, min_packets_per_interval: 20)
      %Config{interval_ms: 10_000, min_packets_per_interval: 20, ...}

      iex> Config.merge(%{thresholds: [%{name: :custom, value: 3.8}]})
      %Config{thresholds: [%Threshold{name: :custom, value: 3.8, ...}], ...}
  """
  @spec merge(map() | keyword()) :: t()
  def merge(overrides) when is_map(overrides) or is_list(overrides) do
    overrides_map = to_map(overrides)
    app_config = get()
    app_config_map = to_map(app_config)

    # Merge app config with overrides (overrides take precedence)
    merged = Map.merge(app_config_map, overrides_map)

    # Convert thresholds to structs
    threshold_structs = convert_thresholds(Map.get(merged, :thresholds, []))

    # Use Map.get with defaults to properly handle false values
    %__MODULE__{
      enabled: Map.get(merged, :enabled, true),
      interval_ms: Map.get(merged, :interval_ms, 5_000),
      min_packets_per_interval: Map.get(merged, :min_packets_per_interval, 10),
      default_delay_ms: Map.get(merged, :default_delay_ms, 50.0),
      thresholds: threshold_structs
    }
  end

  @doc """
  Creates a new Config struct from keyword options.

  Uses struct defaults for any unspecified options. Threshold maps
  are converted to `Threshold` structs.

  ## Parameters

  - `opts` - Keyword list of configuration options

  ## Examples

      iex> Config.new(enabled: false, interval_ms: 10_000)
      %Config{enabled: false, interval_ms: 10_000, ...}

      iex> Config.new([])
      %Config{enabled: true, interval_ms: 5000, ...}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    # Extract thresholds for separate processing
    {thresholds, rest} = Keyword.pop(opts, :thresholds, [])
    threshold_structs = convert_thresholds(thresholds)

    struct(__MODULE__, rest)
    |> Map.put(:thresholds, threshold_structs)
  end

  # Private functions

  defp default_config do
    %{
      enabled: true,
      interval_ms: 5_000,
      min_packets_per_interval: 10,
      default_delay_ms: 50.0,
      thresholds: []
    }
  end

  defp to_map(kw) when is_list(kw), do: Map.new(kw)
  defp to_map(map) when is_map(map), do: map

  defp convert_thresholds(nil), do: []
  defp convert_thresholds([]), do: []

  defp convert_thresholds(threshold_configs) when is_list(threshold_configs) do
    threshold_configs
    |> Enum.map(&convert_threshold/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, threshold} -> threshold end)
  end

  # Handle already-converted Threshold structs
  defp convert_threshold(%Threshold{} = threshold), do: {:ok, threshold}

  defp convert_threshold(%{} = config) do
    opts = [
      name: config[:name],
      value: config[:value],
      hysteresis: config[:hysteresis] || 0.1,
      direction: config[:direction] || :both
    ]

    Threshold.new(opts)
  end

  defp convert_threshold(_invalid), do: {:error, :invalid_config}
end
