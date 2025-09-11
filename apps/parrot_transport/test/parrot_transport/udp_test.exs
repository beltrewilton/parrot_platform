defmodule ParrotTransport.UdpTest do
  use ExUnit.Case, async: true
  
  describe "UDP listener" do
    test "starts and binds to specified port" do
      {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15060)
      assert Process.alive?(transport)
      
      # Verify port is actually bound
      {:ok, {_ip, port}} = ParrotTransport.get_local_address(transport)
      assert port == 15060
      
      # Cleanup
      ParrotTransport.Udp.stop(transport)
    end
    
    test "routes packets to registered handlers" do
      {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15061)
      test_pid = self()
      
      ParrotTransport.register_handler(transport, test_pid)
      
      # Send test packet
      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, {127, 0, 0, 1}, 15061, "test data")
      
      assert_receive {:packet_received, "test data", _source, _metadata}, 1000
      
      # Cleanup
      :gen_udp.close(socket)
      ParrotTransport.Udp.stop(transport)
    end
    
    test "handles multiple simultaneous connections" do
      {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15062)
      test_pid = self()
      
      ParrotTransport.register_handler(transport, test_pid)
      
      # Send multiple packets from different ports
      sockets = for i <- 1..5 do
        {:ok, socket} = :gen_udp.open(0)
        :gen_udp.send(socket, {127, 0, 0, 1}, 15062, "packet #{i}")
        socket
      end
      
      # Should receive all packets
      for i <- 1..5 do
        assert_receive {:packet_received, "packet " <> _, _source, _metadata}, 1000
      end
      
      # Cleanup
      Enum.each(sockets, &:gen_udp.close/1)
      ParrotTransport.Udp.stop(transport)
    end
    
    test "unregisters handlers correctly" do
      {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15063)
      test_pid = self()
      
      ParrotTransport.register_handler(transport, test_pid)
      ParrotTransport.unregister_handler(transport, test_pid)
      
      # Send test packet
      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, {127, 0, 0, 1}, 15063, "test data")
      
      # Should not receive packet after unregistering
      refute_receive {:packet_received, _, _, _}, 100
      
      # Cleanup
      :gen_udp.close(socket)
      ParrotTransport.Udp.stop(transport)
    end
  end
  
  describe "UDP sending" do
    test "sends packets to remote endpoints" do
      # Start listener to receive the packet
      {:ok, receiver_socket} = :gen_udp.open(15064, [:binary, {:active, true}])
      
      # Start transport
      {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15065)
      
      # Send packet
      ParrotTransport.send_packet(transport, "hello world", {{127, 0, 0, 1}, 15064})
      
      # Should receive the packet
      assert_receive {:udp, _, _, _, "hello world"}, 1000
      
      # Cleanup
      :gen_udp.close(receiver_socket)
      ParrotTransport.Udp.stop(transport)
    end
  end
end