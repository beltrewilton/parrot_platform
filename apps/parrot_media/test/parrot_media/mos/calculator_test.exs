defmodule ParrotMedia.MOS.CalculatorTest do
  @moduledoc """
  Tests for the MOS Calculator GenServer.

  The Calculator orchestrates MOS calculation by:
  - Receiving metrics from the Observer
  - Managing calculation intervals
  - Using E-Model to compute scores
  - Detecting threshold crossings
  - Notifying registered handlers

  These tests verify BEHAVIOR through public APIs, not internal state.
  """
  # async: false because tests attach global telemetry handlers that would
  # interfere with each other when running in parallel
  use ExUnit.Case, async: false

  alias ParrotMedia.MOS.Calculator
  alias ParrotMedia.MOS.CallSummary
  alias ParrotMedia.MOS.Config
  alias ParrotMedia.MOS.Score
  alias ParrotMedia.MOS.Threshold

  # ===========================================================================
  # Setup and Helpers
  # ===========================================================================

  setup do
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  defp start_calculator(ctx, opts \\ []) do
    defaults = [
      session_id: ctx.session_id,
      codec: :g711,
      # Use a short interval for testing
      config: Config.new(interval_ms: 100, min_packets_per_interval: 5)
    ]

    opts = Keyword.merge(defaults, opts)
    Calculator.start_link(opts)
  end

  defp good_metrics do
    %{
      packets_received: 50,
      packets_expected: 50,
      jitter_ms: 10.0,
      delay_ms: 50.0
    }
  end

  defp poor_metrics do
    %{
      packets_received: 40,
      packets_expected: 50,
      jitter_ms: 100.0,
      delay_ms: 300.0
    }
  end

  # ===========================================================================
  # Start / Stop Tests
  # ===========================================================================

  describe "start_link/1" do
    test "starts calculator with valid options", ctx do
      assert {:ok, pid} = start_calculator(ctx)
      assert Process.alive?(pid)
      Calculator.stop(pid)
    end

    test "requires session_id", _ctx do
      assert {:error, :missing_session_id} = Calculator.start_link(codec: :g711)
    end

    test "registers with MOS.Registry by session_id", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Verify registration
      assert [{^pid, _}] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)

      Calculator.stop(pid)
    end

    test "uses G.711 codec by default and produces expected MOS range", ctx do
      {:ok, pid} = start_calculator(ctx, codec: nil)

      # Add good metrics to get a score
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(150)

      # G.711 with good metrics should produce MOS >= 4.0
      score = Calculator.current_score(pid)
      assert %Score{} = score
      assert score.value >= 4.0

      Calculator.stop(pid)
    end

    test "Opus codec produces different MOS due to higher equipment impairment", ctx do
      # Start two calculators with different codecs
      {:ok, g711_pid} = start_calculator(ctx, codec: :g711, session_id: "#{ctx.session_id}-g711")
      {:ok, opus_pid} = start_calculator(ctx, codec: :opus, session_id: "#{ctx.session_id}-opus")

      # Add identical metrics to both
      for _ <- 1..5 do
        Calculator.add_metrics(g711_pid, good_metrics())
        Calculator.add_metrics(opus_pid, good_metrics())
      end

      Process.sleep(150)

      g711_score = Calculator.current_score(g711_pid)
      opus_score = Calculator.current_score(opus_pid)

      # Both should have scores
      assert %Score{} = g711_score
      assert %Score{} = opus_score

      # Opus has higher equipment impairment factor (Ie), so MOS is typically lower
      # This tests that codec configuration actually affects the E-Model calculation
      assert opus_score.value != g711_score.value

      Calculator.stop(g711_pid)
      Calculator.stop(opus_pid)
    end

    test "call_id is included in telemetry metadata", ctx do
      test_pid = self()
      handler_id = "test-handler-#{ctx.session_id}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :call_summary],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_metadata, metadata})
        end,
        nil
      )

      {:ok, pid} =
        start_calculator(ctx,
          call_id: "call-123",
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      Calculator.stop(pid)

      assert_receive {:telemetry_metadata, metadata}, 500
      assert metadata.call_id == "call-123"

      :telemetry.detach(handler_id)
    end

    test "direction option affects one-way audio detection in summary", ctx do
      {:ok, pid} =
        start_calculator(ctx,
          direction: :inbound,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      # Add only inbound-direction metrics
      for _ <- 1..10 do
        Calculator.add_metrics(pid, Map.put(good_metrics(), :direction, :inbound))
      end

      Process.sleep(100)

      summary = Calculator.stop(pid)

      # One-way audio detected via summary status
      assert %CallSummary{} = summary
      assert summary.status == :one_way_audio
    end

    test "config min_packets_per_interval affects whether scores are calculated", ctx do
      # High threshold that won't be met
      high_threshold_config = Config.new(interval_ms: 50, min_packets_per_interval: 1000)
      {:ok, pid} = start_calculator(ctx, config: high_threshold_config)

      # Add some metrics (way below threshold)
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      # No scores should be calculated because min packets not met
      assert Calculator.current_score(pid) == nil

      summary = Calculator.stop(pid)
      assert summary.intervals_calculated == 0
      assert summary.status == :insufficient_data
    end
  end

  describe "stop/1" do
    test "stops the calculator gracefully", ctx do
      {:ok, pid} = start_calculator(ctx)
      assert :ok = Calculator.stop(pid)
      refute Process.alive?(pid)
    end

    test "returns CallSummary when metrics were added", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Add some metrics
      Calculator.add_metrics(pid, good_metrics())

      # Stop and get summary
      summary = Calculator.stop(pid)

      assert is_map(summary)
      assert summary.session_id == ctx.session_id
    end

    test "unregisters from Registry on stop", ctx do
      {:ok, pid} = start_calculator(ctx)
      Calculator.stop(pid)

      # Small delay for Registry cleanup
      Process.sleep(10)
      assert [] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)
    end
  end

  # ===========================================================================
  # State Machine Behavior Tests
  # ===========================================================================

  describe "initial state behavior" do
    test "returns :ok on stop when no metrics received", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Stop immediately without adding metrics
      result = Calculator.stop(pid)

      # Awaiting media state returns :ok
      assert result == :ok
    end

    test "current_score returns nil before any intervals complete", ctx do
      {:ok, pid} = start_calculator(ctx)

      # No intervals completed yet
      assert Calculator.current_score(pid) == nil

      Calculator.stop(pid)
    end

    test "call_summary shows insufficient_data before intervals complete", ctx do
      {:ok, pid} = start_calculator(ctx)

      summary = Calculator.call_summary(pid)
      assert summary.status == :insufficient_data
      assert summary.intervals_calculated == 0

      Calculator.stop(pid)
    end
  end

  describe "state transition behavior" do
    test "after metrics added, stop returns CallSummary instead of :ok", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Add metrics to transition to active
      Calculator.add_metrics(pid, good_metrics())

      # Now stop returns summary, not :ok
      result = Calculator.stop(pid)

      assert %CallSummary{} = result
      assert result.session_id == ctx.session_id
    end

    test "current_score returns value after interval completes", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Add sufficient metrics
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())

      # Wait for interval to complete
      Process.sleep(150)

      # Now should have a score
      score = Calculator.current_score(pid)
      assert %Score{} = score
      assert score.value >= 1.0

      Calculator.stop(pid)
    end
  end

  # ===========================================================================
  # Metrics Processing Tests
  # ===========================================================================

  describe "add_metrics/2" do
    test "accepts metrics map", ctx do
      {:ok, pid} = start_calculator(ctx)

      assert :ok = Calculator.add_metrics(pid, good_metrics())

      Calculator.stop(pid)
    end

    test "accumulated metrics produce correct score", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Add metrics in multiple calls (25+25 = 50 packets)
      Calculator.add_metrics(pid, %{packets_received: 25, packets_expected: 25, jitter_ms: 10.0})
      Calculator.add_metrics(pid, %{packets_received: 25, packets_expected: 25, jitter_ms: 10.0})

      # Wait for interval
      Process.sleep(150)

      # Should have calculated a score from accumulated metrics
      score = Calculator.current_score(pid)
      assert %Score{} = score
      # 50 received / 50 expected = 0% loss, should be high MOS
      assert score.value >= 4.0

      Calculator.stop(pid)
    end

    test "accepts partial metrics", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Only jitter, no packet counts
      assert :ok = Calculator.add_metrics(pid, %{jitter_ms: 15.0})

      Calculator.stop(pid)
    end

    test "is synchronous and returns :ok", ctx do
      {:ok, pid} = start_calculator(ctx)

      # add_metrics returns :ok immediately
      result = Calculator.add_metrics(pid, good_metrics())
      assert result == :ok

      Calculator.stop(pid)
    end
  end

  # ===========================================================================
  # Interval Management Tests
  # ===========================================================================

  describe "interval completion" do
    test "completes interval on timer tick and calculates score", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Add sufficient metrics
      for _ <- 1..5 do
        Calculator.add_metrics(pid, %{
          packets_received: 10,
          packets_expected: 10,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval to complete (100ms interval + buffer)
      Process.sleep(150)

      # Should have at least one score
      score = Calculator.current_score(pid)
      assert %Score{} = score

      Calculator.stop(pid)
    end

    test "good metrics yield high MOS score", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Add good metrics
      for _ <- 1..5 do
        Calculator.add_metrics(pid, good_metrics())
      end

      # Wait for interval completion
      Process.sleep(150)

      score = Calculator.current_score(pid)
      assert %Score{} = score
      # Good metrics should yield MOS >= 4.0
      assert score.value >= 4.0

      Calculator.stop(pid)
    end

    test "poor metrics yield lower MOS score", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Add poor metrics (high jitter, loss, delay)
      for _ <- 1..5 do
        Calculator.add_metrics(pid, poor_metrics())
      end

      # Wait for interval completion
      Process.sleep(150)

      score = Calculator.current_score(pid)
      assert %Score{} = score
      # Poor metrics should yield lower MOS
      assert score.value < 4.0

      Calculator.stop(pid)
    end

    test "handles insufficient data in interval gracefully", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 100))

      # Add only a few packets (less than min required)
      Calculator.add_metrics(pid, %{packets_received: 5, packets_expected: 5, jitter_ms: 10.0})

      # Wait for interval
      Process.sleep(100)

      # No score should be calculated
      assert Calculator.current_score(pid) == nil

      summary = Calculator.stop(pid)
      assert summary.status == :insufficient_data

      # But packet counts should still be tracked
      assert summary.total_packets > 0
    end

    test "multiple intervals produce multiple scores with statistics", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # Complete multiple intervals
      for _ <- 1..3 do
        for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
        Process.sleep(80)
      end

      summary = Calculator.call_summary(pid)

      assert summary.intervals_calculated >= 2
      assert summary.avg_mos >= 4.0
      assert summary.min_mos <= summary.max_mos

      Calculator.stop(pid)
    end
  end

  # ===========================================================================
  # Threshold Crossing Tests
  # ===========================================================================

  describe "threshold crossing detection" do
    test "detects falling threshold crossing in summary events", ctx do
      thresholds = [
        %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both}
      ]

      config = Config.new(interval_ms: 50, min_packets_per_interval: 5, thresholds: thresholds)

      {:ok, pid} = start_calculator(ctx, config: config)

      # First interval: good quality
      for _ <- 1..5 do
        Calculator.add_metrics(pid, good_metrics())
      end

      Process.sleep(100)

      # Second interval: poor quality
      for _ <- 1..5 do
        Calculator.add_metrics(pid, poor_metrics())
      end

      Process.sleep(100)

      summary = Calculator.call_summary(pid)

      # Should have detected quality degradation
      falling_events =
        Enum.filter(summary.quality_events, fn event ->
          event.type == :threshold_crossed and event.direction == :falling
        end)

      assert length(falling_events) >= 1

      Calculator.stop(pid)
    end

    test "detects rising threshold crossing in summary events", ctx do
      thresholds = [
        %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both}
      ]

      config = Config.new(interval_ms: 50, min_packets_per_interval: 5, thresholds: thresholds)

      {:ok, pid} = start_calculator(ctx, config: config)

      # First interval: poor quality
      for _ <- 1..5 do
        Calculator.add_metrics(pid, poor_metrics())
      end

      Process.sleep(100)

      # Second interval: good quality
      for _ <- 1..5 do
        Calculator.add_metrics(pid, good_metrics())
      end

      Process.sleep(100)

      summary = Calculator.call_summary(pid)

      # Should have detected quality improvement
      rising_events =
        Enum.filter(summary.quality_events, fn event ->
          event.type == :threshold_crossed and event.direction == :rising
        end)

      assert length(rising_events) >= 1

      Calculator.stop(pid)
    end

    test "respects hysteresis to prevent flapping", ctx do
      thresholds = [
        %Threshold{name: :good, value: 3.5, hysteresis: 0.2, direction: :both}
      ]

      config = Config.new(interval_ms: 50, min_packets_per_interval: 5, thresholds: thresholds)

      {:ok, pid} = start_calculator(ctx, config: config)

      # Metrics that produce MOS near threshold (around 3.5)
      # These oscillate slightly but stay within hysteresis band
      borderline_metrics = %{
        packets_received: 47,
        packets_expected: 50,
        jitter_ms: 40.0,
        delay_ms: 150.0
      }

      # Multiple intervals with borderline quality
      for _ <- 1..3 do
        for _ <- 1..5 do
          Calculator.add_metrics(pid, borderline_metrics)
        end

        Process.sleep(100)
      end

      summary = Calculator.call_summary(pid)

      # Should not have excessive threshold events due to hysteresis
      assert length(summary.quality_events) <= 1

      Calculator.stop(pid)
    end

    test "quality events have correct structure", ctx do
      thresholds = [
        %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both}
      ]

      config = Config.new(interval_ms: 50, min_packets_per_interval: 5, thresholds: thresholds)

      {:ok, pid} = start_calculator(ctx, config: config)

      # Good then poor to trigger event
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      for _ <- 1..5, do: Calculator.add_metrics(pid, poor_metrics())
      Process.sleep(100)

      summary = Calculator.call_summary(pid)

      if length(summary.quality_events) > 0 do
        [event | _] = summary.quality_events

        assert Map.has_key?(event, :timestamp)
        assert Map.has_key?(event, :type)
        assert Map.has_key?(event, :mos)
        assert Map.has_key?(event, :threshold)
        assert Map.has_key?(event, :direction)
      end

      Calculator.stop(pid)
    end
  end

  # ===========================================================================
  # Handler Registration and Notification Tests
  # ===========================================================================

  describe "register_handler/2" do
    test "registers a process and notifies on score calculation", ctx do
      {:ok, pid} = start_calculator(ctx)

      Calculator.register_handler(pid, self())

      # Add sufficient metrics
      for _ <- 1..5 do
        Calculator.add_metrics(pid, good_metrics())
      end

      # Wait for interval and notification
      Process.sleep(200)

      # Should receive score event
      assert_received {:mos_score, %{session_id: _, score: %Score{}}}

      Calculator.stop(pid)
    end

    test "notifies handler on threshold crossing", ctx do
      thresholds = [
        %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both}
      ]

      config = Config.new(interval_ms: 50, min_packets_per_interval: 5, thresholds: thresholds)

      {:ok, pid} = start_calculator(ctx, config: config)

      Calculator.register_handler(pid, self())

      # Good metrics first
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      # Poor metrics to trigger crossing
      for _ <- 1..5, do: Calculator.add_metrics(pid, poor_metrics())
      Process.sleep(100)

      # Should receive threshold event
      assert_received {:mos_threshold_crossed, %{session_id: _, threshold: _, direction: _}}

      Calculator.stop(pid)
    end

    test "notifies handler on summary generation at stop", ctx do
      {:ok, pid} = start_calculator(ctx)

      Calculator.register_handler(pid, self())

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(150)

      Calculator.stop(pid)

      # Should receive summary event
      assert_received {:mos_summary, %{session_id: _, summary: _}}
    end

    test "supports multiple handlers", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Spawn a separate handler process
      test_pid = self()

      handler_pid =
        spawn(fn ->
          receive do
            {:mos_score, _} = msg -> send(test_pid, {:handler2, msg})
          end
        end)

      Calculator.register_handler(pid, self())
      Calculator.register_handler(pid, handler_pid)

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(200)

      # Both handlers should receive notifications
      assert_received {:mos_score, _}
      assert_received {:handler2, {:mos_score, _}}

      Calculator.stop(pid)
    end

    test "handler errors don't crash calculator", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Register a dead process as handler (will cause send to go nowhere)
      dead_handler =
        spawn(fn ->
          :ok
        end)

      Process.sleep(10)
      Calculator.register_handler(pid, dead_handler)

      # Add metrics - calculator should survive
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(150)

      # Calculator should still be alive
      assert Process.alive?(pid)

      Calculator.stop(pid)
    end
  end

  # ===========================================================================
  # Query API Tests
  # ===========================================================================

  describe "current_score/1" do
    test "returns nil when no scores calculated yet", ctx do
      {:ok, pid} = start_calculator(ctx)

      assert Calculator.current_score(pid) == nil

      Calculator.stop(pid)
    end

    test "returns most recent score", ctx do
      {:ok, pid} = start_calculator(ctx)

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(150)

      score = Calculator.current_score(pid)
      assert %Score{} = score
      assert score.value >= 1.0

      Calculator.stop(pid)
    end
  end

  describe "call_summary/1" do
    test "returns summary with session_id", ctx do
      {:ok, pid} = start_calculator(ctx)

      summary = Calculator.call_summary(pid)
      assert summary.session_id == ctx.session_id

      Calculator.stop(pid)
    end

    test "returns summary with :insufficient_data when no intervals completed", ctx do
      {:ok, pid} = start_calculator(ctx)

      summary = Calculator.call_summary(pid)
      assert summary.status == :insufficient_data
      assert summary.intervals_calculated == 0

      Calculator.stop(pid)
    end

    test "returns summary with calculated statistics", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Complete multiple intervals
      for _ <- 1..3 do
        for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
        Process.sleep(150)
      end

      summary = Calculator.call_summary(pid)

      assert summary.status == :complete
      assert summary.intervals_calculated >= 1
      assert summary.avg_mos != nil
      assert summary.min_mos != nil
      assert summary.max_mos != nil

      Calculator.stop(pid)
    end

    test "includes quality events in summary", ctx do
      thresholds = [
        %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both}
      ]

      config = Config.new(interval_ms: 50, min_packets_per_interval: 5, thresholds: thresholds)

      {:ok, pid} = start_calculator(ctx, config: config)

      # Good then poor to trigger threshold
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      for _ <- 1..5, do: Calculator.add_metrics(pid, poor_metrics())
      Process.sleep(100)

      summary = Calculator.call_summary(pid)
      assert is_list(summary.quality_events)

      Calculator.stop(pid)
    end
  end

  # ===========================================================================
  # Registry Lookup Tests
  # ===========================================================================

  describe "registry lookup" do
    test "can lookup calculator by session_id", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Lookup via Registry
      assert [{^pid, _}] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)

      Calculator.stop(pid)
    end

    test "via tuple works for GenServer calls", ctx do
      {:ok, _pid} = start_calculator(ctx)

      # Use via tuple for query
      via = {:via, Registry, {ParrotMedia.MOS.Registry, ctx.session_id}}
      score = Calculator.current_score(via)
      # No intervals completed yet
      assert score == nil

      Calculator.stop(via)
    end
  end

  # ===========================================================================
  # Summary Generation and Telemetry Tests
  # ===========================================================================

  describe "summary generation on terminate" do
    test "generates CallSummary struct when stopped with scores", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Complete an interval with good metrics
      for _ <- 1..5 do
        Calculator.add_metrics(pid, good_metrics())
      end

      Process.sleep(150)

      summary = Calculator.stop(pid)

      # Should return a CallSummary struct
      assert %CallSummary{} = summary
      assert summary.session_id == ctx.session_id
      assert summary.status == :complete
    end

    test "calculates min/max/avg MOS from multiple scores", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # First interval: good metrics
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      # Second interval: poor metrics
      for _ <- 1..5, do: Calculator.add_metrics(pid, poor_metrics())
      Process.sleep(100)

      # Third interval: good metrics again
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      # min_mos should be from poor interval
      assert summary.min_mos < summary.max_mos
      # avg should be between min and max
      assert summary.avg_mos >= summary.min_mos
      assert summary.avg_mos <= summary.max_mos
    end

    test "calculates duration_ms from start_time", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # Add some metrics and wait
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      # Duration should be at least 100ms (the sleep time)
      assert summary.duration_ms >= 100
    end

    test "tracks total_packets and total_lost across intervals", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # First interval: no loss
      for _ <- 1..5,
          do:
            Calculator.add_metrics(pid, %{
              packets_received: 10,
              packets_expected: 10,
              jitter_ms: 10.0,
              delay_ms: 50.0
            })

      Process.sleep(100)

      # Second interval: some loss
      for _ <- 1..5,
          do:
            Calculator.add_metrics(pid, %{
              packets_received: 8,
              packets_expected: 10,
              jitter_ms: 10.0,
              delay_ms: 50.0
            })

      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      # Total expected: 50 (5*10) + 50 (5*10) = 100
      assert summary.total_packets == 100
      # Total lost: 0 + 10 (5*2) = 10
      assert summary.total_lost == 10
      assert summary.overall_loss_percent == 10.0
    end

    test "returns :insufficient_data status when no intervals completed", ctx do
      {:ok, pid} = start_calculator(ctx, config: Config.new(interval_ms: 10_000))

      # Add metrics but don't wait for interval
      Calculator.add_metrics(pid, good_metrics())

      summary = Calculator.stop(pid)

      # Should still get a CallSummary but with insufficient_data status
      assert %CallSummary{} = summary
      assert summary.status == :insufficient_data
      assert summary.intervals_calculated == 0
    end

    test "includes quality_events in summary", ctx do
      thresholds = [
        %Threshold{name: :good, value: 3.5, hysteresis: 0.1, direction: :both}
      ]

      config = Config.new(interval_ms: 50, min_packets_per_interval: 5, thresholds: thresholds)

      {:ok, pid} = start_calculator(ctx, config: config)

      # Good then poor to trigger threshold
      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      for _ <- 1..5, do: Calculator.add_metrics(pid, poor_metrics())
      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      assert is_list(summary.quality_events)
      # Should have captured the threshold crossing
      assert length(summary.quality_events) >= 1
    end
  end

  describe "telemetry emission on terminate" do
    test "emits call_summary telemetry event on stop", ctx do
      # Attach telemetry handler to capture events
      test_pid = self()
      handler_id = "test-handler-#{ctx.session_id}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :call_summary],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      Calculator.stop(pid)

      # Should receive telemetry event
      assert_receive {:telemetry_event, [:parrot_media, :mos, :call_summary], measurements,
                      metadata},
                     500

      assert measurements.min_mos != nil
      assert measurements.max_mos != nil
      assert measurements.avg_mos != nil
      assert measurements.total_packets > 0
      assert measurements.intervals_calculated >= 1
      assert metadata.session_id == ctx.session_id
      assert metadata.status == :complete

      :telemetry.detach(handler_id)
    end

    test "telemetry includes codec and call_id metadata", ctx do
      test_pid = self()
      handler_id = "test-handler-codec-#{ctx.session_id}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :call_summary],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} =
        start_calculator(ctx,
          codec: :opus,
          call_id: "my-call-123",
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      Calculator.stop(pid)

      assert_receive {:telemetry_event, [:parrot_media, :mos, :call_summary], _measurements,
                      metadata},
                     500

      assert metadata.codec == :opus
      assert metadata.call_id == "my-call-123"

      :telemetry.detach(handler_id)
    end

    test "no telemetry emitted when no metrics received", ctx do
      test_pid = self()
      handler_id = "test-handler-none-#{ctx.session_id}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :call_summary],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = start_calculator(ctx)

      # Stop immediately without adding any metrics
      :ok = Calculator.stop(pid)

      # Should not receive telemetry (awaiting_media state returns :ok)
      refute_receive {:telemetry_event, _, _, _}, 100

      :telemetry.detach(handler_id)
    end
  end

  describe "handler notification on terminate" do
    test "notifies registered handlers with CallSummary on stop", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      Calculator.register_handler(pid, self())

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(100)

      Calculator.stop(pid)

      # Should receive summary message with CallSummary struct
      assert_receive {:mos_summary, %{session_id: session_id, summary: summary}}, 500
      assert session_id == ctx.session_id
      assert %CallSummary{} = summary
    end
  end

  # ===========================================================================
  # Edge Cases and Error Handling
  # ===========================================================================

  describe "edge cases" do
    test "handles empty metrics gracefully", ctx do
      {:ok, pid} = start_calculator(ctx)

      assert :ok = Calculator.add_metrics(pid, %{})

      Calculator.stop(pid)
    end

    test "handles very short call (no complete intervals)", ctx do
      {:ok, pid} = start_calculator(ctx, config: Config.new(interval_ms: 10_000))

      Calculator.add_metrics(pid, good_metrics())

      summary = Calculator.stop(pid)
      assert summary.status == :insufficient_data
    end

    test "handles rapid metrics additions", ctx do
      {:ok, pid} = start_calculator(ctx)

      # Rapid fire metrics
      for _ <- 1..100 do
        Calculator.add_metrics(pid, good_metrics())
      end

      # Should not crash
      assert Process.alive?(pid)

      Calculator.stop(pid)
    end

    test "Opus codec produces valid MOS scores", ctx do
      {:ok, pid} = start_calculator(ctx, codec: :opus)

      for _ <- 1..5, do: Calculator.add_metrics(pid, good_metrics())
      Process.sleep(150)

      score = Calculator.current_score(pid)
      assert %Score{} = score
      # Opus with good metrics should still produce valid MOS
      assert score.value >= 1.0 and score.value <= 5.0

      Calculator.stop(pid)
    end
  end

  # ===========================================================================
  # One-Way Audio and Direction Tracking Tests
  # ===========================================================================

  describe "one-way audio detection" do
    test "detects one-way audio when only inbound packets received", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # Add only inbound metrics
      for _ <- 1..10 do
        Calculator.add_metrics(pid, Map.put(good_metrics(), :direction, :inbound))
      end

      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      assert summary.status == :one_way_audio
    end

    test "detects one-way audio when only outbound packets received", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # Add only outbound metrics
      for _ <- 1..10 do
        Calculator.add_metrics(pid, Map.put(good_metrics(), :direction, :outbound))
      end

      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      assert summary.status == :one_way_audio
    end

    test "returns :complete status when bidirectional audio present", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # Add both inbound and outbound metrics
      for _ <- 1..5 do
        Calculator.add_metrics(pid, Map.put(good_metrics(), :direction, :inbound))
        Calculator.add_metrics(pid, Map.put(good_metrics(), :direction, :outbound))
      end

      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      assert summary.status == :complete
    end

    test "returns :insufficient_data when no packets in any direction", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 100))

      # Add too few metrics with directions - not enough for interval completion
      Calculator.add_metrics(pid, Map.put(good_metrics(), :direction, :inbound))

      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      assert summary.status == :insufficient_data
    end

    test "metrics without direction still work (backward compatibility)", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # Add metrics without direction - should still calculate MOS
      for _ <- 1..10 do
        Calculator.add_metrics(pid, good_metrics())
      end

      Process.sleep(100)

      summary = Calculator.stop(pid)

      # Without direction info, we assume bidirectional (backward compatibility)
      assert %CallSummary{} = summary
      assert summary.status == :complete
    end

    test "one-way audio still calculates MOS for active direction", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 5))

      # Add only inbound metrics
      for _ <- 1..10 do
        Calculator.add_metrics(pid, Map.put(good_metrics(), :direction, :inbound))
      end

      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      assert summary.status == :one_way_audio
      # Should still have MOS calculated for the active direction
      assert summary.intervals_calculated >= 1
      assert summary.avg_mos >= 4.0
    end
  end

  describe "no RTP packets edge case" do
    test "returns :ok when calculator stopped with no metrics", ctx do
      {:ok, pid} = start_calculator(ctx)

      # No metrics added, stop immediately
      result = Calculator.stop(pid)

      # When awaiting media (no metrics), returns :ok
      assert result == :ok
    end

    test "returns :insufficient_data when packets below min threshold", ctx do
      {:ok, pid} =
        start_calculator(ctx, config: Config.new(interval_ms: 50, min_packets_per_interval: 100))

      # Add very few packets (below min_packets_per_interval)
      for _ <- 1..3 do
        Calculator.add_metrics(pid, %{
          packets_received: 5,
          packets_expected: 5,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      summary = Calculator.stop(pid)

      assert %CallSummary{} = summary
      assert summary.status == :insufficient_data
      assert summary.intervals_calculated == 0
    end
  end
end
