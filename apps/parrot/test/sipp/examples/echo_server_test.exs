defmodule Parrot.Sipp.Examples.EchoServerTest do
  @moduledoc """
  SIPp integration tests for Parrot.Examples.EchoServer.

  Verifies that the EchoServer example correctly handles INVITE/200/ACK/BYE
  flows using the Parrot DSL layer.

  ## Running Tests

      mix test apps/parrot/test/sipp/examples/echo_server_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/examples/echo_server_test.exs --include sipp
  """

  use ExUnit.Case, async: false

  alias Parrot.Examples.EchoServer
  alias SippTest.SippRunner

  @moduletag :sipp

  # ===========================================================================
  # Test Setup and Helpers
  # ===========================================================================

  setup do
    # Start the EchoServer on a random port
    {:ok, stack} = EchoServer.start(port: 0)
    port = ParrotSip.Stack.get_port(stack)

    on_exit(fn ->
      # Stop the server (if it's still alive)
      if Process.alive?(stack) do
        EchoServer.stop(stack)
      end
    end)

    %{stack: stack, port: port}
  end

  # Get the umbrella root directory
  # From apps/parrot/test/sipp/examples/ -> 5 levels up
  defp umbrella_root do
    Path.expand("../../../../..", __DIR__)
  end

  # ===========================================================================
  # Basic Call Flow Tests
  # ===========================================================================

  describe "EchoServer DSL basic call flow" do
    @describetag :sipp

    test "INVITE -> 200 OK -> ACK -> BYE flow works with EchoServer", %{port: port} do
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

    test "multiple sequential calls work correctly with EchoServer", %{port: port} do
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
