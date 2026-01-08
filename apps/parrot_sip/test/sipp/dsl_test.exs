defmodule SippTest.DSLTest do
  @moduledoc """
  Integration tests for Parrot DSL features using SIPp scenarios.

  These tests verify that the DSL operations (answer, reject, play, bridge, fork, etc.)
  work correctly with real SIP traffic via SIPp.

  ## Test Categories

  - Basic call tests: Verify fundamental call establishment and teardown
  - INFO/DTMF tests: Verify DTMF digit handling via SIP INFO method (RFC 6086)
  - Bridge tests: Verify B2BUA bridge functionality
  - Fork tests: Verify call forking to multiple destinations
  - Hold/Unhold tests: Verify re-INVITE based hold/resume
  - Registration tests: Verify REGISTER handling

  ## Running Tests

      # Run all DSL tests
      mix test test/sipp/dsl_test.exs --include sipp

      # Run with debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test test/sipp/dsl_test.exs --include sipp

      # Run specific test
      mix test test/sipp/dsl_test.exs:42 --include sipp
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "basic call scenarios" do
    test "basic INVITE -> 200 OK -> ACK -> BYE flow" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_basic_call.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have: 1 INVITE, 1 ACK, 1 BYE
      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "multiple sequential basic calls" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_basic_call.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 5,
                 timeout: 30_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # 5 calls, each with 1 INVITE, 1 ACK, 1 BYE
      assert stats.invites == 5
      assert stats.acks == 5
      assert stats.byes == 5

      SipStackHelper.stop(stack)
    end
  end

  describe "INFO/DTMF scenarios" do
    test "UAC sends DTMF digits via INFO method (RFC 6086)" do
      # Create SIP handler that tracks INFO messages
      handler = TestHandler.new()

      # Start complete SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC INFO/DTMF scenario
      # Scenario: INVITE -> ACK -> INFO(1) -> INFO(5) -> INFO(#) -> BYE
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_info_dtmf.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have received: 1 INVITE, 1 ACK, 3 INFOs, 1 BYE
      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.infos == 3
      assert stats.byes == 1

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple calls with DTMF" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_info_dtmf.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 3,
                 timeout: 30_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # 3 calls, each with 1 INVITE, 3 INFOs, 1 BYE
      assert stats.invites == 3
      assert stats.infos == 9
      assert stats.byes == 3

      SipStackHelper.stop(stack)
    end
  end

  describe "play with DTMF response scenarios" do
    test "IVR-style call with DTMF navigation" do
      # Create handler that tracks INFO messages for DTMF
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run scenario that simulates IVR navigation
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_play_dtmf.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have: 1 INVITE, 1 ACK, 3 INFOs (digits 1, 2, *), 1 BYE
      assert stats.invites == 1
      assert stats.acks == 1
      assert stats.infos == 3
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end
  end

  describe "hold/unhold scenarios" do
    test "UAC sends re-INVITE to hold and unhold" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run scenario: INVITE -> re-INVITE(hold) -> re-INVITE(unhold) -> BYE
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_hold_unhold.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have 3 INVITEs (initial + hold + unhold), 3 ACKs, 1 BYE
      assert stats.invites == 3
      assert stats.acks == 3
      assert stats.byes == 1

      SipStackHelper.stop(stack)
    end

    test "multiple hold/unhold cycles" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_hold_unhold.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 3,
                 timeout: 30_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # 3 calls x 3 INVITEs each = 9 INVITEs
      assert stats.invites == 9
      assert stats.acks == 9
      assert stats.byes == 3

      SipStackHelper.stop(stack)
    end
  end

  describe "bridge scenarios" do
    @tag :skip
    @tag :b2bua
    test "B2BUA bridges A-leg to B-leg" do
      # Note: This test requires B2BUA functionality to be implemented.
      # It demonstrates the intended test pattern for bridge testing.
      #
      # Port management for B2BUA tests:
      # - ParrotSip B2BUA listens on b2bua_port
      # - SIPp UAC (A-leg) connects to B2BUA
      # - SIPp UAS (B-leg) listens on bleg_port
      # - B2BUA bridges A-leg to B-leg

      # Random ports to avoid conflicts
      b2bua_port = Enum.random(20_000..25_000)
      bleg_port = Enum.random(25_001..30_000)

      # TODO: When B2BUA is implemented, configure handler with bridge target
      _handler =
        TestHandler.new(bridge_target: "sip:bleg@127.0.0.1:#{bleg_port}")

      # TODO: Start B2BUA stack on b2bua_port
      # {:ok, b2bua_stack} = SipStackHelper.start_b2bua(handler, port: b2bua_port)

      # Start B-leg SIPp UAS in background
      # This would receive the bridged call from B2BUA
      _bleg_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/dsl/uas_bridge_bleg.xml",
            remote_host: "127.0.0.1",
            remote_port: bleg_port,
            local_port: bleg_port,
            calls: 1,
            timeout: 20_000
          )
        end)

      # Give B-leg time to start listening
      Process.sleep(500)

      # Run A-leg SIPp UAC
      # This sends INVITE to B2BUA which bridges to B-leg
      _result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/dsl/uac_bridge.xml",
          remote_host: "127.0.0.1",
          remote_port: b2bua_port,
          calls: 1,
          timeout: 20_000
        )

      # TODO: Assert both legs completed successfully
      # assert :ok == result
      # assert :ok == Task.await(bleg_task, 25_000)

      # Cleanup
      # SipStackHelper.stop(b2bua_stack)

      # For now, skip this test until B2BUA is implemented
      flunk("B2BUA not yet implemented - test demonstrates intended pattern")
    end
  end

  describe "fork scenarios" do
    @tag :skip
    @tag :b2bua
    test "Fork to multiple destinations, first answer wins" do
      # Note: This test requires fork functionality to be implemented.
      # It demonstrates the intended test pattern for fork testing.
      #
      # Port management for fork tests:
      # - ParrotSip forker listens on forker_port
      # - SIPp UAC (caller) connects to forker
      # - Multiple SIPp UAS instances (fork targets) listen on different ports
      # - Forker sends INVITEs to all targets, first to answer wins

      forker_port = Enum.random(20_000..22_000)
      target1_port = Enum.random(22_001..24_000)
      target2_port = Enum.random(24_001..26_000)

      # TODO: When fork is implemented, configure handler with fork targets
      _handler =
        TestHandler.new(
          fork_targets: [
            "sip:target1@127.0.0.1:#{target1_port}",
            "sip:target2@127.0.0.1:#{target2_port}"
          ],
          fork_strategy: :first_answer
        )

      # TODO: Start forker stack
      # {:ok, forker_stack} = SipStackHelper.start_forker(handler, port: forker_port)

      # Start fork target 1 (will answer after 1 second delay built into scenario)
      _target1_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/dsl/uas_fork_target.xml",
            remote_host: "127.0.0.1",
            remote_port: target1_port,
            local_port: target1_port,
            calls: 1,
            timeout: 20_000
          )
        end)

      # Start fork target 2
      _target2_task =
        Task.async(fn ->
          SippRunner.run_scenario(
            scenario_file: "test/sipp/scenarios/dsl/uas_fork_target.xml",
            remote_host: "127.0.0.1",
            remote_port: target2_port,
            local_port: target2_port,
            calls: 1,
            timeout: 20_000
          )
        end)

      # Give targets time to start
      Process.sleep(500)

      # Run caller UAC
      _result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/dsl/uac_fork.xml",
          remote_host: "127.0.0.1",
          remote_port: forker_port,
          calls: 1,
          timeout: 20_000
        )

      # TODO: Assert call completed (one target answered, others got CANCEL)
      # assert :ok == result

      # Cleanup
      # SipStackHelper.stop(forker_stack)

      # For now, skip this test until fork is implemented
      flunk("Fork not yet implemented - test demonstrates intended pattern")
    end
  end

  describe "registration scenarios" do
    test "basic REGISTER -> 200 OK flow" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_register.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # Should have: 1 REGISTER
      assert stats.registers == 1

      SipStackHelper.stop(stack)
    end

    test "multiple sequential registrations" do
      handler = TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/dsl/uac_register.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 5,
                 timeout: 30_000
               )

      Process.sleep(100)
      stats = TestHandler.get_stats(handler)

      # 5 registrations
      assert stats.registers == 5

      SipStackHelper.stop(stack)
    end
  end
end
