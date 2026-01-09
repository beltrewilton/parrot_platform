defmodule Parrot.Sipp.DSL.SimpleIVRTest do
  @moduledoc """
  SIPp integration tests for Parrot.Examples.SimpleIVR.

  Tests that SimpleIVR correctly uses the Parrot DSL layer to handle
  INVITE/200 OK/ACK/BYE flows using real SIP traffic via SIPp.

  ## Running Tests

      mix test apps/parrot/test/sipp/dsl_scenarios/simple_ivr_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/dsl_scenarios/simple_ivr_test.exs --include sipp
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}
  alias Parrot.Examples.SimpleIVR

  @moduletag :sipp

  # ===========================================================================
  # Test Setup and Helpers
  # ===========================================================================

  setup do
    # Create a ParrotSip.Handler that uses Bridge.Handler with SimpleIVR's router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: SimpleIVR.Router})

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
  # Simple IVR Tests
  # ===========================================================================

  describe "SimpleIVR DSL handler" do
    @describetag :sipp

    test "handles basic INVITE -> 200 OK -> ACK -> BYE flow", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Get absolute path to scenario file
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_basic_call.xml"

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

    test "handler module uses InviteHandler behaviour" do
      # Verify the module uses the correct behaviour
      behaviours = SimpleIVR.Handler.module_info(:attributes)[:behaviour] || []
      assert Parrot.InviteHandler in behaviours
    end

    test "router module uses Router DSL" do
      # Verify the router has routes defined
      routes = SimpleIVR.Router.__routes__()
      assert length(routes) > 0

      # First route should be a catch-all for INVITE
      [first_route | _] = routes
      assert first_route.pattern == "*"
      assert first_route.handler == SimpleIVR.Handler
    end
  end
end
