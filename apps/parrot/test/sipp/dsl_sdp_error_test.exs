defmodule Parrot.Sipp.DSL.SdpErrorTest do
  @moduledoc """
  SIPp integration tests for DSL SDP error handling (US3: SDP Negotiation Failure Handling).

  These tests verify that the Parrot DSL layer correctly handles SDP negotiation
  failures by returning 488 Not Acceptable Here per RFC 3261 and RFC 3264.

  ## Test Scenarios

  1. T031: Codec mismatch - INVITE with unsupported codec receives 488 response

  ## Running Tests

      mix test apps/parrot/test/sipp/dsl_sdp_error_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/dsl_sdp_error_test.exs --include sipp

  ## Requirements Covered

  - FR-009: InviteHandler behavior MUST define optional callback handle_sdp_error/2
  - FR-012: System MUST automatically send 488 Not Acceptable Here when SDP negotiation fails
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}

  @moduletag :sipp

  # ===========================================================================
  # Test Router and Handler Definitions
  # ===========================================================================

  defmodule SdpErrorTestHandler do
    @moduledoc """
    DSL handler that answers calls normally.
    When SDP negotiation fails, the default handle_sdp_error/2 will reject with 488.
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      call
      |> answer()
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end

    # Uses default handle_sdp_error/2 which rejects with 488 Not Acceptable Here
  end

  defmodule CustomSdpErrorHandler do
    @moduledoc """
    DSL handler that overrides handle_sdp_error/2 to track the callback invocation.
    Still rejects with 488 but also stores the error reason in assigns.
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      call
      |> answer()
    end

    @impl true
    def handle_sdp_error(reason, call) do
      # Track that we received the error callback by sending to test process
      if test_pid = Application.get_env(:parrot, :sdp_error_test_pid) do
        send(test_pid, {:sdp_error, reason})
      end

      # Still reject with 488
      call |> reject(488)
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end
  end

  defmodule SdpErrorTestRouter do
    @moduledoc """
    Router that routes all INVITEs to SdpErrorTestHandler.
    """
    use Parrot.Router

    invite("*", Parrot.Sipp.DSL.SdpErrorTest.SdpErrorTestHandler)
  end

  defmodule CustomSdpErrorRouter do
    @moduledoc """
    Router that routes all INVITEs to CustomSdpErrorHandler.
    """
    use Parrot.Router

    invite("*", Parrot.Sipp.DSL.SdpErrorTest.CustomSdpErrorHandler)
  end

  # ===========================================================================
  # Test Setup and Helpers
  # ===========================================================================

  setup do
    # Create a ParrotSip.Handler that uses Bridge.Handler with our DSL router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: SdpErrorTestRouter})

    # Start the SIP stack using the test helper
    {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

    on_exit(fn ->
      # Clean up test environment variable
      Application.delete_env(:parrot, :sdp_error_test_pid)

      # Stop transport listener first (if it's still alive)
      if Process.alive?(stack.transport_listener) do
        ParrotTransport.stop_listener(stack.transport_listener)
      end

      # Stop bridge process (if it's still alive)
      if Process.alive?(stack.transport_handler) do
        GenServer.stop(stack.transport_handler)
      end
    end)

    %{stack: stack, port: stack.port}
  end

  # Get the umbrella root directory
  # From apps/parrot/test/sipp/ -> 4 levels up to parrot_platform/
  defp umbrella_root do
    Path.expand("../../../..", __DIR__)
  end

  # ===========================================================================
  # SDP Error Handling Tests (US3)
  # ===========================================================================

  describe "US3: SDP Negotiation Failure Handling" do
    @describetag :sipp

    # Tests for FR-012: System MUST automatically send 488 Not Acceptable Here
    # when SDP negotiation fails due to no common codec.
    #
    # The DSL.MediaHandler.handle_codec_negotiation/3 checks offered codecs
    # against @supported_codecs (pcma, opus) and returns
    # {:error, :no_common_codec} when no match is found.

    @tag :sipp
    @tag timeout: 15_000
    test "INVITE with unsupported codec receives 488 Not Acceptable Here (T031, FR-012)", %{
      port: port
    } do
      # Test FR-012: When caller offers only G.729 (which we don't support),
      # the system should reject with 488 Not Acceptable Here.
      # Give the stack time to fully start
      Process.sleep(100)

      # Use the codec mismatch scenario which expects 488 response
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/error/uac_invite_codec_mismatch.xml"

      # Verify scenario file exists
      assert File.exists?(scenario_file),
             "Scenario file not found: #{scenario_file}"

      # Run SIPp UAC with unsupported codec
      # SIPp should succeed (exit 0) when it receives expected 488 response
      result =
        SippRunner.run_scenario(
          scenario_file: scenario_file,
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      # If SIPp completes successfully, it means:
      # 1. INVITE with unsupported codec (G.729) was sent
      # 2. 488 Not Acceptable Here was received
      # 3. ACK was sent to complete the transaction
      assert result == :ok
    end

    @tag :sipp
    @tag timeout: 30_000
    test "multiple calls with codec mismatch all receive 488 (T031)", %{port: port} do
      # Test that multiple consecutive calls with unsupported codecs
      # all receive proper 488 rejection (no state leakage between calls).
      # Give the stack time to fully start
      Process.sleep(100)

      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/error/uac_invite_codec_mismatch.xml"

      # Run multiple calls with unsupported codec
      result =
        SippRunner.run_scenario(
          scenario_file: scenario_file,
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 3,
          timeout: 30_000
        )

      assert result == :ok
    end
  end

  describe "handle_sdp_error callback invocation via SIPp" do
    @describetag :sipp

    @tag :sipp
    @tag :skip
    test "handle_sdp_error/2 callback is invoked on codec mismatch", %{stack: _stack, port: _port} do
      # Note: This test is marked skip because it requires stopping and restarting
      # the stack with a different router, which is complex in the current setup.
      # The callback invocation is already tested in handler_test.exs (T034, T035).
      # This test documents the integration testing approach for future enhancement.

      # To fully test this:
      # 1. Start stack with CustomSdpErrorRouter
      # 2. Set Application.put_env(:parrot, :sdp_error_test_pid, self())
      # 3. Run SIPp scenario
      # 4. Assert_receive {:sdp_error, reason}

      # The unit tests in handler_test.exs already verify:
      # - T034: handle_sdp_error/2 is invoked when SDP negotiation fails
      # - T035: Default implementation rejects with 488
      # - T036: Auto-reject when handler returns {:noreply, call}
    end
  end
end
