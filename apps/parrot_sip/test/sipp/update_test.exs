defmodule SippTest.UpdateTest do
  @moduledoc """
  Tests for SIP UPDATE method (RFC 3311).

  UPDATE is used for mid-call session modification without the three-way
  handshake required by re-INVITE. It's particularly useful for:
  - Putting calls on hold (sendonly/recvonly)
  - Resuming calls from hold (sendrecv)
  - Quick session timer refreshes
  - Changing media parameters within a dialog

  Unlike re-INVITE, UPDATE:
  - Does not require ACK (it's a non-INVITE transaction)
  - Cannot change the offer/answer role
  - Is faster for simple session modifications
  - Must be sent within an established dialog
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "UPDATE hold scenarios (RFC 3311)" do
    test "UAC sends UPDATE to put call on hold" do
      # Create SIP handler that tracks UPDATE requests
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC UPDATE hold scenario
      # Scenario: INVITE -> 200 -> ACK -> UPDATE (sendonly) -> 200 -> BYE
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/update/uac_update_hold.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 1 INVITE
      assert stats.invites == 1
      # Should have 1 ACK
      assert stats.acks == 1
      # Should have 1 UPDATE
      assert stats.updates == 1
      # Should have 1 BYE
      assert stats.byes == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple calls with UPDATE hold" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/update/uac_update_hold.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 3,
                 timeout: 15_000
               )

      Process.sleep(150)
      stats = TestHandler.get_stats(handler)

      # 3 calls with 1 INVITE, 1 UPDATE, 1 BYE each
      assert stats.invites == 3
      assert stats.acks == 3
      assert stats.updates == 3
      assert stats.byes == 3

      SipStackHelper.stop(stack)
    end
  end

  describe "UPDATE hold and resume scenarios" do
    test "UAC sends UPDATE to hold and then resume" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC UPDATE hold/resume scenario
      # Scenario: INVITE -> UPDATE (hold) -> UPDATE (resume) -> BYE
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/update/uac_update_hold_resume.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 1 INVITE
      assert stats.invites == 1
      # Should have 1 ACK
      assert stats.acks == 1
      # Should have 2 UPDATEs (hold + resume)
      assert stats.updates == 2
      # Should have 1 BYE
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "multiple calls with UPDATE hold/resume cycle" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/update/uac_update_hold_resume.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 3,
                 timeout: 20_000
               )

      Process.sleep(150)
      stats = TestHandler.get_stats(handler)

      # 3 calls × 1 INVITE each = 3 INVITEs
      assert stats.invites == 3
      assert stats.acks == 3
      # 3 calls × 2 UPDATEs each = 6 UPDATEs
      assert stats.updates == 6
      assert stats.byes == 3

      SipStackHelper.stop(stack)
    end
  end
end
