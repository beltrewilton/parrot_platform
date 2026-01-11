defmodule ParrotMedia.MOS.TelemetryTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Telemetry
  alias ParrotMedia.MOS.Score
  alias ParrotMedia.MOS.Interval
  alias ParrotMedia.MOS.Threshold

  describe "event name functions" do
    test "events/0 returns all 3 event names" do
      events = Telemetry.events()

      assert length(events) == 3
      assert [:parrot_media, :mos, :score] in events
      assert [:parrot_media, :mos, :threshold_crossed] in events
      assert [:parrot_media, :mos, :call_summary] in events
    end

    test "score_event/0 returns correct event name" do
      assert Telemetry.score_event() == [:parrot_media, :mos, :score]
    end

    test "threshold_event/0 returns correct event name" do
      assert Telemetry.threshold_event() == [:parrot_media, :mos, :threshold_crossed]
    end

    test "summary_event/0 returns correct event name" do
      assert Telemetry.summary_event() == [:parrot_media, :mos, :call_summary]
    end
  end

  describe "emit_score/3" do
    setup do
      handler_id = "test-score-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :score],
        fn event, measurements, metadata, config ->
          send(config.test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits correct measurements from Score struct" do
      timestamp = DateTime.utc_now()

      {:ok, score} =
        Score.new(
          value: 4.2,
          timestamp: timestamp,
          packet_loss_percent: 0.5,
          jitter_ms: 15.0,
          delay_ms: 50.0,
          r_factor: 90.5
        )

      start_time = ~U[2026-01-10 12:00:00Z]
      end_time = ~U[2026-01-10 12:00:05Z]

      interval =
        Interval.new(start_time)
        |> Interval.add_metrics(%{
          packets_received: 100,
          packets_expected: 100,
          jitter_ms: 15.0,
          delay_ms: 50.0
        })
        |> Interval.complete(end_time)

      :ok = Telemetry.emit_score(score, interval, session_id: "session-123")

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:parrot_media, :mos, :score]
      assert measurements.mos_score == 4.2
      assert measurements.r_factor == 90.5
      assert measurements.packet_loss_percent == 0.5
      assert measurements.jitter_ms == 15.0
      assert measurements.delay_ms == 50.0
      assert measurements.interval_duration_ms == 5000
      assert metadata.session_id == "session-123"
    end

    test "includes all optional metadata" do
      {:ok, score} =
        Score.new(
          value: 4.0,
          timestamp: DateTime.utc_now(),
          packet_loss_percent: 0.0,
          jitter_ms: 10.0,
          delay_ms: 40.0,
          r_factor: 93.0
        )

      interval = Interval.new() |> Interval.complete()

      :ok =
        Telemetry.emit_score(score, interval,
          session_id: "session-456",
          call_id: "call-789",
          codec: :g711,
          direction: :inbound
        )

      assert_receive {:telemetry_event, _event, _measurements, metadata}

      assert metadata.session_id == "session-456"
      assert metadata.call_id == "call-789"
      assert metadata.codec == :g711
      assert metadata.direction == :inbound
    end

    test "handles nil optional score fields gracefully" do
      {:ok, score} =
        Score.new(
          value: 3.5,
          timestamp: DateTime.utc_now()
        )

      interval = Interval.new() |> Interval.complete()

      :ok = Telemetry.emit_score(score, interval, session_id: "session-nil")

      assert_receive {:telemetry_event, _event, measurements, _metadata}

      # nil fields should be preserved or defaulted appropriately
      assert measurements.mos_score == 3.5
      assert measurements.r_factor == nil
      assert measurements.packet_loss_percent == nil
      assert measurements.jitter_ms == nil
      assert measurements.delay_ms == nil
    end

    test "uses interval metrics when score fields are nil" do
      {:ok, score} =
        Score.new(
          value: 3.8,
          timestamp: DateTime.utc_now()
        )

      start_time = ~U[2026-01-10 12:00:00Z]
      end_time = ~U[2026-01-10 12:00:05Z]

      interval =
        Interval.new(start_time)
        |> Interval.add_metrics(%{
          packets_received: 95,
          packets_expected: 100,
          jitter_ms: 20.0,
          delay_ms: 60.0
        })
        |> Interval.complete(end_time)

      :ok =
        Telemetry.emit_score(score, interval,
          session_id: "session-interval",
          use_interval_metrics: true
        )

      assert_receive {:telemetry_event, _event, measurements, _metadata}

      # When use_interval_metrics is true, should fall back to interval values
      assert measurements.interval_duration_ms == 5000
    end
  end

  describe "emit_threshold_crossed/4" do
    setup do
      handler_id = "test-threshold-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :threshold_crossed],
        fn event, measurements, metadata, config ->
          send(config.test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits threshold crossing with falling direction" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      :ok =
        Telemetry.emit_threshold_crossed(3.4, 3.7, threshold,
          session_id: "session-123",
          direction: :falling
        )

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:parrot_media, :mos, :threshold_crossed]
      assert measurements.mos_score == 3.4
      assert measurements.previous_score == 3.7
      assert measurements.threshold == 3.5
      assert metadata.threshold_name == :good
      assert metadata.direction == :falling
      assert metadata.session_id == "session-123"
    end

    test "emits threshold crossing with rising direction" do
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5, hysteresis: 0.1)

      :ok =
        Telemetry.emit_threshold_crossed(3.6, 3.3, threshold,
          session_id: "session-456",
          direction: :rising
        )

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:parrot_media, :mos, :threshold_crossed]
      assert measurements.mos_score == 3.6
      assert measurements.previous_score == 3.3
      assert measurements.threshold == 3.5
      assert metadata.threshold_name == :good
      assert metadata.direction == :rising
      assert metadata.session_id == "session-456"
    end

    test "includes optional call_id in metadata" do
      {:ok, threshold} = Threshold.new(name: :excellent, value: 4.0)

      :ok =
        Telemetry.emit_threshold_crossed(3.9, 4.1, threshold,
          session_id: "session-789",
          call_id: "call-abc",
          direction: :falling
        )

      assert_receive {:telemetry_event, _event, _measurements, metadata}

      assert metadata.session_id == "session-789"
      assert metadata.call_id == "call-abc"
    end

    test "handles custom threshold names" do
      {:ok, threshold} = Threshold.new(name: :critical_quality, value: 2.5)

      :ok =
        Telemetry.emit_threshold_crossed(2.4, 2.6, threshold,
          session_id: "session-custom",
          direction: :falling
        )

      assert_receive {:telemetry_event, _event, _measurements, metadata}

      assert metadata.threshold_name == :critical_quality
    end
  end

  describe "emit_call_summary/2" do
    setup do
      handler_id = "test-summary-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :call_summary],
        fn event, measurements, metadata, config ->
          send(config.test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits all summary measurements" do
      summary = %{
        min_mos: 3.2,
        max_mos: 4.5,
        avg_mos: 3.9,
        total_packets: 10_000,
        total_lost: 50,
        overall_loss_percent: 0.5,
        quality_events_count: 3,
        call_duration_ms: 300_000,
        intervals_calculated: 60
      }

      :ok =
        Telemetry.emit_call_summary(summary,
          session_id: "session-end",
          call_id: "call-end",
          codec: :opus,
          status: :complete
        )

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:parrot_media, :mos, :call_summary]

      # Verify all measurements
      assert measurements.min_mos == 3.2
      assert measurements.max_mos == 4.5
      assert measurements.avg_mos == 3.9
      assert measurements.total_packets == 10_000
      assert measurements.total_lost == 50
      assert measurements.overall_loss_percent == 0.5
      assert measurements.quality_events_count == 3
      assert measurements.call_duration_ms == 300_000
      assert measurements.intervals_calculated == 60

      # Verify metadata
      assert metadata.session_id == "session-end"
      assert metadata.call_id == "call-end"
      assert metadata.codec == :opus
      assert metadata.status == :complete
    end

    test "handles insufficient_data status" do
      summary = %{
        min_mos: nil,
        max_mos: nil,
        avg_mos: nil,
        total_packets: 5,
        total_lost: 0,
        overall_loss_percent: 0.0,
        quality_events_count: 0,
        call_duration_ms: 2000,
        intervals_calculated: 0
      }

      :ok =
        Telemetry.emit_call_summary(summary,
          session_id: "session-short",
          status: :insufficient_data
        )

      assert_receive {:telemetry_event, _event, measurements, metadata}

      assert measurements.min_mos == nil
      assert measurements.max_mos == nil
      assert measurements.avg_mos == nil
      assert measurements.intervals_calculated == 0
      assert metadata.status == :insufficient_data
    end

    test "handles zero quality events" do
      summary = %{
        min_mos: 4.0,
        max_mos: 4.2,
        avg_mos: 4.1,
        total_packets: 1000,
        total_lost: 0,
        overall_loss_percent: 0.0,
        quality_events_count: 0,
        call_duration_ms: 60_000,
        intervals_calculated: 12
      }

      :ok =
        Telemetry.emit_call_summary(summary,
          session_id: "session-stable",
          codec: :g711,
          status: :complete
        )

      assert_receive {:telemetry_event, _event, measurements, _metadata}

      assert measurements.quality_events_count == 0
    end
  end

  describe "telemetry attach/handle integration" do
    test "multiple handlers can attach to same event" do
      handler1_id = "multi-handler-1-#{System.unique_integer([:positive])}"
      handler2_id = "multi-handler-2-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler1_id,
        [:parrot_media, :mos, :score],
        fn _event, _measurements, _metadata, config ->
          send(config.test_pid, :handler1_called)
        end,
        %{test_pid: self()}
      )

      :telemetry.attach(
        handler2_id,
        [:parrot_media, :mos, :score],
        fn _event, _measurements, _metadata, config ->
          send(config.test_pid, :handler2_called)
        end,
        %{test_pid: self()}
      )

      on_exit(fn ->
        :telemetry.detach(handler1_id)
        :telemetry.detach(handler2_id)
      end)

      {:ok, score} =
        Score.new(
          value: 4.0,
          timestamp: DateTime.utc_now()
        )

      interval = Interval.new() |> Interval.complete()

      Telemetry.emit_score(score, interval, session_id: "multi-session")

      assert_receive :handler1_called
      assert_receive :handler2_called
    end

    test "handlers can be attached to all events at once" do
      handler_id = "all-events-handler-#{System.unique_integer([:positive])}"

      for event <- Telemetry.events() do
        :telemetry.attach(
          "#{handler_id}-#{Enum.join(event, "-")}",
          event,
          fn event, _measurements, _metadata, config ->
            send(config.test_pid, {:event_received, event})
          end,
          %{test_pid: self()}
        )
      end

      on_exit(fn ->
        for event <- Telemetry.events() do
          :telemetry.detach("#{handler_id}-#{Enum.join(event, "-")}")
        end
      end)

      # Emit score event
      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())
      interval = Interval.new() |> Interval.complete()
      Telemetry.emit_score(score, interval, session_id: "all-events")

      assert_receive {:event_received, [:parrot_media, :mos, :score]}

      # Emit threshold event
      {:ok, threshold} = Threshold.new(name: :good, value: 3.5)
      Telemetry.emit_threshold_crossed(3.4, 3.6, threshold, session_id: "all-events", direction: :falling)

      assert_receive {:event_received, [:parrot_media, :mos, :threshold_crossed]}

      # Emit summary event
      summary = %{
        min_mos: 3.5,
        max_mos: 4.0,
        avg_mos: 3.8,
        total_packets: 100,
        total_lost: 1,
        overall_loss_percent: 1.0,
        quality_events_count: 1,
        call_duration_ms: 10_000,
        intervals_calculated: 2
      }

      Telemetry.emit_call_summary(summary, session_id: "all-events", status: :complete)

      assert_receive {:event_received, [:parrot_media, :mos, :call_summary]}
    end

    test "detached handlers no longer receive events" do
      handler_id = "detach-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :score],
        fn _event, _measurements, _metadata, config ->
          send(config.test_pid, :handler_called)
        end,
        %{test_pid: self()}
      )

      # Emit and verify handler is called
      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())
      interval = Interval.new() |> Interval.complete()
      Telemetry.emit_score(score, interval, session_id: "detach-test")

      assert_receive :handler_called

      # Detach handler
      :telemetry.detach(handler_id)

      # Emit again - handler should NOT be called
      Telemetry.emit_score(score, interval, session_id: "detach-test-2")

      refute_receive :handler_called, 100
    end
  end
end
