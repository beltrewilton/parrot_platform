defmodule SippTest.CancelTest do
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "CANCEL scenarios" do
    test "UAC sends CANCEL before 200 OK" do
      # Create handler with 180 Ringing response (don't send 200 OK immediately)
      handler = TestHandler.new(invite_response: {180, "Ringing"})

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC CANCEL scenario
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/cancel/uac_cancel.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 5_000
               )

      # Verify stats - should see INVITE and CANCEL
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      assert stats.invites >= 1
      assert stats.cancels >= 1
      assert stats.acks >= 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple CANCEL calls" do
      # Create handler
      handler = TestHandler.new(invite_response: {180, "Ringing"})

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run multiple CANCEL scenarios
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/cancel/uac_cancel.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 5,
                 timeout: 10_000
               )

      # Verify stats
      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      assert stats.invites >= 5
      assert stats.cancels >= 5

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end
end
