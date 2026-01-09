defmodule Parrot.Sipp.DSL.BasicAnswerTest do
  @moduledoc """
  SIPp integration tests for Parrot DSL layer.

  These tests verify that the Parrot DSL layer correctly handles
  INVITE/200 OK/ACK/BYE flows using real SIP traffic via SIPp.

  Unlike the tests in parrot_sip/test/sipp/dsl_test.exs which use
  SippTest.TestHandler (a low-level ParrotSip.Handler), these tests
  use the actual Parrot DSL stack with InviteHandler, Router, and
  Bridge.Handler.

  ## Running Tests

      mix test apps/parrot/test/sipp/dsl_scenarios/basic_answer_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/dsl_scenarios/basic_answer_test.exs --include sipp
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}

  @moduletag :sipp

  # ===========================================================================
  # Test Router and Handler Definitions
  # ===========================================================================

  defmodule TestHandler do
    @moduledoc """
    Simple DSL handler that answers all calls.
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

  defmodule TestRouter do
    @moduledoc """
    Router that routes all INVITEs to TestHandler.
    """
    use Parrot.Router

    invite "*", Parrot.Sipp.DSL.BasicAnswerTest.TestHandler
  end

  # ===========================================================================
  # Test Setup and Helpers
  # ===========================================================================

  setup do
    # Create a ParrotSip.Handler that uses Bridge.Handler with our DSL router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestRouter})

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
  # From apps/parrot/test/sipp/dsl_scenarios/ -> 5 levels up
  defp umbrella_root do
    Path.expand("../../../../..", __DIR__)
  end

  # ===========================================================================
  # Basic Call Flow Tests
  # ===========================================================================

  describe "DSL basic call flow" do
    @describetag :sipp

    test "INVITE -> 200 OK -> ACK -> BYE flow works with DSL handler", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Get absolute path to scenario file
      scenario_file = umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_basic_call.xml"

      # Run SIPp UAC basic call scenario
      result =
        SippRunner.run_scenario(
          scenario_file: scenario_file,
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    test "multiple sequential calls work correctly with DSL", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Get absolute path to scenario file
      scenario_file = umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_basic_call.xml"

      # Run multiple calls sequentially
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
