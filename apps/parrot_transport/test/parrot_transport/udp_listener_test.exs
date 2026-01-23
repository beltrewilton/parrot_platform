defmodule ParrotTransport.UdpListenerTest do
  use ExUnit.Case, async: false

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}
  alias ParrotTransport.UdpListener

  describe "lifecycle states" do
    test "starts and reaches :bound state" do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, pid} = UdpListener.start_link(config)

      # Socket binding happens synchronously in init, so state is immediately :bound
      assert :bound = :sys.get_state(pid) |> elem(0)
    end

    test "binds to specific port" do
      config = %ListenerConfig{transport: :udp, port: 15100}
      {:ok, pid} = UdpListener.start_link(config)

      # get_local_address is a sync call - no sleep needed
      assert {:ok, {_ip, 15100}} = UdpListener.get_local_address(pid)
    end

    test "binds to port 0 and gets random port" do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, pid} = UdpListener.start_link(config)

      # get_local_address is a sync call - no sleep needed
      assert {:ok, {_ip, port}} = UdpListener.get_local_address(pid)
      assert port > 0
    end
  end

  describe "packet reception" do
    setup do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, listener} = UdpListener.start_link(config)

      # Socket binding is sync in init - get_local_address confirms ready state
      {:ok, {_ip, port}} = UdpListener.get_local_address(listener)

      %{listener: listener, port: port}
    end

    test "receives UDP packets and routes to handlers", %{listener: listener, port: port} do
      :ok = UdpListener.register_handler(listener, self())

      {:ok, sender} = :gen_udp.open(0, [:binary])
      :gen_udp.send(sender, {127, 0, 0, 1}, port, "test data")

      assert_receive {:incoming_packet, %IncomingPacket{} = packet}, 1000
      assert packet.data == "test data"
      assert packet.source.transport == :udp
      assert packet.source.local_addr == {{0, 0, 0, 0}, port}

      :gen_udp.close(sender)
    end

    test "routes to multiple handlers", %{listener: listener, port: port} do
      handler1 = self()

      handler2 =
        spawn(fn ->
          receive do
            msg -> send(handler1, {:h2, msg})
          end
        end)

      :ok = UdpListener.register_handler(listener, handler1)
      :ok = UdpListener.register_handler(listener, handler2)

      {:ok, sender} = :gen_udp.open(0, [:binary])
      :gen_udp.send(sender, {127, 0, 0, 1}, port, "broadcast")

      assert_receive {:incoming_packet, _}, 1000
      assert_receive {:h2, {:incoming_packet, _}}, 1000

      :gen_udp.close(sender)
    end

    test "removes dead handlers automatically", %{listener: listener, port: port} do
      dead_handler = spawn(fn -> :ok end)
      # Wait for spawned process to exit (it just returns :ok)
      ref = Process.monitor(dead_handler)
      receive do
        {:DOWN, ^ref, :process, ^dead_handler, :normal} -> :ok
      after
        100 -> flunk("dead_handler didn't exit in time")
      end

      :ok = UdpListener.register_handler(listener, dead_handler)
      :ok = UdpListener.register_handler(listener, self())

      {:ok, sender} = :gen_udp.open(0, [:binary])
      :gen_udp.send(sender, {127, 0, 0, 1}, port, "test")

      assert_receive {:incoming_packet, _}, 1000

      # Check handlers list doesn't have dead handler
      state = :sys.get_state(listener) |> elem(1)
      assert dead_handler not in state.handlers

      :gen_udp.close(sender)
    end
  end

  describe "packet transmission" do
    setup do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, listener} = UdpListener.start_link(config)
      # get_local_address is sync call to confirm listener is ready
      {:ok, _} = UdpListener.get_local_address(listener)
      %{listener: listener}
    end

    test "sends packets successfully", %{listener: listener} do
      {:ok, receiver} = :gen_udp.open(15200, [:binary, {:active, false}])

      :ok = UdpListener.send_data(listener, "test data", {{127, 0, 0, 1}, 15200})

      assert {:ok, {_addr, _port, "test data"}} = :gen_udp.recv(receiver, 0, 1000)

      :gen_udp.close(receiver)
    end
  end

  describe "graceful shutdown" do
    test "stops gracefully" do
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, listener} = UdpListener.start_link(config)

      ref = Process.monitor(listener)

      :ok = UdpListener.stop(listener)

      assert_receive {:DOWN, ^ref, :process, ^listener, _reason}, 1000
    end

    test "can restart on same port after stop" do
      config = %ListenerConfig{transport: :udp, port: 15300}

      {:ok, listener1} = UdpListener.start_link(config)
      {:ok, _} = UdpListener.get_local_address(listener1)

      ref = Process.monitor(listener1)
      :ok = UdpListener.stop(listener1)

      # Wait for listener to fully stop before rebinding to same port
      receive do
        {:DOWN, ^ref, :process, ^listener1, _reason} -> :ok
      after
        1000 -> flunk("listener1 didn't stop in time")
      end

      assert {:ok, _listener2} = UdpListener.start_link(config)
    end
  end
end
