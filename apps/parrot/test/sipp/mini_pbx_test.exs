defmodule Parrot.Sipp.MiniPBXTest do
  @moduledoc """
  SIPp integration tests for the Mini PBX example application.

  Tests end-to-end SIP flows using real SIP traffic via SIPp:
  - Registration with authentication
  - Auto-attendant IVR navigation (requires media - pending)
  - Extension-to-extension calls (requires media - pending)
  - Outbound PSTN routing (requires media - pending)

  ## Running Tests

      mix test apps/parrot/test/sipp/mini_pbx_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/mini_pbx_test.exs --include sipp

  ## Tags

  - `:sipp` - All SIPp integration tests
  - `:pending_media` - Tests requiring full media pipeline (currently not set up)
  - `:pending_sipp_scenario` - Tests missing SIPp scenario files
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}
  alias Parrot.Examples.MiniPBX.{Router, Storage}

  @moduletag :sipp

  # ===========================================================================
  # Test Setup
  # ===========================================================================

  setup do
    # Small delay to allow SIPp from previous test to fully release port 5060
    # SIPp uses this port by default and may briefly hold it after test completion
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

  # Get path to Mini PBX scenarios
  defp scenario_path(filename) do
    Path.expand("scenarios/mini_pbx/#{filename}", __DIR__)
  end

  # ===========================================================================
  # Auto-Attendant Tests
  # ===========================================================================

  describe "auto-attendant IVR (100)" do
    @describetag :sipp

    # This test requires the media pipeline to be properly initialized
    # The AutoAttendant handler calls answer() then play() which needs media
    @tag skip: "requires full media pipeline"
    test "answers call to 100 with 200 OK", %{port: port} do
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_aa_basic.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    @tag skip: "requires full media pipeline"
    test "handles DTMF option 1 (sales)", %{port: port} do
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_aa_option1.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 20_000
        )

      assert result == :ok
    end
  end

  # ===========================================================================
  # Registration Tests
  # ===========================================================================

  describe "registration" do
    @describetag :sipp

    test "handles REGISTER with authentication challenge", %{port: port} do
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_register_auth.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 20_000
        )

      assert result == :ok

      # Give time for registration to be stored
      Process.sleep(100)

      # Verify the registration was stored
      # The AOR is "sip:1001@pbx.local" from the scenario
      case Storage.get_registrations("sip:1001@pbx.local") do
        {:ok, [_ | _]} ->
          assert true

        _ ->
          # Check with different domain format
          case Storage.lookup_extension("1001") do
            {:ok, _contact} -> assert true
            {:error, :not_registered} -> flunk("Registration was not stored")
          end
      end
    end

    test "handles multiple registrations sequentially", %{port: port} do
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_register_auth.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 3,
          timeout: 30_000
        )

      assert result == :ok
    end
  end

  # ===========================================================================
  # Extension Call Tests (require registration and media)
  # ===========================================================================

  describe "extension-to-extension calls" do
    @describetag :sipp

    # Note: Due to Router scope (from_ip: "192.168.0.0/16"), calls from 127.0.0.1
    # won't match the 1xxx route. This test still passes because no-route-match
    # also returns 404. The Extensions handler logic isn't tested here.
    test "rejects call to unregistered extension with 404", %{port: port} do
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_extension_not_found.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    @tag skip: "requires full media pipeline"
    test "routes call to registered extension", %{port: port} do
      # Pre-register an extension in storage
      Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)

      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_extension_call.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 20_000
        )

      assert result == :ok
    end
  end

  # ===========================================================================
  # Presence Tests (SUBSCRIBE/NOTIFY)
  # ===========================================================================

  describe "presence subscription" do
    @describetag :sipp

    test "handles basic SUBSCRIBE and sends NOTIFY", %{port: port} do
      # Pre-register an extension so presence can be tracked
      Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)
      # Set initial presence state
      Storage.set_presence_state("sip:1001@pbx.local", :available)

      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("presence/uac_subscribe_basic.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    test "handles SUBSCRIBE to unregistered extension", %{port: port} do
      # Don't pre-register - test behavior with unknown extension
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("presence/uac_subscribe_invalid.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      # This should succeed - the scenario expects any of 200/403/404
      assert result == :ok
    end
  end

  # ===========================================================================
  # Outbound PSTN Tests
  # ===========================================================================

  describe "outbound PSTN calls (9xxx)" do
    @describetag :sipp

    # Note: Due to Router scope (from_ip: "192.168.0.0/16"), calls from 127.0.0.1
    # won't match the 9xxx route. This test still passes because no-route-match
    # also returns 404. The Outbound handler logic isn't tested here.
    test "rejects invalid short number with 404", %{port: port} do
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_outbound_invalid.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    @tag skip: "requires full media pipeline"
    test "accepts valid outbound number and forks to carriers", %{port: port} do
      Process.sleep(100)

      result =
        SippRunner.run_scenario(
          scenario_file: scenario_path("uac_outbound_valid.xml"),
          remote_host: "127.0.0.1",
          remote_port: port,
          calls: 1,
          timeout: 20_000
        )

      assert result == :ok
    end
  end
end
