defmodule ParrotTransport.TcpListenerTest do
  use ExUnit.Case, async: false

  alias ParrotTransport.TcpListener
  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}

  describe "lifecycle states" do
    test "starts and reaches :listening state" do
      config = %ListenerConfig{transport: :tcp, port: 0}
      {:ok, pid} = TcpListener.start_link(config, self())

      # Socket binding happens synchronously in init, so state is immediately :listening
      assert :listening = :sys.get_state(pid) |> elem(0)
    end

    test "binds to specific port" do
      config = %ListenerConfig{transport: :tcp, port: 16100}
      {:ok, pid} = TcpListener.start_link(config, self())

      # get_local_address is a sync call - no sleep needed
      assert {:ok, {_ip, 16100}} = TcpListener.get_local_address(pid)
    end

    test "binds to port 0 and gets random port" do
      config = %ListenerConfig{transport: :tcp, port: 0}
      {:ok, pid} = TcpListener.start_link(config, self())

      # get_local_address is a sync call - no sleep needed
      assert {:ok, {_ip, port}} = TcpListener.get_local_address(pid)
      assert port > 0
    end
  end

  describe "accepting connections" do
    setup do
      config = %ListenerConfig{transport: :tcp, port: 0}
      {:ok, listener} = TcpListener.start_link(config, self())
      {:ok, {_ip, port}} = TcpListener.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "accepts incoming TCP connection", %{port: port} do
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

      # Send message - the assert_receive below is the synchronization point
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      :ok = :gen_tcp.send(client, message)

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :gen_tcp.close(client)
    end

    test "handles multiple simultaneous connections", %{port: port} do
      clients =
        for _i <- 1..5 do
          {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])
          client
        end

      # Send from each client - no sleep needed, assert_receive is the sync point
      for {client, i} <- Enum.with_index(clients, 1) do
        message = "INVITE sip:client#{i} SIP/2.0\r\nContent-Length: 0\r\n\r\n"
        :ok = :gen_tcp.send(client, message)
      end

      # Should receive all messages
      for i <- 1..5 do
        expected = "INVITE sip:client#{i} SIP/2.0\r\nContent-Length: 0\r\n\r\n"
        assert_receive {:incoming_packet, %IncomingPacket{data: ^expected}}, 1000
      end

      for client <- clients, do: :gen_tcp.close(client)
    end

    test "handles connection with body", %{port: port} do
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

      body = "v=0\r\no=alice 123 456 IN IP4 127.0.0.1\r\n"
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

      :ok = :gen_tcp.send(client, message)

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :gen_tcp.close(client)
    end

    test "handles message split across multiple sends", %{port: port} do
      # Disable Nagle's algorithm to ensure chunks are sent separately
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}, {:nodelay, true}])

      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      # Send in chunks - nodelay ensures they're sent as separate TCP segments
      :ok = :gen_tcp.send(client, "INVITE sip:bob SIP/2.0\r\n")
      :ok = :gen_tcp.send(client, "Content-Length: 0\r\n\r\n")

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :gen_tcp.close(client)
    end

    test "handles multiple messages from same client", %{port: port} do
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

      msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      msg2 = "ACK sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      :ok = :gen_tcp.send(client, msg1)
      :ok = :gen_tcp.send(client, msg2)

      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg1}}, 1000
      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg2}}, 1000

      :gen_tcp.close(client)
    end
  end

  describe "connection cleanup" do
    setup do
      config = %ListenerConfig{transport: :tcp, port: 0}
      {:ok, listener} = TcpListener.start_link(config, self())
      {:ok, {_ip, port}} = TcpListener.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "handles client disconnect gracefully", %{port: port} do
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])

      # Send a message - assert_receive is the sync point for connection being ready
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      :ok = :gen_tcp.send(client, message)
      assert_receive {:incoming_packet, %IncomingPacket{}}, 1000

      # Close client
      :gen_tcp.close(client)

      # Listener should still be alive and accepting new connections
      # The connect/send/receive sequence below confirms the listener is still operational
      {:ok, client2} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, {:active, false}])
      :ok = :gen_tcp.send(client2, message)
      assert_receive {:incoming_packet, %IncomingPacket{}}, 1000

      :gen_tcp.close(client2)
    end
  end

  describe "graceful shutdown" do
    test "stops gracefully" do
      config = %ListenerConfig{transport: :tcp, port: 0}
      {:ok, listener} = TcpListener.start_link(config, self())

      ref = Process.monitor(listener)

      :ok = TcpListener.stop(listener)

      assert_receive {:DOWN, ^ref, :process, ^listener, _reason}, 1000
    end

    test "closes listen socket on stop" do
      config = %ListenerConfig{transport: :tcp, port: 16200}
      {:ok, listener} = TcpListener.start_link(config, self())

      {:ok, _} = TcpListener.get_local_address(listener)

      ref = Process.monitor(listener)
      :ok = TcpListener.stop(listener)

      # Wait for listener to fully stop before rebinding to same port
      receive do
        {:DOWN, ^ref, :process, ^listener, _reason} -> :ok
      after
        1000 -> flunk("listener didn't stop in time")
      end

      # Should be able to bind to same port again
      assert {:ok, _listener2} = TcpListener.start_link(config, self())
    end
  end

  describe "error handling" do
    test "fails when port is already in use" do
      config = %ListenerConfig{transport: :tcp, port: 16300}
      {:ok, listener1} = TcpListener.start_link(config, self())

      # Sync call confirms listener is bound
      {:ok, _} = TcpListener.get_local_address(listener1)

      # Second listener should fail - catch the exit
      Process.flag(:trap_exit, true)
      result = TcpListener.start_link(config, self())

      # Should either return error or we get an EXIT message
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
