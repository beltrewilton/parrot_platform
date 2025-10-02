defmodule ParrotTransport.ConnectionTest do
  use ExUnit.Case, async: false

  alias ParrotTransport.Connection
  alias ParrotTransport.Types.{IncomingPacket, ListenerConfig}

  describe "TCP connection lifecycle" do
    setup do
      # Start a TCP server for tests
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(listen_socket)

      on_exit(fn ->
        :gen_tcp.close(listen_socket)
      end)

      %{listen_socket: listen_socket, port: port}
    end

    test "establishes connection and reaches :connected state", %{listen_socket: listen_socket, port: port} do
      # Start connection
      config = %ListenerConfig{transport: :tcp, port: port, ip: {127, 0, 0, 1}}
      {:ok, conn_pid} = Connection.start_link(config, self())

      # Accept the connection
      {:ok, _server_socket} = :gen_tcp.accept(listen_socket, 1000)

      # Give time to reach :connected state
      Process.sleep(50)

      state = :sys.get_state(conn_pid)
      assert elem(state, 0) == :connected
    end

    test "handles connection refusal", %{port: _port} do
      # Close the listen socket to refuse connection
      {:ok, bad_socket} = :gen_tcp.listen(0, [:binary])
      {:ok, bad_port} = :inet.port(bad_socket)
      :gen_tcp.close(bad_socket)

      # Try to connect to closed port
      config = %ListenerConfig{transport: :tcp, port: bad_port, ip: {127, 0, 0, 1}}
      {:ok, conn_pid} = Connection.start_link(config, self())

      # Should enter reconnecting state
      Process.sleep(100)

      state = :sys.get_state(conn_pid)
      assert elem(state, 0) == :reconnecting
    end
  end

  describe "message framing and reception" do
    setup do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(listen_socket)

      config = %ListenerConfig{transport: :tcp, port: port, ip: {127, 0, 0, 1}}
      {:ok, conn_pid} = Connection.start_link(config, self())

      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 1000)
      Process.sleep(50)

      on_exit(fn ->
        :gen_tcp.close(server_socket)
        :gen_tcp.close(listen_socket)
      end)

      %{server_socket: server_socket, conn_pid: conn_pid}
    end

    test "receives complete message with Content-Length framing", %{server_socket: server_socket} do
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      :ok = :gen_tcp.send(server_socket, message)

      assert_receive {:incoming_packet, %IncomingPacket{} = packet}, 1000
      assert packet.data == message
      assert packet.source.transport == :tcp
    end

    test "handles message split across multiple TCP packets", %{server_socket: server_socket} do
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      # Send in chunks
      :ok = :gen_tcp.send(server_socket, "INVITE sip:bob SIP/2.0\r\n")
      Process.sleep(10)
      :ok = :gen_tcp.send(server_socket, "Content-Length: 0\r\n\r\n")

      assert_receive {:incoming_packet, %IncomingPacket{} = packet}, 1000
      assert packet.data == message
    end

    test "handles multiple messages in single TCP packet", %{server_socket: server_socket} do
      msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      msg2 = "ACK sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      :ok = :gen_tcp.send(server_socket, msg1 <> msg2)

      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg1}}, 1000
      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg2}}, 1000
    end

    test "handles message with body", %{server_socket: server_socket} do
      body = "v=0\r\no=alice 123 456 IN IP4 127.0.0.1\r\n"
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

      :ok = :gen_tcp.send(server_socket, message)

      assert_receive {:incoming_packet, %IncomingPacket{} = packet}, 1000
      assert packet.data == message
    end
  end

  describe "outbound message transmission" do
    setup do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(listen_socket)

      config = %ListenerConfig{transport: :tcp, port: port, ip: {127, 0, 0, 1}}
      {:ok, conn_pid} = Connection.start_link(config, self())

      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 1000)
      Process.sleep(50)

      on_exit(fn ->
        :gen_tcp.close(server_socket)
        :gen_tcp.close(listen_socket)
      end)

      %{server_socket: server_socket, conn_pid: conn_pid}
    end

    test "sends data successfully", %{server_socket: server_socket, conn_pid: conn_pid} do
      data = "INVITE sip:alice SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      :ok = Connection.send_data(conn_pid, data)

      assert {:ok, received} = :gen_tcp.recv(server_socket, 0, 1000)
      assert received == data
    end
  end

  describe "connection failure and reconnection" do
    setup do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(listen_socket)

      config = %ListenerConfig{transport: :tcp, port: port, ip: {127, 0, 0, 1}}
      {:ok, conn_pid} = Connection.start_link(config, self())

      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 1000)
      Process.sleep(50)

      %{server_socket: server_socket, listen_socket: listen_socket, conn_pid: conn_pid}
    end

    test "detects connection closure and enters reconnecting state", %{server_socket: server_socket, conn_pid: conn_pid} do
      :ok = :gen_tcp.close(server_socket)

      # Give time to detect closure and enter reconnecting
      Process.sleep(100)

      state = :sys.get_state(conn_pid)
      assert elem(state, 0) == :reconnecting
    end

    test "reconnects after connection loss", %{server_socket: server_socket, listen_socket: listen_socket, conn_pid: conn_pid} do
      # Close initial connection
      :ok = :gen_tcp.close(server_socket)
      Process.sleep(100)

      # Accept new connection
      {:ok, _new_socket} = :gen_tcp.accept(listen_socket, 2000)

      # Should be back in connected state
      Process.sleep(50)
      state = :sys.get_state(conn_pid)
      assert elem(state, 0) == :connected
    end
  end

  describe "graceful shutdown" do
    setup do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(listen_socket)

      config = %ListenerConfig{transport: :tcp, port: port, ip: {127, 0, 0, 1}}
      {:ok, conn_pid} = Connection.start_link(config, self())

      {:ok, server_socket} = :gen_tcp.accept(listen_socket, 1000)
      Process.sleep(50)

      on_exit(fn ->
        :gen_tcp.close(server_socket)
        :gen_tcp.close(listen_socket)
      end)

      %{conn_pid: conn_pid}
    end

    test "stops gracefully", %{conn_pid: conn_pid} do
      ref = Process.monitor(conn_pid)

      :ok = Connection.stop(conn_pid)

      assert_receive {:DOWN, ^ref, :process, ^conn_pid, _reason}, 1000
    end
  end
end
