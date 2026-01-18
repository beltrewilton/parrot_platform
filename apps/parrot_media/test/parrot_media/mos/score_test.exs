defmodule ParrotMedia.MOS.ScoreTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Score

  describe "new/1" do
    test "creates valid score with required fields" do
      timestamp = DateTime.utc_now()

      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: timestamp
               )

      assert score.value == 4.0
      assert score.timestamp == timestamp
    end

    test "creates score with all fields" do
      timestamp = DateTime.utc_now()

      assert {:ok, score} =
               Score.new(
                 value: 3.8,
                 timestamp: timestamp,
                 packet_loss_percent: 1.5,
                 jitter_ms: 20.0,
                 delay_ms: 150.0,
                 r_factor: 85.0
               )

      assert score.value == 3.8
      assert score.timestamp == timestamp
      assert score.packet_loss_percent == 1.5
      assert score.jitter_ms == 20.0
      assert score.delay_ms == 150.0
      assert score.r_factor == 85.0
    end

    test "derives quality_level :excellent when value >= 4.0" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :excellent
    end

    test "derives quality_level :excellent when value is 4.5" do
      assert {:ok, score} =
               Score.new(
                 value: 4.5,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :excellent
    end

    test "derives quality_level :excellent when value is 5.0" do
      assert {:ok, score} =
               Score.new(
                 value: 5.0,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :excellent
    end

    test "derives quality_level :good when value >= 3.5 and < 4.0" do
      assert {:ok, score} =
               Score.new(
                 value: 3.5,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :good
    end

    test "derives quality_level :good when value is 3.9" do
      assert {:ok, score} =
               Score.new(
                 value: 3.9,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :good
    end

    test "derives quality_level :fair when value >= 3.0 and < 3.5" do
      assert {:ok, score} =
               Score.new(
                 value: 3.0,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :fair
    end

    test "derives quality_level :fair when value is 3.4" do
      assert {:ok, score} =
               Score.new(
                 value: 3.4,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :fair
    end

    test "derives quality_level :poor when value < 3.0" do
      assert {:ok, score} =
               Score.new(
                 value: 2.9,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :poor
    end

    test "derives quality_level :poor when value is 1.0" do
      assert {:ok, score} =
               Score.new(
                 value: 1.0,
                 timestamp: DateTime.utc_now()
               )

      assert score.quality_level == :poor
    end

    test "allows explicit quality_level :insufficient_data" do
      assert {:ok, score} =
               Score.new(
                 value: 3.5,
                 timestamp: DateTime.utc_now(),
                 quality_level: :insufficient_data
               )

      assert score.quality_level == :insufficient_data
    end
  end

  describe "new/1 validation" do
    test "returns error when value is below minimum (1.0)" do
      assert {:error, :value_out_of_range} =
               Score.new(
                 value: 0.9,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error when value is above maximum (5.0)" do
      assert {:error, :value_out_of_range} =
               Score.new(
                 value: 5.1,
                 timestamp: DateTime.utc_now()
               )
    end

    test "accepts value at minimum boundary (1.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 1.0,
                 timestamp: DateTime.utc_now()
               )

      assert score.value == 1.0
    end

    test "accepts value at maximum boundary (5.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 5.0,
                 timestamp: DateTime.utc_now()
               )

      assert score.value == 5.0
    end

    test "returns error when packet_loss_percent is negative" do
      assert {:error, :packet_loss_percent_out_of_range} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 packet_loss_percent: -0.1
               )
    end

    test "returns error when packet_loss_percent exceeds 100.0" do
      assert {:error, :packet_loss_percent_out_of_range} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 packet_loss_percent: 100.1
               )
    end

    test "accepts packet_loss_percent at minimum boundary (0.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 packet_loss_percent: 0.0
               )

      assert score.packet_loss_percent == 0.0
    end

    test "accepts packet_loss_percent at maximum boundary (100.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 packet_loss_percent: 100.0
               )

      assert score.packet_loss_percent == 100.0
    end

    test "returns error when jitter_ms is negative" do
      assert {:error, :jitter_ms_out_of_range} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 jitter_ms: -1.0
               )
    end

    test "accepts jitter_ms at minimum boundary (0.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 jitter_ms: 0.0
               )

      assert score.jitter_ms == 0.0
    end

    test "accepts large jitter_ms values" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 jitter_ms: 1000.0
               )

      assert score.jitter_ms == 1000.0
    end

    test "returns error when delay_ms is negative" do
      assert {:error, :delay_ms_out_of_range} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 delay_ms: -1.0
               )
    end

    test "accepts delay_ms at minimum boundary (0.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 delay_ms: 0.0
               )

      assert score.delay_ms == 0.0
    end

    test "accepts large delay_ms values" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 delay_ms: 500.0
               )

      assert score.delay_ms == 500.0
    end

    test "returns error when value is missing" do
      assert {:error, :missing_value} =
               Score.new(
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error when timestamp is missing" do
      assert {:error, :missing_timestamp} =
               Score.new(
                 value: 4.0
               )
    end

    test "returns error when value is nil" do
      assert {:error, :missing_value} =
               Score.new(
                 value: nil,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error when timestamp is nil" do
      assert {:error, :missing_timestamp} =
               Score.new(
                 value: 4.0,
                 timestamp: nil
               )
    end

    # r_factor validation tests (ITU-T G.107: 0-100 range)

    test "accepts r_factor at minimum boundary (0.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 r_factor: 0.0
               )

      assert score.r_factor == 0.0
    end

    test "accepts r_factor at middle value (50.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 r_factor: 50.0
               )

      assert score.r_factor == 50.0
    end

    test "accepts r_factor at maximum boundary (100.0)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 r_factor: 100.0
               )

      assert score.r_factor == 100.0
    end

    test "returns error when r_factor is negative" do
      assert {:error, :r_factor_out_of_range} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 r_factor: -0.1
               )
    end

    test "returns error when r_factor exceeds 100.0" do
      assert {:error, :r_factor_out_of_range} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 r_factor: 100.1
               )
    end

    test "accepts nil r_factor" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now(),
                 r_factor: nil
               )

      assert score.r_factor == nil
    end

    test "accepts missing r_factor (defaults to nil)" do
      assert {:ok, score} =
               Score.new(
                 value: 4.0,
                 timestamp: DateTime.utc_now()
               )

      assert score.r_factor == nil
    end
  end

  describe "quality_level_for/1" do
    test "returns :excellent for value 4.0" do
      assert Score.quality_level_for(4.0) == :excellent
    end

    test "returns :excellent for value 4.5" do
      assert Score.quality_level_for(4.5) == :excellent
    end

    test "returns :excellent for value 5.0" do
      assert Score.quality_level_for(5.0) == :excellent
    end

    test "returns :good for value 3.5" do
      assert Score.quality_level_for(3.5) == :good
    end

    test "returns :good for value 3.9" do
      assert Score.quality_level_for(3.9) == :good
    end

    test "returns :good for value 3.99" do
      assert Score.quality_level_for(3.99) == :good
    end

    test "returns :fair for value 3.0" do
      assert Score.quality_level_for(3.0) == :fair
    end

    test "returns :fair for value 3.4" do
      assert Score.quality_level_for(3.4) == :fair
    end

    test "returns :fair for value 3.49" do
      assert Score.quality_level_for(3.49) == :fair
    end

    test "returns :poor for value 2.9" do
      assert Score.quality_level_for(2.9) == :poor
    end

    test "returns :poor for value 2.0" do
      assert Score.quality_level_for(2.0) == :poor
    end

    test "returns :poor for value 1.0" do
      assert Score.quality_level_for(1.0) == :poor
    end
  end

  describe "struct definition" do
    test "Score struct exists with expected fields" do
      score = %Score{value: 4.0, timestamp: DateTime.utc_now()}

      assert Map.has_key?(score, :value)
      assert Map.has_key?(score, :timestamp)
      assert Map.has_key?(score, :packet_loss_percent)
      assert Map.has_key?(score, :jitter_ms)
      assert Map.has_key?(score, :delay_ms)
      assert Map.has_key?(score, :r_factor)
      assert Map.has_key?(score, :quality_level)
    end

    test "Score struct enforces required keys" do
      # @enforce_keys [:value, :timestamp] ensures these are required at compile time
      keys = Score.__struct__() |> Map.keys()
      assert :value in keys
      assert :timestamp in keys

      # Verify struct!/2 raises when required keys are missing
      assert_raise ArgumentError, fn ->
        struct!(Score, %{})
      end
    end

    test "Score struct enforces value as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Score, %{timestamp: DateTime.utc_now()})
      end
    end

    test "Score struct enforces timestamp as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Score, %{value: 4.0})
      end
    end

    test "Score struct has nil defaults for optional fields" do
      score = %Score{value: 4.0, timestamp: DateTime.utc_now()}

      assert score.packet_loss_percent == nil
      assert score.jitter_ms == nil
      assert score.delay_ms == nil
      assert score.r_factor == nil
      assert score.quality_level == nil
    end
  end

  describe "edge cases" do
    test "handles floating point precision at boundaries" do
      # Test at the 4.0 boundary
      assert {:ok, score_excellent} = Score.new(value: 4.0, timestamp: DateTime.utc_now())
      assert score_excellent.quality_level == :excellent

      # Just below 4.0
      assert {:ok, score_good} = Score.new(value: 3.999, timestamp: DateTime.utc_now())
      assert score_good.quality_level == :good
    end

    test "handles floating point precision at 3.5 boundary" do
      assert {:ok, score_good} = Score.new(value: 3.5, timestamp: DateTime.utc_now())
      assert score_good.quality_level == :good

      # Just below 3.5
      assert {:ok, score_fair} = Score.new(value: 3.499, timestamp: DateTime.utc_now())
      assert score_fair.quality_level == :fair
    end

    test "handles floating point precision at 3.0 boundary" do
      assert {:ok, score_fair} = Score.new(value: 3.0, timestamp: DateTime.utc_now())
      assert score_fair.quality_level == :fair

      # Just below 3.0
      assert {:ok, score_poor} = Score.new(value: 2.999, timestamp: DateTime.utc_now())
      assert score_poor.quality_level == :poor
    end

    test "accepts integer values for float fields" do
      assert {:ok, score} =
               Score.new(
                 value: 4,
                 timestamp: DateTime.utc_now(),
                 packet_loss_percent: 0,
                 jitter_ms: 10,
                 delay_ms: 100,
                 r_factor: 90
               )

      assert score.value == 4
      assert score.packet_loss_percent == 0
      assert score.jitter_ms == 10
      assert score.delay_ms == 100
      assert score.r_factor == 90
    end

    test "handles typical VoIP metrics scenario - excellent quality" do
      assert {:ok, score} =
               Score.new(
                 value: 4.3,
                 timestamp: DateTime.utc_now(),
                 packet_loss_percent: 0.1,
                 jitter_ms: 5.0,
                 delay_ms: 50.0,
                 r_factor: 93.0
               )

      assert score.quality_level == :excellent
    end

    test "handles typical VoIP metrics scenario - degraded quality" do
      assert {:ok, score} =
               Score.new(
                 value: 2.5,
                 timestamp: DateTime.utc_now(),
                 packet_loss_percent: 5.0,
                 jitter_ms: 50.0,
                 delay_ms: 300.0,
                 r_factor: 60.0
               )

      assert score.quality_level == :poor
    end
  end
end
