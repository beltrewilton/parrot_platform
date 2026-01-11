defmodule ParrotMedia.WsBidirectional.TelemetryTest do
  @moduledoc """
  TDD tests for telemetry events in the bidirectional WebSocket feature.

  These tests verify that proper telemetry events are emitted for:
  - Connection lifecycle (connect start/stop, disconnect)
  - Audio statistics (periodic stats)
  - Frame drops

  ## TDD Approach

  These tests are written BEFORE implementation and should initially fail.
  The Telemetry module will be implemented to make them pass.

  ## Telemetry Event Naming Convention

  Following Elixir telemetry conventions:
  - [:parrot_media, :ws_bidirectional, :connect, :start]
  - [:parrot_media, :ws_bidirectional, :connect, :stop]
  - [:parrot_media, :ws_bidirectional, :disconnect]
  - [:parrot_media, :ws_bidirectional, :audio, :stats]
  - [:parrot_media, :ws_bidirectional, :audio, :frame_dropped]
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.WsBidirectional.Connector
  alias ParrotMedia.WsBidirectional.Config

  # Base port offset to avoid conflicts with other tests
  @base_port 16_000

  # Telemetry event names
  @connect_start [:parrot_media, :ws_bidirectional, :connect, :start]
  @connect_stop [:parrot_media, :ws_bidirectional, :connect, :stop]
  @disconnect [:parrot_media, :ws_bidirectional, :disconnect]
  @audio_stats [:parrot_media, :ws_bidirectional, :audio, :stats]
  @frame_dropped [:parrot_media, :ws_bidirectional, :audio, :frame_dropped]

  setup do
    # Generate unique port for this test to avoid conflicts
    port = @base_port + :rand.uniform(1000)
    connection_id = "telemetry_test_conn_#{System.unique_integer([:positive])}"
    test_pid = self()
    handler_id = "telemetry-test-handler-#{System.unique_integer([:positive])}"

    # Start mock WebSocket server
    {:ok, server_pid} =
      start_supervised(
        {ParrotMedia.Test.MockWsServer, port: port, test_pid: test_pid},
        id: {:mock_ws_server, port}
      )

    url = "ws://localhost:#{port}/ws"

    on_exit(fn ->
      # Detach any telemetry handlers that might still be attached
      # Handler IDs are passed to each test, so we can't easily clean them all up here
      # Individual tests are responsible for cleanup via on_exit
      :ok
    end)

    {:ok,
     port: port,
     connection_id: connection_id,
     url: url,
     server_pid: server_pid,
     test_pid: test_pid,
     handler_id: handler_id}
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp attach_telemetry_handler(handler_id, event_name, test_pid) do
    :telemetry.attach(
      handler_id,
      event_name,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )
  end

  defp detach_telemetry_handler(handler_id) do
    :telemetry.detach(handler_id)
  rescue
    # Ignore errors if handler was already detached
    _ -> :ok
  end

  # ============================================================================
  # Connection telemetry events
  # ============================================================================

  describe "connection telemetry events" do
    test "emits [:parrot_media, :ws_bidirectional, :connect, :start] on connection start", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler before starting connection
      handler_id = "#{handler_id}-connect-start"
      attach_telemetry_handler(handler_id, @connect_start, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Should receive telemetry event for connection start
      assert_receive {:telemetry_event, @connect_start, measurements, metadata}, 1000

      # Verify measurements include monotonic_time (standard for :start events)
      assert Map.has_key?(measurements, :monotonic_time) or Map.has_key?(measurements, :system_time)

      # Verify metadata includes connection_id
      assert metadata.connection_id == connection_id

      # Clean up
      Connector.disconnect(pid)
    end

    test "emits [:parrot_media, :ws_bidirectional, :connect, :stop] on successful connection", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-connect-stop"
      attach_telemetry_handler(handler_id, @connect_stop, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection to establish
      Process.sleep(100)

      # Should receive telemetry event for connection stop (successful connection)
      assert_receive {:telemetry_event, @connect_stop, measurements, metadata}, 1000

      # Verify measurements include duration (standard for :stop events)
      assert Map.has_key?(measurements, :duration)
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0

      # Verify metadata includes connection_id
      assert metadata.connection_id == connection_id

      # Clean up
      Connector.disconnect(pid)
    end

    test "emits [:parrot_media, :ws_bidirectional, :disconnect] on disconnect", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-disconnect"
      attach_telemetry_handler(handler_id, @disconnect, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Disconnect
      Connector.disconnect(pid)

      # Should receive telemetry event for disconnect
      assert_receive {:telemetry_event, @disconnect, _measurements, metadata}, 1000

      # Verify metadata includes connection_id
      assert metadata.connection_id == connection_id

      # Verify metadata includes reason
      assert Map.has_key?(metadata, :reason)
    end

    test "connect events include connection_id in metadata", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach handlers for both start and stop events
      start_handler_id = "#{handler_id}-start-meta"
      stop_handler_id = "#{handler_id}-stop-meta"

      attach_telemetry_handler(start_handler_id, @connect_start, test_pid)
      attach_telemetry_handler(stop_handler_id, @connect_stop, test_pid)

      on_exit(fn ->
        detach_telemetry_handler(start_handler_id)
        detach_telemetry_handler(stop_handler_id)
      end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Verify start event has connection_id
      assert_receive {:telemetry_event, @connect_start, _measurements, start_metadata}, 1000
      assert start_metadata.connection_id == connection_id

      # Verify stop event has connection_id
      assert_receive {:telemetry_event, @connect_stop, _measurements, stop_metadata}, 1000
      assert stop_metadata.connection_id == connection_id

      # Clean up
      Connector.disconnect(pid)
    end

    test "disconnect events include reason in metadata", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-disconnect-reason"
      attach_telemetry_handler(handler_id, @disconnect, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Disconnect with user request
      Connector.disconnect(pid)

      # Should receive disconnect telemetry with reason
      assert_receive {:telemetry_event, @disconnect, _measurements, metadata}, 1000

      assert metadata.connection_id == connection_id
      assert metadata.reason == :user_requested
    end

    test "disconnect events include connection duration in measurements", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-disconnect-duration"
      attach_telemetry_handler(handler_id, @disconnect, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection to establish and some time to pass
      Process.sleep(150)

      # Disconnect
      Connector.disconnect(pid)

      # Should receive disconnect telemetry with duration
      assert_receive {:telemetry_event, @disconnect, measurements, _metadata}, 1000

      # Duration should be present and greater than 0 (we waited 150ms)
      assert Map.has_key?(measurements, :duration)
      assert is_integer(measurements.duration)
      # Duration is in native time units, should be positive
      assert measurements.duration > 0
    end
  end

  # ============================================================================
  # Audio telemetry events
  # ============================================================================

  describe "audio telemetry" do
    test "emits [:parrot_media, :ws_bidirectional, :audio, :stats] periodically", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-audio-stats"
      attach_telemetry_handler(handler_id, @audio_stats, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection and some stats collection time
      # The telemetry module should emit stats periodically (e.g., every 1-5 seconds)
      Process.sleep(100)

      # Send some audio to ensure there's activity
      Connector.send_audio(pid, <<0x01, 0x02, 0x03>>)
      Connector.send_audio(pid, <<0x04, 0x05, 0x06>>)

      # Wait for periodic stats emission
      # Give enough time for at least one stats emission cycle
      Process.sleep(2000)

      # Should receive at least one stats telemetry event
      assert_receive {:telemetry_event, @audio_stats, _measurements, metadata}, 5000

      # Verify metadata includes connection_id
      assert metadata.connection_id == connection_id

      # Clean up
      Connector.disconnect(pid)
    end

    test "stats include frames_sent, frames_received, frames_dropped counts", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-stats-counts"
      attach_telemetry_handler(handler_id, @audio_stats, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Send some audio frames
      Connector.send_audio(pid, <<0x01, 0x02, 0x03>>)
      Connector.send_audio(pid, <<0x04, 0x05, 0x06>>)
      Connector.send_audio(pid, <<0x07, 0x08, 0x09>>)

      # Wait for periodic stats emission
      Process.sleep(2000)

      # Should receive stats telemetry with frame counts
      assert_receive {:telemetry_event, @audio_stats, measurements, _metadata}, 5000

      # Verify all expected measurements are present
      assert Map.has_key?(measurements, :frames_sent)
      assert Map.has_key?(measurements, :frames_received)
      assert Map.has_key?(measurements, :frames_dropped)

      # Verify they are integers
      assert is_integer(measurements.frames_sent)
      assert is_integer(measurements.frames_received)
      assert is_integer(measurements.frames_dropped)

      # We sent 3 frames, so frames_sent should be at least 3
      assert measurements.frames_sent >= 3

      # Clean up
      Connector.disconnect(pid)
    end

    test "emits [:parrot_media, :ws_bidirectional, :audio, :frame_dropped] when frame dropped", %{
      connection_id: connection_id,
      url: url,
      port: port,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-frame-dropped"
      attach_telemetry_handler(handler_id, @frame_dropped, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      # Use a very small buffer to force frame drops
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          buffer_size: 2
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Stop the server to trigger buffering and eventual drops
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect detection
      Process.sleep(200)

      # Send more frames than the buffer can hold to trigger drops
      for i <- 1..5 do
        Connector.send_audio(pid, <<i::8>>)
      end

      # Give time for frame drop telemetry to be emitted
      Process.sleep(100)

      # Should receive frame_dropped telemetry event
      assert_receive {:telemetry_event, @frame_dropped, measurements, metadata}, 1000

      # Verify metadata includes connection_id
      assert metadata.connection_id == connection_id

      # Verify measurements include dropped frame count
      assert Map.has_key?(measurements, :count)
      assert is_integer(measurements.count)
      assert measurements.count >= 1

      # Clean up
      Connector.disconnect(pid)
    end

    test "frame_dropped event includes dropped frame count in measurements", %{
      connection_id: connection_id,
      url: url,
      port: port,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-dropped-count"
      attach_telemetry_handler(handler_id, @frame_dropped, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      # Use a very small buffer to force frame drops
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          buffer_size: 2
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Stop the server to trigger buffering
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect detection
      Process.sleep(200)

      # Send 5 frames with buffer size 2, should drop 3
      for i <- 1..5 do
        Connector.send_audio(pid, <<i::8>>)
      end

      # Collect all frame_dropped events
      Process.sleep(100)

      # Should receive at least one frame_dropped event with count
      assert_receive {:telemetry_event, @frame_dropped, measurements, _metadata}, 1000

      # Count should be at least 1 (might receive multiple events, one per drop)
      assert measurements.count >= 1

      # Clean up
      Connector.disconnect(pid)
    end

    test "stats include buffer_size in measurements", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-buffer-size"
      attach_telemetry_handler(handler_id, @audio_stats, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection and stats emission
      Process.sleep(100)

      # Send some audio
      Connector.send_audio(pid, <<0x01, 0x02, 0x03>>)

      # Wait for periodic stats
      Process.sleep(2000)

      # Should receive stats with buffer_size
      assert_receive {:telemetry_event, @audio_stats, measurements, _metadata}, 5000

      # Verify buffer_size is present
      assert Map.has_key?(measurements, :buffer_size)
      assert is_integer(measurements.buffer_size)
      assert measurements.buffer_size >= 0

      # Clean up
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # Edge cases and additional telemetry tests
  # ============================================================================

  describe "telemetry edge cases" do
    test "connect start event includes url in metadata", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-url-meta"
      attach_telemetry_handler(handler_id, @connect_start, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Should receive start event with url in metadata
      assert_receive {:telemetry_event, @connect_start, _measurements, metadata}, 1000

      assert metadata.connection_id == connection_id
      assert metadata.url == url

      # Clean up
      Connector.disconnect(pid)
    end

    test "connect stop event includes connection status in metadata", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-status-meta"
      attach_telemetry_handler(handler_id, @connect_stop, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Should receive stop event with status in metadata
      assert_receive {:telemetry_event, @connect_stop, _measurements, metadata}, 1000

      assert metadata.connection_id == connection_id
      # Status should indicate success
      assert metadata.status == :ok or metadata.result == :connected

      # Clean up
      Connector.disconnect(pid)
    end

    test "telemetry events are emitted even when no callback module is configured", %{
      connection_id: connection_id,
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handlers for all major events
      start_handler_id = "#{handler_id}-no-callback-start"
      stop_handler_id = "#{handler_id}-no-callback-stop"

      attach_telemetry_handler(start_handler_id, @connect_start, test_pid)
      attach_telemetry_handler(stop_handler_id, @connect_stop, test_pid)

      on_exit(fn ->
        detach_telemetry_handler(start_handler_id)
        detach_telemetry_handler(stop_handler_id)
      end)

      # Create config without callback module
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: nil
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Should still receive telemetry events
      assert_receive {:telemetry_event, @connect_start, _, _}, 1000
      assert_receive {:telemetry_event, @connect_stop, _, _}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "multiple connections emit independent telemetry events", %{
      url: url,
      test_pid: test_pid,
      handler_id: handler_id
    } do
      # Attach telemetry handler
      handler_id = "#{handler_id}-multi-conn"
      attach_telemetry_handler(handler_id, @connect_stop, test_pid)

      on_exit(fn -> detach_telemetry_handler(handler_id) end)

      # Create two connections with different IDs
      connection_id_1 = "multi_conn_1_#{System.unique_integer([:positive])}"
      connection_id_2 = "multi_conn_2_#{System.unique_integer([:positive])}"

      {:ok, config1} =
        Config.new(
          connection_id: connection_id_1,
          url: url
        )

      {:ok, config2} =
        Config.new(
          connection_id: connection_id_2,
          url: url
        )

      {:ok, pid1} = Connector.start_link(config1)
      {:ok, pid2} = Connector.start_link(config2)

      # Wait for connections
      Process.sleep(200)

      # Collect telemetry events
      events =
        receive_all_events(@connect_stop, 500)

      # Should have events for both connections
      connection_ids = Enum.map(events, fn {_, _, metadata} -> metadata.connection_id end)
      assert connection_id_1 in connection_ids
      assert connection_id_2 in connection_ids

      # Clean up
      Connector.disconnect(pid1)
      Connector.disconnect(pid2)
    end
  end

  # Helper to receive all matching events within a timeout
  defp receive_all_events(event_name, timeout) do
    receive_all_events(event_name, timeout, [])
  end

  defp receive_all_events(event_name, timeout, acc) do
    receive do
      {:telemetry_event, ^event_name, measurements, metadata} ->
        receive_all_events(event_name, timeout, [{event_name, measurements, metadata} | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end
end
