defmodule SippTest.ErrorTest do
  @moduledoc """
  SIPp integration tests for error scenarios.

  These tests verify correct error handling per RFC 3261:
  - 481 Call/Transaction Does Not Exist for BYE to non-existent dialog
  - Other error response codes for various failure conditions
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp

  describe "481 Call/Transaction Does Not Exist" do
    test "BYE for non-existent dialog returns 481" do
      # Create SIP handler with default responses
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp scenario that sends BYE with fabricated dialog identifiers
      # RFC 3261 Section 15.1.2: A BYE for a non-existent dialog MUST receive 481
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/error/uac_bye_no_dialog.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 1,
                 timeout: 5_000
               )

      # Cleanup
      SipStackHelper.stop(stack)
    end

    test "multiple BYE requests for non-existent dialogs all return 481" do
      # Create SIP handler
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run multiple calls - each should receive 481
      assert :ok ==
               SippRunner.run_scenario(
                 scenario_file: "test/sipp/scenarios/error/uac_bye_no_dialog.xml",
                 remote_host: "127.0.0.1",
                 remote_port: stack.port,
                 calls: 5,
                 timeout: 10_000
               )

      # Cleanup
      SipStackHelper.stop(stack)
    end
  end
end
