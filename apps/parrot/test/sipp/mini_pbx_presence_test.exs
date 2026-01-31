defmodule Parrot.Sipp.MiniPBXPresenceTest do
  @moduledoc """
  SIPp integration tests for Mini PBX Presence functionality.

  Tests SUBSCRIBE/NOTIFY flows for presence state tracking.
  """
  use ExUnit.Case, async: false

  @moduletag :sipp
  @moduletag :presence

  alias Parrot.Examples.MiniPBX.{Router, Storage}
  alias SippTest.{SipStackHelper, SippRunner}

  setup do
    # Small delay to allow SIPp from previous test to fully release port 5060
    Process.sleep(300)

    # Ensure Mnesia is started and tables exist
    :mnesia.start()

    case Storage.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clear storage before each test
    Storage.clear_all()

    # Create handler using Bridge.Handler with MiniPBX Router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: Router})

    # Start the SIP stack
    {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

    on_exit(fn ->
      # Stop transport listener
      if Process.alive?(stack.transport_listener) do
        ParrotTransport.stop_listener(stack.transport_listener)
      end

      # Stop bridge process
      if Process.alive?(stack.transport_handler) do
        GenServer.stop(stack.transport_handler)
      end

      # Allow time for SIPp to fully release port 5060
      Process.sleep(200)
    end)

    %{stack: stack, port: stack.port}
  end

  # Get path to Mini PBX presence scenarios
  defp scenario_path(filename) do
    Path.expand("scenarios/mini_pbx/presence/#{filename}", __DIR__)
  end

  # ===========================================================================
  # Basic Subscription Tests
  # ===========================================================================

  describe "basic presence subscription" do
    @describetag :sipp

    test "SUBSCRIBE returns 200 OK and sends initial NOTIFY", %{port: port} do
      # Pre-register an extension so presence can be tracked
      Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)
      # Set initial presence state
      Storage.set_presence_state("sip:1001@pbx.local", :available)

      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_subscribe_basic.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    test "SUBSCRIBE to unregistered extension still receives NOTIFY", %{port: port} do
      # Don't pre-register - test behavior with unknown extension
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_subscribe_invalid.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      # MiniPBX allows subscriptions to any extension (returns presence as "Offline")
      assert result == :ok
    end
  end

  # ===========================================================================
  # Subscription Lifecycle Tests
  # ===========================================================================

  describe "subscription lifecycle" do
    @describetag :sipp
    @tag :skip

    test "subscription can be refreshed before expiry", %{port: port} do
      # Pre-register extension
      Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)
      Storage.set_presence_state("sip:1001@pbx.local", :available)

      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_subscribe_refresh.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 30_000
        )

      assert result == :ok
    end
  end

  # ===========================================================================
  # State Change Tests
  # ===========================================================================

  describe "presence state changes" do
    @describetag :sipp
    @tag :skip

    test "subscriber receives NOTIFY when extension state changes", %{port: port} do
      # Pre-register extension
      Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)
      Storage.set_presence_state("sip:1001@pbx.local", :available)

      Process.sleep(100)

      # This test would require coordination with another SIPp instance
      # to trigger state changes. For now, it's marked as skip.
      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_subscribe_state_change.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 20_000
        )

      assert result == :ok
    end
  end
end
