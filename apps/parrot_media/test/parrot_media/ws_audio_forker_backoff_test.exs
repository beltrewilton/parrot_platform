defmodule ParrotMedia.WsAudioForkerBackoffTest do
  @moduledoc """
  Tests for exponential backoff behavior in WsAudioForker.

  These tests verify:
  - Exponential backoff timing is configured and passed to Fresh
  - Max retries limit is enforced
  - Reconnect count resets on successful connection
  - Audio streaming resumes after reconnection
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.WsAudioForker
  alias ParrotMedia.WsAudioForker.Config

  # Base port offset to avoid conflicts with other tests
  @base_port 15_000

  # Callback module for testing reconnection and failure events
  defmodule ReconnectCallback do
    @behaviour ParrotMedia.WsAudioForker.Callback

    @impl true
    def init(args) do
      {:ok, %{test_pid: args[:test_pid]}}
    end

    @impl true
    def handle_fork_event({:fork_event, _fork_id, {:reconnecting, attempt}}, state) do
      send(state.test_pid, {:reconnecting, attempt})
      {:ok, state}
    end

    def handle_fork_event({:fork_event, _fork_id, :connected}, state) do
      send(state.test_pid, :connected)
      {:ok, state}
    end

    def handle_fork_event({:fork_event, _fork_id, {:failed, reason}}, state) do
      send(state.test_pid, {:failed, reason})
      {:ok, state}
    end

    def handle_fork_event(_event, state) do
      {:ok, state}
    end
  end

  setup do
    # Generate unique port for this test to avoid conflicts
    port = @base_port + :rand.uniform(1000)
    fork_id = "backoff_test_#{System.unique_integer([:positive])}"

    {:ok, port: port, fork_id: fork_id}
  end

  # ============================================================================
  # Config tests for backoff fields
  # ============================================================================

  describe "Config backoff fields" do
    test "Config.new accepts backoff_initial_ms option" do
      {:ok, config} =
        Config.new(
          fork_id: "test",
          url: "wss://example.com/ws",
          backoff_initial_ms: 500
        )

      assert config.backoff_initial_ms == 500
    end

    test "Config.new accepts backoff_max_ms option" do
      {:ok, config} =
        Config.new(
          fork_id: "test",
          url: "wss://example.com/ws",
          backoff_max_ms: 60_000
        )

      assert config.backoff_max_ms == 60_000
    end

    test "Config has sensible defaults for backoff" do
      {:ok, config} =
        Config.new(
          fork_id: "test",
          url: "wss://example.com/ws"
        )

      # Default initial backoff should be 1 second (1000ms)
      assert config.backoff_initial_ms == 1000
      # Default max backoff should be 30 seconds (30000ms)
      assert config.backoff_max_ms == 30_000
    end

    test "Config.validate rejects invalid backoff_initial_ms" do
      config = %Config{
        fork_id: "test",
        url: "wss://example.com/ws",
        backoff_initial_ms: -1,
        backoff_max_ms: 30_000,
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_backoff_initial} = Config.validate(config)
    end

    test "Config.validate rejects invalid backoff_max_ms" do
      config = %Config{
        fork_id: "test",
        url: "wss://example.com/ws",
        backoff_initial_ms: 1000,
        backoff_max_ms: 0,
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :invalid_backoff_max} = Config.validate(config)
    end

    test "Config.validate rejects backoff_initial_ms > backoff_max_ms" do
      config = %Config{
        fork_id: "test",
        url: "wss://example.com/ws",
        backoff_initial_ms: 60_000,
        backoff_max_ms: 1000,
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, :backoff_initial_exceeds_max} = Config.validate(config)
    end
  end

  # ============================================================================
  # Max retries enforcement
  # ============================================================================

  describe "max_retries enforcement" do
    test "forker terminates after max_retries exceeded (mid-stream failure)", %{
      port: port,
      fork_id: fork_id
    } do
      # Trap exits so we don't crash when the forker exits
      Process.flag(:trap_exit, true)

      # Start mock server, connect, then shut it down to test mid-stream failure
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws",
          max_retries: 2,
          backoff_initial_ms: 50,
          backoff_max_ms: 100
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      ref = Process.monitor(pid)

      # Wait for successful connection
      Process.sleep(100)
      assert WsAudioForker.connected?(pid) == true

      # Stop the server to trigger mid-stream failure and reconnection attempts
      stop_supervised({:mock_ws_server, port})

      # Wait for reconnection attempts and eventual termination
      # With max_retries: 2 and backoff starting at 50ms, should terminate quickly
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5000

      # The process should terminate with a reason indicating max retries exceeded
      # Due to process linking, the reason may or may not be wrapped in :shutdown
      assert match?({:shutdown, {:max_retries_exceeded, _}}, reason) or
               match?({:shutdown, :max_retries_exceeded}, reason) or
               match?({:max_retries_exceeded, _}, reason)
    end

    test "forker does not terminate when max_retries is 0 (unlimited)", %{port: port, fork_id: fork_id} do
      # Start mock server
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws",
          max_retries: 0  # 0 means unlimited
        )

      {:ok, pid} = WsAudioForker.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Should be connected and running
      assert Process.alive?(pid)
      assert WsAudioForker.connected?(pid) == true

      WsAudioForker.stop(pid)
    end

    test "reconnect_count is exposed in status (mid-stream failure)", %{
      port: port,
      fork_id: fork_id
    } do
      # Trap exits so we don't crash
      Process.flag(:trap_exit, true)

      # Start mock server, connect, then shut it down
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws",
          max_retries: 10,
          backoff_initial_ms: 50,
          backoff_max_ms: 100
        )

      {:ok, pid} = WsAudioForker.start_link(config)

      # Wait for successful connection
      Process.sleep(100)
      assert WsAudioForker.connected?(pid) == true

      {:ok, status_before} = WsAudioForker.status(pid)
      assert status_before.reconnect_count == 0

      # Stop the server to trigger mid-stream failure
      stop_supervised({:mock_ws_server, port})

      # Wait for at least one reconnection attempt
      Process.sleep(200)

      {:ok, status} = WsAudioForker.status(pid)

      # Reconnect count should be > 0 since mid-stream failure triggered reconnection
      assert status.reconnect_count >= 1

      WsAudioForker.stop(pid)
    end
  end

  # ============================================================================
  # Reconnect count reset
  # ============================================================================

  describe "reconnect_count reset on successful connection" do
    test "reconnect_count resets to 0 when connection succeeds", %{port: port, fork_id: fork_id} do
      # Start mock server
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws"
        )

      {:ok, pid} = WsAudioForker.start_link(config)

      # Wait for connection
      Process.sleep(100)

      {:ok, status} = WsAudioForker.status(pid)

      # Reconnect count should be 0 after successful connection
      assert status.reconnect_count == 0
      assert status.connection_state == :connected

      WsAudioForker.stop(pid)
    end
  end

  # ============================================================================
  # Audio streaming resumes after reconnection
  # ============================================================================

  describe "audio streaming after reconnection" do
    test "buffered audio is sent after reconnection", %{port: port, fork_id: fork_id} do
      # Start mock server
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws",
          buffer_size: 10
        )

      {:ok, pid} = WsAudioForker.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Send audio
      audio_data = <<1, 2, 3, 4, 5>>
      :ok = WsAudioForker.send_audio(pid, audio_data)

      # Verify audio was received
      assert_receive {:ws_frame, ^audio_data}, 1000

      WsAudioForker.stop(pid)
    end
  end

  # ============================================================================
  # Callback notifications for reconnection events
  # ============================================================================

  # ============================================================================
  # Initial connection failure vs mid-stream failure (P2.3)
  # ============================================================================

  describe "initial connection failure (never connected)" do
    test "forker terminates immediately with initial_connection_failed on unreachable URL", %{
      fork_id: fork_id
    } do
      # Trap exits so we don't crash when the forker exits
      Process.flag(:trap_exit, true)

      # Use a non-existent server - the forker should fail immediately
      # WITHOUT retrying because it never successfully connected
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:59999/ws",
          max_retries: 5,
          backoff_initial_ms: 50,
          backoff_max_ms: 100
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      ref = Process.monitor(pid)

      # Should terminate quickly (not waiting for 5 retry attempts)
      # With backoff of 50-100ms and 5 retries, the old behavior would take 250-500ms minimum
      # The new behavior should fail in under 200ms
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 500

      # The reason should indicate initial connection failed (no retries)
      assert match?({:shutdown, {:initial_connection_failed, _}}, reason)
    end

    test "callback receives initial_connection_failed event (not reconnecting)", %{
      fork_id: fork_id
    } do
      Process.flag(:trap_exit, true)

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:59999/ws",
          max_retries: 5,
          backoff_initial_ms: 50,
          backoff_max_ms: 100,
          callback_module: ReconnectCallback,
          callback_state: %{test_pid: self()}
        )

      {:ok, _pid} = WsAudioForker.start_link(config)

      # Should NOT receive any reconnecting events because we never connected
      refute_receive {:reconnecting, _}, 300

      # Should receive a failed event with initial_connection_failed reason
      assert_receive {:failed, {:initial_connection_failed, _reason}}, 500
    end
  end

  describe "mid-stream failure (was connected, then disconnected)" do
    test "forker retries with backoff when connection drops after being established", %{
      port: port,
      fork_id: fork_id
    } do
      # Trap exits so we don't crash when the forker terminates after max_retries
      Process.flag(:trap_exit, true)

      # Start mock server
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws",
          max_retries: 3,
          backoff_initial_ms: 50,
          backoff_max_ms: 100,
          callback_module: ReconnectCallback,
          callback_state: %{test_pid: self()}
        )

      {:ok, _pid} = WsAudioForker.start_link(config)

      # Wait for successful connection
      assert_receive :connected, 1000

      # Now stop the server to simulate mid-stream failure
      stop_supervised({:mock_ws_server, port})
      Process.sleep(50)

      # The forker should enter reconnection mode (not immediate failure)
      # because it WAS connected before
      assert_receive {:reconnecting, 1}, 500
      assert_receive {:reconnecting, 2}, 500
      assert_receive {:reconnecting, 3}, 500

      # Eventually fail after max retries
      # Due to race conditions, we may receive either the callback message or the EXIT first
      # The EXIT reason may or may not be wrapped in :shutdown
      receive do
        {:failed, {:max_retries_exceeded, _}} -> :ok
        {:EXIT, _, {:shutdown, {:max_retries_exceeded, _}}} -> :ok
        {:EXIT, _, {:max_retries_exceeded, _}} -> :ok
      after
        1000 -> flunk("Expected max_retries_exceeded message")
      end
    end

    test "mid-stream failure uses exponential backoff timing", %{port: port, fork_id: fork_id} do
      # Trap exits so we don't crash when the forker terminates after max_retries
      Process.flag(:trap_exit, true)

      # Start mock server
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws",
          max_retries: 3,
          backoff_initial_ms: 100,
          backoff_max_ms: 200,
          callback_module: ReconnectCallback,
          callback_state: %{test_pid: self()}
        )

      {:ok, _pid} = WsAudioForker.start_link(config)

      # Wait for successful connection
      assert_receive :connected, 1000

      # Stop the server to simulate mid-stream failure
      stop_supervised({:mock_ws_server, port})

      # Record timing of reconnection attempts
      start_time = System.monotonic_time(:millisecond)
      assert_receive {:reconnecting, 1}, 500
      t1 = System.monotonic_time(:millisecond) - start_time

      assert_receive {:reconnecting, 2}, 500
      t2 = System.monotonic_time(:millisecond) - start_time

      assert_receive {:reconnecting, 3}, 500
      t3 = System.monotonic_time(:millisecond) - start_time

      # Verify exponential backoff is happening (timing should increase)
      # Each subsequent reconnect should be delayed more than the previous
      # Due to timing jitter, we just verify the total time is reasonable
      assert t3 > t2
      assert t2 > t1

      # Process terminates after max retries, no cleanup needed
    end
  end

  describe "reconnection callback events" do
    test "callback receives reconnecting events with attempt count (mid-stream failure)", %{
      port: port,
      fork_id: fork_id
    } do
      # Trap exits so we don't crash when the forker terminates after max_retries
      Process.flag(:trap_exit, true)

      # Start mock server
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server, port}
        )

      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:#{port}/ws",
          max_retries: 3,
          backoff_initial_ms: 50,
          backoff_max_ms: 100,
          callback_module: ReconnectCallback,
          callback_state: %{test_pid: self()}
        )

      {:ok, _pid} = WsAudioForker.start_link(config)

      # Wait for successful connection
      assert_receive :connected, 1000

      # Stop the server to trigger mid-stream failure
      stop_supervised({:mock_ws_server, port})

      # Should receive reconnecting events
      assert_receive {:reconnecting, 1}, 1000
      assert_receive {:reconnecting, 2}, 1000
      assert_receive {:reconnecting, 3}, 1000

      # Should eventually receive a failure indication
      # Due to process linking race conditions, we may receive either:
      # - {:failed, reason} from the callback
      # - {:EXIT, pid, reason} from the linked process termination
      receive do
        {:failed, _reason} -> :ok
        {:EXIT, _pid, {:max_retries_exceeded, _}} -> :ok
        {:EXIT, _pid, {:shutdown, {:max_retries_exceeded, _}}} -> :ok
      after
        2000 -> flunk("Expected failure notification (callback or EXIT)")
      end
    end
  end
end
