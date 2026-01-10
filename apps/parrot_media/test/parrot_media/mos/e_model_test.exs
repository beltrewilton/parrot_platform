defmodule ParrotMedia.MOS.EModelTest do
  @moduledoc """
  Tests for the ITU-T G.107 E-model algorithm implementation.

  Reference: ITU-T Rec. G.107 (2005) - The E-model
  Reference: ITU-T Rec. G.113 - Transmission impairments

  These tests verify the E-model correctly calculates MOS scores from
  network metrics (packet loss, jitter, delay) for various codecs.
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.EModel

  # ===========================================================================
  # Codec Parameters Tests (ITU-T G.113)
  # ===========================================================================

  describe "codec_params/1" do
    test "returns correct parameters for G.711 with PLC (reference codec)" do
      # G.711 is the reference codec with Ie=0 by definition
      # Bpl=25.1 for G.711 with packet loss concealment
      {ie, bpl} = EModel.codec_params(:g711)
      assert ie == 0
      assert bpl == 25.1
    end

    test "returns correct parameters for G.711 without PLC" do
      # G.711 without PLC has lower robustness (Bpl=4.3)
      {ie, bpl} = EModel.codec_params(:g711_no_plc)
      assert ie == 0
      assert bpl == 4.3
    end

    test "returns correct parameters for Opus (high bitrate)" do
      # Opus high bitrate - Ie=10 per ITU-T G.113
      {ie, bpl} = EModel.codec_params(:opus)
      assert ie == 10
      assert bpl == 20.0
    end

    test "returns correct parameters for Opus (low bitrate)" do
      # Opus low bitrate - Ie=15 per ITU-T G.113
      {ie, bpl} = EModel.codec_params(:opus_low)
      assert ie == 15
      assert bpl == 15.0
    end

    test "returns correct parameters for G.729" do
      # G.729AB official ITU-T G.113 values
      {ie, bpl} = EModel.codec_params(:g729)
      assert ie == 11
      assert bpl == 19.0
    end

    test "defaults to G.711 for unknown codec" do
      # Should fall back to reference codec parameters
      {ie, bpl} = EModel.codec_params(:unknown_codec)
      assert ie == 0
      assert bpl == 25.1
    end
  end

  # ===========================================================================
  # R-factor to MOS Conversion Tests (ITU-T G.107 Appendix B)
  # ===========================================================================

  describe "r_to_mos/1" do
    test "returns 1.0 for R < 0 (clamped lower bound)" do
      assert EModel.r_to_mos(-10.0) == 1.0
      assert EModel.r_to_mos(-1.0) == 1.0
      assert EModel.r_to_mos(-0.1) == 1.0
    end

    test "returns 4.5 for R > 100 (clamped upper bound)" do
      assert EModel.r_to_mos(100.1) == 4.5
      assert EModel.r_to_mos(110.0) == 4.5
      assert EModel.r_to_mos(200.0) == 4.5
    end

    test "returns 1.0 for R = 0" do
      assert EModel.r_to_mos(0.0) == 1.0
    end

    test "returns approximately 4.41 for R = 93.2 (perfect G.711)" do
      # R0 = 93.2 is the baseline quality for perfect conditions
      mos = EModel.r_to_mos(93.2)
      assert_in_delta mos, 4.41, 0.05
    end

    test "returns approximately 4.5 for R = 100" do
      # Maximum R gives maximum MOS (with tiny floating point difference)
      mos = EModel.r_to_mos(100.0)
      assert_in_delta mos, 4.5, 0.01
    end

    test "returns correct MOS for R = 60 (mid-range)" do
      # At R=60, formula simplifies: 1.0 + 0.035*60 + 60*(0)*(40)*7e-6
      # = 1.0 + 2.1 + 0 = 3.1
      mos = EModel.r_to_mos(60.0)
      assert_in_delta mos, 3.1, 0.01
    end

    test "returns correct MOS for R = 50 (lower quality)" do
      # MOS = 1.0 + 0.035*50 + 50*(-10)*(50)*7e-6
      # = 1.0 + 1.75 + (-0.175) = 2.575
      mos = EModel.r_to_mos(50.0)
      assert_in_delta mos, 2.575, 0.01
    end

    test "returns correct MOS for R = 80 (good quality)" do
      # MOS = 1.0 + 0.035*80 + 80*(20)*(20)*7e-6
      # = 1.0 + 2.8 + 0.224 = 4.024
      mos = EModel.r_to_mos(80.0)
      assert_in_delta mos, 4.024, 0.01
    end

    test "returns MOS within valid range 1.0-4.5 for all valid R" do
      for r <- [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100] do
        mos = EModel.r_to_mos(r)
        assert mos >= 1.0, "MOS for R=#{r} should be >= 1.0, got #{mos}"
        assert mos <= 4.5, "MOS for R=#{r} should be <= 4.5, got #{mos}"
      end
    end
  end

  # ===========================================================================
  # Delay Impairment Tests (Id)
  # ===========================================================================

  describe "calculate_id/1" do
    test "returns 0 for delay <= 100ms" do
      # No impairment for delays up to 100ms
      assert EModel.calculate_id(0.0) == 0.0
      assert EModel.calculate_id(50.0) == 0.0
      assert EModel.calculate_id(100.0) == 0.0
    end

    test "returns small impairment for delay slightly above 100ms" do
      # Impairment begins above 100ms
      id = EModel.calculate_id(110.0)
      assert id > 0.0
      assert id < 5.0
    end

    test "returns increasing impairment for higher delays" do
      id_150 = EModel.calculate_id(150.0)
      id_200 = EModel.calculate_id(200.0)
      id_300 = EModel.calculate_id(300.0)

      assert id_150 > 0.0
      assert id_200 > id_150
      assert id_300 > id_200
    end

    test "returns significant impairment for high delay (400ms)" do
      # 400ms is typical satellite delay - should have significant impact
      id = EModel.calculate_id(400.0)
      assert id > 20.0
    end

    test "handles very low delay gracefully" do
      id = EModel.calculate_id(10.0)
      assert id == 0.0
    end

    test "handles negative delay (should clamp to 0)" do
      # Negative delay is invalid, treat as 0
      id = EModel.calculate_id(-10.0)
      assert id == 0.0
    end
  end

  # ===========================================================================
  # Equipment Impairment Tests (Ie_eff)
  # ===========================================================================

  describe "calculate_ie_eff/3" do
    test "returns Ie when packet loss is 0" do
      # With 0% loss, Ie_eff = Ie (no additional impairment from loss)
      ie = 0
      bpl = 25.1

      ie_eff = EModel.calculate_ie_eff(0.0, ie, bpl)
      assert ie_eff == 0.0
    end

    test "returns correct impairment for 1% loss with G.711" do
      # Ie_eff = Ie + (95 - Ie) * Ppl / (Ppl + Bpl)
      # = 0 + (95 - 0) * 1 / (1 + 25.1)
      # = 95 * 1 / 26.1
      # = 3.64
      ie = 0
      bpl = 25.1

      ie_eff = EModel.calculate_ie_eff(1.0, ie, bpl)
      assert_in_delta ie_eff, 3.64, 0.1
    end

    test "returns higher impairment for higher packet loss" do
      ie = 0
      bpl = 25.1

      ie_eff_1 = EModel.calculate_ie_eff(1.0, ie, bpl)
      ie_eff_5 = EModel.calculate_ie_eff(5.0, ie, bpl)
      ie_eff_10 = EModel.calculate_ie_eff(10.0, ie, bpl)

      assert ie_eff_5 > ie_eff_1
      assert ie_eff_10 > ie_eff_5
    end

    test "returns correct impairment for 5% loss with G.711" do
      # Ie_eff = 0 + 95 * 5 / (5 + 25.1) = 475 / 30.1 = 15.78
      ie = 0
      bpl = 25.1

      ie_eff = EModel.calculate_ie_eff(5.0, ie, bpl)
      assert_in_delta ie_eff, 15.78, 0.1
    end

    test "accounts for codec Ie value" do
      # G.729 has Ie=11
      ie = 11
      bpl = 19.0

      # At 0% loss, Ie_eff = Ie = 11
      ie_eff_0 = EModel.calculate_ie_eff(0.0, ie, bpl)
      assert_in_delta ie_eff_0, 11.0, 0.1

      # At 1% loss: 11 + (95-11) * 1 / (1 + 19) = 11 + 84/20 = 11 + 4.2 = 15.2
      ie_eff_1 = EModel.calculate_ie_eff(1.0, ie, bpl)
      assert_in_delta ie_eff_1, 15.2, 0.1
    end

    test "asymptotically approaches 95 for very high loss" do
      ie = 0
      bpl = 25.1

      # At 50% loss: 95 * 50 / (50 + 25.1) = 4750 / 75.1 = 63.25
      ie_eff_50 = EModel.calculate_ie_eff(50.0, ie, bpl)
      assert_in_delta ie_eff_50, 63.25, 0.5

      # At 100% loss, approaches 95: 95 * 100 / 125.1 = 75.94
      ie_eff_100 = EModel.calculate_ie_eff(100.0, ie, bpl)
      assert_in_delta ie_eff_100, 75.94, 0.5
    end

    test "G.711 without PLC degrades faster than with PLC" do
      # Without PLC, Bpl is much lower (4.3), so degradation is faster
      ie_eff_with_plc = EModel.calculate_ie_eff(2.0, 0, 25.1)
      ie_eff_no_plc = EModel.calculate_ie_eff(2.0, 0, 4.3)

      assert ie_eff_no_plc > ie_eff_with_plc
    end
  end

  # ===========================================================================
  # R-factor Calculation Tests
  # ===========================================================================

  describe "calculate_r_factor/4" do
    test "returns approximately R0 (93.2) for perfect conditions" do
      # 0% loss, 0ms jitter, 50ms delay (well under 100ms threshold)
      r = EModel.calculate_r_factor(0.0, 0.0, 50.0, :g711)
      assert_in_delta r, 93.2, 0.5
    end

    test "returns lower R for packet loss" do
      # With 1% loss, R should be reduced
      r_perfect = EModel.calculate_r_factor(0.0, 0.0, 50.0, :g711)
      r_with_loss = EModel.calculate_r_factor(1.0, 0.0, 50.0, :g711)

      assert r_with_loss < r_perfect
    end

    test "returns lower R for high jitter" do
      # High jitter increases effective delay
      r_low_jitter = EModel.calculate_r_factor(0.0, 10.0, 50.0, :g711)
      r_high_jitter = EModel.calculate_r_factor(0.0, 100.0, 50.0, :g711)

      assert r_high_jitter < r_low_jitter
    end

    test "returns lower R for high delay" do
      r_low_delay = EModel.calculate_r_factor(0.0, 0.0, 50.0, :g711)
      r_high_delay = EModel.calculate_r_factor(0.0, 0.0, 200.0, :g711)

      assert r_high_delay < r_low_delay
    end

    test "returns R within valid range 0-100" do
      # Even with severe conditions, R should be in valid range
      r = EModel.calculate_r_factor(50.0, 200.0, 500.0, :g711)
      assert r >= 0.0
      assert r <= 100.0
    end

    test "jitter contributes to delay impairment" do
      # effective_delay = delay_ms + jitter_ms * 2
      # With 50ms jitter, effective delay = 50 + 100 = 150ms
      r_no_jitter = EModel.calculate_r_factor(0.0, 0.0, 150.0, :g711)
      r_with_jitter = EModel.calculate_r_factor(0.0, 50.0, 50.0, :g711)

      # Should be approximately equal (both have 150ms effective delay)
      assert_in_delta r_no_jitter, r_with_jitter, 0.5
    end

    test "returns lower R for low-quality codecs" do
      # G.729 has Ie=11, so it starts with lower quality
      r_g711 = EModel.calculate_r_factor(0.0, 0.0, 50.0, :g711)
      r_g729 = EModel.calculate_r_factor(0.0, 0.0, 50.0, :g729)

      assert r_g729 < r_g711
      # Difference should be approximately the Ie value (11)
      assert_in_delta r_g711 - r_g729, 11.0, 1.0
    end
  end

  # ===========================================================================
  # MOS Calculation Tests (End-to-End)
  # ===========================================================================

  describe "calculate_mos/4" do
    test "returns approximately 4.4 for perfect conditions" do
      # Reference value from task description
      # Perfect: 0% loss, 0ms jitter, 50ms delay
      mos = EModel.calculate_mos(0.0, 0.0, 50.0, :g711)
      assert_in_delta mos, 4.4, 0.1
    end

    test "returns good MOS for low loss conditions" do
      # 1% loss, 10ms jitter, 100ms delay
      # Low jitter (10ms) adds 20ms effective delay -> 120ms total (above threshold)
      # With 1% loss, quality is still good but slightly degraded
      mos = EModel.calculate_mos(1.0, 10.0, 100.0, :g711)
      # Actual E-model value: ~4.33 (better than rough estimate)
      assert_in_delta mos, 4.33, 0.1
      assert mos >= 4.0, "Low loss conditions should yield MOS >= 4.0"
    end

    test "returns fair-to-good MOS for medium loss conditions" do
      # 3% loss, 30ms jitter, 150ms delay
      # 30ms jitter adds 60ms effective delay -> 210ms total
      # 3% loss has noticeable impact on G.711
      mos = EModel.calculate_mos(3.0, 30.0, 150.0, :g711)
      # Actual E-model value: ~3.98 (still good quality)
      assert_in_delta mos, 3.98, 0.1
      assert mos >= 3.5, "Medium conditions should yield MOS >= 3.5"
    end

    test "returns fair MOS for high loss conditions" do
      # 5% loss, 50ms jitter, 200ms delay
      # 50ms jitter adds 100ms effective delay -> 300ms total
      # 5% loss significantly impacts quality
      mos = EModel.calculate_mos(5.0, 50.0, 200.0, :g711)
      # Actual E-model value: ~3.24
      assert_in_delta mos, 3.24, 0.1
      assert mos >= 3.0, "High loss conditions should yield MOS >= 3.0"
    end

    test "returns poor MOS for severe conditions" do
      # 10% loss, 100ms jitter, 300ms delay
      # 100ms jitter adds 200ms effective delay -> 500ms total (very high)
      # 10% loss severely impacts quality
      mos = EModel.calculate_mos(10.0, 100.0, 300.0, :g711)
      # Actual E-model value: ~1.85 (poor quality)
      assert_in_delta mos, 1.85, 0.15
      assert mos < 2.5, "Severe conditions should yield MOS < 2.5"
    end

    test "returns MOS within valid range 1.0-4.5" do
      for {loss, jitter, delay} <- [
            {0.0, 0.0, 50.0},
            {5.0, 50.0, 150.0},
            {20.0, 100.0, 300.0},
            {50.0, 200.0, 500.0}
          ] do
        mos = EModel.calculate_mos(loss, jitter, delay, :g711)
        assert mos >= 1.0, "MOS should be >= 1.0, got #{mos}"
        assert mos <= 4.5, "MOS should be <= 4.5, got #{mos}"
      end
    end

    test "defaults to G.711 codec when not specified" do
      mos_explicit = EModel.calculate_mos(1.0, 20.0, 100.0, :g711)
      mos_default = EModel.calculate_mos(1.0, 20.0, 100.0)

      assert mos_explicit == mos_default
    end

    test "returns lower MOS for Opus low bitrate vs high bitrate" do
      mos_high = EModel.calculate_mos(1.0, 20.0, 100.0, :opus)
      mos_low = EModel.calculate_mos(1.0, 20.0, 100.0, :opus_low)

      assert mos_low < mos_high
    end
  end

  # ===========================================================================
  # Edge Cases and Boundary Conditions
  # ===========================================================================

  describe "edge cases" do
    test "handles 0% packet loss correctly" do
      mos = EModel.calculate_mos(0.0, 20.0, 100.0, :g711)
      assert mos > 4.0
    end

    test "handles 100% packet loss" do
      mos = EModel.calculate_mos(100.0, 0.0, 50.0, :g711)
      # Should be very low MOS but not crash
      assert mos >= 1.0
      assert mos < 2.0
    end

    test "handles 0ms jitter" do
      mos = EModel.calculate_mos(1.0, 0.0, 100.0, :g711)
      assert mos >= 1.0
      assert mos <= 4.5
    end

    test "handles 0ms delay" do
      mos = EModel.calculate_mos(1.0, 20.0, 0.0, :g711)
      assert mos >= 1.0
      assert mos <= 4.5
    end

    test "handles very high jitter (300ms)" do
      mos = EModel.calculate_mos(0.0, 300.0, 50.0, :g711)
      # High jitter should significantly degrade quality
      assert mos < 3.0
    end

    test "handles very high delay (1000ms)" do
      mos = EModel.calculate_mos(0.0, 0.0, 1000.0, :g711)
      # Very high delay should significantly degrade quality
      # At 1000ms, the delay impairment is substantial but not catastrophic
      # The E-model produces MOS ~2.54 for this case
      assert mos < 3.0, "1000ms delay should yield MOS < 3.0"
      assert mos > 2.0, "1000ms delay alone shouldn't drop below 2.0"
    end

    test "handles negative values gracefully" do
      # Negative values should be treated as 0
      mos_neg_loss = EModel.calculate_mos(-1.0, 20.0, 100.0, :g711)
      mos_zero_loss = EModel.calculate_mos(0.0, 20.0, 100.0, :g711)
      assert_in_delta mos_neg_loss, mos_zero_loss, 0.1

      mos_neg_jitter = EModel.calculate_mos(1.0, -10.0, 100.0, :g711)
      mos_zero_jitter = EModel.calculate_mos(1.0, 0.0, 100.0, :g711)
      assert_in_delta mos_neg_jitter, mos_zero_jitter, 0.1

      mos_neg_delay = EModel.calculate_mos(1.0, 20.0, -50.0, :g711)
      mos_zero_delay = EModel.calculate_mos(1.0, 20.0, 0.0, :g711)
      assert_in_delta mos_neg_delay, mos_zero_delay, 0.1
    end

    test "handles integer inputs" do
      # Should accept integers and convert to float internally
      mos = EModel.calculate_mos(1, 20, 100, :g711)
      assert mos >= 1.0
      assert mos <= 4.5
    end
  end

  # ===========================================================================
  # Consistency and Monotonicity Tests
  # ===========================================================================

  describe "consistency properties" do
    test "MOS decreases monotonically with increasing packet loss" do
      mos_values =
        for loss <- [0, 1, 2, 5, 10, 20] do
          EModel.calculate_mos(loss * 1.0, 20.0, 100.0, :g711)
        end

      # Verify each subsequent MOS is lower
      mos_values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] ->
        assert curr <= prev,
               "MOS should decrease with higher loss: #{inspect(mos_values)}"
      end)
    end

    test "MOS decreases monotonically with increasing jitter" do
      mos_values =
        for jitter <- [0, 10, 20, 50, 100, 200] do
          EModel.calculate_mos(1.0, jitter * 1.0, 100.0, :g711)
        end

      mos_values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] ->
        assert curr <= prev,
               "MOS should decrease with higher jitter: #{inspect(mos_values)}"
      end)
    end

    test "MOS decreases monotonically with increasing delay (above 100ms threshold)" do
      mos_values =
        for delay <- [100, 150, 200, 300, 400, 500] do
          EModel.calculate_mos(1.0, 20.0, delay * 1.0, :g711)
        end

      mos_values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [prev, curr] ->
        assert curr <= prev,
               "MOS should decrease with higher delay: #{inspect(mos_values)}"
      end)
    end

    test "R-factor is always between 0 and R0 for valid inputs" do
      for _ <- 1..50 do
        loss = :rand.uniform() * 20.0
        jitter = :rand.uniform() * 100.0
        delay = :rand.uniform() * 300.0

        r = EModel.calculate_r_factor(loss, jitter, delay, :g711)
        assert r >= 0.0
        assert r <= 93.2 + 0.1  # Allow small floating point tolerance
      end
    end
  end

  # ===========================================================================
  # Effective Delay Calculation Tests
  # ===========================================================================

  describe "effective_delay/2" do
    test "calculates effective delay correctly" do
      # effective_delay = delay_ms + jitter_ms * 2
      assert EModel.effective_delay(50.0, 10.0) == 70.0
      assert EModel.effective_delay(100.0, 0.0) == 100.0
      assert EModel.effective_delay(50.0, 50.0) == 150.0
    end

    test "handles zero jitter" do
      assert EModel.effective_delay(100.0, 0.0) == 100.0
    end

    test "handles zero delay" do
      assert EModel.effective_delay(0.0, 25.0) == 50.0
    end
  end
end
