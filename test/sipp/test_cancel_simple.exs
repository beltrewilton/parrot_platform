Code.require_file("support/sipp_runner.ex", __DIR__)
Code.require_file("support/test_handler.ex", __DIR__)
Code.require_file("support/sip_stack_helper.ex", __DIR__)

defmodule SippTest.CancelSimpleTest do
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "CANCEL with hardcoded branch" do
    test "UAC sends CANCEL with same branch as INVITE" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp with hardcoded branch scenario
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "/tmp/simple_cancel_test.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 5000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 1
      assert stats.cancels == 1
      assert stats.acks == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end
end
