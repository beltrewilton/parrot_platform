defmodule ParrotMedia.WsAudioForkerTest do
  @moduledoc """
  Tests for ParrotMedia.WsAudioForker lifecycle and send_audio functionality.

  These tests use the MockWsServer and MockWsHandler to verify that:
  - Forkers start and stop correctly
  - Registry registration works
  - Audio frames are properly sent over WebSocket connections
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.WsAudioForker
  alias ParrotMedia.WsAudioForker.Config

  # Base port offset to avoid conflicts with other tests
  @base_port 14_000

  setup do
    # Generate unique port for this test to avoid conflicts
    port = @base_port + :rand.uniform(1000)
    fork_id = "test_fork_#{System.unique_integer([:positive])}"

    # Start mock WebSocket server
    {:ok, server_pid} =
      start_supervised(
        {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
        id: {:mock_ws_server, port}
      )

    url = "ws://localhost:#{port}/ws"

    {:ok, port: port, fork_id: fork_id, url: url, server_pid: server_pid}
  end

  # ============================================================================
  # T013: start_link/stop tests
  # ============================================================================

  describe "start_link/1" do
    test "starts forker with valid config", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      assert {:ok, pid} = WsAudioForker.start_link(config)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      WsAudioForker.stop(pid)
    end

    test "registers forker with WsForkerRegistry using fork_id", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)

      # Verify registration in WsForkerRegistry
      assert [{^pid, _}] = Registry.lookup(ParrotMedia.WsForkerRegistry, {:ws_forker, fork_id})

      # Clean up
      WsAudioForker.stop(pid)
    end

    test "returns error for invalid config - missing url" do
      # Create an invalid config by bypassing new/1 validation
      config = %Config{
        fork_id: "test_fork",
        url: nil,
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, _reason} = WsAudioForker.start_link(config)
    end

    test "returns error for invalid config - empty fork_id" do
      # Create an invalid config by bypassing new/1 validation
      config = %Config{
        fork_id: "",
        url: "ws://localhost:9999/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        audio_format: :pcm_16le,
        buffer_size: 100,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, _reason} = WsAudioForker.start_link(config)
    end

    test "returns error for duplicate fork_id", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      # Start first forker
      {:ok, pid1} = WsAudioForker.start_link(config)
      assert Process.alive?(pid1)

      # Attempt to start second forker with same fork_id
      assert {:error, {:already_registered, _}} = WsAudioForker.start_link(config)

      # Clean up
      WsAudioForker.stop(pid1)
    end

    test "starts forker with all optional config fields", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url,
          headers: [{"Authorization", "Bearer test_token"}],
          callback_module: nil,
          callback_state: %{session_id: "test_session"},
          audio_format: :opus,
          buffer_size: 200,
          connect_timeout_ms: 10_000,
          max_retries: 3
        )

      assert {:ok, pid} = WsAudioForker.start_link(config)
      assert Process.alive?(pid)

      # Clean up
      WsAudioForker.stop(pid)
    end
  end

  describe "stop/1 with PID" do
    test "stops forker gracefully when given PID", %{fork_id: fork_id, url: url} do
      {:ok, config} = Config.new(fork_id: fork_id, url: url)
      {:ok, pid} = WsAudioForker.start_link(config)

      assert Process.alive?(pid)
      assert :ok = WsAudioForker.stop(pid)

      # Give some time for process to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "removes from registry when stopped via PID", %{fork_id: fork_id, url: url} do
      {:ok, config} = Config.new(fork_id: fork_id, url: url)
      {:ok, pid} = WsAudioForker.start_link(config)

      # Verify registered
      assert [{^pid, _}] = Registry.lookup(ParrotMedia.WsForkerRegistry, {:ws_forker, fork_id})

      # Stop and verify unregistered
      :ok = WsAudioForker.stop(pid)
      Process.sleep(50)

      assert [] = Registry.lookup(ParrotMedia.WsForkerRegistry, {:ws_forker, fork_id})
    end

    test "returns error for unknown PID" do
      # Create a PID that doesn't exist
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(fake_pid)

      assert {:error, :not_found} = WsAudioForker.stop(fake_pid)
    end
  end

  describe "stop/1 with fork_id string" do
    test "stops forker gracefully when given fork_id string", %{fork_id: fork_id, url: url} do
      {:ok, config} = Config.new(fork_id: fork_id, url: url)
      {:ok, pid} = WsAudioForker.start_link(config)

      assert Process.alive?(pid)
      assert :ok = WsAudioForker.stop(fork_id)

      # Give some time for process to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "removes from registry when stopped via fork_id", %{fork_id: fork_id, url: url} do
      {:ok, config} = Config.new(fork_id: fork_id, url: url)
      {:ok, pid} = WsAudioForker.start_link(config)

      # Verify registered
      assert [{^pid, _}] = Registry.lookup(ParrotMedia.WsForkerRegistry, {:ws_forker, fork_id})

      # Stop via fork_id and verify unregistered
      :ok = WsAudioForker.stop(fork_id)
      Process.sleep(50)

      assert [] = Registry.lookup(ParrotMedia.WsForkerRegistry, {:ws_forker, fork_id})
    end

    test "returns error for unknown fork_id" do
      assert {:error, :not_found} = WsAudioForker.stop("nonexistent_fork_id")
    end
  end

  describe "forker termination" do
    test "terminates cleanly when stopped", %{fork_id: fork_id, url: url} do
      {:ok, config} = Config.new(fork_id: fork_id, url: url)
      {:ok, pid} = WsAudioForker.start_link(config)

      # Monitor the process
      ref = Process.monitor(pid)

      # Stop the forker
      :ok = WsAudioForker.stop(pid)

      # Wait for DOWN message indicating clean termination
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1000
      assert reason == :normal or reason == :shutdown or match?({:shutdown, _}, reason)
    end

    test "closes WebSocket connection when stopped", %{fork_id: fork_id, url: url} do
      {:ok, config} = Config.new(fork_id: fork_id, url: url)
      {:ok, pid} = WsAudioForker.start_link(config)

      # Allow connection to be established
      Process.sleep(100)

      # Stop the forker
      :ok = WsAudioForker.stop(pid)

      # The mock server should receive a close notification
      # This tests that the WebSocket is closed gracefully
      assert_receive {:ws_closed, _received}, 2000
    end

    test "can start new forker with same fork_id after previous is stopped", %{
      fork_id: fork_id,
      url: url
    } do
      {:ok, config} = Config.new(fork_id: fork_id, url: url)

      # Start first forker
      {:ok, pid1} = WsAudioForker.start_link(config)
      assert Process.alive?(pid1)

      # Stop it
      :ok = WsAudioForker.stop(pid1)
      Process.sleep(50)
      refute Process.alive?(pid1)

      # Start new forker with same fork_id
      {:ok, pid2} = WsAudioForker.start_link(config)
      assert Process.alive?(pid2)
      assert pid1 != pid2

      # Clean up
      WsAudioForker.stop(pid2)
    end
  end

  # ============================================================================
  # T014: send_audio tests
  # ============================================================================

  describe "send_audio/2 with PID" do
    test "sends audio binary to WebSocket server", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)

      # Wait for connection to establish
      Process.sleep(100)

      # Send audio data
      audio_data = <<0x00, 0x01, 0x02, 0x03, 0xFF>>
      result = WsAudioForker.send_audio(pid, audio_data)

      assert result == :ok

      # Verify audio was received by mock server
      assert_receive {:ws_frame, ^audio_data}, 1000

      WsAudioForker.stop(pid)
    end

    test "returns :ok when audio is queued", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      audio_data = <<0xAB, 0xCD>>
      assert WsAudioForker.send_audio(pid, audio_data) == :ok

      WsAudioForker.stop(pid)
    end
  end

  describe "send_audio/2 with fork_id string" do
    test "sends audio binary using fork_id lookup", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, _pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      audio_data = <<0x10, 0x20, 0x30>>
      result = WsAudioForker.send_audio(fork_id, audio_data)

      assert result == :ok

      # Verify audio was received by mock server
      assert_receive {:ws_frame, ^audio_data}, 1000

      WsAudioForker.stop(fork_id)
    end

    test "returns {:error, :not_found} for unknown fork_id" do
      result = WsAudioForker.send_audio("nonexistent_fork_id", <<0x00>>)

      assert result == {:error, :not_found}
    end
  end

  describe "send_audio/3 with opts" do
    test "accepts optional metadata keyword list", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      audio_data = <<0xDE, 0xAD, 0xBE, 0xEF>>
      result = WsAudioForker.send_audio(pid, audio_data, timestamp: 12345)

      assert result == :ok

      # Verify audio was received (metadata handling is implementation detail)
      assert_receive {:ws_frame, ^audio_data}, 1000

      WsAudioForker.stop(pid)
    end

    test "accepts empty opts list", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      audio_data = <<0x11, 0x22>>
      result = WsAudioForker.send_audio(pid, audio_data, [])

      assert result == :ok

      WsAudioForker.stop(pid)
    end
  end

  describe "send_audio/2 error cases" do
    test "returns {:error, :not_found} for unknown PID" do
      # Create a PID that doesn't exist
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      result = WsAudioForker.send_audio(fake_pid, <<0x00>>)

      assert result == {:error, :not_found}
    end

    test "returns {:error, :not_found} for unknown fork_id string" do
      result = WsAudioForker.send_audio("definitely_not_a_valid_fork_id", <<0x00>>)

      assert result == {:error, :not_found}
    end
  end

  describe "send_audio/2 multiple frames" do
    test "sends multiple audio frames in order", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Send multiple frames
      frame1 = <<0x01, 0x01, 0x01>>
      frame2 = <<0x02, 0x02, 0x02>>
      frame3 = <<0x03, 0x03, 0x03>>

      assert WsAudioForker.send_audio(pid, frame1) == :ok
      assert WsAudioForker.send_audio(pid, frame2) == :ok
      assert WsAudioForker.send_audio(pid, frame3) == :ok

      # Verify frames received in order
      assert_receive {:ws_frame, ^frame1}, 1000
      assert_receive {:ws_frame, ^frame2}, 1000
      assert_receive {:ws_frame, ^frame3}, 1000

      WsAudioForker.stop(pid)
    end

    test "audio frame is received by mock server", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Send audio and verify it arrives at the mock server
      audio_data = <<0xCA, 0xFE, 0xBA, 0xBE>>
      WsAudioForker.send_audio(pid, audio_data)

      # The mock handler sends {:ws_frame, data} to test_pid
      assert_receive {:ws_frame, received_data}, 1000
      assert received_data == audio_data

      WsAudioForker.stop(pid)
    end
  end

  describe "send_audio/2 edge cases" do
    test "handles empty binary", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Send empty binary - should still succeed
      empty_data = <<>>
      result = WsAudioForker.send_audio(pid, empty_data)

      assert result == :ok

      # Verify empty frame was received
      assert_receive {:ws_frame, ^empty_data}, 1000

      WsAudioForker.stop(pid)
    end

    test "handles large audio frame", %{fork_id: fork_id, url: url} do
      {:ok, config} =
        Config.new(
          fork_id: fork_id,
          url: url
        )

      {:ok, pid} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Create a larger audio frame (16KB - typical for audio chunks)
      large_data = :crypto.strong_rand_bytes(16 * 1024)
      result = WsAudioForker.send_audio(pid, large_data)

      assert result == :ok

      # Verify large frame was received
      assert_receive {:ws_frame, ^large_data}, 2000

      WsAudioForker.stop(pid)
    end
  end
end
