defmodule SippTest.BasicTest do
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "basic UDP scenarios" do
    test "UAC INVITE - full call flow" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start complete SIP stack (ParrotTransport + ParrotSip)
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC INVITE scenario
      # Note: Scenario has 5-second pause, needs longer timeout
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.byes == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "UAC OPTIONS - ping/pong" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC OPTIONS scenario
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_options.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 5_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.options == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple sequential calls" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run multiple calls
      # Note: Each call has 5-second pause, needs much longer timeout for 10 calls
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
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

    test "UAC REGISTER - registration handling" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC REGISTER scenario
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_register.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 5_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.registers == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "UAC REGISTER - multiple registrations" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run multiple REGISTER requests
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_register.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 5,
                 timeout: 10_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.registers == 5

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "UAC BYE - dialog termination" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC BYE scenario (INVITE + BYE)
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_bye_only.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 5_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.byes == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end
end
