defmodule SippTest.ReinviteTest do
  @moduledoc """
  Tests for re-INVITE scenarios.

  Re-INVITE is used for session modification within an established dialog:
  - Putting calls on hold (sendonly/recvonly)
  - Resuming calls from hold (sendrecv)
  - Changing codecs
  - Changing IP addresses or ports
  - Adding/removing media streams

  These tests verify that the ParrotSip library correctly handles
  multiple INVITE requests within the same dialog, maintaining proper
  dialog state and transaction handling.
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "re-INVITE hold scenarios" do
    test "UAC sends re-INVITE to put call on hold (sendonly)" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC re-INVITE hold scenario
      # Scenario: INVITE -> 200 -> ACK -> re-INVITE (sendonly) -> 200 -> ACK -> BYE
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_hold.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 2 INVITEs (initial + re-INVITE)
      assert stats.invites == 2
      # Should have 2 ACKs (one for each INVITE response)
      assert stats.acks == 2
      # Should have 1 BYE
      assert stats.byes == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple calls with hold" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run multiple calls that include hold
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_hold.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 5,
                 timeout: 30_000
               )

      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      # 5 calls × 2 INVITEs each = 10 INVITEs
      assert stats.invites == 10
      assert stats.acks == 10
      assert stats.byes == 5

      SipStackHelper.stop(stack)
    end
  end

  describe "re-INVITE hold and resume scenarios" do
    test "UAC sends re-INVITE to hold and then resume" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC re-INVITE hold/resume scenario
      # Scenario: INVITE -> re-INVITE (hold) -> re-INVITE (resume) -> BYE
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_resume.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 3 INVITEs (initial + hold + resume)
      assert stats.invites == 3
      assert stats.acks == 3
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "multiple calls with hold/resume cycle" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_resume.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 3,
                 timeout: 15_000
               )

      Process.sleep(150)
      stats = TestHandler.get_stats(handler)

      # 3 calls × 3 INVITEs each = 9 INVITEs
      assert stats.invites == 9
      assert stats.acks == 9
      assert stats.byes == 3

      SipStackHelper.stop(stack)
    end
  end

  describe "re-INVITE codec change scenarios" do
    test "UAC sends re-INVITE to change codec" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC re-INVITE codec change scenario
      # Initial INVITE has PCMU+PCMA, re-INVITE has only PCMA
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_codec_change.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 2 INVITEs (initial + codec change)
      assert stats.invites == 2
      assert stats.acks == 2
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "multiple calls with codec changes" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_codec_change.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 5,
                 timeout: 30_000
               )

      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 10
      assert stats.acks == 10
      assert stats.byes == 5

      SipStackHelper.stop(stack)
    end
  end

  describe "multiple sequential re-INVITEs" do
    test "UAC sends multiple re-INVITEs in same dialog" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run scenario with 4 re-INVITEs: hold -> resume -> codec change -> hold again
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_multiple.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 5 INVITEs (initial + 4 re-INVITEs)
      assert stats.invites == 5
      assert stats.acks == 5
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "stress test - many re-INVITEs in single call" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # This stress tests transaction handling and dialog state management
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_multiple.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 3,
                 timeout: 20_000
               )

      Process.sleep(200)
      stats = TestHandler.get_stats(handler)

      # 3 calls × 5 INVITEs each = 15 INVITEs
      assert stats.invites == 15
      assert stats.acks == 15
      assert stats.byes == 3

      SipStackHelper.stop(stack)
    end
  end

  describe "re-INVITE edge cases" do
    test "re-INVITE with no SDP (offer/answer reversal)" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Per RFC 3264 Section 8: re-INVITE without SDP asks UAS to generate offer
      # Flow: INVITE(SDP) -> re-INVITE(no SDP) -> 200(SDP offer) -> ACK(SDP answer)
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_no_sdp.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 2 INVITEs (initial + re-INVITE without SDP)
      assert stats.invites == 2
      assert stats.acks == 2
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "re-INVITE timeout and retransmission" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Tests SIP transaction layer retransmission per RFC 3261 Section 17.1.1
      # The library should properly handle retransmissions if response is delayed
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/reinvite/uac_reinvite_timeout.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 10_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 2 INVITEs (initial + re-INVITE with timeout test)
      assert stats.invites == 2
      assert stats.acks == 2
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end
  end
end
