defmodule SippTest.RFC2543LegacyTest do
  @moduledoc """
  Tests for RFC 2543 legacy behavior (missing branch parameters).

  RFC 3261 Section 17.2.3 specifies that when a branch parameter is missing,
  transaction matching must fall back to RFC 2543 behavior, computing the
  transaction ID from Request-URI, To tag, From tag, Call-ID, CSeq number,
  and top Via.

  This test uses a SIPp scenario that deliberately omits branch parameters
  to verify the application handles legacy devices gracefully.
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "RFC 2543 legacy mode (no branch parameters)" do
    test "multiple sequential calls without branch parameters" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run multiple calls where INVITE has branch but BYE does NOT
      # This reproduces the original bug where all BYE requests get transaction ID ":bye:2"
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_invite_bye_no_branch.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 10,
                 timeout: 60_000
               )

      # Verify stats
      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 10
      assert stats.acks == 10
      assert stats.byes == 10

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end
end
