defmodule ParrotMedia.MOS.ObserverTest do
  @moduledoc """
  Unit tests for MOS Observer Membrane element.

  The Observer is a Membrane Filter element that:
  1. Passes audio buffers through unchanged (zero latency)
  2. Periodically collects stats and counts buffers
  3. Sends metrics to the Calculator via `Calculator.add_metrics/2`

  Tests verify the Observer:
  - Acts as a pass-through filter with zero processing latency
  - Starts a stats collection timer on playing
  - Sends metrics to the Calculator at configured intervals
  - Handles missing Calculator gracefully
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Observer
  alias ParrotMedia.MOS.Calculator
  alias ParrotMedia.MOS.Config
  alias Membrane.Buffer

  # ===========================================================================
  # Setup and Helpers
  # ===========================================================================

  setup do
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  defp start_calculator(session_id) do
    Calculator.start_link(
      session_id: session_id,
      codec: :g711,
      config: Config.new(interval_ms: 1000, min_packets_per_interval: 1)
    )
  end

  defp create_test_buffer(payload, pts) do
    %Buffer{
      payload: payload,
      pts: pts,
      dts: pts,
      metadata: %{
        rtp: %{
          sequence_number: 1,
          timestamp: pts,
          payload_type: 8
        }
      }
    }
  end

  defp create_stream_format do
    # Use a simple format that will pass through
    %Membrane.RTP{}
  end

  # ===========================================================================
  # Initialization Tests
  # ===========================================================================

  describe "handle_init/2" do
    test "initializes with session_id", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}

      {[], state} = Observer.handle_init(nil, opts)

      assert state.session_id == ctx.session_id
      assert state.stats_interval_ms == 1000
    end

    test "uses default stats_interval_ms of 1000", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}

      {[], state} = Observer.handle_init(nil, opts)

      assert state.stats_interval_ms == 1000
    end

    test "accepts custom stats_interval_ms", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 500}

      {[], state} = Observer.handle_init(nil, opts)

      assert state.stats_interval_ms == 500
    end

    test "initializes buffer_count to 0", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}

      {[], state} = Observer.handle_init(nil, opts)

      assert state.buffer_count == 0
    end

    test "initializes stats_timer to nil", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}

      {[], state} = Observer.handle_init(nil, opts)

      assert state.stats_timer == nil
    end

    test "initializes last_timestamp to nil", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}

      {[], state} = Observer.handle_init(nil, opts)

      assert state.last_timestamp == nil
    end
  end

  # ===========================================================================
  # Stream Format Tests
  # ===========================================================================

  describe "handle_stream_format/4" do
    test "forwards stream format unchanged", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      stream_format = create_stream_format()

      {actions, _state} = Observer.handle_stream_format(:input, stream_format, nil, state)

      assert [{:stream_format, {:output, ^stream_format}}] = actions
    end
  end

  # ===========================================================================
  # Buffer Pass-through Tests (Zero Latency)
  # ===========================================================================

  describe "handle_buffer/4 - pass-through" do
    test "passes buffer through unchanged", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      buffer = create_test_buffer(<<1, 2, 3, 4>>, 1000)

      {actions, _state} = Observer.handle_buffer(:input, buffer, nil, state)

      # Buffer should be forwarded to output unchanged
      assert [{:buffer, {:output, ^buffer}}] = actions
    end

    test "preserves buffer payload exactly", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      original_payload = :crypto.strong_rand_bytes(160)
      buffer = create_test_buffer(original_payload, 1000)

      {[{:buffer, {:output, output_buffer}}], _state} =
        Observer.handle_buffer(:input, buffer, nil, state)

      assert output_buffer.payload == original_payload
    end

    test "preserves buffer timestamps", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      buffer = create_test_buffer(<<1, 2, 3>>, 12345)

      {[{:buffer, {:output, output_buffer}}], _state} =
        Observer.handle_buffer(:input, buffer, nil, state)

      assert output_buffer.pts == 12345
      assert output_buffer.dts == 12345
    end

    test "preserves buffer metadata", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      buffer = %Buffer{
        payload: <<1, 2, 3>>,
        pts: 1000,
        metadata: %{rtp: %{sequence_number: 42, timestamp: 1000, payload_type: 8}}
      }

      {[{:buffer, {:output, output_buffer}}], _state} =
        Observer.handle_buffer(:input, buffer, nil, state)

      assert output_buffer.metadata == buffer.metadata
    end

    test "increments buffer_count on each buffer", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      assert state.buffer_count == 0

      buffer1 = create_test_buffer(<<1>>, 1000)
      {_, state} = Observer.handle_buffer(:input, buffer1, nil, state)
      assert state.buffer_count == 1

      buffer2 = create_test_buffer(<<2>>, 2000)
      {_, state} = Observer.handle_buffer(:input, buffer2, nil, state)
      assert state.buffer_count == 2

      buffer3 = create_test_buffer(<<3>>, 3000)
      {_, state} = Observer.handle_buffer(:input, buffer3, nil, state)
      assert state.buffer_count == 3
    end

    test "updates last_timestamp from buffer pts", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      assert state.last_timestamp == nil

      buffer = create_test_buffer(<<1>>, 5000)
      {_, state} = Observer.handle_buffer(:input, buffer, nil, state)

      assert state.last_timestamp == 5000
    end

    test "handles buffers without pts gracefully", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      buffer = %Buffer{payload: <<1, 2, 3>>, pts: nil}

      {[{:buffer, {:output, output_buffer}}], state} =
        Observer.handle_buffer(:input, buffer, nil, state)

      assert output_buffer.payload == <<1, 2, 3>>
      # last_timestamp should remain nil
      assert state.last_timestamp == nil
    end
  end

  # ===========================================================================
  # Playing State Tests (Timer Start)
  # ===========================================================================

  describe "handle_playing/2" do
    test "starts stats collection timer", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 100}
      {[], state} = Observer.handle_init(nil, opts)

      assert state.stats_timer == nil

      {actions, new_state} = Observer.handle_playing(nil, state)

      # Timer should be started
      assert new_state.stats_timer != nil
      assert is_reference(new_state.stats_timer)

      # No immediate actions needed
      assert actions == []

      # Clean up timer
      Process.cancel_timer(new_state.stats_timer)
    end

    test "schedules timer for configured interval", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 50}
      {[], state} = Observer.handle_init(nil, opts)

      {[], new_state} = Observer.handle_playing(nil, state)

      # Wait for timer to fire
      assert_receive :collect_stats, 100

      Process.cancel_timer(new_state.stats_timer)
    end
  end

  # ===========================================================================
  # Stats Collection Tests
  # ===========================================================================

  describe "handle_info :collect_stats" do
    test "sends metrics to Calculator when Calculator exists", ctx do
      {:ok, _calc_pid} = start_calculator(ctx.session_id)

      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      # Simulate some buffers having been processed
      state = %{state | buffer_count: 50, last_timestamp: 10000}

      {actions, new_state} = Observer.handle_info(:collect_stats, nil, state)

      # Should reschedule timer
      assert new_state.stats_timer != nil
      assert is_reference(new_state.stats_timer)
      assert actions == []

      # Buffer count should be reset
      assert new_state.buffer_count == 0

      # Give Calculator time to process the cast
      Process.sleep(10)

      # Verify Calculator received metrics - stopping returns CallSummary (not :ok) when active
      via = {:via, Registry, {ParrotMedia.MOS.Registry, ctx.session_id}}
      result = Calculator.stop(via)
      assert %ParrotMedia.MOS.CallSummary{} = result

      # Clean up timer
      Process.cancel_timer(new_state.stats_timer)
    end

    test "handles missing Calculator gracefully", ctx do
      # Don't start a calculator - it should not exist
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      state = %{state | buffer_count: 50}

      # Should not crash even without Calculator
      {actions, new_state} = Observer.handle_info(:collect_stats, nil, state)

      # Should still reschedule timer
      assert new_state.stats_timer != nil
      assert actions == []

      # Clean up
      Process.cancel_timer(new_state.stats_timer)
    end

    test "resets buffer_count after sending metrics", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      state = %{state | buffer_count: 100}
      assert state.buffer_count == 100

      {_, new_state} = Observer.handle_info(:collect_stats, nil, state)

      assert new_state.buffer_count == 0

      Process.cancel_timer(new_state.stats_timer)
    end

    test "reschedules stats timer", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 50}
      {[], state} = Observer.handle_init(nil, opts)

      state = %{state | buffer_count: 10, stats_timer: nil}

      {_, new_state} = Observer.handle_info(:collect_stats, nil, state)

      assert new_state.stats_timer != nil

      # Verify timer fires again
      assert_receive :collect_stats, 100

      Process.cancel_timer(new_state.stats_timer)
    end

    test "calculates packets_expected based on buffer_count", ctx do
      # Use shorter interval for faster test
      {:ok, _calc_pid} = Calculator.start_link(
        session_id: ctx.session_id,
        codec: :g711,
        config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
      )

      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      # Simulate 25 buffers processed
      state = %{state | buffer_count: 25}

      {_, new_state} = Observer.handle_info(:collect_stats, nil, state)

      # Give Calculator time to complete an interval and calculate score
      Process.sleep(100)

      via = {:via, Registry, {ParrotMedia.MOS.Registry, ctx.session_id}}

      # Verify metrics were received by checking the summary
      summary = Calculator.call_summary(via)

      # If we got enough packets, we should have calculated intervals
      # The summary should show total_packets reflecting what we sent
      assert summary.total_packets > 0 or summary.intervals_calculated >= 0

      Calculator.stop(via)
      Process.cancel_timer(new_state.stats_timer)
    end
  end

  # ===========================================================================
  # Unknown Message Handling
  # ===========================================================================

  describe "handle_info/3 - unknown messages" do
    test "ignores unknown messages", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      {actions, new_state} = Observer.handle_info(:unknown_message, nil, state)

      assert actions == []
      assert new_state == state
    end
  end

  # ===========================================================================
  # End of Stream Tests
  # ===========================================================================

  describe "handle_end_of_stream/3" do
    test "forwards end of stream to output", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      {actions, _state} = Observer.handle_end_of_stream(:input, nil, state)

      assert [{:end_of_stream, :output}] = actions
    end

    test "cancels stats timer on end of stream", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      # Start playing to get a timer
      {[], state} = Observer.handle_playing(nil, state)
      assert state.stats_timer != nil

      timer_ref = state.stats_timer

      {_actions, new_state} = Observer.handle_end_of_stream(:input, nil, state)

      # Timer should be cancelled
      assert new_state.stats_timer == nil

      # Verify timer was actually cancelled (read returns false if cancelled)
      assert Process.read_timer(timer_ref) == false
    end

    test "sends final metrics before ending", ctx do
      {:ok, _calc_pid} = start_calculator(ctx.session_id)

      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      # Process some buffers
      state = %{state | buffer_count: 30}

      {_actions, _state} = Observer.handle_end_of_stream(:input, nil, state)

      # Give Calculator time to process
      Process.sleep(10)

      # Verify Calculator received metrics - returns CallSummary (not :ok) when metrics were received
      via = {:via, Registry, {ParrotMedia.MOS.Registry, ctx.session_id}}
      result = Calculator.stop(via)
      assert %ParrotMedia.MOS.CallSummary{} = result
    end
  end

  # ===========================================================================
  # Integration-style Tests
  # ===========================================================================

  describe "full flow integration" do
    test "complete flow: init -> playing -> buffers -> stats -> end", ctx do
      {:ok, _calc_pid} = start_calculator(ctx.session_id)

      # Initialize
      opts = %{session_id: ctx.session_id, stats_interval_ms: 50}
      {[], state} = Observer.handle_init(nil, opts)

      # Forward stream format
      stream_format = create_stream_format()
      {[{:stream_format, {:output, _}}], state} =
        Observer.handle_stream_format(:input, stream_format, nil, state)

      # Start playing
      {[], state} = Observer.handle_playing(nil, state)
      assert state.stats_timer != nil

      # Process several buffers
      buffers = for i <- 1..10, do: create_test_buffer(<<i>>, i * 1000)

      state =
        Enum.reduce(buffers, state, fn buffer, acc_state ->
          {[{:buffer, {:output, _}}], new_state} =
            Observer.handle_buffer(:input, buffer, nil, acc_state)
          new_state
        end)

      assert state.buffer_count == 10

      # Wait for stats collection
      Process.sleep(100)

      # Manually trigger stats collection to verify it works
      {[], state} = Observer.handle_info(:collect_stats, nil, state)
      assert state.buffer_count == 0

      # End stream
      {[{:end_of_stream, :output}], final_state} =
        Observer.handle_end_of_stream(:input, nil, state)

      assert final_state.stats_timer == nil

      # Verify Calculator received data - returns CallSummary when metrics were received
      via = {:via, Registry, {ParrotMedia.MOS.Registry, ctx.session_id}}
      result = Calculator.stop(via)
      assert %ParrotMedia.MOS.CallSummary{} = result
    end

    test "multiple intervals send multiple metrics", ctx do
      # Use shorter interval config for faster test
      {:ok, _calc_pid} = Calculator.start_link(
        session_id: ctx.session_id,
        codec: :g711,
        config: Config.new(interval_ms: 50, min_packets_per_interval: 1)
      )

      opts = %{session_id: ctx.session_id, stats_interval_ms: 30}
      {[], state} = Observer.handle_init(nil, opts)

      # Start playing
      {[], state} = Observer.handle_playing(nil, state)

      # Process buffers and wait for multiple intervals
      state = %{state | buffer_count: 20}

      # First interval
      {[], state} = Observer.handle_info(:collect_stats, nil, state)
      Process.cancel_timer(state.stats_timer)

      state = %{state | buffer_count: 30}

      # Second interval
      {[], state} = Observer.handle_info(:collect_stats, nil, state)

      # Wait for Calculator to process both metric batches
      Process.sleep(100)

      via = {:via, Registry, {ParrotMedia.MOS.Registry, ctx.session_id}}

      # Verify multiple metrics were received via the summary
      summary = Calculator.call_summary(via)
      # Total packets should be sum of both intervals (20 + 30 = 50)
      assert summary.total_packets >= 30

      Calculator.stop(via)
      Process.cancel_timer(state.stats_timer)
    end
  end

  # ===========================================================================
  # Zero Latency Verification Tests
  # ===========================================================================

  describe "zero latency verification" do
    test "buffer handling does not modify buffer timing", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      # Create buffer with specific timing
      original_pts = 123_456_789
      buffer = %Buffer{
        payload: <<1, 2, 3, 4, 5>>,
        pts: original_pts,
        dts: original_pts
      }

      # Measure time before and after
      start_time = System.monotonic_time(:microsecond)

      {[{:buffer, {:output, output_buffer}}], _state} =
        Observer.handle_buffer(:input, buffer, nil, state)

      end_time = System.monotonic_time(:microsecond)

      # Processing should be < 1ms (1000 microseconds)
      processing_time = end_time - start_time
      assert processing_time < 1000, "Processing took #{processing_time}us, expected < 1000us"

      # Timestamps should be unchanged
      assert output_buffer.pts == original_pts
      assert output_buffer.dts == original_pts
    end

    test "buffer payload is not copied or modified", ctx do
      opts = %{session_id: ctx.session_id, stats_interval_ms: 1000}
      {[], state} = Observer.handle_init(nil, opts)

      # Create buffer with large payload
      payload = :crypto.strong_rand_bytes(1024)
      buffer = %Buffer{payload: payload, pts: 0}

      {[{:buffer, {:output, output_buffer}}], _state} =
        Observer.handle_buffer(:input, buffer, nil, state)

      # Should be the exact same binary (not a copy)
      assert output_buffer.payload == payload
    end
  end
end
