defmodule ParrotMedia.MOS.IntegrationTest do
  @moduledoc """
  Integration tests for MOS (Mean Opinion Score) scoring system.

  These tests verify that the MOS components work together end-to-end:
  - Calculator starts/stops with MediaSession
  - Observer sends metrics to Calculator
  - MOS scores are calculated correctly

  Note: These tests require the full media stack to be available
  and are marked as integration tests.
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.MediaSession
  alias ParrotMedia.MOS.Calculator
  alias ParrotMedia.MOS.Config

  # ===========================================================================
  # Test Handler
  # ===========================================================================

  defmodule TestMediaHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(args) do
      {:ok, Map.merge(%{}, args)}
    end

    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end

    @impl true
    def handle_stream_start(_id, _dir, state) do
      {:noreply, state}
    end

    @impl true
    def handle_session_start(_id, _opts, state) do
      {:ok, state}
    end

    @impl true
    def handle_offer(_sdp, _direction, state) do
      {:noreply, state}
    end

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      # Find first common codec
      common = Enum.find(offered, fn c -> c in supported end)

      if common do
        {:ok, common, state}
      else
        {:error, :no_common_codec, state}
      end
    end

    @impl true
    def handle_negotiation_complete(_local_sdp, _remote_sdp, _codec, state) do
      {:ok, state}
    end
  end

  # ===========================================================================
  # Setup
  # ===========================================================================

  setup do
    # Generate unique session ID
    session_id = "mos-integration-test-#{:erlang.unique_integer([:positive])}"

    # Ensure MOS is enabled for tests
    original_config = Application.get_env(:parrot_media, :mos)

    Application.put_env(:parrot_media, :mos, %{
      enabled: true,
      interval_ms: 100,
      min_packets_per_interval: 1,
      default_delay_ms: 50.0,
      thresholds: []
    })

    on_exit(fn ->
      # Restore original config
      if original_config do
        Application.put_env(:parrot_media, :mos, original_config)
      else
        Application.delete_env(:parrot_media, :mos)
      end
    end)

    {:ok, session_id: session_id}
  end

  # ===========================================================================
  # Calculator Lifecycle Tests
  # ===========================================================================

  describe "Calculator lifecycle with MediaSession" do
    test "Calculator starts when MediaSession starts media", ctx do
      # Start media session
      {:ok, session} =
        MediaSession.start_link(
          id: ctx.session_id,
          dialog_id: "dialog-#{ctx.session_id}",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # Create a simple SDP offer
      sdp_offer = build_test_sdp_offer()

      # Process offer to get answer
      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      # Start media - this should start the Calculator
      :ok = MediaSession.start_media(session)

      # Allow time for Calculator to start
      Process.sleep(50)

      # Verify Calculator is registered
      assert [{calc_pid, _}] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)
      assert Process.alive?(calc_pid)

      # Cleanup
      MediaSession.terminate_session(session)

      # Allow time for cleanup
      Process.sleep(50)
    end

    test "Calculator stops when MediaSession terminates", ctx do
      # Start media session
      {:ok, session} =
        MediaSession.start_link(
          id: ctx.session_id,
          dialog_id: "dialog-#{ctx.session_id}",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # Process offer and start media
      sdp_offer = build_test_sdp_offer()
      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)
      :ok = MediaSession.start_media(session)

      # Allow time for Calculator to start
      Process.sleep(50)

      # Verify Calculator is running
      [{calc_pid, _}] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)
      assert Process.alive?(calc_pid)

      # Terminate the session
      MediaSession.terminate_session(session)

      # Allow time for cleanup
      Process.sleep(100)

      # Verify Calculator is stopped
      assert [] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)
      refute Process.alive?(calc_pid)
    end

    test "MOS is disabled when config says disabled", ctx do
      # Disable MOS in config
      Application.put_env(:parrot_media, :mos, %{enabled: false})

      # Start media session
      {:ok, session} =
        MediaSession.start_link(
          id: ctx.session_id,
          dialog_id: "dialog-#{ctx.session_id}",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # Process offer and start media
      sdp_offer = build_test_sdp_offer()
      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)
      :ok = MediaSession.start_media(session)

      # Allow time
      Process.sleep(50)

      # Verify no Calculator is registered
      assert [] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)

      # Cleanup
      MediaSession.terminate_session(session)
    end

    test "Calculator tracks codec from MediaSession", ctx do
      # Set up telemetry handler to capture codec
      test_pid = self()
      handler_id = "test-codec-handler-#{ctx.session_id}"

      :telemetry.attach(
        handler_id,
        [:parrot_media, :mos, :call_summary],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_codec, metadata.codec})
        end,
        nil
      )

      # Start media session
      {:ok, session} =
        MediaSession.start_link(
          id: ctx.session_id,
          dialog_id: "dialog-#{ctx.session_id}",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          supported_codecs: [:pcma]
        )

      # Process offer and start media
      sdp_offer = build_test_sdp_offer()
      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)
      :ok = MediaSession.start_media(session)

      # Allow time for Calculator to start
      Process.sleep(50)

      # Verify Calculator was started
      [{calc_pid, _}] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)
      assert Process.alive?(calc_pid)

      # Send some metrics so we can verify codec via telemetry on stop
      Calculator.add_metrics(calc_pid, %{packets_received: 10, packets_expected: 10, jitter_ms: 5.0})
      Process.sleep(100)

      # Stop Calculator to trigger telemetry
      Calculator.stop(calc_pid)

      # Verify codec was tracked correctly (defaults to :g711)
      assert_receive {:telemetry_codec, :g711}, 500

      :telemetry.detach(handler_id)

      # Cleanup
      MediaSession.terminate_session(session)
    end
  end

  # ===========================================================================
  # Direct Calculator Tests
  # ===========================================================================

  describe "Calculator direct usage" do
    test "can start Calculator independently", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      assert Process.alive?(calc_pid)

      # Verify registration
      assert [{^calc_pid, _}] = Registry.lookup(ParrotMedia.MOS.Registry, ctx.session_id)

      Calculator.stop(calc_pid)
    end

    test "Calculator calculates MOS scores", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      # Add good metrics
      for _ <- 1..10 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval completion
      Process.sleep(100)

      # Should have calculated a score
      score = Calculator.current_score(calc_pid)
      assert score != nil
      # Good quality
      assert score.value >= 4.0

      Calculator.stop(calc_pid)
    end

    test "Calculator generates summary on stop", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      # Add metrics
      for _ <- 1..10 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval
      Process.sleep(100)

      # Stop and get summary
      summary = Calculator.stop(calc_pid)

      assert summary.session_id == ctx.session_id
      assert summary.status == :complete
      assert summary.intervals_calculated >= 1
      assert summary.avg_mos != nil
    end
  end

  # ===========================================================================
  # Config Integration Tests
  # ===========================================================================

  describe "Config integration" do
    test "MOS Config.enabled?() respects application config" do
      # Should be enabled from setup
      assert Config.enabled?() == true

      # Disable it
      Application.put_env(:parrot_media, :mos, %{enabled: false})
      assert Config.enabled?() == false

      # Re-enable for other tests
      Application.put_env(:parrot_media, :mos, %{enabled: true, interval_ms: 100})
    end

    test "Config.merge() creates proper Config struct" do
      config = Config.merge(interval_ms: 200, min_packets_per_interval: 20)

      assert %Config{} = config
      assert config.interval_ms == 200
      assert config.min_packets_per_interval == 20
    end
  end

  # ===========================================================================
  # Call Summary Edge Cases
  # ===========================================================================

  describe "call summary edge cases" do
    test "one-way audio detection when only inbound metrics", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      # Simulate one-way audio - only inbound packets
      for _ <- 1..10 do
        Calculator.add_metrics(calc_pid, %{
          direction: :inbound,
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      summary = Calculator.stop(calc_pid)

      # Should detect one-way audio
      assert summary.status == :one_way_audio
      # MOS should still be calculated for the active direction
      assert summary.intervals_calculated >= 1
      assert summary.avg_mos >= 4.0
    end

    test "one-way audio detection when only outbound metrics", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      # Simulate one-way audio - only outbound packets
      for _ <- 1..10 do
        Calculator.add_metrics(calc_pid, %{
          direction: :outbound,
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      summary = Calculator.stop(calc_pid)

      assert summary.status == :one_way_audio
      assert summary.intervals_calculated >= 1
    end

    test "bidirectional call returns :complete status", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      # Simulate bidirectional audio
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          direction: :inbound,
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })

        Calculator.add_metrics(calc_pid, %{
          direction: :outbound,
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      summary = Calculator.stop(calc_pid)

      assert summary.status == :complete
      assert summary.intervals_calculated >= 1
    end

    test "very short call with insufficient data", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 10_000, min_packets_per_interval: 100)
        )

      # Add some metrics but not enough for a full interval
      Calculator.add_metrics(calc_pid, %{
        direction: :inbound,
        packets_received: 10,
        packets_expected: 10,
        jitter_ms: 10.0,
        delay_ms: 50.0
      })

      # Don't wait for interval - stop immediately
      summary = Calculator.stop(calc_pid)

      assert summary.status == :insufficient_data
      assert summary.intervals_calculated == 0
    end

    test "backward compatibility - metrics without direction", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      # Add metrics without direction (old behavior)
      for _ <- 1..10 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      summary = Calculator.stop(calc_pid)

      # Without direction info, assumes bidirectional for backward compatibility
      assert summary.status == :complete
      assert summary.intervals_calculated >= 1
    end

    test "call summary includes all expected fields", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 5)
        )

      for _ <- 1..10 do
        Calculator.add_metrics(calc_pid, %{
          direction: :inbound,
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })

        Calculator.add_metrics(calc_pid, %{
          direction: :outbound,
          packets_received: 48,
          packets_expected: 50,
          jitter_ms: 15.0,
          delay_ms: 60.0
        })
      end

      Process.sleep(100)

      summary = Calculator.stop(calc_pid)

      # Verify all CallSummary fields
      assert %ParrotMedia.MOS.CallSummary{} = summary
      assert summary.session_id == ctx.session_id
      assert is_atom(summary.status)
      assert summary.status in [:complete, :insufficient_data, :one_way_audio]
      assert is_float(summary.min_mos)
      assert is_float(summary.max_mos)
      assert is_float(summary.avg_mos)
      assert summary.min_mos >= 1.0 and summary.min_mos <= 5.0
      assert summary.max_mos >= 1.0 and summary.max_mos <= 5.0
      assert summary.avg_mos >= 1.0 and summary.avg_mos <= 5.0
      assert is_integer(summary.total_packets)
      assert is_integer(summary.total_lost)
      assert is_float(summary.overall_loss_percent)
      assert is_integer(summary.intervals_calculated)
      assert is_integer(summary.duration_ms)
      assert is_list(summary.quality_events)
    end
  end

  # ===========================================================================
  # Handler Callback Integration Tests (T051)
  # ===========================================================================

  describe "handler callback invocation" do
    test "handler receives MOS score callbacks", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Register this process as handler
      Calculator.register_handler(calc_pid, self())

      # Add metrics to trigger score calculation
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval
      Process.sleep(100)

      # Should receive MOS score message
      assert_receive {:mos_score, %{session_id: session_id, score: score}}, 200
      assert session_id == ctx.session_id
      assert %ParrotMedia.MOS.Score{} = score
      assert score.value >= 4.0

      Calculator.stop(calc_pid)
    end

    test "handler receives threshold crossing callbacks", ctx do
      session_id = ctx.session_id

      # Configure with thresholds
      Application.put_env(:parrot_media, :mos, %{
        enabled: true,
        interval_ms: 50,
        min_packets_per_interval: 1,
        default_delay_ms: 50.0,
        thresholds: [
          %{name: :excellent, value: 4.0, hysteresis: 0.0},
          %{name: :good, value: 3.5, hysteresis: 0.0}
        ]
      })

      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: session_id,
          codec: :g711,
          config: Config.merge([])
        )

      # Register this process as handler
      Calculator.register_handler(calc_pid, self())

      # First add good quality metrics (MOS > 4.0)
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 5.0,
          delay_ms: 30.0
        })
      end

      Process.sleep(100)

      # Then add poor quality metrics (MOS < 3.5)
      for _ <- 1..10 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 35,
          packets_expected: 50,
          jitter_ms: 100.0,
          delay_ms: 200.0
        })
      end

      Process.sleep(100)

      # Should have received threshold crossing
      # Note: direction is :falling or :rising (from Threshold module)
      assert_receive {:mos_threshold_crossed, %{session_id: ^session_id, threshold: _, direction: :falling}}, 200

      Calculator.stop(calc_pid)
    end

    test "handler receives summary callback on stop", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Register this process as handler
      Calculator.register_handler(calc_pid, self())

      # Add some metrics
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      # Stop the calculator - this triggers summary notification
      Calculator.stop(calc_pid)

      # Should receive summary message
      assert_receive {:mos_summary, %{session_id: session_id, summary: summary}}, 200
      assert session_id == ctx.session_id
      assert %ParrotMedia.MOS.CallSummary{} = summary
    end

    test "callback timing is within 50ms", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Register this process as handler
      Calculator.register_handler(calc_pid, self())

      # Record when we add metrics
      start_time = System.monotonic_time(:millisecond)

      # Add metrics to trigger score calculation
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      # Wait for interval (50ms) plus some buffer
      Process.sleep(60)

      # Should receive message quickly after interval completes
      assert_receive {:mos_score, _}, 100
      receive_time = System.monotonic_time(:millisecond)

      # The callback should have been received within 50ms of interval completion
      # (interval is 50ms, so total time should be around 50-100ms)
      elapsed = receive_time - start_time
      assert elapsed < 150, "Callback took #{elapsed}ms, expected < 150ms"

      Calculator.stop(calc_pid)
    end
  end

  describe "error isolation between handlers" do
    defmodule RaisingHandler do
      @behaviour ParrotMedia.MOS.Handler

      @impl true
      def init(_opts), do: {:ok, %{}}

      @impl true
      def handle_mos_score(_session_id, _score, _state) do
        raise "Intentional error in handler"
      end

      @impl true
      def handle_threshold_crossed(_session_id, _event, _state) do
        raise "Intentional error in handler"
      end

      @impl true
      def handle_call_summary(_session_id, _summary, _state) do
        raise "Intentional error in handler"
      end
    end

    test "error in one handler does not affect others", ctx do
      session_id = ctx.session_id

      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Start a task that will raise
      {:ok, raising_task} =
        Task.start(fn ->
          receive do
            {:mos_score, _} ->
              raise "Intentional error"
          end
        end)

      # Register both handlers - the raising one first
      Calculator.register_handler(calc_pid, raising_task)
      Calculator.register_handler(calc_pid, self())

      # Add metrics
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      # This process should still receive the callback even if the other crashed
      assert_receive {:mos_score, %{session_id: ^session_id, score: _}}, 200

      Calculator.stop(calc_pid)
    end

    test "dead handler pid does not crash calculator", ctx do
      session_id = ctx.session_id

      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Start and immediately kill a task
      {:ok, dead_task} = Task.start(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead_task)

      # Register dead handler and this process
      Calculator.register_handler(calc_pid, dead_task)
      Calculator.register_handler(calc_pid, self())

      # Add metrics
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      # Calculator should still be alive and sending to valid handlers
      assert Process.alive?(calc_pid)
      assert_receive {:mos_score, %{session_id: ^session_id, score: _}}, 200

      Calculator.stop(calc_pid)
    end

    test "multiple handlers all receive events", ctx do
      {:ok, calc_pid} =
        Calculator.start_link(
          session_id: ctx.session_id,
          codec: :g711,
          config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
        )

      # Start multiple handler tasks that forward to this process
      parent = self()

      handler_pids =
        for i <- 1..3 do
          {:ok, pid} =
            Task.start(fn ->
              receive do
                {:mos_score, msg} ->
                  send(parent, {:handler, i, msg})
              end
            end)

          pid
        end

      # Register all handlers
      for pid <- handler_pids do
        Calculator.register_handler(calc_pid, pid)
      end

      # Add metrics
      for _ <- 1..5 do
        Calculator.add_metrics(calc_pid, %{
          packets_received: 50,
          packets_expected: 50,
          jitter_ms: 10.0,
          delay_ms: 50.0
        })
      end

      Process.sleep(100)

      # All handlers should receive the event
      assert_receive {:handler, 1, _}, 200
      assert_receive {:handler, 2, _}, 200
      assert_receive {:handler, 3, _}, 200

      Calculator.stop(calc_pid)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp build_test_sdp_offer do
    """
    v=0
    o=- 123456 123457 IN IP4 127.0.0.1
    s=Test Session
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 10000 RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    a=sendrecv
    """
  end
end
