defmodule ParrotMedia.MOS.EventTest do
  @moduledoc """
  Tests for MOS Event struct.

  The Event struct represents a threshold crossing event with:
  - type: :threshold_crossed
  - session_id: the media session identifier
  - mos: the MOS score that triggered the crossing
  - threshold: the threshold name (atom like :excellent, :good, :fair)
  - direction: :rising or :falling
  - timestamp: when the crossing occurred
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Event

  # ===========================================================================
  # Struct Definition Tests
  # ===========================================================================

  describe "Event struct" do
    test "defines required fields" do
      event = %Event{
        type: :threshold_crossed,
        session_id: "session-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      }

      assert event.type == :threshold_crossed
      assert event.session_id == "session-123"
      assert event.mos == 3.4
      assert event.threshold == :good
      assert event.direction == :falling
      assert %DateTime{} = event.timestamp
    end

    test "enforces required keys" do
      # Cannot create Event struct without required fields
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Event, %{})
      end
    end
  end

  # ===========================================================================
  # new/1 Validation Tests
  # ===========================================================================

  describe "Event.new/1" do
    test "creates valid event with all fields" do
      timestamp = DateTime.utc_now()

      {:ok, event} =
        Event.new(
          type: :threshold_crossed,
          session_id: "session-123",
          mos: 3.4,
          threshold: :good,
          direction: :falling,
          timestamp: timestamp
        )

      assert event.type == :threshold_crossed
      assert event.session_id == "session-123"
      assert event.mos == 3.4
      assert event.threshold == :good
      assert event.direction == :falling
      assert event.timestamp == timestamp
    end

    test "returns error for missing type" do
      assert {:error, :missing_type} =
               Event.new(
                 session_id: "session-123",
                 mos: 3.4,
                 threshold: :good,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for invalid type" do
      assert {:error, :invalid_type} =
               Event.new(
                 type: :invalid_type,
                 session_id: "session-123",
                 mos: 3.4,
                 threshold: :good,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for missing session_id" do
      assert {:error, :missing_session_id} =
               Event.new(
                 type: :threshold_crossed,
                 mos: 3.4,
                 threshold: :good,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for nil session_id" do
      assert {:error, :missing_session_id} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: nil,
                 mos: 3.4,
                 threshold: :good,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for missing mos" do
      assert {:error, :missing_mos} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: "session-123",
                 threshold: :good,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for mos out of range (too low)" do
      assert {:error, :mos_out_of_range} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: "session-123",
                 mos: 0.5,
                 threshold: :good,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for mos out of range (too high)" do
      assert {:error, :mos_out_of_range} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: "session-123",
                 mos: 5.5,
                 threshold: :good,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for missing threshold" do
      assert {:error, :missing_threshold} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: "session-123",
                 mos: 3.4,
                 direction: :falling,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for missing direction" do
      assert {:error, :missing_direction} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: "session-123",
                 mos: 3.4,
                 threshold: :good,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for invalid direction" do
      assert {:error, :invalid_direction} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: "session-123",
                 mos: 3.4,
                 threshold: :good,
                 direction: :sideways,
                 timestamp: DateTime.utc_now()
               )
    end

    test "returns error for missing timestamp" do
      assert {:error, :missing_timestamp} =
               Event.new(
                 type: :threshold_crossed,
                 session_id: "session-123",
                 mos: 3.4,
                 threshold: :good,
                 direction: :falling
               )
    end
  end

  # ===========================================================================
  # Direction Validation Tests
  # ===========================================================================

  describe "direction validation" do
    test "accepts :rising direction" do
      {:ok, event} =
        Event.new(
          type: :threshold_crossed,
          session_id: "session-123",
          mos: 4.1,
          threshold: :excellent,
          direction: :rising,
          timestamp: DateTime.utc_now()
        )

      assert event.direction == :rising
    end

    test "accepts :falling direction" do
      {:ok, event} =
        Event.new(
          type: :threshold_crossed,
          session_id: "session-123",
          mos: 3.4,
          threshold: :good,
          direction: :falling,
          timestamp: DateTime.utc_now()
        )

      assert event.direction == :falling
    end
  end

  # ===========================================================================
  # MOS Range Boundary Tests
  # ===========================================================================

  describe "MOS range boundaries" do
    test "accepts minimum valid MOS (1.0)" do
      {:ok, event} =
        Event.new(
          type: :threshold_crossed,
          session_id: "session-123",
          mos: 1.0,
          threshold: :poor,
          direction: :falling,
          timestamp: DateTime.utc_now()
        )

      assert event.mos == 1.0
    end

    test "accepts maximum valid MOS (5.0)" do
      {:ok, event} =
        Event.new(
          type: :threshold_crossed,
          session_id: "session-123",
          mos: 5.0,
          threshold: :excellent,
          direction: :rising,
          timestamp: DateTime.utc_now()
        )

      assert event.mos == 5.0
    end

    test "accepts MOS as integer" do
      {:ok, event} =
        Event.new(
          type: :threshold_crossed,
          session_id: "session-123",
          mos: 4,
          threshold: :excellent,
          direction: :rising,
          timestamp: DateTime.utc_now()
        )

      assert event.mos == 4
    end
  end

  # ===========================================================================
  # Threshold Types Tests
  # ===========================================================================

  describe "threshold types" do
    test "accepts atom threshold names" do
      for threshold <- [:excellent, :good, :fair, :poor, :custom_threshold] do
        {:ok, event} =
          Event.new(
            type: :threshold_crossed,
            session_id: "session-123",
            mos: 3.5,
            threshold: threshold,
            direction: :falling,
            timestamp: DateTime.utc_now()
          )

        assert event.threshold == threshold
      end
    end
  end

  # ===========================================================================
  # threshold_crossed/1 Convenience Function Tests
  # ===========================================================================

  describe "Event.threshold_crossed/1" do
    test "creates threshold crossed event with defaults" do
      {:ok, event} =
        Event.threshold_crossed(
          session_id: "session-123",
          mos: 3.4,
          threshold: :good,
          direction: :falling
        )

      assert event.type == :threshold_crossed
      assert event.session_id == "session-123"
      assert event.mos == 3.4
      assert event.threshold == :good
      assert event.direction == :falling
      # Should have a timestamp
      assert %DateTime{} = event.timestamp
    end

    test "accepts explicit timestamp" do
      timestamp = ~U[2024-01-15 10:30:00Z]

      {:ok, event} =
        Event.threshold_crossed(
          session_id: "session-123",
          mos: 3.4,
          threshold: :good,
          direction: :falling,
          timestamp: timestamp
        )

      assert event.timestamp == timestamp
    end
  end
end
