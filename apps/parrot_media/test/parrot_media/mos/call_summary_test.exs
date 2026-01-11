defmodule ParrotMedia.MOS.CallSummaryTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.CallSummary

  describe "new/1" do
    test "creates valid summary with all required fields" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-session-123",
                 min_mos: 3.5,
                 max_mos: 4.3,
                 avg_mos: 3.9,
                 total_packets: 5000,
                 total_lost: 50,
                 intervals_calculated: 10,
                 duration_ms: 50_000,
                 status: :complete
               )

      assert summary.session_id == "test-session-123"
      assert summary.min_mos == 3.5
      assert summary.max_mos == 4.3
      assert summary.avg_mos == 3.9
      assert summary.total_packets == 5000
      assert summary.total_lost == 50
      assert summary.intervals_calculated == 10
      assert summary.duration_ms == 50_000
      assert summary.status == :complete
    end

    test "creates summary with quality_events list" do
      events = [
        %{
          type: :threshold_crossed,
          mos: 2.9,
          threshold: 3.0,
          timestamp: ~U[2026-01-10 12:00:30Z]
        },
        %{type: :threshold_crossed, mos: 3.1, threshold: 3.0, timestamp: ~U[2026-01-10 12:00:45Z]}
      ]

      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-session-123",
                 min_mos: 2.9,
                 max_mos: 4.0,
                 avg_mos: 3.5,
                 total_packets: 5000,
                 total_lost: 150,
                 intervals_calculated: 10,
                 duration_ms: 50_000,
                 status: :complete,
                 quality_events: events
               )

      assert summary.quality_events == events
      assert length(summary.quality_events) == 2
    end

    test "defaults quality_events to empty list when not provided" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-session-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 5000,
                 total_lost: 50,
                 intervals_calculated: 10,
                 duration_ms: 50_000,
                 status: :complete
               )

      assert summary.quality_events == []
    end

    test "calculates overall_loss_percent from total_packets and total_lost" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-session-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: 50,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )

      assert summary.overall_loss_percent == 5.0
    end

    test "calculates overall_loss_percent with zero total_lost" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-session-123",
                 min_mos: 4.3,
                 max_mos: 4.5,
                 avg_mos: 4.4,
                 total_packets: 10_000,
                 total_lost: 0,
                 intervals_calculated: 20,
                 duration_ms: 100_000,
                 status: :complete
               )

      assert summary.overall_loss_percent == 0.0
    end

    test "handles zero total_packets for overall_loss_percent" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-session-123",
                 min_mos: 1.0,
                 max_mos: 1.0,
                 avg_mos: 1.0,
                 total_packets: 0,
                 total_lost: 0,
                 intervals_calculated: 0,
                 duration_ms: 5000,
                 status: :insufficient_data
               )

      assert summary.overall_loss_percent == 0.0
    end

    test "creates summary with insufficient_data status" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "short-call-456",
                 min_mos: 1.0,
                 max_mos: 1.0,
                 avg_mos: 1.0,
                 total_packets: 5,
                 total_lost: 0,
                 intervals_calculated: 0,
                 duration_ms: 500,
                 status: :insufficient_data
               )

      assert summary.status == :insufficient_data
    end

    test "creates summary with one_way_audio status" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "one-way-789",
                 min_mos: 3.0,
                 max_mos: 4.0,
                 avg_mos: 3.5,
                 total_packets: 2500,
                 total_lost: 25,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :one_way_audio
               )

      assert summary.status == :one_way_audio
    end
  end

  describe "new/1 validation" do
    test "returns error when session_id is missing" do
      assert {:error, :missing_session_id} =
               CallSummary.new(
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when session_id is nil" do
      assert {:error, :missing_session_id} =
               CallSummary.new(
                 session_id: nil,
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when min_mos is below 1.0" do
      assert {:error, :min_mos_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 0.5,
                 max_mos: 4.0,
                 avg_mos: 3.0,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when min_mos is above 5.0" do
      assert {:error, :min_mos_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 5.5,
                 max_mos: 5.5,
                 avg_mos: 5.5,
                 total_packets: 1000,
                 total_lost: 0,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when max_mos is below 1.0" do
      # min_mos is valid, but max_mos is below 1.0
      assert {:error, :max_mos_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 1.0,
                 max_mos: 0.9,
                 avg_mos: 1.0,
                 total_packets: 1000,
                 total_lost: 500,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when max_mos is above 5.0" do
      assert {:error, :max_mos_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 4.0,
                 max_mos: 5.1,
                 avg_mos: 4.5,
                 total_packets: 1000,
                 total_lost: 0,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when avg_mos is below 1.0" do
      assert {:error, :avg_mos_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 1.0,
                 max_mos: 4.0,
                 avg_mos: 0.5,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when avg_mos is above 5.0" do
      assert {:error, :avg_mos_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 4.0,
                 max_mos: 5.0,
                 avg_mos: 5.1,
                 total_packets: 1000,
                 total_lost: 0,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when total_packets is negative" do
      assert {:error, :total_packets_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: -1,
                 total_lost: 0,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when total_lost is negative" do
      assert {:error, :total_lost_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: -1,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when intervals_calculated is negative" do
      assert {:error, :intervals_calculated_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: -1,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when duration_ms is negative" do
      assert {:error, :duration_ms_out_of_range} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: -1,
                 status: :complete
               )
    end

    test "returns error when status is invalid" do
      assert {:error, :invalid_status} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :unknown
               )
    end

    test "returns error when status is missing" do
      assert {:error, :missing_status} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000
               )
    end

    test "accepts MOS values at boundaries (1.0 and 5.0)" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 1.0,
                 max_mos: 5.0,
                 avg_mos: 3.0,
                 total_packets: 1000,
                 total_lost: 100,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )

      assert summary.min_mos == 1.0
      assert summary.max_mos == 5.0
    end

    test "accepts zero for total_packets" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 1.0,
                 max_mos: 1.0,
                 avg_mos: 1.0,
                 total_packets: 0,
                 total_lost: 0,
                 intervals_calculated: 0,
                 duration_ms: 500,
                 status: :insufficient_data
               )

      assert summary.total_packets == 0
    end

    test "accepts zero for duration_ms" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 1.0,
                 max_mos: 1.0,
                 avg_mos: 1.0,
                 total_packets: 0,
                 total_lost: 0,
                 intervals_calculated: 0,
                 duration_ms: 0,
                 status: :insufficient_data
               )

      assert summary.duration_ms == 0
    end

    test "returns error when min_mos is greater than avg_mos" do
      assert {:error, :min_mos_exceeds_avg_mos} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 4.0,
                 max_mos: 4.5,
                 avg_mos: 3.5,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when avg_mos is greater than max_mos" do
      assert {:error, :avg_mos_exceeds_max_mos} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.0,
                 max_mos: 3.5,
                 avg_mos: 4.0,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when min_mos is greater than max_mos" do
      assert {:error, :min_mos_exceeds_max_mos} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 4.5,
                 max_mos: 3.5,
                 avg_mos: 4.0,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when total_lost exceeds total_packets" do
      assert {:error, :total_lost_exceeds_total_packets} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.0,
                 max_mos: 4.0,
                 avg_mos: 3.5,
                 total_packets: 100,
                 total_lost: 150,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete
               )
    end

    test "returns error when quality_events is not a list" do
      assert {:error, :invalid_quality_events} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.0,
                 max_mos: 4.0,
                 avg_mos: 3.5,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete,
                 quality_events: "not a list"
               )
    end

    test "returns error when quality_events is a map" do
      assert {:error, :invalid_quality_events} =
               CallSummary.new(
                 session_id: "test-123",
                 min_mos: 3.0,
                 max_mos: 4.0,
                 avg_mos: 3.5,
                 total_packets: 1000,
                 total_lost: 10,
                 intervals_calculated: 5,
                 duration_ms: 25_000,
                 status: :complete,
                 quality_events: %{type: :threshold_crossed}
               )
    end
  end

  describe "struct definition" do
    test "CallSummary struct exists with expected fields" do
      summary = %CallSummary{
        session_id: "test",
        min_mos: 3.0,
        max_mos: 4.0,
        avg_mos: 3.5,
        total_packets: 1000,
        total_lost: 10,
        overall_loss_percent: 1.0,
        quality_events: [],
        intervals_calculated: 5,
        duration_ms: 25_000,
        status: :complete
      }

      assert Map.has_key?(summary, :session_id)
      assert Map.has_key?(summary, :min_mos)
      assert Map.has_key?(summary, :max_mos)
      assert Map.has_key?(summary, :avg_mos)
      assert Map.has_key?(summary, :total_packets)
      assert Map.has_key?(summary, :total_lost)
      assert Map.has_key?(summary, :overall_loss_percent)
      assert Map.has_key?(summary, :quality_events)
      assert Map.has_key?(summary, :intervals_calculated)
      assert Map.has_key?(summary, :duration_ms)
      assert Map.has_key?(summary, :status)
    end

    test "CallSummary struct enforces required keys" do
      keys = CallSummary.__struct__() |> Map.keys()

      assert :session_id in keys
      assert :min_mos in keys
      assert :max_mos in keys
      assert :avg_mos in keys
      assert :total_packets in keys
      assert :total_lost in keys
      assert :status in keys
    end
  end

  describe "edge cases" do
    test "handles typical excellent quality call summary" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "excellent-call-001",
                 min_mos: 4.2,
                 max_mos: 4.5,
                 avg_mos: 4.35,
                 total_packets: 15_000,
                 total_lost: 15,
                 intervals_calculated: 30,
                 duration_ms: 150_000,
                 status: :complete
               )

      assert summary.overall_loss_percent == 0.1
      assert summary.status == :complete
    end

    test "handles typical poor quality call summary" do
      events = [
        %{
          type: :threshold_crossed,
          mos: 2.8,
          threshold: 3.0,
          timestamp: ~U[2026-01-10 12:01:00Z]
        },
        %{type: :threshold_crossed, mos: 2.5, threshold: 3.0, timestamp: ~U[2026-01-10 12:01:15Z]}
      ]

      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "poor-call-002",
                 min_mos: 2.3,
                 max_mos: 3.5,
                 avg_mos: 2.9,
                 total_packets: 10_000,
                 total_lost: 800,
                 intervals_calculated: 20,
                 duration_ms: 100_000,
                 status: :complete,
                 quality_events: events
               )

      assert summary.overall_loss_percent == 8.0
      assert length(summary.quality_events) == 2
    end

    test "handles very short call with insufficient data" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "short-call-003",
                 min_mos: 1.0,
                 max_mos: 1.0,
                 avg_mos: 1.0,
                 total_packets: 8,
                 total_lost: 0,
                 intervals_calculated: 0,
                 duration_ms: 400,
                 status: :insufficient_data
               )

      assert summary.status == :insufficient_data
      assert summary.intervals_calculated == 0
    end

    test "handles high packet loss scenario" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "high-loss-004",
                 min_mos: 1.5,
                 max_mos: 2.8,
                 avg_mos: 2.1,
                 total_packets: 5000,
                 total_lost: 1000,
                 intervals_calculated: 10,
                 duration_ms: 50_000,
                 status: :complete
               )

      assert summary.overall_loss_percent == 20.0
    end

    test "handles integer values for float MOS fields" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "integer-mos-005",
                 min_mos: 3,
                 max_mos: 4,
                 avg_mos: 4,
                 total_packets: 10_000,
                 total_lost: 100,
                 intervals_calculated: 20,
                 duration_ms: 100_000,
                 status: :complete
               )

      assert summary.min_mos == 3
      assert summary.max_mos == 4
      assert summary.avg_mos == 4
    end

    test "handles floating point precision in loss calculation" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "precision-006",
                 min_mos: 3.5,
                 max_mos: 4.0,
                 avg_mos: 3.8,
                 total_packets: 3,
                 total_lost: 1,
                 intervals_calculated: 1,
                 duration_ms: 5000,
                 status: :complete
               )

      # 1/3 * 100 = 33.333...
      assert_in_delta summary.overall_loss_percent, 33.333, 0.001
    end

    test "handles max_mos equal to min_mos (stable quality)" do
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "stable-007",
                 min_mos: 4.0,
                 max_mos: 4.0,
                 avg_mos: 4.0,
                 total_packets: 5000,
                 total_lost: 50,
                 intervals_calculated: 10,
                 duration_ms: 50_000,
                 status: :complete
               )

      assert summary.min_mos == summary.max_mos
      assert summary.min_mos == summary.avg_mos
    end
  end

  describe "acceptance scenarios" do
    test "completed call provides min/max/avg MOS" do
      # US2 Scenario 1: Given a completed call, When the call ends,
      # Then the system provides minimum, maximum, and average MOS scores
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "completed-call-us2-1",
                 min_mos: 3.2,
                 max_mos: 4.4,
                 avg_mos: 3.9,
                 total_packets: 12_000,
                 total_lost: 120,
                 intervals_calculated: 24,
                 duration_ms: 120_000,
                 status: :complete
               )

      assert summary.min_mos == 3.2
      assert summary.max_mos == 4.4
      assert summary.avg_mos == 3.9
    end

    test "quality events include timestamps in summary" do
      # US2 Scenario 2: Given a completed call with quality events,
      # When the call ends, Then the summary includes timestamps of quality degradation periods
      quality_events = [
        %{
          type: :threshold_crossed,
          mos: 2.9,
          threshold: 3.0,
          direction: :down,
          timestamp: ~U[2026-01-10 12:05:30Z]
        },
        %{
          type: :threshold_crossed,
          mos: 3.1,
          threshold: 3.0,
          direction: :up,
          timestamp: ~U[2026-01-10 12:06:15Z]
        }
      ]

      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "quality-events-us2-2",
                 min_mos: 2.9,
                 max_mos: 4.0,
                 avg_mos: 3.5,
                 total_packets: 10_000,
                 total_lost: 200,
                 intervals_calculated: 20,
                 duration_ms: 100_000,
                 status: :complete,
                 quality_events: quality_events
               )

      assert length(summary.quality_events) == 2

      [first_event, second_event] = summary.quality_events
      assert first_event.timestamp == ~U[2026-01-10 12:05:30Z]
      assert second_event.timestamp == ~U[2026-01-10 12:06:15Z]
    end

    test "no audio packets indicates insufficient data" do
      # US2 Scenario 3: Given a call with no audio packets received,
      # When the call ends, Then the summary indicates insufficient data for MOS calculation
      assert {:ok, summary} =
               CallSummary.new(
                 session_id: "no-audio-us2-3",
                 min_mos: 1.0,
                 max_mos: 1.0,
                 avg_mos: 1.0,
                 total_packets: 0,
                 total_lost: 0,
                 intervals_calculated: 0,
                 duration_ms: 10_000,
                 status: :insufficient_data
               )

      assert summary.status == :insufficient_data
      assert summary.total_packets == 0
    end
  end
end
