defmodule ParrotMedia.WsBidirectional.ConnectorTest do
  @moduledoc """
  Tests for ParrotMedia.WsBidirectional.Connector GenServer.

  This is the central GenServer that manages bidirectional WebSocket connections
  for audio streaming to/from AI services.

  ## TDD Approach

  These tests are written BEFORE implementation and should initially fail.
  The Connector module will be implemented to make them pass.

  ## Test Categories

  - start_link/1 - Starting and registering connectors
  - Connection lifecycle - State transitions and callbacks
  - send_audio/2 - Outbound audio handling
  - Receive audio - Inbound audio from WebSocket
  - Mute/unmute - Direction-specific muting
  - Status - Connection status reporting
  - Disconnect - Graceful shutdown
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.WsBidirectional.Connector
  alias ParrotMedia.WsBidirectional.Config

  # Base port offset to avoid conflicts with other tests
  @base_port 15_000

  setup do
    # Generate unique port for this test to avoid conflicts
    port = @base_port + :rand.uniform(1000)
    connection_id = "test_conn_#{System.unique_integer([:positive])}"

    # Start mock WebSocket server
    {:ok, server_pid} =
      start_supervised(
        {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
        id: {:mock_ws_server, port}
      )

    url = "ws://localhost:#{port}/ws"

    {:ok, port: port, connection_id: connection_id, url: url, server_pid: server_pid}
  end

  # ============================================================================
  # start_link/1 tests
  # ============================================================================

  describe "start_link/1" do
    test "starts connector with valid config", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      assert {:ok, pid} = Connector.start_link(config)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Clean up
      Connector.disconnect(pid)
    end

    test "registers in BidirectionalRegistry by connection_id", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Verify registration in BidirectionalRegistry
      assert [{^pid, _}] =
               Registry.lookup(
                 ParrotMedia.BidirectionalRegistry,
                 {:bidirectional, connection_id}
               )

      # Clean up
      Connector.disconnect(pid)
    end

    test "returns error for already registered connection_id", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      # Start first connector
      {:ok, pid1} = Connector.start_link(config)
      assert Process.alive?(pid1)

      # Attempt to start second connector with same connection_id
      assert {:error, {:already_registered, _}} = Connector.start_link(config)

      # Clean up
      Connector.disconnect(pid1)
    end

    test "initial state is :connecting", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Get status immediately - should be connecting
      {:ok, status} = Connector.status(pid)
      assert status.connection_state == :connecting

      # Clean up
      Connector.disconnect(pid)
    end

    test "returns error for invalid config - missing url" do
      config = %Config{
        connection_id: "test_conn",
        url: nil,
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, _reason} = Connector.start_link(config)
    end

    test "returns error for invalid config - empty connection_id" do
      config = %Config{
        connection_id: "",
        url: "ws://localhost:9999/ws",
        headers: [],
        callback_module: nil,
        callback_state: %{},
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100,
        jitter_buffer_ms: 60,
        connect_timeout_ms: 5000,
        max_retries: 5
      }

      assert {:error, _reason} = Connector.start_link(config)
    end

    test "starts connector with all optional config fields", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          headers: [{"Authorization", "Bearer test_token"}],
          callback_module: nil,
          callback_state: %{session_id: "test_session"},
          inbound_format: :pcmu,
          outbound_format: :opus,
          sample_rate: 24000,
          buffer_size: 200,
          jitter_buffer_ms: 100,
          connect_timeout_ms: 10_000,
          max_retries: 3
        )

      assert {:ok, pid} = Connector.start_link(config)
      assert Process.alive?(pid)

      # Clean up
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # Connection lifecycle tests
  # ============================================================================

  describe "connection lifecycle" do
    test "transitions to :connected on successful WebSocket handshake", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection to establish
      Process.sleep(100)

      {:ok, status} = Connector.status(pid)
      assert status.connection_state == :connected

      # Clean up
      Connector.disconnect(pid)
    end

    test "invokes callback on :connected event", %{connection_id: connection_id, url: url} do
      test_pid = self()

      defmodule ConnectedCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:connected}, state) do
          send(state.test_pid, :callback_connected)
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: ConnectedCallback,
          callback_state: %{test_pid: test_pid}
        )

      {:ok, pid} = Connector.start_link(config)

      # Should receive callback within reasonable time
      assert_receive :callback_connected, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "tracks connected_at timestamp", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      {:ok, status} = Connector.status(pid)
      assert status.connected_at != nil
      assert %DateTime{} = status.connected_at

      # Clean up
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # send_audio/2 tests
  # ============================================================================

  describe "send_audio/2" do
    test "forwards audio to WebSocket when connected", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Send audio
      audio_data = <<0x00, 0x01, 0x02, 0x03, 0xFF>>
      result = Connector.send_audio(pid, audio_data)

      assert result == :ok

      # Verify audio was received by mock server
      assert_receive {:ws_frame, ^audio_data}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "increments frames_sent counter", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Check initial count
      {:ok, status_before} = Connector.status(pid)
      assert status_before.frames_sent == 0

      # Send audio frames
      Connector.send_audio(pid, <<0x01, 0x02>>)
      Connector.send_audio(pid, <<0x03, 0x04>>)
      Connector.send_audio(pid, <<0x05, 0x06>>)

      # Give time for processing
      Process.sleep(50)

      {:ok, status_after} = Connector.status(pid)
      assert status_after.frames_sent == 3

      # Clean up
      Connector.disconnect(pid)
    end

    test "buffers audio when temporarily disconnected", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          buffer_size: 10
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Stop the server to simulate disconnection
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect to be detected
      Process.sleep(100)

      # Send audio while disconnected - should be buffered
      audio_data = <<0x01, 0x02, 0x03>>
      result = Connector.send_audio(pid, audio_data)

      # Should still return :ok as it's buffered
      assert result == :ok

      {:ok, status} = Connector.status(pid)
      assert status.buffer_size > 0

      # Clean up
      Connector.disconnect(pid)
    end

    test "drops oldest frames when buffer exceeds buffer_size", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          buffer_size: 3
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Stop the server to simulate disconnection
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect
      Process.sleep(100)

      # Send more frames than buffer allows
      Connector.send_audio(pid, <<0x01>>)
      Connector.send_audio(pid, <<0x02>>)
      Connector.send_audio(pid, <<0x03>>)
      Connector.send_audio(pid, <<0x04>>)
      Connector.send_audio(pid, <<0x05>>)

      # Give time for processing
      Process.sleep(50)

      {:ok, status} = Connector.status(pid)
      assert status.buffer_size == 3
      assert status.frames_dropped == 2

      # Clean up
      Connector.disconnect(pid)
    end

    test "increments frames_dropped when dropping", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          buffer_size: 2
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection then disconnect
      Process.sleep(100)
      stop_supervised({:mock_ws_server, port})
      Process.sleep(100)

      # Initial dropped count should be 0
      {:ok, status_before} = Connector.status(pid)
      assert status_before.frames_dropped == 0

      # Fill buffer and overflow
      Connector.send_audio(pid, <<0x01>>)
      Connector.send_audio(pid, <<0x02>>)
      Connector.send_audio(pid, <<0x03>>)
      # Should cause 1 drop

      Process.sleep(50)

      {:ok, status_after} = Connector.status(pid)
      assert status_after.frames_dropped == 1

      # Clean up
      Connector.disconnect(pid)
    end

    test "returns :ok when outbound not muted", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Outbound is not muted by default
      audio_data = <<0xAB, 0xCD>>
      result = Connector.send_audio(pid, audio_data)

      assert result == :ok

      # Clean up
      Connector.disconnect(pid)
    end

    test "returns {:error, :muted} when outbound muted", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Mute outbound
      :ok = Connector.mute(pid, :outbound)

      # Try to send audio
      audio_data = <<0xAB, 0xCD>>
      result = Connector.send_audio(pid, audio_data)

      assert result == {:error, :muted}

      # Clean up
      Connector.disconnect(pid)
    end

    test "send_audio/2 using connection_id string lookup", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, _pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Send audio using connection_id
      audio_data = <<0x10, 0x20, 0x30>>
      result = Connector.send_audio(connection_id, audio_data)

      assert result == :ok

      # Verify audio was received
      assert_receive {:ws_frame, ^audio_data}, 1000

      # Clean up
      Connector.disconnect(connection_id)
    end

    test "returns {:error, :not_found} for unknown connection_id" do
      result = Connector.send_audio("nonexistent_connection", <<0x00>>)

      assert result == {:error, :not_found}
    end
  end

  # ============================================================================
  # Receive audio (from Connection) tests
  # ============================================================================

  describe "receive audio (from Connection)" do
    test "forwards received audio to registered source", %{
      connection_id: connection_id,
      url: url
    } do
      # Register this test process as the source
      source_pid = self()

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Register as source
      Connector.register_source(pid, source_pid)

      # Simulate receiving audio from WebSocket (mock server sends binary)
      audio_data = <<0xDE, 0xAD, 0xBE, 0xEF>>

      # The mock server can send binary data to simulate AI response
      # We need to get the handler pid and send through it
      # For now, we'll use internal message simulation
      send(pid, {:connection_event, {:ws_audio, audio_data}})

      # Should receive the audio at source_pid
      assert_receive {:ws_audio, ^audio_data}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "increments frames_received counter", %{connection_id: connection_id, url: url} do
      source_pid = self()

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      Connector.register_source(pid, source_pid)

      # Check initial count
      {:ok, status_before} = Connector.status(pid)
      assert status_before.frames_received == 0

      # Simulate receiving audio frames
      send(pid, {:connection_event, {:ws_audio, <<0x01>>}})
      send(pid, {:connection_event, {:ws_audio, <<0x02>>}})
      send(pid, {:connection_event, {:ws_audio, <<0x03>>}})

      # Give time for processing
      Process.sleep(50)

      {:ok, status_after} = Connector.status(pid)
      assert status_after.frames_received == 3

      # Clean up
      Connector.disconnect(pid)
    end

    test "does not forward when inbound muted", %{connection_id: connection_id, url: url} do
      source_pid = self()

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      Connector.register_source(pid, source_pid)

      # Mute inbound
      :ok = Connector.mute(pid, :inbound)

      # Simulate receiving audio
      audio_data = <<0xDE, 0xAD>>
      send(pid, {:connection_event, {:ws_audio, audio_data}})

      # Should NOT receive the audio (give a short timeout to verify)
      refute_receive {:ws_audio, ^audio_data}, 100

      # Clean up
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # Mute/unmute tests
  # ============================================================================

  describe "mute/unmute" do
    test "mute(:outbound) sets outbound_muted to true", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Initial state should be unmuted
      {:ok, status_before} = Connector.status(pid)
      assert status_before.outbound_muted == false

      # Mute outbound
      assert :ok = Connector.mute(pid, :outbound)

      {:ok, status_after} = Connector.status(pid)
      assert status_after.outbound_muted == true

      # Clean up
      Connector.disconnect(pid)
    end

    test "unmute(:outbound) sets outbound_muted to false", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Mute then unmute
      Connector.mute(pid, :outbound)
      {:ok, status_muted} = Connector.status(pid)
      assert status_muted.outbound_muted == true

      assert :ok = Connector.unmute(pid, :outbound)

      {:ok, status_unmuted} = Connector.status(pid)
      assert status_unmuted.outbound_muted == false

      # Clean up
      Connector.disconnect(pid)
    end

    test "mute(:inbound) sets inbound_muted to true", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Initial state should be unmuted
      {:ok, status_before} = Connector.status(pid)
      assert status_before.inbound_muted == false

      # Mute inbound
      assert :ok = Connector.mute(pid, :inbound)

      {:ok, status_after} = Connector.status(pid)
      assert status_after.inbound_muted == true

      # Clean up
      Connector.disconnect(pid)
    end

    test "unmute(:inbound) sets inbound_muted to false", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Mute then unmute
      Connector.mute(pid, :inbound)
      {:ok, status_muted} = Connector.status(pid)
      assert status_muted.inbound_muted == true

      assert :ok = Connector.unmute(pid, :inbound)

      {:ok, status_unmuted} = Connector.status(pid)
      assert status_unmuted.inbound_muted == false

      # Clean up
      Connector.disconnect(pid)
    end

    test "mute/unmute using connection_id string lookup", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, _pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Test with string lookup
      assert :ok = Connector.mute(connection_id, :outbound)
      {:ok, status_muted} = Connector.status(connection_id)
      assert status_muted.outbound_muted == true

      assert :ok = Connector.unmute(connection_id, :outbound)
      {:ok, status_unmuted} = Connector.status(connection_id)
      assert status_unmuted.outbound_muted == false

      # Clean up
      Connector.disconnect(connection_id)
    end

    test "mute returns {:error, :not_found} for unknown connection" do
      assert {:error, :not_found} = Connector.mute("nonexistent", :outbound)
    end

    test "unmute returns {:error, :not_found} for unknown connection" do
      assert {:error, :not_found} = Connector.unmute("nonexistent", :inbound)
    end
  end

  # ============================================================================
  # Status tests
  # ============================================================================

  describe "status/1" do
    test "returns connection status map", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      {:ok, status} = Connector.status(pid)

      assert is_map(status)
      assert status.connection_state == :connected

      # Clean up
      Connector.disconnect(pid)
    end

    test "includes all expected fields", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      {:ok, status} = Connector.status(pid)

      # Verify all expected fields are present
      assert Map.has_key?(status, :connection_state)
      assert Map.has_key?(status, :outbound_muted)
      assert Map.has_key?(status, :inbound_muted)
      assert Map.has_key?(status, :frames_sent)
      assert Map.has_key?(status, :frames_received)
      assert Map.has_key?(status, :frames_dropped)
      assert Map.has_key?(status, :reconnect_count)
      assert Map.has_key?(status, :buffer_size)
      assert Map.has_key?(status, :buffer_capacity)
      assert Map.has_key?(status, :connected_at)

      # Clean up
      Connector.disconnect(pid)
    end

    test "status/1 using connection_id string lookup", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, _pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Get status using connection_id string
      {:ok, status} = Connector.status(connection_id)

      assert is_map(status)
      assert status.connection_state == :connected

      # Clean up
      Connector.disconnect(connection_id)
    end

    test "returns {:error, :not_found} for unknown connection" do
      result = Connector.status("nonexistent_connection")

      assert result == {:error, :not_found}
    end

    test "returns {:error, :not_found} for dead PID" do
      # Create a PID that doesn't exist
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(fake_pid)

      result = Connector.status(fake_pid)

      assert result == {:error, :not_found}
    end
  end

  # ============================================================================
  # Disconnect tests
  # ============================================================================

  describe "disconnect/1" do
    test "closes WebSocket connection", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Disconnect
      assert :ok = Connector.disconnect(pid)

      # The mock server should receive a close notification
      assert_receive {:ws_closed, _received}, 2000
    end

    test "transitions to :stopped state", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Monitor the process
      ref = Process.monitor(pid)

      # Disconnect
      :ok = Connector.disconnect(pid)

      # Wait for process to terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1000
      assert reason == :normal or reason == :shutdown or match?({:shutdown, _}, reason)
    end

    test "unregisters from Registry", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Verify registered
      assert [{^pid, _}] =
               Registry.lookup(
                 ParrotMedia.BidirectionalRegistry,
                 {:bidirectional, connection_id}
               )

      # Disconnect and verify unregistered
      :ok = Connector.disconnect(pid)
      Process.sleep(50)

      assert [] =
               Registry.lookup(
                 ParrotMedia.BidirectionalRegistry,
                 {:bidirectional, connection_id}
               )
    end

    test "disconnect/1 using connection_id string lookup", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)
      assert Process.alive?(pid)

      # Wait for connection
      Process.sleep(100)

      # Disconnect using connection_id string
      assert :ok = Connector.disconnect(connection_id)

      # Give time for process to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns {:error, :not_found} for unknown connection_id" do
      result = Connector.disconnect("nonexistent_connection")

      assert result == {:error, :not_found}
    end

    test "returns {:error, :not_found} for dead PID" do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(fake_pid)

      result = Connector.disconnect(fake_pid)

      assert result == {:error, :not_found}
    end

    test "can start new connector with same connection_id after previous is disconnected", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      # Start first connector
      {:ok, pid1} = Connector.start_link(config)
      assert Process.alive?(pid1)

      # Disconnect it
      :ok = Connector.disconnect(pid1)
      Process.sleep(50)
      refute Process.alive?(pid1)

      # Start new connector with same connection_id
      {:ok, pid2} = Connector.start_link(config)
      assert Process.alive?(pid2)
      assert pid1 != pid2

      # Clean up
      Connector.disconnect(pid2)
    end
  end

  # ============================================================================
  # whereis/1 tests
  # ============================================================================

  describe "whereis/1" do
    test "returns {:ok, pid} for registered connection", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      assert {:ok, ^pid} = Connector.whereis(connection_id)

      # Clean up
      Connector.disconnect(pid)
    end

    test "returns {:error, :not_found} for unknown connection_id" do
      assert {:error, :not_found} = Connector.whereis("nonexistent")
    end
  end

  # ============================================================================
  # send_message/2 tests
  # ============================================================================

  describe "send_message/2" do
    test "sends text message to WebSocket", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Send a text/JSON message
      message = ~s({"type": "control", "action": "pause"})
      result = Connector.send_message(pid, message)

      assert result == :ok

      # Verify message was received by mock server
      assert_receive {:ws_text, ^message}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "send_message/2 using connection_id string lookup", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, _pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      message = ~s({"type": "hello"})
      result = Connector.send_message(connection_id, message)

      assert result == :ok

      assert_receive {:ws_text, ^message}, 1000

      # Clean up
      Connector.disconnect(connection_id)
    end

    test "returns {:error, :not_found} for unknown connection" do
      result = Connector.send_message("nonexistent", "message")

      assert result == {:error, :not_found}
    end
  end

  # ============================================================================
  # Callback event tests
  # ============================================================================

  describe "callback events" do
    test "invokes callback on :disconnected event", %{connection_id: connection_id, url: url} do
      test_pid = self()

      defmodule DisconnectedCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:disconnected, _reason}, state) do
          send(state.test_pid, :callback_disconnected)
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: DisconnectedCallback,
          callback_state: %{test_pid: test_pid}
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Disconnect
      Connector.disconnect(pid)

      # Should receive callback
      assert_receive :callback_disconnected, 1000
    end

    test "forwards ws_message to callback", %{connection_id: connection_id, url: url} do
      test_pid = self()

      defmodule WsMessageCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:ws_message, data}, state) do
          send(state.test_pid, {:callback_ws_message, data})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: WsMessageCallback,
          callback_state: %{test_pid: test_pid}
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Simulate receiving a text message from WebSocket
      json_message = ~s({"type": "transcript", "text": "Hello"})
      send(pid, {:connection_event, {:ws_message, json_message}})

      # Should receive callback with the message
      assert_receive {:callback_ws_message, ^json_message}, 1000

      # Clean up
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # Edge case tests
  # ============================================================================

  describe "edge cases" do
    test "handles empty audio binary", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Send empty binary
      empty_data = <<>>
      result = Connector.send_audio(pid, empty_data)

      assert result == :ok

      # Verify empty frame was received
      assert_receive {:ws_frame, ^empty_data}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "handles large audio frame", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Create a larger audio frame (16KB - typical for audio chunks)
      large_data = :crypto.strong_rand_bytes(16 * 1024)
      result = Connector.send_audio(pid, large_data)

      assert result == :ok

      # Verify large frame was received
      assert_receive {:ws_frame, ^large_data}, 2000

      # Clean up
      Connector.disconnect(pid)
    end

    test "sends multiple audio frames in order", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Send multiple frames
      frame1 = <<0x01, 0x01, 0x01>>
      frame2 = <<0x02, 0x02, 0x02>>
      frame3 = <<0x03, 0x03, 0x03>>

      assert Connector.send_audio(pid, frame1) == :ok
      assert Connector.send_audio(pid, frame2) == :ok
      assert Connector.send_audio(pid, frame3) == :ok

      # Verify frames received in order
      assert_receive {:ws_frame, ^frame1}, 1000
      assert_receive {:ws_frame, ^frame2}, 1000
      assert_receive {:ws_frame, ^frame3}, 1000

      # Clean up
      Connector.disconnect(pid)
    end
  end
end
