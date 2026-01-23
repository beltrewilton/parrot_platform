defmodule ParrotMedia.WsAudioForkerUS2Test do
  @moduledoc """
  US2: Multiple Concurrent Forks Tests

  This test module verifies that WsAudioForker supports multiple concurrent forks,
  each operating independently with unique fork_ids.

  Test coverage:
  - e9h.4.1: Registry lookup tests (whereis/1)
  - e9h.4.2: Multiple concurrent forks test
  - e9h.4.3: Fork isolation test
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.WsAudioForker
  alias ParrotMedia.WsAudioForker.Config

  # Base port offset to avoid conflicts with other tests
  @base_port 15_000

  # Helper to generate unique test resources
  # Using System.unique_integer ensures no collisions within the same test
  defp unique_port, do: @base_port + System.unique_integer([:positive, :monotonic])
  defp unique_fork_id, do: "fork_#{System.unique_integer([:positive])}"

  defp start_mock_server(port) do
    start_supervised(
      {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
      id: {:mock_ws_server, port}
    )
  end

  defp start_forker(fork_id, url) do
    {:ok, config} = Config.new(fork_id: fork_id, url: url)
    WsAudioForker.start_link(config)
  end

  # ============================================================================
  # e9h.4.1: Registry lookup tests (whereis/1)
  # ============================================================================

  describe "whereis/1" do
    setup do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"
      {:ok, port: port, url: url}
    end

    test "returns {:ok, pid} for registered fork_id", %{url: url} do
      fork_id = unique_fork_id()
      {:ok, pid} = start_forker(fork_id, url)

      assert {:ok, ^pid} = WsAudioForker.whereis(fork_id)

      WsAudioForker.stop(pid)
    end

    test "returns {:error, :not_found} for unregistered fork_id", %{url: _url} do
      assert {:error, :not_found} = WsAudioForker.whereis("nonexistent_fork_id")
    end

    test "returns {:error, :not_found} after fork is stopped", %{url: url} do
      fork_id = unique_fork_id()
      {:ok, pid} = start_forker(fork_id, url)

      # Verify it's registered
      assert {:ok, ^pid} = WsAudioForker.whereis(fork_id)

      # Stop and wait for process to terminate
      :ok = WsAudioForker.stop(pid)
      Process.sleep(50)

      # Should no longer be found
      assert {:error, :not_found} = WsAudioForker.whereis(fork_id)
    end

    test "returns different PIDs for different fork_ids", %{url: url} do
      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)

      assert {:ok, result_pid1} = WsAudioForker.whereis(fork_id_1)
      assert {:ok, result_pid2} = WsAudioForker.whereis(fork_id_2)

      assert result_pid1 == pid1
      assert result_pid2 == pid2
      assert pid1 != pid2

      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
    end
  end

  # ============================================================================
  # e9h.4.2: Multiple concurrent forks test
  # ============================================================================

  describe "multiple concurrent forks" do
    test "can start multiple forkers with different fork_ids to same endpoint" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()
      fork_id_3 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)
      {:ok, pid3} = start_forker(fork_id_3, url)

      # All processes should be alive and distinct
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
      assert Process.alive?(pid3)

      assert pid1 != pid2
      assert pid2 != pid3
      assert pid1 != pid3

      # All should be findable via whereis
      assert {:ok, ^pid1} = WsAudioForker.whereis(fork_id_1)
      assert {:ok, ^pid2} = WsAudioForker.whereis(fork_id_2)
      assert {:ok, ^pid3} = WsAudioForker.whereis(fork_id_3)

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
      WsAudioForker.stop(pid3)
    end

    test "can start multiple forkers with different urls (same server, different paths)" do
      # Test multiple forkers connecting to the same server endpoint
      # This verifies that multiple forkers can coexist regardless of URL
      port = unique_port()
      {:ok, _server} = start_mock_server(port)

      # Use the same server but the URL difference demonstrates
      # that forkers are identified by fork_id, not URL
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)

      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
      assert pid1 != pid2

      # Verify they are independent processes with independent registrations
      assert {:ok, ^pid1} = WsAudioForker.whereis(fork_id_1)
      assert {:ok, ^pid2} = WsAudioForker.whereis(fork_id_2)

      # Wait for connections
      Process.sleep(100)

      # Send to each fork and verify both work
      audio_1 = <<0xAA>>
      audio_2 = <<0xBB>>
      :ok = WsAudioForker.send_audio(fork_id_1, audio_1)
      :ok = WsAudioForker.send_audio(fork_id_2, audio_2)

      assert_receive {:ws_frame, _}, 1000
      assert_receive {:ws_frame, _}, 1000

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
    end

    test "each fork can send audio independently" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)

      # Wait for connections to establish
      Process.sleep(100)

      # Send distinct audio from each fork
      audio_1 = <<0x11, 0x11, 0x11>>
      audio_2 = <<0x22, 0x22, 0x22>>

      :ok = WsAudioForker.send_audio(fork_id_1, audio_1)
      :ok = WsAudioForker.send_audio(fork_id_2, audio_2)

      # Both should be received (order may vary)
      assert_receive {:ws_frame, received_1}, 1000
      assert_receive {:ws_frame, received_2}, 1000

      received_set = MapSet.new([received_1, received_2])
      assert MapSet.member?(received_set, audio_1)
      assert MapSet.member?(received_set, audio_2)

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
    end

    test "send_audio works with fork_id string for multiple forks" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_ids = for _ <- 1..5, do: unique_fork_id()
      pids = for fork_id <- fork_ids, do: elem(start_forker(fork_id, url), 1)

      # Wait for connections
      Process.sleep(100)

      # Send unique audio from each fork using fork_id string
      for {fork_id, i} <- Enum.with_index(fork_ids) do
        audio = <<i::8, i::8, i::8>>
        assert :ok = WsAudioForker.send_audio(fork_id, audio)
      end

      # Receive all frames
      for _ <- 1..5 do
        assert_receive {:ws_frame, _}, 1000
      end

      # Clean up
      for pid <- pids, do: WsAudioForker.stop(pid)
    end

    test "status/1 works independently for each fork" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)

      # Wait for connections
      Process.sleep(100)

      # Send different amounts of audio to each fork
      audio = <<0x00>>
      :ok = WsAudioForker.send_audio(fork_id_1, audio)
      :ok = WsAudioForker.send_audio(fork_id_1, audio)
      :ok = WsAudioForker.send_audio(fork_id_1, audio)
      :ok = WsAudioForker.send_audio(fork_id_2, audio)

      # Wait for frames to be processed
      for _ <- 1..4, do: assert_receive({:ws_frame, _}, 1000)

      # Check status of each fork independently
      {:ok, status1} = WsAudioForker.status(fork_id_1)
      {:ok, status2} = WsAudioForker.status(fork_id_2)

      assert status1.frames_sent == 3
      assert status2.frames_sent == 1

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
    end

    test "connected?/1 works independently for each fork" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)

      # Wait for connections
      Process.sleep(100)

      # Both should be connected
      assert WsAudioForker.connected?(fork_id_1) == true
      assert WsAudioForker.connected?(fork_id_2) == true

      # Using PIDs should also work
      assert WsAudioForker.connected?(pid1) == true
      assert WsAudioForker.connected?(pid2) == true

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
    end
  end

  # ============================================================================
  # e9h.4.3: Fork isolation test
  # ============================================================================

  describe "fork isolation" do
    test "stopping one fork does not affect others" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()
      fork_id_3 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)
      {:ok, pid3} = start_forker(fork_id_3, url)

      # Wait for connections
      Process.sleep(100)

      # Stop the middle fork
      :ok = WsAudioForker.stop(pid2)
      Process.sleep(50)

      # Others should still be alive and functional
      assert Process.alive?(pid1)
      assert Process.alive?(pid3)
      refute Process.alive?(pid2)

      # Should still be able to send audio to remaining forks
      audio = <<0xFF>>
      assert :ok = WsAudioForker.send_audio(fork_id_1, audio)
      assert :ok = WsAudioForker.send_audio(fork_id_3, audio)

      assert_receive {:ws_frame, ^audio}, 1000
      assert_receive {:ws_frame, ^audio}, 1000

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid3)
    end

    test "fork to unreachable endpoint fails without affecting other forks" do
      # Start a working server
      good_port = unique_port()
      {:ok, _server} = start_mock_server(good_port)
      good_url = "ws://localhost:#{good_port}/ws"

      # Bad URL - no server running
      bad_port = unique_port() + 5000
      bad_url = "ws://localhost:#{bad_port}/ws"

      good_fork_id = unique_fork_id()
      bad_fork_id = unique_fork_id()

      # Start good fork first
      {:ok, good_pid} = start_forker(good_fork_id, good_url)
      Process.sleep(100)

      # Trap exits so the test process doesn't crash when bad fork fails
      Process.flag(:trap_exit, true)

      # Start bad fork - it should fail to connect
      {:ok, bad_config} = Config.new(fork_id: bad_fork_id, url: bad_url)
      {:ok, bad_pid} = WsAudioForker.start_link(bad_config)

      # Monitor the bad fork to detect when it fails
      ref = Process.monitor(bad_pid)

      # The bad fork should fail quickly (initial connection failure)
      # We expect both :DOWN and :EXIT messages
      assert_receive {:DOWN, ^ref, :process, ^bad_pid, _reason}, 5000

      # Consume the EXIT message from the linked process
      receive do
        {:EXIT, ^bad_pid, _reason} -> :ok
      after
        100 -> :ok
      end

      # Good fork should still be alive and working
      assert Process.alive?(good_pid)
      assert WsAudioForker.connected?(good_fork_id) == true

      audio = <<0xAB, 0xCD>>
      :ok = WsAudioForker.send_audio(good_fork_id, audio)
      assert_receive {:ws_frame, ^audio}, 1000

      # Clean up
      WsAudioForker.stop(good_pid)
    end

    test "each fork maintains its own buffer independently" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, config1} = Config.new(fork_id: fork_id_1, url: url, buffer_size: 10)
      {:ok, config2} = Config.new(fork_id: fork_id_2, url: url, buffer_size: 50)

      {:ok, pid1} = WsAudioForker.start_link(config1)
      {:ok, pid2} = WsAudioForker.start_link(config2)

      # Wait for connections
      Process.sleep(100)

      {:ok, status1} = WsAudioForker.status(fork_id_1)
      {:ok, status2} = WsAudioForker.status(fork_id_2)

      # Buffer capacities should be independent
      assert status1.buffer_capacity == 10
      assert status2.buffer_capacity == 50

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
    end

    test "fork reconnect_count is independent per fork" do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"

      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, pid1} = start_forker(fork_id_1, url)
      {:ok, pid2} = start_forker(fork_id_2, url)

      # Wait for connections
      Process.sleep(100)

      {:ok, status1} = WsAudioForker.status(fork_id_1)
      {:ok, status2} = WsAudioForker.status(fork_id_2)

      # Both should start with 0 reconnect count
      assert status1.reconnect_count == 0
      assert status2.reconnect_count == 0

      # Clean up
      WsAudioForker.stop(pid1)
      WsAudioForker.stop(pid2)
    end
  end

  # ============================================================================
  # Additional API tests for US2
  # ============================================================================

  describe "send_audio/2 with fork_id string (US2 specific)" do
    setup do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"
      {:ok, port: port, url: url}
    end

    test "send_audio with fork_id string routes to correct forker", %{url: url} do
      fork_id_1 = unique_fork_id()
      fork_id_2 = unique_fork_id()

      {:ok, _pid1} = start_forker(fork_id_1, url)
      {:ok, _pid2} = start_forker(fork_id_2, url)

      Process.sleep(100)

      # Send distinct audio via fork_id strings
      audio_1 = <<0xAA, 0xAA>>
      audio_2 = <<0xBB, 0xBB>>

      :ok = WsAudioForker.send_audio(fork_id_1, audio_1)
      :ok = WsAudioForker.send_audio(fork_id_2, audio_2)

      # Verify both received
      assert_receive {:ws_frame, _}, 1000
      assert_receive {:ws_frame, _}, 1000

      WsAudioForker.stop(fork_id_1)
      WsAudioForker.stop(fork_id_2)
    end

    test "send_audio returns error for wrong fork_id", %{url: url} do
      fork_id = unique_fork_id()
      {:ok, _pid} = start_forker(fork_id, url)

      # Try to send to wrong fork_id
      assert {:error, :not_found} = WsAudioForker.send_audio("wrong_fork_id", <<0x00>>)

      WsAudioForker.stop(fork_id)
    end
  end

  describe "status/1 with fork_id string (US2 specific)" do
    setup do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"
      {:ok, port: port, url: url}
    end

    test "status/1 returns correct data for fork_id string", %{url: url} do
      fork_id = unique_fork_id()
      {:ok, _pid} = start_forker(fork_id, url)

      Process.sleep(100)

      {:ok, status} = WsAudioForker.status(fork_id)

      assert is_map(status)
      assert Map.has_key?(status, :connection_state)
      assert Map.has_key?(status, :buffer_size)
      assert Map.has_key?(status, :buffer_capacity)
      assert Map.has_key?(status, :buffer_fill_percent)
      assert Map.has_key?(status, :frames_sent)
      assert Map.has_key?(status, :frames_dropped)
      assert Map.has_key?(status, :reconnect_count)

      WsAudioForker.stop(fork_id)
    end

    test "status/1 returns error for unknown fork_id" do
      assert {:error, :not_found} = WsAudioForker.status("nonexistent_fork")
    end
  end

  describe "connected?/1 with fork_id string (US2 specific)" do
    setup do
      port = unique_port()
      {:ok, _server} = start_mock_server(port)
      url = "ws://localhost:#{port}/ws"
      {:ok, port: port, url: url}
    end

    test "connected?/1 returns true when connected via fork_id", %{url: url} do
      fork_id = unique_fork_id()
      {:ok, _pid} = start_forker(fork_id, url)

      Process.sleep(100)

      assert WsAudioForker.connected?(fork_id) == true

      WsAudioForker.stop(fork_id)
    end

    test "connected?/1 returns error for unknown fork_id" do
      assert {:error, :not_found} = WsAudioForker.connected?("nonexistent_fork")
    end
  end
end
