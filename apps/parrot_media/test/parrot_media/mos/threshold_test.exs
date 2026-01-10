defmodule ParrotMedia.MOS.ThresholdTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Threshold

  describe "new/1" do
    test "creates valid threshold with required fields" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5
               )

      assert threshold.name == :good
      assert threshold.value == 3.5
    end

    test "creates threshold with all fields" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :custom,
                 value: 3.8,
                 hysteresis: 0.2,
                 direction: :falling
               )

      assert threshold.name == :custom
      assert threshold.value == 3.8
      assert threshold.hysteresis == 0.2
      assert threshold.direction == :falling
    end

    test "applies default hysteresis of 0.1" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5
               )

      assert threshold.hysteresis == 0.1
    end

    test "applies default direction of :both" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5
               )

      assert threshold.direction == :both
    end
  end

  describe "new/1 validation - name" do
    test "returns error when name is not an atom" do
      assert {:error, :invalid_name} =
               Threshold.new(
                 name: "good",
                 value: 3.5
               )
    end

    test "returns error when name is an integer" do
      assert {:error, :invalid_name} =
               Threshold.new(
                 name: 123,
                 value: 3.5
               )
    end

    test "returns error when name is nil" do
      assert {:error, :missing_name} =
               Threshold.new(
                 name: nil,
                 value: 3.5
               )
    end

    test "returns error when name is missing" do
      assert {:error, :missing_name} =
               Threshold.new(
                 value: 3.5
               )
    end

    test "accepts any atom as name" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :my_custom_threshold,
                 value: 3.5
               )

      assert threshold.name == :my_custom_threshold
    end
  end

  describe "new/1 validation - value" do
    test "returns error when value is below minimum (1.0)" do
      assert {:error, :value_out_of_range} =
               Threshold.new(
                 name: :good,
                 value: 0.9
               )
    end

    test "returns error when value is above maximum (5.0)" do
      assert {:error, :value_out_of_range} =
               Threshold.new(
                 name: :good,
                 value: 5.1
               )
    end

    test "accepts value at minimum boundary (1.0)" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :poor,
                 value: 1.0
               )

      assert threshold.value == 1.0
    end

    test "accepts value at maximum boundary (5.0)" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :excellent,
                 value: 5.0
               )

      assert threshold.value == 5.0
    end

    test "returns error when value is nil" do
      assert {:error, :missing_value} =
               Threshold.new(
                 name: :good,
                 value: nil
               )
    end

    test "returns error when value is missing" do
      assert {:error, :missing_value} =
               Threshold.new(
                 name: :good
               )
    end

    test "returns error when value is not a number" do
      assert {:error, :invalid_value} =
               Threshold.new(
                 name: :good,
                 value: "3.5"
               )
    end

    test "accepts integer values for float fields" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 4
               )

      assert threshold.value == 4
    end
  end

  describe "new/1 validation - hysteresis" do
    test "returns error when hysteresis is negative" do
      assert {:error, :hysteresis_out_of_range} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 hysteresis: -0.1
               )
    end

    test "accepts hysteresis at minimum boundary (0.0)" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 hysteresis: 0.0
               )

      assert threshold.hysteresis == 0.0
    end

    test "accepts large hysteresis values" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 hysteresis: 1.0
               )

      assert threshold.hysteresis == 1.0
    end

    test "returns error when hysteresis is not a number" do
      assert {:error, :invalid_hysteresis} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 hysteresis: "0.1"
               )
    end

    test "accepts integer hysteresis values" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 hysteresis: 0
               )

      assert threshold.hysteresis == 0
    end
  end

  describe "new/1 validation - direction" do
    test "accepts :falling direction" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 direction: :falling
               )

      assert threshold.direction == :falling
    end

    test "accepts :rising direction" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 direction: :rising
               )

      assert threshold.direction == :rising
    end

    test "accepts :both direction" do
      assert {:ok, threshold} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 direction: :both
               )

      assert threshold.direction == :both
    end

    test "returns error when direction is invalid atom" do
      assert {:error, :invalid_direction} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 direction: :up
               )
    end

    test "returns error when direction is not an atom" do
      assert {:error, :invalid_direction} =
               Threshold.new(
                 name: :good,
                 value: 3.5,
                 direction: "falling"
               )
    end
  end

  describe "crossed?/3 - basic threshold crossing" do
    test "detects falling crossing when MOS drops below threshold" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5)

      assert {true, :falling} = Threshold.crossed?(threshold, 3.6, 3.4)
    end

    test "detects rising crossing when MOS rises above threshold" do
      # With default hysteresis 0.1, previous must be < (3.5 - 0.1) = 3.4
      # So we use 3.3 as previous to ensure we're below the hysteresis buffer
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5)

      assert {true, :rising} = Threshold.crossed?(threshold, 3.3, 3.6)
    end

    test "returns false when MOS stays above threshold" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5)

      assert false == Threshold.crossed?(threshold, 3.8, 3.7)
    end

    test "returns false when MOS stays below threshold" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5)

      assert false == Threshold.crossed?(threshold, 3.2, 3.3)
    end

    test "returns false when MOS values are equal" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5)

      assert false == Threshold.crossed?(threshold, 3.5, 3.5)
    end

    test "detects falling when previous equals threshold and current below" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.0)

      # With zero hysteresis, being at threshold (3.5) counts as >= threshold,
      # so dropping to 3.4 IS a falling crossing
      assert {true, :falling} = Threshold.crossed?(threshold, 3.5, 3.4)
    end

    test "detects crossing from just above to below threshold" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.0)

      assert {true, :falling} = Threshold.crossed?(threshold, 3.51, 3.49)
    end
  end

  describe "crossed?/3 - hysteresis for falling" do
    test "hysteresis prevents crossing when drop is within buffer" do
      # Threshold at 3.5 with hysteresis 0.1
      # Falling: triggers when crossing from >= 3.6 to < 3.5
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 3.55 is below hysteresis buffer (3.6), so no crossing
      assert false == Threshold.crossed?(threshold, 3.55, 3.4)
    end

    test "hysteresis allows crossing when outside buffer" do
      # Threshold at 3.5 with hysteresis 0.1
      # Falling: triggers when crossing from >= 3.6 to < 3.5
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 3.6 is at hysteresis buffer, current 3.4 is below threshold
      assert {true, :falling} = Threshold.crossed?(threshold, 3.6, 3.4)
    end

    test "hysteresis allows crossing when well outside buffer" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 4.0 is well above hysteresis buffer, current 3.4 is below threshold
      assert {true, :falling} = Threshold.crossed?(threshold, 4.0, 3.4)
    end

    test "hysteresis prevents crossing when current is in threshold zone" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 3.6 is at hysteresis buffer, but current 3.5 equals threshold (not below)
      assert false == Threshold.crossed?(threshold, 3.6, 3.5)
    end
  end

  describe "crossed?/3 - hysteresis for rising" do
    test "hysteresis prevents crossing when rise is within buffer" do
      # Threshold at 3.5 with hysteresis 0.1
      # Rising: triggers when crossing from < 3.4 to >= 3.5
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 3.45 is above hysteresis buffer (3.4), so no crossing
      assert false == Threshold.crossed?(threshold, 3.45, 3.6)
    end

    test "hysteresis allows crossing when outside buffer" do
      # Threshold at 3.5 with hysteresis 0.1
      # Rising: triggers when crossing from < 3.4 to >= 3.5
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 3.39 is below hysteresis buffer, current 3.5 is at threshold
      assert {true, :rising} = Threshold.crossed?(threshold, 3.39, 3.5)
    end

    test "hysteresis allows crossing when well outside buffer" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 2.5 is well below hysteresis buffer, current 3.6 is above threshold
      assert {true, :rising} = Threshold.crossed?(threshold, 2.5, 3.6)
    end

    test "hysteresis prevents crossing when previous is at hysteresis boundary" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Previous 3.4 is at hysteresis buffer (not below it), so no crossing
      assert false == Threshold.crossed?(threshold, 3.4, 3.6)
    end
  end

  describe "crossed?/3 - direction filtering" do
    test "direction :falling only detects falling crossings" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, direction: :falling, hysteresis: 0.0)

      # Falling should be detected
      assert {true, :falling} = Threshold.crossed?(threshold, 3.6, 3.4)

      # Rising should be ignored
      assert false == Threshold.crossed?(threshold, 3.4, 3.6)
    end

    test "direction :rising only detects rising crossings" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, direction: :rising, hysteresis: 0.0)

      # Rising should be detected
      assert {true, :rising} = Threshold.crossed?(threshold, 3.4, 3.6)

      # Falling should be ignored
      assert false == Threshold.crossed?(threshold, 3.6, 3.4)
    end

    test "direction :both detects both crossings" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, direction: :both, hysteresis: 0.0)

      # Both directions should be detected
      assert {true, :falling} = Threshold.crossed?(threshold, 3.6, 3.4)
      assert {true, :rising} = Threshold.crossed?(threshold, 3.4, 3.6)
    end
  end

  describe "crossed?/3 - edge cases" do
    test "handles zero hysteresis correctly for falling" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.0)

      # With zero hysteresis, any crossing from strictly above to strictly below counts
      assert {true, :falling} = Threshold.crossed?(threshold, 3.51, 3.49)
    end

    test "handles zero hysteresis correctly for rising" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.0)

      # With zero hysteresis, any crossing from strictly below to at-or-above counts
      assert {true, :rising} = Threshold.crossed?(threshold, 3.49, 3.5)
    end

    test "handles floating point precision at boundaries" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # 3.5999... should be treated as >= 3.6
      assert {true, :falling} = Threshold.crossed?(threshold, 3.6, 3.4)
    end

    test "handles large MOS changes" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      # Large drop from excellent to poor
      assert {true, :falling} = Threshold.crossed?(threshold, 4.5, 1.5)

      # Large rise from poor to excellent
      assert {true, :rising} = Threshold.crossed?(threshold, 1.5, 4.5)
    end

    test "handles threshold at minimum MOS boundary (1.0)" do
      {:ok, threshold} = Threshold.new(name: :minimum, value: 1.0, hysteresis: 0.0)

      # Can't really cross below 1.0 in valid MOS range
      assert false == Threshold.crossed?(threshold, 1.1, 1.0)

      # Rising from 1.0 to above
      assert false == Threshold.crossed?(threshold, 1.0, 1.1)
    end

    test "handles threshold at maximum MOS boundary (5.0)" do
      {:ok, threshold} = Threshold.new(name: :maximum, value: 5.0, hysteresis: 0.0)

      # Rising to exactly 5.0 from below IS a rising crossing
      assert {true, :rising} = Threshold.crossed?(threshold, 4.9, 5.0)

      # Can't cross ABOVE 5.0 since it's the max, but crossing TO 5.0 is valid
      # Falling from 5.0 to 4.9 IS a falling crossing
      assert {true, :falling} = Threshold.crossed?(threshold, 5.0, 4.9)
    end
  end

  describe "struct definition" do
    test "Threshold struct exists with expected fields" do
      threshold = %Threshold{name: :good, value: 3.5}

      assert Map.has_key?(threshold, :name)
      assert Map.has_key?(threshold, :value)
      assert Map.has_key?(threshold, :hysteresis)
      assert Map.has_key?(threshold, :direction)
    end

    test "Threshold struct enforces required keys" do
      keys = Threshold.__struct__() |> Map.keys()
      assert :name in keys
      assert :value in keys

      # Verify struct!/2 raises when required keys are missing
      assert_raise ArgumentError, fn ->
        struct!(Threshold, %{})
      end
    end

    test "Threshold struct enforces name as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Threshold, %{value: 3.5})
      end
    end

    test "Threshold struct enforces value as required key" do
      assert_raise ArgumentError, fn ->
        struct!(Threshold, %{name: :good})
      end
    end

    test "Threshold struct has correct defaults for optional fields" do
      threshold = %Threshold{name: :good, value: 3.5}

      assert threshold.hysteresis == 0.1
      assert threshold.direction == :both
    end
  end

  describe "default_thresholds/0" do
    test "returns a list of default thresholds" do
      thresholds = Threshold.default_thresholds()

      assert is_list(thresholds)
      assert length(thresholds) == 3
    end

    test "includes excellent threshold at 4.0" do
      thresholds = Threshold.default_thresholds()
      excellent = Enum.find(thresholds, &(&1.name == :excellent))

      assert excellent.value == 4.0
      assert excellent.direction == :both
    end

    test "includes good threshold at 3.5" do
      thresholds = Threshold.default_thresholds()
      good = Enum.find(thresholds, &(&1.name == :good))

      assert good.value == 3.5
      assert good.direction == :both
    end

    test "includes fair threshold at 3.0" do
      thresholds = Threshold.default_thresholds()
      fair = Enum.find(thresholds, &(&1.name == :fair))

      assert fair.value == 3.0
      assert fair.direction == :both
    end
  end
end
