defmodule ParrotMedia.RTCP.SinkTest do
  @moduledoc """
  Tests for the RTCP Sink element.

  The RTCP Sink receives and parses RTCP packets (primarily Receiver Reports),
  extracts quality metrics, and forwards them to the MOS Calculator.
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.RTCP.Sink

  # ===========================================================================
  # RTCP Packet Test Data (RFC 3550)
  # ===========================================================================

  # A valid RTCP Receiver Report packet structure:
  # - Header: version=2, padding=0, RC=1 (1 report block), PT=201 (RR)
  # - SSRC of sender
  # - Report block(s) with: SSRC, fraction_lost, cumulative_lost,
  #   extended_highest_seq, jitter, last_sr, delay_since_last_sr

  @rr_packet_single_report <<
    # Header: V=2, P=0, RC=1, PT=201 (RR), Length=7 (32-bit words - 1)
    0x81, 0xC9, 0x00, 0x07,
    # SSRC of packet sender
    0x12, 0x34, 0x56, 0x78,
    # Report block 1:
    # SSRC of source being reported
    0xAB, 0xCD, 0xEF, 0x01,
    # Fraction lost (8 bits) + Cumulative lost (24 bits) = 5% loss (13/256 ≈ 5%)
    0x0D, 0x00, 0x00, 0x10,
    # Extended highest sequence number received
    0x00, 0x01, 0x00, 0x50,
    # Interarrival jitter (in RTP timestamp units, 8kHz clock = 160 = 20ms)
    0x00, 0x00, 0x00, 0xA0,
    # Last SR timestamp (middle 32 bits of NTP)
    0x11, 0x22, 0x33, 0x44,
    # Delay since last SR (1/65536 sec units, 65536 = 1 second)
    0x00, 0x01, 0x00, 0x00
  >>

  @rr_packet_no_reports <<
    # Header: V=2, P=0, RC=0, PT=201 (RR), Length=1
    0x80, 0xC9, 0x00, 0x01,
    # SSRC of packet sender
    0x12, 0x34, 0x56, 0x78
  >>

  # Sender Report packet (PT=200) - should be handled but metrics extracted differently
  @sr_packet <<
    # Header: V=2, P=0, RC=1, PT=200 (SR), Length=12
    0x81, 0xC8, 0x00, 0x0C,
    # SSRC
    0x12, 0x34, 0x56, 0x78,
    # NTP timestamp (64 bits)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    # RTP timestamp
    0x00, 0x00, 0x00, 0x00,
    # Sender's packet count
    0x00, 0x00, 0x00, 0x64,
    # Sender's octet count
    0x00, 0x00, 0x32, 0x00,
    # Report block (same structure as RR)
    0xAB, 0xCD, 0xEF, 0x01,
    0x0D, 0x00, 0x00, 0x10,
    0x00, 0x01, 0x00, 0x50,
    0x00, 0x00, 0x00, 0xA0,
    0x11, 0x22, 0x33, 0x44,
    0x00, 0x01, 0x00, 0x00
  >>

  # ===========================================================================
  # Unit Tests: RTCP Parsing
  # ===========================================================================

  describe "parse_rtcp/1" do
    test "parses valid RR packet with single report block" do
      assert {:ok, metrics} = Sink.parse_rtcp(@rr_packet_single_report)

      assert metrics.ssrc == 0xABCDEF01
      # Fraction lost: 13/256 * 100 = ~5.08%
      assert_in_delta metrics.loss_percent, 5.08, 0.1
      # Jitter: 160 / (8000/1000) = 20ms for 8kHz clock
      assert_in_delta metrics.jitter_ms, 20.0, 1.0
      # RTT calculation from LSR + DLSR
      assert metrics.lsr != nil
      assert metrics.dlsr != nil
    end

    test "handles RR packet with no report blocks" do
      assert {:ok, :no_reports} = Sink.parse_rtcp(@rr_packet_no_reports)
    end

    test "extracts report blocks from SR packet" do
      assert {:ok, metrics} = Sink.parse_rtcp(@sr_packet)

      # SR packets also contain report blocks
      assert metrics.ssrc == 0xABCDEF01
      assert_in_delta metrics.loss_percent, 5.08, 0.1
    end

    test "returns error for malformed packet" do
      assert {:error, :invalid_rtcp} = Sink.parse_rtcp(<<1, 2, 3>>)
    end

    test "returns error for non-RTCP data" do
      # RTP packet (version 2, PT < 200)
      rtp_packet = <<0x80, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00>>
      assert {:error, :not_rtcp} = Sink.parse_rtcp(rtp_packet)
    end
  end

  # ===========================================================================
  # Unit Tests: Metric Conversion
  # ===========================================================================

  describe "convert_jitter/2" do
    test "converts jitter from RTP timestamp units to milliseconds for 8kHz" do
      # 160 timestamp units at 8kHz = 20ms
      assert_in_delta Sink.convert_jitter(160, 8000), 20.0, 0.1
    end

    test "converts jitter for 16kHz clock rate" do
      # 320 timestamp units at 16kHz = 20ms
      assert_in_delta Sink.convert_jitter(320, 16000), 20.0, 0.1
    end

    test "converts jitter for 48kHz clock rate" do
      # 960 timestamp units at 48kHz = 20ms
      assert_in_delta Sink.convert_jitter(960, 48000), 20.0, 0.1
    end

    test "returns 0 for zero jitter" do
      assert Sink.convert_jitter(0, 8000) == 0.0
    end
  end

  describe "calculate_rtt/2" do
    test "calculates RTT from LSR and DLSR" do
      # If DLSR = 65536 (1 second) and we assume current time - LSR = 1.5 sec
      # RTT = 1.5 - 1.0 = 0.5 sec = 500ms
      # This requires knowing when the SR was sent, so we need the current NTP time
      lsr = 0x11223344
      dlsr = 0x00010000  # 1 second in 1/65536 units

      # For unit test, we verify the calculation formula is correct
      # RTT = (current_ntp_mid32 - LSR) - DLSR
      # The function needs current time, so we mock it
      assert {:ok, rtt_ms} = Sink.calculate_rtt(lsr, dlsr, current_ntp: 0x11233344)
      # Expected: (0x11233344 - 0x11223344) - 0x00010000 = 0x00010000 - 0x00010000 = 0
      # Actually: 0x11233344 - 0x11223344 = 0x10000 (65536 = 1 second)
      # RTT = 1 sec - 1 sec = 0ms
      assert_in_delta rtt_ms, 0.0, 1.0
    end

    test "returns nil when LSR is 0 (no SR received yet)" do
      assert {:ok, nil} = Sink.calculate_rtt(0, 0)
    end
  end

  describe "fraction_lost_to_percent/1" do
    test "converts 0 to 0%" do
      assert Sink.fraction_lost_to_percent(0) == 0.0
    end

    test "converts 256 to 100%" do
      # Fraction lost is 8-bit, so 255 is max
      assert_in_delta Sink.fraction_lost_to_percent(255), 99.6, 0.5
    end

    test "converts 128 to ~50%" do
      assert_in_delta Sink.fraction_lost_to_percent(128), 50.0, 0.5
    end

    test "converts 13 to ~5%" do
      assert_in_delta Sink.fraction_lost_to_percent(13), 5.08, 0.1
    end
  end

  # ===========================================================================
  # Integration Tests: MOS Calculator Integration
  # ===========================================================================

  describe "send_to_calculator/2" do
    setup do
      session_id = "rtcp-test-#{:erlang.unique_integer([:positive])}"

      # Start a MOS Calculator for testing
      {:ok, calc_pid} = ParrotMedia.MOS.Calculator.start_link(
        session_id: session_id,
        codec: :g711,
        config: ParrotMedia.MOS.Config.new(interval_ms: 50, min_packets_per_interval: 1)
      )

      on_exit(fn ->
        if Process.alive?(calc_pid), do: ParrotMedia.MOS.Calculator.stop(calc_pid)
      end)

      {:ok, session_id: session_id, calc_pid: calc_pid}
    end

    test "sends RTCP metrics to MOS Calculator", ctx do
      metrics = %{
        jitter_ms: 15.0,
        rtt_ms: 100.0,
        loss_percent: 2.0
      }

      assert :ok = Sink.send_to_calculator(ctx.session_id, metrics)

      # The Calculator should receive the metrics
      # We verify by checking the summary after an interval
      Process.sleep(100)

      {:ok, summary} = ParrotMedia.MOS.call_summary(ctx.session_id)
      # With real RTCP data, the jitter should reflect our input
      assert summary != nil
    end

    test "handles missing calculator gracefully" do
      metrics = %{jitter_ms: 10.0, rtt_ms: 50.0, loss_percent: 0.0}

      # Should not crash when calculator doesn't exist
      assert :ok = Sink.send_to_calculator("nonexistent-session", metrics)
    end
  end
end
