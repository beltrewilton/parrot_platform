defmodule SippTest.RegisterBasicTest do
  @moduledoc """
  SIPp integration tests for basic REGISTER scenarios without authentication.

  Tests covered:
  - Basic REGISTER / 200 OK (no auth)
  - REGISTER with expires=0 (unregister)
  - Multiple contacts in single REGISTER

  RFC References:
  - RFC 3261 Section 10: Registrations
  - RFC 3261 Section 10.2: Constructing the REGISTER Request
  - RFC 3261 Section 10.3: Processing REGISTER Requests
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, TestHandler, SipStackHelper}

  @moduletag :sipp
  @moduletag :register

  describe "Basic REGISTER scenarios" do
    setup do
      # Create SIP handler that accepts registrations
      handler = TestHandler.new()

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      on_exit(fn ->
        try do
          SipStackHelper.stop(stack)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      %{stack: stack, handler: handler}
    end

    @tag timeout: 15_000
    test "REGISTER receives 200 OK without authentication", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/register/uac_register_basic.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 10_000
        )

      assert result == :ok

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.registers == 1
    end

    @tag timeout: 15_000
    test "REGISTER with expires=0 unregisters contact", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/register/uac_register_unregister.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 10_000
        )

      assert result == :ok

      # Verify stats - should see 2 registers (register + unregister)
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.registers == 2
    end

    @tag timeout: 15_000
    test "REGISTER with multiple contacts", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/register/uac_register_multi_contact.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 10_000
        )

      assert result == :ok

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.registers == 1
    end

    @tag timeout: 20_000
    test "multiple sequential REGISTER requests", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/register/uac_register_basic.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 5,
          timeout: 15_000
        )

      assert result == :ok

      # Verify stats
      Process.sleep(100)
      stats = TestHandler.get_stats(handler)
      assert stats.registers == 5
    end
  end
end
