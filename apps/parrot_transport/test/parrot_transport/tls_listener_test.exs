defmodule ParrotTransport.TlsListenerTest do
  use ExUnit.Case, async: false

  alias ParrotTransport.TlsListener
  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}

  @cert_file "test/support/certs/cert.pem"
  @key_file "test/support/certs/key.pem"

  describe "lifecycle states" do
    test "starts and reaches :listening state" do
      config = %ListenerConfig{
        transport: :tls,
        port: 0,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, pid} = TlsListener.start_link(config, self())

      Process.sleep(50)

      assert :listening = :sys.get_state(pid) |> elem(0)
    end

    test "binds to specific port" do
      config = %ListenerConfig{
        transport: :tls,
        port: 17100,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, pid} = TlsListener.start_link(config, self())

      Process.sleep(50)

      assert {:ok, {_ip, 17100}} = TlsListener.get_local_address(pid)
    end

    test "binds to port 0 and gets random port" do
      config = %ListenerConfig{
        transport: :tls,
        port: 0,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, pid} = TlsListener.start_link(config, self())

      Process.sleep(50)

      assert {:ok, {_ip, port}} = TlsListener.get_local_address(pid)
      assert port > 0
    end

    test "fails when certificate file not found" do
      config = %ListenerConfig{
        transport: :tls,
        port: 0,
        certfile: "nonexistent.pem",
        keyfile: @key_file
      }

      Process.flag(:trap_exit, true)
      result = TlsListener.start_link(config, self())

      case result do
        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          assert_receive {:EXIT, ^pid, _reason}, 1000
      end

      Process.flag(:trap_exit, false)
    end

    test "fails when key file not found" do
      config = %ListenerConfig{
        transport: :tls,
        port: 0,
        certfile: @cert_file,
        keyfile: "nonexistent.pem"
      }

      Process.flag(:trap_exit, true)
      result = TlsListener.start_link(config, self())

      case result do
        {:error, _reason} ->
          :ok

        {:ok, pid} ->
          assert_receive {:EXIT, ^pid, _reason}, 1000
      end

      Process.flag(:trap_exit, false)
    end
  end

  describe "accepting connections" do
    setup do
      config = %ListenerConfig{
        transport: :tls,
        port: 0,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, listener} = TlsListener.start_link(config, self())
      {:ok, {_ip, port}} = TlsListener.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "accepts incoming TLS connection", %{port: port} do
      {:ok, client} =
        :ssl.connect({127, 0, 0, 1}, port, [
          :binary,
          {:active, false},
          {:verify, :verify_none}
        ])

      # Give time for connection and SSL handshake
      Process.sleep(200)

      # Verify we can send/receive
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      :ok = :ssl.send(client, message)

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :ssl.close(client)
    end

    test "handles multiple simultaneous TLS connections", %{port: port} do
      clients =
        for _i <- 1..5 do
          {:ok, client} =
            :ssl.connect({127, 0, 0, 1}, port, [
              :binary,
              {:active, false},
              {:verify, :verify_none}
            ])

          client
        end

      Process.sleep(200)

      # Send from each client
      for {client, i} <- Enum.with_index(clients, 1) do
        message = "INVITE sip:client#{i} SIP/2.0\r\nContent-Length: 0\r\n\r\n"
        :ok = :ssl.send(client, message)
      end

      # Should receive all messages
      for i <- 1..5 do
        expected = "INVITE sip:client#{i} SIP/2.0\r\nContent-Length: 0\r\n\r\n"
        assert_receive {:incoming_packet, %IncomingPacket{data: ^expected}}, 1000
      end

      for client <- clients, do: :ssl.close(client)
    end

    test "handles connection with body", %{port: port} do
      {:ok, client} =
        :ssl.connect({127, 0, 0, 1}, port, [
          :binary,
          {:active, false},
          {:verify, :verify_none}
        ])

      Process.sleep(100)

      body = "v=0\r\no=alice 123 456 IN IP4 127.0.0.1\r\n"
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

      :ok = :ssl.send(client, message)

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :ssl.close(client)
    end

    test "handles message split across multiple sends", %{port: port} do
      {:ok, client} =
        :ssl.connect({127, 0, 0, 1}, port, [
          :binary,
          {:active, false},
          {:verify, :verify_none}
        ])

      Process.sleep(100)

      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      # Send in chunks
      :ok = :ssl.send(client, "INVITE sip:bob SIP/2.0\r\n")
      Process.sleep(10)
      :ok = :ssl.send(client, "Content-Length: 0\r\n\r\n")

      assert_receive {:incoming_packet, %IncomingPacket{data: ^message}}, 1000

      :ssl.close(client)
    end

    test "handles multiple messages from same client", %{port: port} do
      {:ok, client} =
        :ssl.connect({127, 0, 0, 1}, port, [
          :binary,
          {:active, false},
          {:verify, :verify_none}
        ])

      Process.sleep(100)

      msg1 = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      msg2 = "ACK sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"

      :ok = :ssl.send(client, msg1)
      :ok = :ssl.send(client, msg2)

      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg1}}, 1000
      assert_receive {:incoming_packet, %IncomingPacket{data: ^msg2}}, 1000

      :ssl.close(client)
    end
  end

  describe "connection cleanup" do
    setup do
      config = %ListenerConfig{
        transport: :tls,
        port: 0,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, listener} = TlsListener.start_link(config, self())
      {:ok, {_ip, port}} = TlsListener.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "handles client disconnect gracefully", %{port: port} do
      {:ok, client} =
        :ssl.connect({127, 0, 0, 1}, port, [
          :binary,
          {:active, false},
          {:verify, :verify_none}
        ])

      Process.sleep(100)

      # Send a message
      message = "INVITE sip:bob SIP/2.0\r\nContent-Length: 0\r\n\r\n"
      :ok = :ssl.send(client, message)
      assert_receive {:incoming_packet, %IncomingPacket{}}, 1000

      # Close client
      :ssl.close(client)
      Process.sleep(50)

      # Listener should still be alive and accepting new connections
      {:ok, client2} =
        :ssl.connect({127, 0, 0, 1}, port, [
          :binary,
          {:active, false},
          {:verify, :verify_none}
        ])

      Process.sleep(100)
      :ok = :ssl.send(client2, message)
      assert_receive {:incoming_packet, %IncomingPacket{}}, 1000

      :ssl.close(client2)
    end
  end

  describe "graceful shutdown" do
    test "stops gracefully" do
      config = %ListenerConfig{
        transport: :tls,
        port: 0,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, listener} = TlsListener.start_link(config, self())

      ref = Process.monitor(listener)

      :ok = TlsListener.stop(listener)

      assert_receive {:DOWN, ^ref, :process, ^listener, _reason}, 1000
    end

    test "closes listen socket on stop" do
      config = %ListenerConfig{
        transport: :tls,
        port: 17200,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, listener} = TlsListener.start_link(config, self())

      Process.sleep(50)

      :ok = TlsListener.stop(listener)
      Process.sleep(50)

      # Should be able to bind to same port again
      assert {:ok, _listener2} = TlsListener.start_link(config, self())
    end
  end

  describe "error handling" do
    test "fails when port is already in use" do
      config = %ListenerConfig{
        transport: :tls,
        port: 17300,
        certfile: @cert_file,
        keyfile: @key_file
      }

      {:ok, _listener1} = TlsListener.start_link(config, self())

      Process.sleep(50)

      # Second listener should fail
      Process.flag(:trap_exit, true)
      result = TlsListener.start_link(config, self())

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
