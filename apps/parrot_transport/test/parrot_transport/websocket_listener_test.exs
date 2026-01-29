defmodule ParrotTransport.WebsocketListenerTest do
  use ExUnit.Case, async: false

  alias ParrotTransport.WebsocketListener
  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}

  describe "lifecycle states" do
    test "starts and reaches :listening state" do
      config = %ListenerConfig{
        transport: :websocket,
        port: 0
      }

      {:ok, pid} = WebsocketListener.start_link(config, self())

      Process.sleep(50)

      assert :listening = WebsocketListener.get_state(pid)
    end

    test "binds to specific port" do
      config = %ListenerConfig{
        transport: :websocket,
        port: 18100
      }

      {:ok, pid} = WebsocketListener.start_link(config, self())

      Process.sleep(50)

      assert {:ok, {_ip, 18100}} = WebsocketListener.get_local_address(pid)
    end

    test "binds to port 0 and gets random port" do
      config = %ListenerConfig{
        transport: :websocket,
        port: 0
      }

      {:ok, pid} = WebsocketListener.start_link(config, self())

      Process.sleep(50)

      assert {:ok, {_ip, port}} = WebsocketListener.get_local_address(pid)
      assert port > 0
    end
  end

  describe "accepting connections" do
    setup do
      config = %ListenerConfig{
        transport: :websocket,
        port: 0
      }

      {:ok, listener} = WebsocketListener.start_link(config, self())
      {:ok, {_ip, port}} = WebsocketListener.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "accepts incoming WebSocket connection", %{port: port} do
      {:ok, client} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
      {:ok, :http} = :gun.await_up(client)

      stream_ref = :gun.ws_upgrade(client, "/")

      receive do
        {:gun_upgrade, ^client, ^stream_ref, [<<"websocket">>], _headers} ->
          :ok
      after
        1000 -> flunk("WebSocket upgrade timeout")
      end

      # Send a text frame
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      :gun.ws_send(client, stream_ref, {:text, message})

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :gun.close(client)
    end

    test "includes correct source addresses in incoming packet", %{port: port} do
      # Fix for parrot_platform-1av: WebSocket source address bug
      # Before fix: all packets had source 0.0.0.0:0
      # After fix: packets contain correct remote and local addresses

      {:ok, client} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
      {:ok, :http} = :gun.await_up(client)

      stream_ref = :gun.ws_upgrade(client, "/")

      receive do
        {:gun_upgrade, ^client, ^stream_ref, [<<"websocket">>], _headers} ->
          :ok
      after
        1000 -> flunk("WebSocket upgrade timeout")
      end

      message = "INVITE sip:test SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      :gun.ws_send(client, stream_ref, {:text, message})

      assert_receive {:incoming_packet, %IncomingPacket{source: source}}, 1000

      # Remote address should be 127.0.0.1 with non-zero port (client's port)
      assert {remote_ip, remote_port} = source.remote_addr
      assert remote_ip == {127, 0, 0, 1}, "Remote IP should be 127.0.0.1, got #{inspect(remote_ip)}"
      assert remote_port > 0, "Remote port should be > 0, got #{remote_port}"

      # Local address should be 127.0.0.1 with the listener's port
      # Note: The exact local IP depends on how Cowboy binds (could be 0.0.0.0 or 127.0.0.1)
      assert {local_ip, local_port} = source.local_addr
      assert local_port == port, "Local port should be #{port}, got #{local_port}"
      # Local IP could be 0.0.0.0 (any) or 127.0.0.1 depending on binding
      assert local_ip != nil, "Local IP should not be nil"

      :gun.close(client)
    end

    test "handles binary frames", %{port: port} do
      {:ok, client} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
      {:ok, :http} = :gun.await_up(client)

      stream_ref = :gun.ws_upgrade(client, "/")

      receive do
        {:gun_upgrade, ^client, ^stream_ref, [<<"websocket">>], _headers} ->
          :ok
      after
        1000 -> flunk("WebSocket upgrade timeout")
      end

      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      :gun.ws_send(client, stream_ref, {:binary, message})

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :gun.close(client)
    end

    test "handles multiple simultaneous WebSocket connections", %{port: port} do
      clients =
        for _i <- 1..5 do
          {:ok, client} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
          {:ok, :http} = :gun.await_up(client)
          stream_ref = :gun.ws_upgrade(client, "/")

          receive do
            {:gun_upgrade, ^client, ^stream_ref, [<<"websocket">>], _headers} ->
              :ok
          after
            1000 -> flunk("WebSocket upgrade timeout")
          end

          {client, stream_ref}
        end

      Process.sleep(200)

      # Send from each client
      for {{client, stream_ref}, i} <- Enum.with_index(clients, 1) do
        message = "INVITE sip:client#{i} SIP/2.0\r\nContent-Length: 0\r\n\r\n"
        :gun.ws_send(client, stream_ref, {:text, message})
      end

      # Should receive all messages
      for i <- 1..5 do
        expected = "INVITE sip:client#{i} SIP/2.0\r\nContent-Length: 0\r\n\r\n"
        assert_receive {:incoming_packet, %IncomingPacket{data: ^expected}}, 1000
      end

      for {client, _stream_ref} <- clients, do: :gun.close(client)
    end

    test "handles multiple messages from same client", %{port: port} do
      {:ok, client} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
      {:ok, :http} = :gun.await_up(client)

      stream_ref = :gun.ws_upgrade(client, "/")

      receive do
        {:gun_upgrade, ^client, ^stream_ref, [<<"websocket">>], _headers} ->
          :ok
      after
        1000 -> flunk("WebSocket upgrade timeout")
      end

      msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      msg2 = "ACK sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      :gun.ws_send(client, stream_ref, {:text, msg1})
      :gun.ws_send(client, stream_ref, {:text, msg2})

      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg1}}, 1000
      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg2}}, 1000

      :gun.close(client)
    end
  end

  describe "connection cleanup" do
    setup do
      config = %ListenerConfig{
        transport: :websocket,
        port: 0
      }

      {:ok, listener} = WebsocketListener.start_link(config, self())
      {:ok, {_ip, port}} = WebsocketListener.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "handles client disconnect gracefully", %{port: port} do
      {:ok, client} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
      {:ok, :http} = :gun.await_up(client)

      stream_ref = :gun.ws_upgrade(client, "/")

      receive do
        {:gun_upgrade, ^client, ^stream_ref, [<<"websocket">>], _headers} ->
          :ok
      after
        1000 -> flunk("WebSocket upgrade timeout")
      end

      # Send a message
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      :gun.ws_send(client, stream_ref, {:text, message})
      assert_receive {:incoming_packet, %IncomingPacket{}}, 1000

      # Close client
      :gun.close(client)
      Process.sleep(50)

      # Listener should still be alive and accepting new connections
      {:ok, client2} = :gun.open({127, 0, 0, 1}, port, %{protocols: [:http]})
      {:ok, :http} = :gun.await_up(client2)

      stream_ref2 = :gun.ws_upgrade(client2, "/")

      receive do
        {:gun_upgrade, ^client2, ^stream_ref2, [<<"websocket">>], _headers} ->
          :ok
      after
        1000 -> flunk("WebSocket upgrade timeout")
      end

      :gun.ws_send(client2, stream_ref2, {:text, message})
      assert_receive {:incoming_packet, %IncomingPacket{}}, 1000

      :gun.close(client2)
    end
  end

  describe "graceful shutdown" do
    test "stops gracefully" do
      config = %ListenerConfig{
        transport: :websocket,
        port: 0
      }

      {:ok, listener} = WebsocketListener.start_link(config, self())

      ref = Process.monitor(listener)

      :ok = WebsocketListener.stop(listener)

      assert_receive {:DOWN, ^ref, :process, ^listener, _reason}, 1000
    end

    test "closes listen socket on stop" do
      config = %ListenerConfig{
        transport: :websocket,
        port: 18200
      }

      {:ok, listener} = WebsocketListener.start_link(config, self())

      Process.sleep(50)

      :ok = WebsocketListener.stop(listener)
      Process.sleep(50)

      # Should be able to bind to same port again
      assert {:ok, _listener2} = WebsocketListener.start_link(config, self())
    end
  end

  describe "error handling" do
    test "fails when port is already in use" do
      config = %ListenerConfig{
        transport: :websocket,
        port: 18300
      }

      {:ok, _listener1} = WebsocketListener.start_link(config, self())

      Process.sleep(50)

      # Second listener should fail
      Process.flag(:trap_exit, true)
      result = WebsocketListener.start_link(config, self())

      case result do
        {:error, {:bind_error, :eaddrinuse}} ->
          :ok

        {:ok, pid} ->
          # Started but should exit immediately
          assert_receive {:EXIT, ^pid, {:bind_error, :eaddrinuse}}, 1000

        {:error, reason} ->
          # Some other error with bind_error in it
          assert match?({:bind_error, _}, reason)
      end

      Process.flag(:trap_exit, false)
    end
  end
end
