defmodule ParrotMedia.ForkSinkTest do
  use ExUnit.Case, async: true

  alias ParrotMedia.ForkSink

  describe "struct options" do
    test "defines required options" do
      # ForkSink should require destination_address and destination_port
      sink = %ForkSink{
        destination_address: {192, 168, 1, 100},
        destination_port: 5000
      }

      assert sink.destination_address == {192, 168, 1, 100}
      assert sink.destination_port == 5000
    end

    test "accepts string IP address" do
      sink = %ForkSink{
        destination_address: "10.0.0.1",
        destination_port: 6000
      }

      assert sink.destination_address == "10.0.0.1"
      assert sink.destination_port == 6000
    end

    test "has optional fork_id field" do
      sink = %ForkSink{
        destination_address: {192, 168, 1, 100},
        destination_port: 5000,
        fork_id: "fork_1"
      }

      assert sink.fork_id == "fork_1"
    end
  end

  describe "buffer handling" do
    test "ForkSink is a valid Membrane Sink" do
      # Verify the module uses Membrane.Sink
      assert function_exported?(ForkSink, :handle_init, 2)
      assert function_exported?(ForkSink, :handle_buffer, 4)
    end
  end
end
