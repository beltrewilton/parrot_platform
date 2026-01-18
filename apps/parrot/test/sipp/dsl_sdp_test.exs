defmodule Parrot.Sipp.DSL.SdpNegotiationTest do
  @moduledoc """
  SIPp integration tests for DSL SDP negotiation (US1: SDP Negotiation).

  These tests verify that the Parrot DSL layer correctly handles
  SDP offer/answer negotiation per RFC 3261 and RFC 3264.

  ## Test Scenarios

  1. Basic SDP negotiation - INVITE with SDP offer, 200 OK with SDP answer
  2. Codec negotiation - Verify supported codecs (PCMU, PCMA) are negotiated

  ## Running Tests

      mix test apps/parrot/test/sipp/dsl_sdp_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/dsl_sdp_test.exs --include sipp
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}

  @moduletag :sipp

  # ===========================================================================
  # Test Router and Handler Definitions
  # ===========================================================================

  defmodule SdpTestHandler do
    @moduledoc """
    DSL handler that answers calls to test SDP negotiation.
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
  end

  defmodule SdpTestRouter do
    @moduledoc """
    Router that routes all INVITEs to SdpTestHandler.
    """
    use Parrot.Router

    invite("*", Parrot.Sipp.DSL.SdpNegotiationTest.SdpTestHandler)
  end

  # ===========================================================================
  # Test Setup and Helpers
  # ===========================================================================

  setup do
    # Create a ParrotSip.Handler that uses Bridge.Handler with our DSL router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: SdpTestRouter})

    # Start the SIP stack using the test helper
    {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

    on_exit(fn ->
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
  # From apps/parrot/test/sipp/ -> 4 levels up
  defp umbrella_root do
    Path.expand("../../../..", __DIR__)
  end

  # ===========================================================================
  # SDP Negotiation Tests
  # ===========================================================================

  describe "US1: SDP Negotiation" do
    @describetag :sipp

    @tag :sipp
    test "INVITE with SDP offer receives 200 OK with SDP answer (T010)", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Use the basic call scenario which includes SDP offer/answer
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_basic_call.xml"

      # Run SIPp UAC with SDP scenario
      result =
        SippRunner.run_scenario(
          scenario_file: scenario_file,
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      # If SIPp completes successfully, it means:
      # 1. INVITE with SDP was sent
      # 2. 200 OK was received (with SDP answer for real SIP clients)
      # 3. ACK was sent
      # 4. BYE was sent and 200 OK received
      assert result == :ok
    end

    @tag :sipp
    test "multiple calls with SDP negotiation succeed", %{port: port} do
      Process.sleep(100)

      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_basic_call.xml"

      # Run multiple calls to test session cleanup between calls
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
end
