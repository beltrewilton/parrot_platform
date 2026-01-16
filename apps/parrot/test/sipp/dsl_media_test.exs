defmodule Parrot.Sipp.DSL.MediaTest do
  @moduledoc """
  SIPp integration tests for DSL media operations (US2: Media Lifecycle).

  These tests verify that the Parrot DSL layer correctly handles
  media operations (play, record) during active calls.

  ## Test Scenarios

  1. Play audio during call - Handler answers and plays audio file
  2. Call completes successfully after play operation

  ## Running Tests

      mix test apps/parrot/test/sipp/dsl_media_test.exs --include sipp

      # With debug logging
      LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/dsl_media_test.exs --include sipp
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}

  @moduletag :sipp

  # ===========================================================================
  # Test Router and Handler Definitions
  # ===========================================================================

  defmodule PlayAudioHandler do
    @moduledoc """
    DSL handler that answers calls and plays an audio file.
    """
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      call
      |> answer()
      |> play("priv/audio/parrot-welcome.wav")
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, call}
    end
  end

  defmodule MediaTestRouter do
    @moduledoc """
    Router that routes all INVITEs to PlayAudioHandler.
    """
    use Parrot.Router

    invite("*", Parrot.Sipp.DSL.MediaTest.PlayAudioHandler)
  end

  # ===========================================================================
  # Test Setup and Helpers
  # ===========================================================================

  setup do
    # Create a ParrotSip.Handler that uses Bridge.Handler with our DSL router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: MediaTestRouter})

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
  # Media Operation Tests (T023, T027)
  # ===========================================================================

  describe "US2: Media Lifecycle" do
    @describetag :sipp

    @tag :sipp
    test "play operation executes during active call (T023, T027)", %{port: port} do
      # Give the stack time to fully start
      Process.sleep(100)

      # Use the basic call scenario which includes:
      # 1. INVITE with SDP
      # 2. 200 OK (handler answers and plays audio)
      # 3. ACK
      # 4. pause (during which audio plays)
      # 5. BYE / 200 OK
      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_basic_call.xml"

      # Run SIPp UAC scenario
      # If the play operation causes any errors, the test will fail
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

    @tag :sipp
    test "multiple calls with play operations succeed", %{port: port} do
      Process.sleep(100)

      scenario_file =
        umbrella_root() <> "/apps/parrot_sip/test/sipp/scenarios/dsl/uac_basic_call.xml"

      # Run multiple calls to test cleanup between calls
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
