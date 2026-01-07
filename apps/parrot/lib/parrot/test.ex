defmodule Parrot.Test do
  @moduledoc """
  Test helpers for testing Parrot DSL handlers.

  This module provides a comprehensive testing framework for Parrot-based VoIP
  applications. It includes:

  * **Fixtures** - Create test call structures
  * **Assertions** - Verify call behavior (played files, bridges, etc.)
  * **Simulators** - Simulate events (DTMF, playback complete, etc.)

  ## Quick Start

  Use the `Parrot.Test` module in your test files:

      defmodule MyApp.IVRHandlerTest do
        use ExUnit.Case
        use Parrot.Test

        test "plays welcome message on answer" do
          call = call_fixture(assigns: %{menu: :main})
          result = MyApp.IVRHandler.handle_dtmf("1", call)

          assert_played(result, "sales-menu.wav")
          assert_assign(result, :menu, :sales)
        end
      end

  ## Testing Levels

  ### 1. Unit Tests - Direct Handler Testing

  Test handler functions directly with call fixtures:

      test "routes to sales on digit 1" do
        call = call_fixture(assigns: %{menu: :main})
        result = MyApp.IVRHandler.handle_dtmf("1", call)

        assert_played(result, "sales-menu.wav")
        assert_assign(result, :menu, :sales)
      end

  ### 2. Flow Tests - Simulated Call Sequences

  Test complete call flows with simulated events:

      test "complete IVR flow to sales" do
        call = call_fixture(handler: MyApp.IVRHandler)
        call = invoke_handle_invite(call)

        assert_played(call, "welcome.wav")

        call = simulate_play_complete(call, "welcome.wav")
        assert_played(call, "main-menu.wav")

        call = simulate_dtmf(call, "1")
        assert_bridged(call, ~r/sales/)
      end

  ### 3. SIPp Integration Tests

  Test with real SIP traffic using SIPp scenarios (see guides/testing.md).

  ## Available Functions

  ### Fixtures

  * `call_fixture/1` - Create a test call state struct

  ### Assertions

  * `assert_played/2,3` - Assert file was played
  * `assert_bridged/2,3` - Assert call was bridged
  * `assert_answered/1` - Assert call was answered
  * `assert_rejected/2` - Assert call was rejected
  * `assert_hung_up/1` - Assert call was hung up
  * `assert_assign/3` - Assert assign value
  * `assert_collecting_dtmf/1,2` - Assert DTMF collection started
  * `assert_prompted/2,3` - Assert prompt started
  * `assert_recording/2,3` - Assert recording started

  ### Simulators

  * `simulate_dtmf/2` - Simulate DTMF digits received
  * `simulate_play_complete/2` - Simulate playback finished
  * `simulate_bridge_result/2` - Simulate bridge result
  * `simulate_prompt_complete/3` - Simulate prompt completion
  * `simulate_record_complete/3` - Simulate recording finished
  * `simulate_hangup/1` - Simulate remote hangup
  * `simulate_conference_join/2` - Simulate conference join
  * `simulate_conference_leave/3` - Simulate conference leave
  * `invoke_handle_invite/1` - Invoke handler's handle_invite

  """

  alias Parrot.Test.CallState

  @doc """
  Sets up the test module with Parrot test helpers.

  When you `use Parrot.Test`, the following are imported:

  * All functions from `Parrot.Test.Assertions`
  * All functions from `Parrot.Test.Simulator`
  * The `call_fixture/1` function

  ## Options

  * `:async` - Pass through to ExUnit.Case (default: true)

  ## Example

      defmodule MyApp.HandlerTest do
        use ExUnit.Case
        use Parrot.Test

        test "example" do
          call = call_fixture()
          # ...
        end
      end

  """
  defmacro __using__(_opts) do
    quote do
      import Parrot.Test, only: [call_fixture: 0, call_fixture: 1]
      import Parrot.Test.Assertions
      import Parrot.Test.Simulator
    end
  end

  @doc """
  Creates a test call fixture with optional configuration.

  This creates a `Parrot.Test.CallState` struct that can be used to test
  handler callbacks. The struct tracks all actions performed on the call.

  ## Options

  * `:id` - Call identifier (default: auto-generated)
  * `:from` - From URI (default: "sip:test@example.com")
  * `:to` - To URI (default: "sip:100@local")
  * `:assigns` - Initial assigns map (default: %{})
  * `:status` - Initial call status (default: :ringing)
  * `:handler` - Handler module for simulation

  ## Examples

      # Basic fixture
      call = call_fixture()

      # With custom assigns
      call = call_fixture(assigns: %{menu: :main, retries: 0})

      # With handler for flow simulation
      call = call_fixture(handler: MyApp.IVRHandler)

      # With custom URIs
      call = call_fixture(
        from: "sip:alice@example.com",
        to: "sip:sales@company.com"
      )

  """
  @spec call_fixture(keyword()) :: CallState.t()
  def call_fixture(opts \\ []) do
    CallState.new(opts)
  end

  @doc """
  Simulates a complete call from start to finish.

  This function creates a call fixture, invokes the handler's `handle_invite`,
  and returns the resulting call state. It's a convenience wrapper for:

      call = call_fixture(handler: handler, to: to)
      call = invoke_handle_invite(call)

  ## Options

  * `:handler` - Required. The handler module to use.
  * `:to` - To URI (default: "sip:100@local")
  * `:from` - From URI (default: "sip:test@example.com")
  * `:assigns` - Initial assigns (default: %{})

  ## Returns

  `{:ok, call}` - The call state after handle_invite

  ## Examples

      {:ok, call} = simulate_call(handler: MyApp.IVRHandler, to: "sip:100@local")
      assert_played(call, "welcome.wav")

  Note: This function requires InviteHandler to be implemented. For simpler
  testing without the handler, use `call_fixture/1` directly.

  """
  @spec simulate_call(keyword()) :: {:ok, CallState.t()} | {:error, term()}
  def simulate_call(opts) do
    handler = Keyword.fetch!(opts, :handler)

    call_opts =
      opts
      |> Keyword.delete(:handler)
      |> Keyword.put(:handler, handler)

    call = call_fixture(call_opts)

    # Ensure the module is loaded before checking
    Code.ensure_loaded(handler)

    if function_exported?(handler, :handle_invite, 1) do
      updated_call = Parrot.Test.Simulator.invoke_handle_invite(call)
      {:ok, updated_call}
    else
      {:error, {:callback_not_defined, :handle_invite}}
    end
  end
end
