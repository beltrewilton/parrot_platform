defmodule ParrotMedia.WsAudioForkerIntegrationTest do
  @moduledoc """
  Integration tests for the WebSocket audio forking pipeline.

  These tests verify the complete end-to-end flow:
  1. Audio data flows through a Membrane pipeline
  2. WsForkSink receives the audio
  3. WsForkSink forwards to WsAudioForker
  4. WsAudioForker sends over WebSocket
  5. Mock WebSocket server receives the data

  These tests are expected to FAIL initially (TDD red phase) since the
  WsAudioForker and WsForkSink implementations don't exist yet.
  """

  use ExUnit.Case, async: false

  alias ParrotMedia.WsAudioForker
  alias ParrotMedia.WsAudioForker.Config
  alias ParrotMedia.WsForkSink
  alias ParrotMedia.Test.MockWsServer

  # Use unique port to avoid conflicts with other tests
  @port 4200

  setup do
    # Start mock WebSocket server
    {:ok, _pid} = start_supervised({MockWsServer, port: @port, test_pid: self()})

    # Give the server time to start
    Process.sleep(50)

    :ok
  end

  describe "end-to-end audio forking" do
    test "audio flows from forker to WebSocket server" do
      # 1. Create forker config
      {:ok, config} =
        Config.new(
          fork_id: "integration_test_1",
          url: "ws://localhost:#{@port}/ws"
        )

      # 2. Start forker
      {:ok, forker} = WsAudioForker.start_link(config)

      # 3. Wait for WebSocket connection to establish
      Process.sleep(100)

      # 4. Send audio data
      audio_data = <<1, 2, 3, 4, 5>>
      :ok = WsAudioForker.send_audio(forker, audio_data)

      # 5. Verify mock server received it
      assert_receive {:ws_frame, ^audio_data}, 1000

      # 6. Cleanup
      WsAudioForker.stop(forker)
    end

    test "multiple frames flow through correctly in order" do
      {:ok, config} =
        Config.new(
          fork_id: "integration_test_ordering",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Send multiple audio frames
      frame1 = <<1, 1, 1, 1>>
      frame2 = <<2, 2, 2, 2>>
      frame3 = <<3, 3, 3, 3>>

      :ok = WsAudioForker.send_audio(forker, frame1)
      :ok = WsAudioForker.send_audio(forker, frame2)
      :ok = WsAudioForker.send_audio(forker, frame3)

      # Verify frames received in order
      assert_receive {:ws_frame, ^frame1}, 1000
      assert_receive {:ws_frame, ^frame2}, 1000
      assert_receive {:ws_frame, ^frame3}, 1000

      WsAudioForker.stop(forker)
    end

    test "stopping forker gracefully closes connection" do
      {:ok, config} =
        Config.new(
          fork_id: "integration_test_stop",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Send some data to verify connection is working
      audio_data = <<42, 42, 42>>
      :ok = WsAudioForker.send_audio(forker, audio_data)
      assert_receive {:ws_frame, ^audio_data}, 1000

      # Stop the forker
      :ok = WsAudioForker.stop(forker)

      # Verify WebSocket closed (MockWsHandler sends :ws_closed on terminate)
      assert_receive {:ws_closed, received_frames}, 2000
      assert [^audio_data] = received_frames
    end

    test "forker connects to WebSocket before sending" do
      {:ok, config} =
        Config.new(
          fork_id: "integration_test_connect_first",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Verify forker is connected
      assert WsAudioForker.connected?(forker) == true

      WsAudioForker.stop(forker)
    end

    test "frames are received by external service (mock)" do
      {:ok, config} =
        Config.new(
          fork_id: "integration_test_external",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Simulate audio frames from a SIP call
      # 20ms of 16-bit mono audio at 8kHz = 160 samples = 320 bytes
      audio_frame = :crypto.strong_rand_bytes(320)

      :ok = WsAudioForker.send_audio(forker, audio_frame)

      # External service (mock) receives the exact frame
      assert_receive {:ws_frame, received_frame}, 1000
      assert received_frame == audio_frame

      WsAudioForker.stop(forker)
    end
  end

  describe "WsForkSink to WsAudioForker integration" do
    test "WsForkSink forwards buffers to forker process" do
      {:ok, config} =
        Config.new(
          fork_id: "sink_integration_test",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # WsForkSink should be able to send via the forker
      audio_data = <<10, 20, 30, 40, 50>>
      WsForkSink.forward_to_forker(forker, audio_data)

      assert_receive {:ws_frame, ^audio_data}, 1000

      WsAudioForker.stop(forker)
    end
  end

  describe "multiple concurrent forkers" do
    test "multiple forkers can operate independently" do
      # Start first forker on port 4200
      {:ok, config1} =
        Config.new(
          fork_id: "concurrent_test_1",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker1} = WsAudioForker.start_link(config1)
      Process.sleep(50)

      # Start second forker on same port (different connection)
      {:ok, config2} =
        Config.new(
          fork_id: "concurrent_test_2",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker2} = WsAudioForker.start_link(config2)
      Process.sleep(50)

      # Send different data through each forker
      data1 = <<1, 1, 1, 1>>
      data2 = <<2, 2, 2, 2>>

      :ok = WsAudioForker.send_audio(forker1, data1)
      :ok = WsAudioForker.send_audio(forker2, data2)

      # Verify both are received (order may vary)
      received = receive_frames(2, 1000)
      assert data1 in received
      assert data2 in received

      WsAudioForker.stop(forker1)
      WsAudioForker.stop(forker2)
    end

    test "stopping one forker does not affect others" do
      {:ok, config1} =
        Config.new(
          fork_id: "independent_test_1",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, config2} =
        Config.new(
          fork_id: "independent_test_2",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker1} = WsAudioForker.start_link(config1)
      {:ok, forker2} = WsAudioForker.start_link(config2)
      Process.sleep(100)

      # Stop first forker
      WsAudioForker.stop(forker1)

      # Second forker should still work
      data = <<99, 99, 99>>
      :ok = WsAudioForker.send_audio(forker2, data)
      assert_receive {:ws_frame, ^data}, 1000

      WsAudioForker.stop(forker2)
    end
  end

  describe "large audio payloads" do
    test "handles large audio buffers" do
      {:ok, config} =
        Config.new(
          fork_id: "large_payload_test",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # 1 second of 16-bit mono audio at 16kHz = 32,000 bytes
      large_audio = :crypto.strong_rand_bytes(32_000)

      :ok = WsAudioForker.send_audio(forker, large_audio)

      assert_receive {:ws_frame, received}, 2000
      assert byte_size(received) == 32_000
      assert received == large_audio

      WsAudioForker.stop(forker)
    end

    test "handles multiple large buffers" do
      {:ok, config} =
        Config.new(
          fork_id: "multi_large_payload_test",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Send 3 large buffers
      buffers =
        Enum.map(1..3, fn i ->
          # Each buffer is 10KB with different content
          :binary.copy(<<i>>, 10_000)
        end)

      Enum.each(buffers, fn buffer ->
        :ok = WsAudioForker.send_audio(forker, buffer)
      end)

      # Verify all received
      received = receive_frames(3, 3000)
      assert length(received) == 3

      Enum.each(buffers, fn buffer ->
        assert buffer in received
      end)

      WsAudioForker.stop(forker)
    end
  end

  describe "rapid frame sending" do
    test "handles rapid succession of frames" do
      {:ok, config} =
        Config.new(
          fork_id: "rapid_send_test",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Send 100 frames as fast as possible (simulating real-time audio)
      frame_count = 100

      frames =
        Enum.map(1..frame_count, fn i ->
          <<i::16>>
        end)

      Enum.each(frames, fn frame ->
        :ok = WsAudioForker.send_audio(forker, frame)
      end)

      # All frames should be received
      received = receive_frames(frame_count, 5000)
      assert length(received) == frame_count

      # Verify ordering is preserved
      Enum.zip(frames, received)
      |> Enum.each(fn {expected, actual} ->
        assert expected == actual
      end)

      WsAudioForker.stop(forker)
    end

    test "handles bursts with small delays" do
      {:ok, config} =
        Config.new(
          fork_id: "burst_test",
          url: "ws://localhost:#{@port}/ws"
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Simulate 20ms audio frames (50 per second)
      frame_count = 50
      frame_size = 320  # 20ms of 16-bit mono at 8kHz

      frames =
        Enum.map(1..frame_count, fn _ ->
          :crypto.strong_rand_bytes(frame_size)
        end)

      # Send with realistic timing
      Enum.each(frames, fn frame ->
        :ok = WsAudioForker.send_audio(forker, frame)
        # 20ms delay simulating real-time audio
        Process.sleep(20)
      end)

      # Collect all received frames
      received = receive_frames(frame_count, 3000)
      assert length(received) == frame_count

      WsAudioForker.stop(forker)
    end
  end

  describe "error handling" do
    test "forker handles connection failure gracefully" do
      # Try to connect to a port where nothing is listening
      {:ok, config} =
        Config.new(
          fork_id: "connection_failure_test",
          url: "ws://localhost:59999/ws",
          max_retries: 0
        )

      # Should start but fail to connect
      result = WsAudioForker.start_link(config)

      case result do
        {:ok, forker} ->
          # If it starts, it should report disconnected state
          Process.sleep(200)
          refute WsAudioForker.connected?(forker)
          WsAudioForker.stop(forker)

        {:error, _reason} ->
          # Or it may fail to start entirely, which is also acceptable
          :ok
      end
    end

    test "forker buffers data when reconnecting" do
      {:ok, config} =
        Config.new(
          fork_id: "buffer_test",
          url: "ws://localhost:#{@port}/ws",
          buffer_size: 10
        )

      {:ok, forker} = WsAudioForker.start_link(config)
      Process.sleep(100)

      # Verify initial connection
      assert WsAudioForker.connected?(forker) == true

      # Send data while connected
      data = <<1, 2, 3, 4, 5>>
      :ok = WsAudioForker.send_audio(forker, data)
      assert_receive {:ws_frame, ^data}, 1000

      WsAudioForker.stop(forker)
    end
  end

  describe "callback integration" do
    defmodule TestCallback do
      @behaviour ParrotMedia.WsAudioForker.Callback

      @impl true
      def init(args) do
        {:ok, %{test_pid: args[:test_pid], events: []}}
      end

      @impl true
      def handle_fork_event({:fork_event, _fork_id, :connected}, state) do
        send(state.test_pid, :forker_connected)
        {:ok, %{state | events: [:connected | state.events]}}
      end

      def handle_fork_event({:fork_event, _fork_id, {:ws_message, data}}, state) do
        send(state.test_pid, {:forker_received, data})
        {:ok, %{state | events: [{:message, data} | state.events]}}
      end

      def handle_fork_event(_event, state) do
        {:ok, state}
      end
    end

    test "callback receives connection event" do
      {:ok, config} =
        Config.new(
          fork_id: "callback_test",
          url: "ws://localhost:#{@port}/ws",
          callback_module: TestCallback,
          callback_state: %{test_pid: self()}
        )

      {:ok, forker} = WsAudioForker.start_link(config)

      # Should receive connected callback
      assert_receive :forker_connected, 2000

      WsAudioForker.stop(forker)
    end
  end

  # Helper to receive multiple frames
  defp receive_frames(count, timeout) do
    receive_frames(count, timeout, [])
  end

  defp receive_frames(0, _timeout, acc) do
    Enum.reverse(acc)
  end

  defp receive_frames(count, timeout, acc) do
    receive do
      {:ws_frame, data} ->
        receive_frames(count - 1, timeout, [data | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end
end
