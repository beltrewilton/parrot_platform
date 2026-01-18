defmodule ParrotMedia.MOS.ConfigTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Config
  alias ParrotMedia.MOS.Threshold

  describe "struct definition" do
    test "Config struct exists with expected fields" do
      config = %Config{}

      assert Map.has_key?(config, :enabled)
      assert Map.has_key?(config, :interval_ms)
      assert Map.has_key?(config, :min_packets_per_interval)
      assert Map.has_key?(config, :default_delay_ms)
      assert Map.has_key?(config, :thresholds)
    end

    test "Config struct has correct default values" do
      config = %Config{}

      assert config.enabled == true
      assert config.interval_ms == 5_000
      assert config.min_packets_per_interval == 10
      assert config.default_delay_ms == 50.0
      assert config.thresholds == []
    end
  end

  describe "get/0" do
    test "returns full MOS configuration from application env" do
      config = Config.get()

      # Config may be returned as keyword list or map
      assert is_list(config) or is_map(config)
      assert config[:enabled] != nil
      assert config[:interval_ms] != nil
      assert config[:min_packets_per_interval] != nil
      assert config[:default_delay_ms] != nil
      assert config[:thresholds] != nil
    end

    test "returns enabled setting from application config" do
      config = Config.get()

      assert config[:enabled] == true
    end

    test "returns interval_ms from application config" do
      config = Config.get()

      assert config[:interval_ms] == 5_000
    end

    test "returns thresholds list from application config" do
      config = Config.get()

      assert is_list(config[:thresholds])
      assert length(config[:thresholds]) > 0
    end
  end

  describe "get/1" do
    test "returns specific config key" do
      assert Config.get(:enabled) == true
    end

    test "returns interval_ms setting" do
      assert Config.get(:interval_ms) == 5_000
    end

    test "returns min_packets_per_interval setting" do
      assert Config.get(:min_packets_per_interval) == 10
    end

    test "returns default_delay_ms setting" do
      assert Config.get(:default_delay_ms) == 50.0
    end

    test "returns thresholds list" do
      thresholds = Config.get(:thresholds)

      assert is_list(thresholds)
      assert length(thresholds) > 0
    end

    test "returns nil for unknown key" do
      assert Config.get(:unknown_key) == nil
    end
  end

  describe "enabled?/0" do
    test "returns boolean indicating if MOS is enabled globally" do
      result = Config.enabled?()

      assert is_boolean(result)
    end

    test "returns true when MOS is enabled in config" do
      # Default config has enabled: true
      assert Config.enabled?() == true
    end
  end

  describe "thresholds/0" do
    test "returns list of Threshold structs" do
      thresholds = Config.thresholds()

      assert is_list(thresholds)
      assert length(thresholds) > 0

      Enum.each(thresholds, fn threshold ->
        assert %Threshold{} = threshold
      end)
    end

    test "converts threshold maps from config to Threshold structs" do
      thresholds = Config.thresholds()

      # Verify we have the expected thresholds from config
      names = Enum.map(thresholds, & &1.name)
      assert :excellent in names
      assert :good in names
      assert :fair in names
      assert :poor in names
    end

    test "threshold structs have correct values from config" do
      thresholds = Config.thresholds()

      excellent = Enum.find(thresholds, &(&1.name == :excellent))
      assert excellent.value == 4.0
      assert excellent.hysteresis == 0.1

      good = Enum.find(thresholds, &(&1.name == :good))
      assert good.value == 3.5
      assert good.hysteresis == 0.1
    end

    test "threshold structs have default direction of :both" do
      thresholds = Config.thresholds()

      Enum.each(thresholds, fn threshold ->
        assert threshold.direction == :both
      end)
    end
  end

  describe "merge/1" do
    test "returns Config struct with defaults when passed empty map" do
      config = Config.merge(%{})

      assert %Config{} = config
      assert config.enabled == true
      assert config.interval_ms == 5_000
      assert config.min_packets_per_interval == 10
      assert config.default_delay_ms == 50.0
    end

    test "overrides enabled setting" do
      config = Config.merge(%{enabled: false})

      assert config.enabled == false
    end

    test "overrides interval_ms setting" do
      config = Config.merge(%{interval_ms: 10_000})

      assert config.interval_ms == 10_000
    end

    test "overrides min_packets_per_interval setting" do
      config = Config.merge(%{min_packets_per_interval: 20})

      assert config.min_packets_per_interval == 20
    end

    test "overrides default_delay_ms setting" do
      config = Config.merge(%{default_delay_ms: 100.0})

      assert config.default_delay_ms == 100.0
    end

    test "overrides thresholds with custom list" do
      custom_thresholds = [
        %{name: :custom, value: 3.8, hysteresis: 0.2}
      ]

      config = Config.merge(%{thresholds: custom_thresholds})

      assert length(config.thresholds) == 1
      assert %Threshold{name: :custom, value: 3.8, hysteresis: 0.2} = hd(config.thresholds)
    end

    test "preserves non-overridden settings" do
      config = Config.merge(%{enabled: false})

      # Other settings should remain at defaults from app config
      assert config.interval_ms == 5_000
      assert config.min_packets_per_interval == 10
      assert config.default_delay_ms == 50.0
    end

    test "converts threshold maps to Threshold structs" do
      custom_thresholds = [
        %{name: :high, value: 4.5, hysteresis: 0.15, direction: :falling},
        %{name: :low, value: 2.5, hysteresis: 0.1}
      ]

      config = Config.merge(%{thresholds: custom_thresholds})

      assert length(config.thresholds) == 2

      high = Enum.find(config.thresholds, &(&1.name == :high))
      assert %Threshold{} = high
      assert high.value == 4.5
      assert high.hysteresis == 0.15
      assert high.direction == :falling

      low = Enum.find(config.thresholds, &(&1.name == :low))
      assert %Threshold{} = low
      assert low.value == 2.5
      assert low.direction == :both
    end

    test "accepts keyword list for overrides" do
      config = Config.merge(enabled: false, interval_ms: 3_000)

      assert config.enabled == false
      assert config.interval_ms == 3_000
    end

    test "populates thresholds from app config when not overridden" do
      config = Config.merge(%{enabled: false})

      # Thresholds should come from app config
      assert length(config.thresholds) > 0

      names = Enum.map(config.thresholds, & &1.name)
      assert :excellent in names
      assert :good in names
    end
  end

  describe "merge/1 with invalid threshold configs" do
    test "filters out invalid threshold configs" do
      # Mix of valid and invalid thresholds
      thresholds = [
        %{name: :valid, value: 3.5},
        %{name: "invalid_name", value: 3.0},
        %{name: :also_valid, value: 4.0}
      ]

      config = Config.merge(%{thresholds: thresholds})

      # Should only have 2 valid thresholds
      assert length(config.thresholds) == 2

      names = Enum.map(config.thresholds, & &1.name)
      assert :valid in names
      assert :also_valid in names
    end

    test "filters out threshold with invalid value range" do
      thresholds = [
        %{name: :valid, value: 3.5},
        %{name: :invalid_value, value: 6.0}
      ]

      config = Config.merge(%{thresholds: thresholds})

      assert length(config.thresholds) == 1
      assert hd(config.thresholds).name == :valid
    end

    test "returns empty thresholds list when all are invalid" do
      thresholds = [
        %{name: "string_name", value: 3.5},
        %{value: 3.0}
      ]

      config = Config.merge(%{thresholds: thresholds})

      assert config.thresholds == []
    end
  end

  describe "new/1" do
    test "creates Config struct from keyword options" do
      config = Config.new(enabled: false, interval_ms: 10_000)

      assert %Config{} = config
      assert config.enabled == false
      assert config.interval_ms == 10_000
    end

    test "uses struct defaults for unspecified options" do
      config = Config.new(enabled: false)

      assert config.enabled == false
      assert config.interval_ms == 5_000
      assert config.min_packets_per_interval == 10
    end

    test "converts threshold maps to Threshold structs" do
      thresholds = [
        %{name: :custom, value: 3.8}
      ]

      config = Config.new(thresholds: thresholds)

      assert length(config.thresholds) == 1
      assert %Threshold{name: :custom, value: 3.8} = hd(config.thresholds)
    end

    test "accepts empty options and returns defaults" do
      config = Config.new([])

      assert config.enabled == true
      assert config.interval_ms == 5_000
    end

    test "filters invalid thresholds" do
      thresholds = [
        %{name: :valid, value: 3.5},
        %{name: "invalid", value: 3.0}
      ]

      config = Config.new(thresholds: thresholds)

      assert length(config.thresholds) == 1
    end
  end
end
