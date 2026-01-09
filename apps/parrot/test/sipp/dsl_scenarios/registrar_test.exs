defmodule Parrot.Sipp.DSL.RegistrarTest do
  @moduledoc """
  SIPp integration tests for DSL-based registrar.

  Tests that the Parrot.Examples.Registrar module correctly handles
  REGISTER requests using the DSL layer (Parrot.RegistrationHandler +
  Parrot.Router).

  ## Running Tests

      mix test apps/parrot/test/sipp/dsl_scenarios/registrar_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/dsl_scenarios/registrar_test.exs --include sipp
  """

  use ExUnit.Case, async: false

  alias Parrot.Examples.Registrar
  alias SippTest.SippRunner

  @moduletag :sipp

  # ===========================================================================
  # Test Setup and Helpers
  # ===========================================================================

  setup do
    # Start the registrar using its start/1 function
    {:ok, stack} = Registrar.start(port: 0)
    port = ParrotSip.Stack.get_port(stack)

    on_exit(fn ->
      # Stop the stack (if it's still alive)
      if Process.alive?(stack) do
        ParrotSip.Stack.stop(stack)
      end

      # Stop the TableOwner process
      if pid = Process.whereis(Registrar.TableOwner) do
        GenServer.stop(pid)
      end

      # Clean up ETS table
      try do
        :ets.delete(Registrar)
      catch
        :error, :badarg -> :ok
      end
    end)

    %{stack: stack, port: port}
  end

  # Get the umbrella root directory
  defp umbrella_root do
    Path.expand("../../../../..", __DIR__)
  end

  # ===========================================================================
  # Registration Tests
  # ===========================================================================

  describe "DSL registrar" do
    @describetag :sipp

    test "accepts basic REGISTER and returns 200 OK", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Get absolute path to scenario file
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_register.xml"

      # Run SIPp UAC register scenario
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

    test "stores registration binding in ETS", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Get absolute path to scenario file
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_register.xml"

      # Run SIPp UAC register scenario
      result =
        SippRunner.run_scenario(
          scenario_file: scenario_file,
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok

      # Give time for registration to be stored
      Process.sleep(100)

      # Verify registration was stored
      registrations = Registrar.list_registrations()
      assert length(registrations) > 0

      # Get the first registration (there should only be one)
      [{aor, binding}] = registrations
      assert is_binary(aor)
      assert is_map(binding)
      assert Map.has_key?(binding, :contact)
      assert Map.has_key?(binding, :expires)
    end

    test "lookup finds registered contact", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Get absolute path to scenario file
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_register.xml"

      # Run SIPp UAC register scenario
      result =
        SippRunner.run_scenario(
          scenario_file: scenario_file,
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok

      # Give time for registration to be stored
      Process.sleep(100)

      # Get registered AOR
      [{aor, _binding}] = Registrar.list_registrations()

      # Lookup should succeed
      assert {:ok, binding} = Registrar.lookup(aor)
      assert is_map(binding)
    end

    test "handles multiple registrations", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Get absolute path to scenario file
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_register.xml"

      # Run multiple register requests
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
