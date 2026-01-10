defmodule ParrotSip.Integration.CDRIntegrationTest do
  @moduledoc """
  Integration tests for CDR generation with SIPp.

  These tests verify that CDRs are generated correctly for various call scenarios
  using real SIP traffic via SIPp. Tests cover:

  - T026: Answered call generates CDR with disposition :answered
  - T027: Rejected call (486 Busy) generates CDR with disposition :busy
  - T028: Cancelled call generates CDR with disposition :cancelled

  NOTE: These tests require SIPp to be installed. Run with:
    mix test --only sipp apps/parrot_sip/test/parrot_sip/integration/cdr_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}
  alias ParrotSip.CDR

  @moduletag :sipp

  # Test CDR handler that collects CDRs and sends them to the test process
  defmodule TestCDRHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    require Logger

    @impl true
    def init(test_pid) do
      Logger.debug("[TestCDRHandler] Initialized with test_pid: #{inspect(test_pid)}")
      {:ok, test_pid}
    end

    @impl true
    def handle_cdr(cdr, test_pid) do
      Logger.debug("[TestCDRHandler] Received CDR: #{inspect(cdr.call_id)}")
      send(test_pid, {:cdr_received, cdr})
      :ok
    end
  end

  describe "CDR generation integration" do
    setup do
      # Clear any existing handlers before each test
      CDR.clear_handlers()

      # Register test CDR handler that forwards to test process
      :ok = CDR.register_handler(TestCDRHandler, self())

      on_exit(fn ->
        CDR.unregister_handler(TestCDRHandler)
        CDR.clear_handlers()
      end)

      :ok
    end

    @tag :cdr
    test "T026: answered call generates CDR with disposition :answered" do
      # Create SIP handler that answers calls (200 OK by default)
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp UAC INVITE scenario (full call flow with BYE)
      # Note: This scenario has a 5-second pause, needs longer timeout
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      # Wait for CDR to be generated and dispatched
      # The CDR is generated when the dialog terminates (after BYE)
      assert_receive {:cdr_received, cdr}, 10_000

      # Verify CDR fields for answered call
      assert cdr.disposition == :answered,
             "Expected disposition :answered, got #{inspect(cdr.disposition)}"

      assert cdr.talk_duration_ms > 0,
             "Talk duration should be > 0 for answered calls"

      assert cdr.answered_at != nil,
             "answered_at should be set for answered calls"

      assert cdr.invite_received_at != nil,
             "invite_received_at should always be set"

      assert cdr.ended_at != nil,
             "ended_at should always be set"

      assert cdr.call_id != nil,
             "call_id should be set"

      assert cdr.caller_uri != nil,
             "caller_uri should be set"

      assert cdr.callee_uri != nil,
             "callee_uri should be set"

      # For BYE termination
      assert cdr.termination_cause.method == :bye,
             "Termination method should be :bye"

      assert cdr.direction == :inbound,
             "Direction should be :inbound for UAS"

      # Cleanup
      SipStackHelper.stop(stack)
    end

    # T027: PENDING - Requires transaction-level CDR generation for rejected calls
    #
    # Per spec FR-001, CDRs should be generated for all call attempts including rejections.
    # However, the current architecture only generates CDRs for established dialogs.
    # A 486 Busy response does not create a dialog (only 2xx responses or provisional
    # responses with To-tag create dialogs), so no CDR is generated.
    #
    # TODO: To support CDR generation for rejected calls, implement one of:
    # 1. Transaction-level CDR generation (tracks INVITE transactions regardless of dialog)
    # 2. Synthetic CDR creation in the handler when rejecting with 4xx/5xx/6xx
    @tag :cdr
    @tag skip: "Requires transaction-level CDR generation for rejected calls (see FR-001)"
    test "T027: rejected call (486 Busy) generates CDR with disposition :busy" do
      # Create SIP handler that responds with 486 Busy Here
      handler = TestHandler.new(invite_response: {486, "Busy Here"})

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # For a rejected call, we need a different approach:
      # The standard uac_invite.xml expects 200 OK and will fail with 486
      # For rejected calls before dialog establishment, CDRs may not be generated
      # since dialogs are only created for successful responses (2xx) or early dialogs (1xx with To-tag)

      # Run SIPp scenario - it will get 486 and should handle the rejection
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 5_000
        )

      # SIPp will fail because the scenario expects 200 OK but gets 486
      # This is expected behavior for this test
      case result do
        :ok ->
          # If somehow it succeeded, check for CDR
          :ok

        {:error, {:sipp_failed, _status, _output}} ->
          # Expected - SIPp failed because it got 486 instead of 200
          :ok
      end

      # For pre-dialog rejection (486 without To-tag), a CDR may or may not be generated
      # depending on implementation. Early rejection typically doesn't create a dialog.
      # Check if we received a CDR - this tests the implementation behavior
      receive do
        {:cdr_received, cdr} ->
          # If a CDR was generated, verify it has correct disposition
          assert cdr.disposition == :busy,
                 "Expected disposition :busy, got #{inspect(cdr.disposition)}"

          assert cdr.answered_at == nil,
                 "answered_at should be nil for rejected calls"

          assert cdr.talk_duration_ms == 0,
                 "talk_duration_ms should be 0 for unanswered calls"
      after
        2_000 ->
          # Known architectural limitation: CDRs only generated for established dialogs.
          # Rejected calls (486) don't create dialogs, so no CDR is generated.
          flunk(
            "CDR not generated - requires transaction-level CDR generation for rejected calls (see FR-001)"
          )
      end

      # Cleanup
      SipStackHelper.stop(stack)
    end

    # T028: PENDING - Requires early dialog support or transaction-level CDR generation
    #
    # Per spec FR-001, CDRs should be generated for all call attempts including cancellations.
    # However, the current architecture only generates CDRs for established dialogs.
    #
    # For cancelled calls, we need an early dialog to be created. Per RFC 3261 Section 12.1.1,
    # early dialogs require a To-tag in provisional responses. Currently, Transaction.Server
    # only adds To-tags for 2xx responses, so 180 Ringing doesn't create a dialog.
    #
    # TODO: To support CDR generation for cancelled calls, implement one of:
    # 1. Early dialog support (add To-tag to provisional responses per RFC 3261 Section 12.1.1)
    # 2. Transaction-level CDR generation (tracks INVITE transactions regardless of dialog)
    @tag :cdr
    @tag skip: "Requires early dialog support or transaction-level CDR generation (see FR-001)"
    test "T028: cancelled call generates CDR with disposition :cancelled" do
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
                 timeout: 10_000
               )

      # Check if a CDR was generated
      # Current behavior: No CDR is generated because no early dialog is created
      # (180 Ringing without To-tag doesn't create a dialog)
      receive do
        {:cdr_received, cdr} ->
          # If CDR IS received (e.g., if implementation changes to support early dialogs),
          # verify it has the correct disposition
          assert cdr.disposition == :cancelled,
                 "Expected disposition :cancelled, got #{inspect(cdr.disposition)}"

          assert cdr.answered_at == nil,
                 "answered_at should be nil for cancelled calls"

          assert cdr.talk_duration_ms == 0,
                 "talk_duration_ms should be 0 for cancelled calls"

          assert cdr.invite_received_at != nil,
                 "invite_received_at should be set"

          assert cdr.ended_at != nil,
                 "ended_at should be set"

          assert cdr.termination_cause.sip_code == 487,
                 "SIP code should be 487 (Request Terminated) for cancelled calls"

          assert cdr.termination_cause.method == :cancel,
                 "Termination method should be :cancel"

          assert cdr.ring_duration_ms >= 0,
                 "ring_duration_ms should be >= 0"
      after
        2_000 ->
          # Known architectural limitation: CDRs only generated for established dialogs.
          # Cancelled calls require early dialogs (To-tag in 1xx) which aren't currently
          # created by Transaction.Server.
          flunk(
            "CDR not generated - requires early dialog support or transaction-level CDR generation (see FR-001)"
          )
      end

      # Cleanup
      SipStackHelper.stop(stack)
    end

    @tag :cdr
    test "multiple calls generate separate CDRs" do
      # Create SIP handler that answers calls
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run 3 sequential calls
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 3,
                 timeout: 30_000
               )

      # Collect all CDRs
      cdrs =
        Enum.reduce_while(1..10, [], fn _, acc ->
          receive do
            {:cdr_received, cdr} ->
              new_acc = [cdr | acc]

              if length(new_acc) >= 3 do
                {:halt, new_acc}
              else
                {:cont, new_acc}
              end
          after
            5_000 ->
              {:halt, acc}
          end
        end)

      # Verify we got 3 CDRs
      assert length(cdrs) == 3, "Expected 3 CDRs, got #{length(cdrs)}"

      # Each CDR should have a unique call_id
      call_ids = Enum.map(cdrs, & &1.call_id) |> Enum.uniq()
      assert length(call_ids) == 3, "CDRs should have unique call_ids"

      # All should be answered
      assert Enum.all?(cdrs, &(&1.disposition == :answered)),
             "All CDRs should have disposition :answered"

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end

  describe "CDR timing accuracy" do
    setup do
      CDR.clear_handlers()
      :ok = CDR.register_handler(TestCDRHandler, self())

      on_exit(fn ->
        CDR.unregister_handler(TestCDRHandler)
        CDR.clear_handlers()
      end)

      :ok
    end

    @tag :cdr
    test "ring and talk durations are calculated correctly" do
      # Create SIP handler that answers calls
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run scenario (has 5-second pause during call)
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 15_000
               )

      # Wait for CDR
      assert_receive {:cdr_received, cdr}, 10_000

      # Verify timing relationships
      assert cdr.invite_received_at != nil
      assert cdr.answered_at != nil
      assert cdr.ended_at != nil

      # Ring duration should be positive (time from INVITE to 200 OK)
      assert cdr.ring_duration_ms >= 0,
             "Ring duration should be >= 0, got #{cdr.ring_duration_ms}"

      # Talk duration should be approximately 5 seconds (the pause in scenario)
      # Allow some tolerance for processing time
      # The scenario has a 5000ms pause
      assert cdr.talk_duration_ms >= 4_500,
             "Talk duration should be >= 4500ms (scenario has 5s pause), got #{cdr.talk_duration_ms}"

      assert cdr.talk_duration_ms <= 7_000,
             "Talk duration should be <= 7000ms, got #{cdr.talk_duration_ms}"

      # Verify timestamps are in correct order
      assert DateTime.compare(cdr.invite_received_at, cdr.answered_at) in [:lt, :eq],
             "invite_received_at should be <= answered_at"

      assert DateTime.compare(cdr.answered_at, cdr.ended_at) in [:lt, :eq],
             "answered_at should be <= ended_at"

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end
end
