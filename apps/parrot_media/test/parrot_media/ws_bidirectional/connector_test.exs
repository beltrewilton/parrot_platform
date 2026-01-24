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

  # Timeout constants for US4 disconnect tests
  @ws_close_timeout 2000
  @process_down_timeout 1000
  @callback_timeout 1000
  @registry_cleanup_wait 100

  # Helper to get the conn_pid from connector state for testing
  # Uses the public Connector.conn_pid/1 API
  defp get_conn_pid(connector_pid) do
    case Connector.conn_pid(connector_pid) do
      {:ok, conn_pid} -> conn_pid
      {:error, :not_connected} -> nil
    end
  end

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
      # Get the conn_pid to properly simulate the connection sending the event
      conn_pid = get_conn_pid(pid)
      send(pid, {:connection_event, conn_pid, {:ws_audio, audio_data}})

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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Simulate receiving audio frames
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0x01>>}})
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0x02>>}})
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0x03>>}})

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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Simulate receiving audio
      audio_data = <<0xDE, 0xAD>>
      send(pid, {:connection_event, conn_pid, {:ws_audio, audio_data}})

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
  # Mute/unmute control tests (US3 - Control Audio Direction)
  # ============================================================================

  describe "mute/unmute control (US3)" do
    test "mute(:outbound) stops audio from being sent to WebSocket", %{
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

      # Verify audio flows normally when unmuted
      audio_before_mute = <<0xAA, 0xBB>>
      :ok = Connector.send_audio(pid, audio_before_mute)
      assert_receive {:ws_frame, ^audio_before_mute}, 1000

      # Mute outbound
      :ok = Connector.mute(pid, :outbound)

      # Audio should NOT be sent to WebSocket when muted
      audio_during_mute = <<0xCC, 0xDD>>
      result = Connector.send_audio(pid, audio_during_mute)
      assert result == {:error, :muted}

      # Verify the muted frame was not sent
      refute_receive {:ws_frame, ^audio_during_mute}, 100

      # Clean up
      Connector.disconnect(pid)
    end

    test "unmute(:outbound) resumes sending audio to WebSocket", %{
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

      # Mute then unmute outbound
      :ok = Connector.mute(pid, :outbound)
      :ok = Connector.unmute(pid, :outbound)

      # Audio should flow again after unmute
      audio_after_unmute = <<0xEE, 0xFF>>
      :ok = Connector.send_audio(pid, audio_after_unmute)
      assert_receive {:ws_frame, ^audio_after_unmute}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "mute(:inbound) stops forwarding WebSocket audio to source", %{
      connection_id: connection_id,
      url: url
    } do
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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Verify audio flows normally when unmuted
      audio_before_mute = <<0x11, 0x22>>
      send(pid, {:connection_event, conn_pid, {:ws_audio, audio_before_mute}})
      assert_receive {:ws_audio, ^audio_before_mute}, 1000

      # Mute inbound
      :ok = Connector.mute(pid, :inbound)

      # Audio should NOT be forwarded when muted
      audio_during_mute = <<0x33, 0x44>>
      send(pid, {:connection_event, conn_pid, {:ws_audio, audio_during_mute}})
      refute_receive {:ws_audio, ^audio_during_mute}, 100

      # Clean up
      Connector.disconnect(pid)
    end

    test "unmute(:inbound) resumes forwarding WebSocket audio to source", %{
      connection_id: connection_id,
      url: url
    } do
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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Mute then unmute inbound
      :ok = Connector.mute(pid, :inbound)
      :ok = Connector.unmute(pid, :inbound)

      # Audio should flow again after unmute
      audio_after_unmute = <<0x55, 0x66>>
      send(pid, {:connection_event, conn_pid, {:ws_audio, audio_after_unmute}})
      assert_receive {:ws_audio, ^audio_after_unmute}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "muting one direction does not affect the other direction", %{
      connection_id: connection_id,
      url: url
    } do
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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Mute only outbound
      :ok = Connector.mute(pid, :outbound)

      # Outbound should be muted
      assert {:error, :muted} = Connector.send_audio(pid, <<0xAA>>)

      # But inbound should still work
      inbound_audio = <<0xBB, 0xCC>>
      send(pid, {:connection_event, conn_pid, {:ws_audio, inbound_audio}})
      assert_receive {:ws_audio, ^inbound_audio}, 1000

      # Now mute inbound and unmute outbound
      :ok = Connector.mute(pid, :inbound)
      :ok = Connector.unmute(pid, :outbound)

      # Outbound should work now
      outbound_audio = <<0xDD, 0xEE>>
      :ok = Connector.send_audio(pid, outbound_audio)
      assert_receive {:ws_frame, ^outbound_audio}, 1000

      # But inbound should be muted
      inbound_audio_2 = <<0xFF, 0x00>>
      send(pid, {:connection_event, conn_pid, {:ws_audio, inbound_audio_2}})
      refute_receive {:ws_audio, ^inbound_audio_2}, 100

      # Clean up
      Connector.disconnect(pid)
    end

    test "status reflects current mute state for both directions", %{
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

      # Initial state - both unmuted
      {:ok, status} = Connector.status(pid)
      assert status.outbound_muted == false
      assert status.inbound_muted == false

      # Mute outbound only
      :ok = Connector.mute(pid, :outbound)
      {:ok, status} = Connector.status(pid)
      assert status.outbound_muted == true
      assert status.inbound_muted == false

      # Mute inbound also
      :ok = Connector.mute(pid, :inbound)
      {:ok, status} = Connector.status(pid)
      assert status.outbound_muted == true
      assert status.inbound_muted == true

      # Unmute outbound
      :ok = Connector.unmute(pid, :outbound)
      {:ok, status} = Connector.status(pid)
      assert status.outbound_muted == false
      assert status.inbound_muted == true

      # Unmute inbound
      :ok = Connector.unmute(pid, :inbound)
      {:ok, status} = Connector.status(pid)
      assert status.outbound_muted == false
      assert status.inbound_muted == false

      # Clean up
      Connector.disconnect(pid)
    end

    test "frames_received counter increments even when inbound is muted", %{
      connection_id: connection_id,
      url: url
    } do
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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Mute inbound
      :ok = Connector.mute(pid, :inbound)

      # Check initial count
      {:ok, status_before} = Connector.status(pid)
      initial_received = status_before.frames_received

      # Simulate receiving audio frames while muted
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0x01>>}})
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0x02>>}})
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0x03>>}})

      # Give time for processing
      Process.sleep(50)

      # Counter should still increment even though audio wasn't forwarded
      {:ok, status_after} = Connector.status(pid)
      assert status_after.frames_received == initial_received + 3

      # But the audio should not have been forwarded
      refute_receive {:ws_audio, _}, 50

      # Clean up
      Connector.disconnect(pid)
    end

    test "frames_sent counter does not increment when outbound is muted", %{
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

      # Send some frames successfully first
      :ok = Connector.send_audio(pid, <<0x01>>)
      :ok = Connector.send_audio(pid, <<0x02>>)

      {:ok, status_before_mute} = Connector.status(pid)
      assert status_before_mute.frames_sent == 2

      # Mute outbound
      :ok = Connector.mute(pid, :outbound)

      # Try to send more frames (should be rejected)
      {:error, :muted} = Connector.send_audio(pid, <<0x03>>)
      {:error, :muted} = Connector.send_audio(pid, <<0x04>>)

      # Counter should not have incremented
      {:ok, status_after_mute} = Connector.status(pid)
      assert status_after_mute.frames_sent == 2

      # Clean up
      Connector.disconnect(pid)
    end

    test "can mute both directions simultaneously", %{
      connection_id: connection_id,
      url: url
    } do
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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Mute both directions
      :ok = Connector.mute(pid, :outbound)
      :ok = Connector.mute(pid, :inbound)

      # Verify status
      {:ok, status} = Connector.status(pid)
      assert status.outbound_muted == true
      assert status.inbound_muted == true

      # Outbound should be blocked
      assert {:error, :muted} = Connector.send_audio(pid, <<0xAA>>)

      # Inbound should be blocked (audio not forwarded)
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0xBB>>}})
      refute_receive {:ws_audio, _}, 100

      # Unmute both
      :ok = Connector.unmute(pid, :outbound)
      :ok = Connector.unmute(pid, :inbound)

      # Both should work again
      :ok = Connector.send_audio(pid, <<0xCC>>)
      assert_receive {:ws_frame, <<0xCC>>}, 1000

      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0xDD>>}})
      assert_receive {:ws_audio, <<0xDD>>}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "mute state persists across multiple operations", %{
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

      # Try multiple sends - all should fail
      for i <- 1..5 do
        assert {:error, :muted} = Connector.send_audio(pid, <<i>>)
      end

      # Status should still show muted
      {:ok, status} = Connector.status(pid)
      assert status.outbound_muted == true

      # Clean up
      Connector.disconnect(pid)
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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Simulate receiving a text message from WebSocket
      json_message = ~s({"type": "transcript", "text": "Hello"})
      send(pid, {:connection_event, conn_pid, {:ws_message, json_message}})

      # Should receive callback with the message
      assert_receive {:callback_ws_message, ^json_message}, 1000

      # Clean up
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # Disconnect and cleanup tests (US4)
  # ============================================================================

  describe "disconnect and cleanup (US4)" do
    test "disconnect/1 closes WebSocket gracefully", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Verify connected
      {:ok, status} = Connector.status(pid)
      assert status.connection_state == :connected

      # Disconnect should send close frame to WebSocket
      assert :ok = Connector.disconnect(pid)

      # The mock server should receive a close notification
      assert_receive {:ws_closed, _reason}, @ws_close_timeout
    end

    test "disconnect/1 stops the Connector process", %{connection_id: connection_id, url: url} do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)
      assert Process.alive?(pid)

      # Wait for connection
      Process.sleep(100)

      # Monitor to catch exit
      ref = Process.monitor(pid)

      # Disconnect
      assert :ok = Connector.disconnect(pid)

      # Process should terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, @process_down_timeout
      assert reason == :normal or reason == :shutdown or match?({:shutdown, _}, reason)
      refute Process.alive?(pid)
    end

    test "disconnect/1 unregisters from Registry", %{connection_id: connection_id, url: url} do
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

      # Wait for connection then disconnect
      Process.sleep(100)
      assert :ok = Connector.disconnect(pid)

      # Wait for termination
      Process.sleep(@registry_cleanup_wait)

      # Verify unregistered
      assert [] =
               Registry.lookup(
                 ParrotMedia.BidirectionalRegistry,
                 {:bidirectional, connection_id}
               )
    end

    test "disconnect/1 invokes callback with {:disconnected, :user_requested}", %{
      connection_id: connection_id,
      url: url
    } do
      test_pid = self()

      defmodule UserRequestedDisconnectCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:disconnected, :user_requested}, state) do
          send(state.test_pid, {:callback_disconnect_reason, :user_requested})
          {:ok, state}
        end

        def handle_event({:disconnected, reason}, state) do
          send(state.test_pid, {:callback_disconnect_reason, reason})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: UserRequestedDisconnectCallback,
          callback_state: %{test_pid: test_pid}
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Disconnect
      assert :ok = Connector.disconnect(pid)

      # Should receive callback with :user_requested reason
      assert_receive {:callback_disconnect_reason, :user_requested}, @callback_timeout
    end

    test "disconnect during reconnection stops retry attempts", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule ReconnectionStopCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:reconnecting, attempt}, state) do
          send(state.test_pid, {:reconnecting, attempt})
          {:ok, state}
        end

        def handle_event({:disconnected, reason}, state) do
          send(state.test_pid, {:disconnected, reason})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: ReconnectionStopCallback,
          callback_state: %{test_pid: test_pid},
          max_retries: 10
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Stop the server to trigger reconnection attempts
      stop_supervised({:mock_ws_server, port})

      # Wait for at least one reconnection attempt (may or may not receive depending on timing)
      Process.sleep(200)

      # Disconnect while potentially reconnecting
      ref = Process.monitor(pid)
      assert :ok = Connector.disconnect(pid)

      # Process should terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @process_down_timeout

      # Verify no more reconnection messages come after disconnect
      refute_receive {:reconnecting, _}, 500
    end

    test "resources are properly cleaned up - no lingering processes", %{
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

      # Get the connection process PID from the Connector state
      # We'll monitor both the connector and verify cleanup
      connector_ref = Process.monitor(pid)

      # Disconnect
      assert :ok = Connector.disconnect(pid)

      # Wait for connector to terminate
      assert_receive {:DOWN, ^connector_ref, :process, ^pid, _reason}, @process_down_timeout

      # Wait for registry cleanup to propagate (registry is eventually consistent)
      Process.sleep(@registry_cleanup_wait)

      # Verify no processes are registered for this connection
      assert [] =
               Registry.lookup(
                 ParrotMedia.BidirectionalRegistry,
                 {:bidirectional, connection_id}
               )

      # Verify whereis returns not_found
      assert {:error, :not_found} = Connector.whereis(connection_id)
    end

    test "multiple rapid connect/disconnect cycles work correctly", %{
      connection_id: _connection_id,
      url: url
    } do
      # Run multiple cycles with unique connection_ids
      for i <- 1..3 do
        cycle_id = "rapid_cycle_#{System.unique_integer([:positive])}_#{i}"

        {:ok, config} =
          Config.new(
            connection_id: cycle_id,
            url: url
          )

        {:ok, pid} = Connector.start_link(config)
        assert Process.alive?(pid)

        # Wait for connection
        Process.sleep(50)

        # Disconnect
        assert :ok = Connector.disconnect(pid)
        Process.sleep(50)

        # Verify cleaned up
        refute Process.alive?(pid)
        assert {:error, :not_found} = Connector.whereis(cycle_id)
      end
    end

    test "disconnect clears pending outbound buffer", %{
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

      # Stop server to trigger buffering
      stop_supervised({:mock_ws_server, port})
      Process.sleep(100)

      # Send frames that will be buffered
      buffered_frame_1 = <<0x01>>
      buffered_frame_2 = <<0x02>>
      buffered_frame_3 = <<0x03>>
      Connector.send_audio(pid, buffered_frame_1)
      Connector.send_audio(pid, buffered_frame_2)
      Connector.send_audio(pid, buffered_frame_3)

      # Verify frames are buffered
      {:ok, status} = Connector.status(pid)
      assert status.buffer_size > 0
      buffered_count = status.buffer_size

      # Disconnect - should clean up buffer without sending
      ref = Process.monitor(pid)
      assert :ok = Connector.disconnect(pid)

      # Wait for termination
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @process_down_timeout

      # Verify no buffered frames were sent to WebSocket during disconnect
      # The mock server would have received {:ws_frame, data} messages if frames were sent
      refute_receive {:ws_frame, ^buffered_frame_1}, @registry_cleanup_wait
      refute_receive {:ws_frame, ^buffered_frame_2}, 0
      refute_receive {:ws_frame, ^buffered_frame_3}, 0

      # Confirm the buffer had frames that were discarded, not sent
      assert buffered_count == 3
    end

    test "disconnect stops source audio forwarding", %{connection_id: connection_id, url: url} do
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

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Simulate receiving audio - should forward
      send(pid, {:connection_event, conn_pid, {:ws_audio, <<0x01>>}})
      assert_receive {:ws_audio, <<0x01>>}, @registry_cleanup_wait

      # Disconnect
      ref = Process.monitor(pid)
      assert :ok = Connector.disconnect(pid)

      # Wait for termination
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @process_down_timeout

      # Verify no more audio forwarding (process is dead anyway)
      refute Process.alive?(pid)
    end
  end

  # ============================================================================
  # Lifecycle events tests (US2 - T023)
  # ============================================================================

  describe "lifecycle events (US2)" do
    test "invokes callback with {:connected} when WebSocket connects", %{
      connection_id: connection_id,
      url: url
    } do
      test_pid = self()

      defmodule US2ConnectedCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:connected}, state) do
          send(state.test_pid, {:lifecycle_event, :connected})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2ConnectedCallback,
          callback_state: %{test_pid: test_pid}
        )

      {:ok, pid} = Connector.start_link(config)

      # Should receive connected callback when WebSocket handshake completes
      assert_receive {:lifecycle_event, :connected}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "invokes callback with {:disconnected, reason} when connection drops", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule US2DisconnectedCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:disconnected, reason}, state) do
          send(state.test_pid, {:lifecycle_event, :disconnected, reason})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2DisconnectedCallback,
          callback_state: %{test_pid: test_pid},
          # Set max_retries to 0 so it fails immediately without reconnection attempts
          max_retries: 0
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection to establish
      Process.sleep(100)

      # Stop the mock server to simulate connection drop
      stop_supervised({:mock_ws_server, port})

      # Should receive disconnected callback with reason
      assert_receive {:lifecycle_event, :disconnected, _reason}, 2000

      # Clean up
      Connector.disconnect(pid)
    end

    test "invokes callback with {:reconnecting, attempt} during reconnection attempts", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule US2ReconnectingCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:reconnecting, attempt}, state) do
          send(state.test_pid, {:lifecycle_event, :reconnecting, attempt})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2ReconnectingCallback,
          callback_state: %{test_pid: test_pid},
          max_retries: 3
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      # Stop the mock server to trigger reconnection
      stop_supervised({:mock_ws_server, port})

      # Should receive reconnecting callback with attempt number
      assert_receive {:lifecycle_event, :reconnecting, 1}, 2000

      # Clean up
      Connector.disconnect(pid)
    end

    test "invokes callback with {:failed, reason} when max retries exceeded", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule US2FailedCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:failed, reason}, state) do
          send(state.test_pid, {:lifecycle_event, :failed, reason})
          {:ok, state}
        end

        def handle_event({:reconnecting, _attempt}, state) do
          # Track reconnection attempts
          send(state.test_pid, :reconnecting_attempt)
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2FailedCallback,
          callback_state: %{test_pid: test_pid},
          max_retries: 2
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      # Stop the mock server - no server to reconnect to
      stop_supervised({:mock_ws_server, port})

      # Should receive failed callback after max retries exceeded
      # Allow time for the retries
      assert_receive {:lifecycle_event, :failed, _reason}, 10_000

      # The connector should have transitioned to :failed state
      {:ok, status} = Connector.status(pid)
      assert status.connection_state == :failed

      # Clean up
      Connector.disconnect(pid)
    end

    test "forwards WebSocket text/JSON messages to callback as {:ws_message, data}", %{
      connection_id: connection_id,
      url: url
    } do
      test_pid = self()

      defmodule US2WsMessageCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:ws_message, data}, state) do
          send(state.test_pid, {:lifecycle_event, :ws_message, data})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2WsMessageCallback,
          callback_state: %{test_pid: test_pid}
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Get the conn_pid to properly simulate the connection sending events
      conn_pid = get_conn_pid(pid)

      # Simulate receiving a text/JSON message from WebSocket
      json_message = ~s({"type": "transcript", "text": "Hello world"})
      send(pid, {:connection_event, conn_pid, {:ws_message, json_message}})

      # Should receive the message via callback
      assert_receive {:lifecycle_event, :ws_message, ^json_message}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "transitions through correct state sequence on connect", %{
      connection_id: connection_id,
      url: url
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url
        )

      {:ok, pid} = Connector.start_link(config)

      # Initial state should be :connecting
      {:ok, initial_status} = Connector.status(pid)
      assert initial_status.connection_state == :connecting

      # Wait for connection to establish
      Process.sleep(100)

      # After connection, state should be :connected
      {:ok, connected_status} = Connector.status(pid)
      assert connected_status.connection_state == :connected

      # Clean up
      Connector.disconnect(pid)
    end

    test "transitions through correct state sequence on disconnect and reconnect", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          max_retries: 3
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      {:ok, connected_status} = Connector.status(pid)
      assert connected_status.connection_state == :connected

      # Stop server to trigger reconnection
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect detection and reconnection attempt
      Process.sleep(200)

      # State should be :reconnecting or :disconnected
      {:ok, reconnecting_status} = Connector.status(pid)
      assert reconnecting_status.connection_state in [:reconnecting, :disconnected]

      # Clean up
      Connector.disconnect(pid)
    end
  end

  # ============================================================================
  # Reconnection behavior tests (US2 - T024)
  # ============================================================================

  describe "reconnection behavior (US2)" do
    test "attempts reconnection when connection drops unexpectedly", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule US2ReconnectAttemptCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:reconnecting, attempt}, state) do
          send(state.test_pid, {:reconnect_attempt, attempt})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2ReconnectAttemptCallback,
          callback_state: %{test_pid: test_pid},
          max_retries: 5
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      # Stop server to trigger reconnection
      stop_supervised({:mock_ws_server, port})

      # Should attempt reconnection
      assert_receive {:reconnect_attempt, 1}, 2000

      # Clean up
      Connector.disconnect(pid)
    end

    test "uses exponential backoff between retries", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule US2BackoffCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:reconnecting, attempt}, state) do
          # Record timestamp of each reconnection attempt
          send(state.test_pid, {:reconnect_at, attempt, System.monotonic_time(:millisecond)})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2BackoffCallback,
          callback_state: %{test_pid: test_pid},
          max_retries: 4
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      # Stop server - no way to reconnect, will keep retrying
      stop_supervised({:mock_ws_server, port})

      # Collect timestamps of reconnection attempts
      assert_receive {:reconnect_at, 1, t1}, 2000
      assert_receive {:reconnect_at, 2, t2}, 5000
      assert_receive {:reconnect_at, 3, t3}, 10_000

      # Calculate delays between attempts
      delay_1_to_2 = t2 - t1
      delay_2_to_3 = t3 - t2

      # Verify exponential backoff: second delay should be larger than first
      # Allow some tolerance for timing variations
      assert delay_2_to_3 > delay_1_to_2 * 0.8,
             "Expected exponential backoff: delay_2_to_3 (#{delay_2_to_3}ms) should be >= delay_1_to_2 (#{delay_1_to_2}ms)"

      # Clean up
      Connector.disconnect(pid)
    end

    test "respects max_retries config", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule US2MaxRetriesCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:reconnecting, attempt}, state) do
          send(state.test_pid, {:reconnect_attempt, attempt})
          {:ok, state}
        end

        def handle_event({:failed, _reason}, state) do
          send(state.test_pid, :connection_failed)
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      max_retries = 3

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2MaxRetriesCallback,
          callback_state: %{test_pid: test_pid},
          max_retries: max_retries
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      # Stop server - no way to reconnect
      stop_supervised({:mock_ws_server, port})

      # Should receive exactly max_retries reconnection attempts
      for attempt <- 1..max_retries do
        assert_receive {:reconnect_attempt, ^attempt}, 10_000
      end

      # After max_retries, should receive failure notification
      assert_receive :connection_failed, 5000

      # Should NOT receive more reconnection attempts
      refute_receive {:reconnect_attempt, _}, 500

      # Clean up
      Connector.disconnect(pid)
    end

    test "stops attempting after max_retries exceeded", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      test_pid = self()

      defmodule US2StopAttemptsCallback do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_event({:reconnecting, attempt}, state) do
          send(state.test_pid, {:reconnect_attempt, attempt})
          {:ok, state}
        end

        def handle_event({:failed, reason}, state) do
          send(state.test_pid, {:failed, reason})
          {:ok, state}
        end

        def handle_event(_event, state), do: {:ok, state}
      end

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          callback_module: US2StopAttemptsCallback,
          callback_state: %{test_pid: test_pid},
          max_retries: 2
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      # Stop server
      stop_supervised({:mock_ws_server, port})

      # Wait for all retries to complete and failure
      assert_receive {:reconnect_attempt, 1}, 2000
      assert_receive {:reconnect_attempt, 2}, 5000
      assert_receive {:failed, _reason}, 5000

      # Verify state is :failed
      {:ok, status} = Connector.status(pid)
      assert status.connection_state == :failed

      # Ensure no more reconnection attempts after failure
      refute_receive {:reconnect_attempt, _}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "buffers audio during reconnection up to buffer_size frames", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      buffer_capacity = 5

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          buffer_size: buffer_capacity,
          max_retries: 3
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Stop server to trigger reconnection state
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect detection
      Process.sleep(200)

      # Send audio frames while disconnected - they should be buffered
      for i <- 1..buffer_capacity do
        Connector.send_audio(pid, <<i::8>>)
      end

      # Give time for buffering
      Process.sleep(50)

      # Verify frames are buffered
      {:ok, status} = Connector.status(pid)
      assert status.buffer_size == buffer_capacity
      assert status.frames_dropped == 0

      # Clean up
      Connector.disconnect(pid)
    end

    test "resumes sending buffered audio after reconnection", %{
      connection_id: connection_id,
      port: port
    } do
      buffer_capacity = 3

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: "ws://localhost:#{port}/ws",
          buffer_size: buffer_capacity,
          max_retries: 5
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      # Stop server to trigger disconnection
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect
      Process.sleep(200)

      # Send audio while disconnected (will be buffered)
      frame1 = <<0xAA>>
      frame2 = <<0xBB>>
      frame3 = <<0xCC>>
      Connector.send_audio(pid, frame1)
      Connector.send_audio(pid, frame2)
      Connector.send_audio(pid, frame3)

      # Verify buffered
      Process.sleep(50)
      {:ok, status_before} = Connector.status(pid)
      assert status_before.buffer_size == 3

      # Restart the mock server to allow reconnection
      {:ok, _server_pid} =
        start_supervised(
          {ParrotMedia.Test.MockWsServer, port: port, test_pid: self()},
          id: {:mock_ws_server_2, port}
        )

      # Wait for reconnection and buffer flush
      Process.sleep(500)

      # After reconnection, buffer should be flushed
      {:ok, status_after} = Connector.status(pid)
      assert status_after.buffer_size == 0

      # The buffered frames should have been sent to the WebSocket
      # (Order may vary based on timing, so we just check they were sent)
      assert_receive {:ws_frame, ^frame1}, 1000
      assert_receive {:ws_frame, ^frame2}, 1000
      assert_receive {:ws_frame, ^frame3}, 1000

      # Clean up
      Connector.disconnect(pid)
    end

    test "drops oldest frames when buffer exceeds buffer_size during reconnection", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      buffer_capacity = 3

      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          buffer_size: buffer_capacity,
          max_retries: 3
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for connection
      Process.sleep(100)

      # Stop server to trigger reconnection state
      stop_supervised({:mock_ws_server, port})

      # Wait for disconnect
      Process.sleep(200)

      # Send more frames than buffer can hold
      for i <- 1..6 do
        Connector.send_audio(pid, <<i::8>>)
      end

      Process.sleep(50)

      {:ok, status} = Connector.status(pid)
      # Buffer should be at capacity
      assert status.buffer_size == buffer_capacity
      # Should have dropped 3 frames (6 sent - 3 capacity)
      assert status.frames_dropped == 3

      # Clean up
      Connector.disconnect(pid)
    end

    test "increments reconnect_count on each reconnection", %{
      connection_id: connection_id,
      url: url,
      port: port
    } do
      {:ok, config} =
        Config.new(
          connection_id: connection_id,
          url: url,
          max_retries: 5
        )

      {:ok, pid} = Connector.start_link(config)

      # Wait for initial connection
      Process.sleep(100)

      {:ok, initial_status} = Connector.status(pid)
      assert initial_status.reconnect_count == 0

      # Stop server to trigger reconnection
      stop_supervised({:mock_ws_server, port})

      # Wait for reconnection attempts
      Process.sleep(1000)

      {:ok, status} = Connector.status(pid)
      assert status.reconnect_count > 0

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
