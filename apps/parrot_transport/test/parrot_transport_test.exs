defmodule ParrotTransportTest do
  use ExUnit.Case, async: false

  alias ParrotTransport
  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}

  describe "UDP listener lifecycle" do
    test "starts UDP listener and returns listener pid" do
      config = %ListenerConfig{transport: :udp, port: 0}
      assert {:ok, pid} = ParrotTransport.start_listener(config)
      assert Process.alive?(pid)
    end

    test "stops UDP listener" do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, pid} = ParrotTransport.start_listener(config)

      assert :ok = ParrotTransport.stop_listener(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "gets local address from UDP listener" do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, pid} = ParrotTransport.start_listener(config)

      assert {:ok, {_ip, port}} = ParrotTransport.get_local_address(pid)
      assert port > 0
    end
  end

  describe "UDP packet handling" do
    setup do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, listener} = ParrotTransport.start_listener(config)
      {:ok, {_ip, port}} = ParrotTransport.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "registers handler and receives packets", %{listener: listener, port: port} do
      :ok = ParrotTransport.register_handler(listener, self())

      {:ok, sender} = :gen_udp.open(0, [:binary])
      :gen_udp.send(sender, {127, 0, 0, 1}, port, "test message")

      assert_receive {:incoming_packet, %IncomingPacket{} = packet}, 1000
      assert packet.data == "test message"
      assert packet.source.transport == :udp

      :gen_udp.close(sender)
    end

    test "sends UDP data", %{listener: listener} do
      {:ok, receiver} = :gen_udp.open(15400, [:binary, {:active, false}])

      :ok = ParrotTransport.send_data(listener, "outbound data", {{127, 0, 0, 1}, 15400})

      assert {:ok, {_addr, _port, "outbound data"}} = :gen_udp.recv(receiver, 0, 1000)

      :gen_udp.close(receiver)
    end
  end

  describe "named listeners" do
    test "starts named UDP listener" do
      config = %ListenerConfig{transport: :udp, port: 0, name: :test_udp}
      assert {:ok, _pid} = ParrotTransport.start_listener(config)

      # Can access by name
      assert {:ok, {_ip, _port}} = ParrotTransport.get_local_address(:test_udp)
    end

    test "prevents duplicate named listeners" do
      config = %ListenerConfig{transport: :udp, port: 0, name: :duplicate_test}
      assert {:ok, _pid} = ParrotTransport.start_listener(config)
      assert {:error, {:already_started, _pid}} = ParrotTransport.start_listener(config)
    end
  end

  describe "supervisor integration" do
    test "listeners are supervised" do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, pid} = ParrotTransport.start_listener(config)

      # Kill the process
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Should NOT be restarted (temporary children)
      refute Process.alive?(pid)
    end
  end

  describe "error handling" do
    test "returns error for invalid transport" do
      config = %ListenerConfig{transport: :invalid, port: 5060}
      assert {:error, :unsupported_transport} = ParrotTransport.start_listener(config)
    end

    test "returns error when port is already in use" do
      config1 = %ListenerConfig{transport: :udp, port: 15500}
      config2 = %ListenerConfig{transport: :udp, port: 15500}

      {:ok, _pid1} = ParrotTransport.start_listener(config1)
      assert {:error, :eaddrinuse} = ParrotTransport.start_listener(config2)
    end
  end
end
