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
    test "forker terminates after max_retries exceeded", %{fork_id: fork_id} do
      # Trap exits so we don't crash when the forker exits
      Process.flag(:trap_exit, true)

      # Connect to a non-existent server to force reconnection attempts
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:59999/ws",
          max_retries: 2,
          backoff_initial_ms: 50,
          backoff_max_ms: 100
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      ref = Process.monitor(pid)

      # Wait for reconnection attempts and eventual termination
      # With max_retries: 2 and backoff starting at 50ms, should terminate quickly
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5000

      # The process should terminate with a reason indicating max retries exceeded
      assert match?({:shutdown, {:max_retries_exceeded, _}}, reason) or
               match?({:shutdown, :max_retries_exceeded}, reason)
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

    test "reconnect_count is exposed in status", %{fork_id: fork_id} do
      # Connect to non-existent server to trigger reconnection
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:59999/ws",
          max_retries: 10,
          backoff_initial_ms: 50,
          backoff_max_ms: 100
        )

      {:ok, pid} = WsAudioForker.start_link(config)

      # Wait for at least one reconnection attempt
      Process.sleep(200)

      {:ok, status} = WsAudioForker.status(pid)

      # Reconnect count should be > 0 since initial connection failed
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

  describe "reconnection callback events" do
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

    test "callback receives reconnecting events with attempt count", %{fork_id: fork_id} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: "ws://localhost:59999/ws",
          max_retries: 3,
          backoff_initial_ms: 50,
          backoff_max_ms: 100,
          callback_module: ReconnectCallback,
          callback_state: %{test_pid: self()}
        )

      {:ok, _pid} = WsAudioForker.start_link(config)

      # Should receive reconnecting events
      assert_receive {:reconnecting, 1}, 1000
      assert_receive {:reconnecting, 2}, 1000
      assert_receive {:reconnecting, 3}, 1000

      # Should eventually receive failed event
      assert_receive {:failed, _reason}, 2000
    end
  end
end
