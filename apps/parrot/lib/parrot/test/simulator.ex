defmodule Parrot.Test.Simulator do
  @moduledoc """
  Call flow simulation helpers for testing Parrot DSL handlers.

  These functions simulate events that occur during a call, allowing you to
  test handler callbacks without actual SIP/media infrastructure:

  * `simulate_dtmf/2` - Simulate DTMF digit received
  * `simulate_play_complete/2` - Simulate playback completion
  * `simulate_bridge_result/2` - Simulate bridge result (answered, failed, etc.)
  * `simulate_prompt_complete/3` - Simulate prompt completion with collected digits
  * `simulate_record_complete/3` - Simulate recording completion
  * `simulate_hangup/1` - Simulate remote party hanging up

  ## Usage

      defmodule MyApp.IVRFlowTest do
        use ExUnit.Case
        import Parrot.Test.Simulator
        import Parrot.Test.Assertions

        test "IVR routes to sales on digit 1" do
          call = Parrot.Test.call_fixture(handler: MyApp.IVRHandler)

          # Simulate the call flow
          call = call |> invoke_handle_invite()
          assert_played(call, "welcome.wav")

          call = simulate_play_complete(call, "welcome.wav")
          assert_played(call, "main-menu.wav")

          call = simulate_dtmf(call, "1")
          assert_bridged(call, ~r/sales/)
        end
      end

  """

  alias Parrot.Test.CallState

  @doc """
  Simulates DTMF digits being received during a call.

  This triggers the handler's `handle_dtmf/2` callback with the given digits.
  Pass `:timeout` to simulate a DTMF collection timeout.

  ## Examples

      # Single digit
      call = simulate_dtmf(call, "1")

      # Multiple digits
      call = simulate_dtmf(call, "1234")

      # Timeout
      call = simulate_dtmf(call, :timeout)

  """
  @spec simulate_dtmf(CallState.t(), String.t() | :timeout) :: CallState.t()
  def simulate_dtmf(%CallState{handler: nil} = call, _digits) do
    # No handler, just return the call (useful for testing without handler)
    call
  end

  def simulate_dtmf(%CallState{handler: handler} = call, digits) do
    call_handler_callback(handler, :handle_dtmf, [digits, call], call)
  end

  @doc """
  Simulates playback completion for an audio file.

  This triggers the handler's `handle_play_complete/2` callback.

  ## Examples

      call = simulate_play_complete(call, "welcome.wav")

  """
  @spec simulate_play_complete(CallState.t(), String.t()) :: CallState.t()
  def simulate_play_complete(%CallState{handler: nil} = call, _filename) do
    call |> CallState.clear_pending_action()
  end

  def simulate_play_complete(%CallState{handler: handler} = call, filename) do
    call = CallState.clear_pending_action(call)
    call_handler_callback(handler, :handle_play_complete, [filename, call], call)
  end

  @doc """
  Simulates bridge completion with a result.

  This triggers the handler's `handle_bridge_complete/2` callback.

  ## Results

  * `:answered` - Bridge was answered
  * `{:failed, reason}` - Bridge failed (`:busy`, `:no_answer`, `:rejected`, etc.)

  ## Examples

      # Successful bridge
      call = simulate_bridge_result(call, :answered)

      # Failed bridge - busy
      call = simulate_bridge_result(call, {:failed, :busy})

      # Failed bridge - no answer
      call = simulate_bridge_result(call, {:failed, :no_answer})

  """
  @spec simulate_bridge_result(CallState.t(), :answered | {:failed, atom()}) :: CallState.t()
  def simulate_bridge_result(%CallState{handler: nil} = call, _result) do
    call |> CallState.clear_pending_action()
  end

  def simulate_bridge_result(%CallState{handler: handler} = call, result) do
    call = CallState.clear_pending_action(call)
    call_handler_callback(handler, :handle_bridge_complete, [result, call], call)
  end

  @doc """
  Simulates prompt completion (play + collect) with collected digits.

  This triggers the handler's `handle_prompt_complete/3` callback.

  ## Examples

      # Collected digits
      call = simulate_prompt_complete(call, "enter-pin.wav", "1234")

      # Timeout (no digits)
      call = simulate_prompt_complete(call, "enter-pin.wav", :timeout)

  """
  @spec simulate_prompt_complete(CallState.t(), String.t(), String.t() | :timeout) ::
          CallState.t()
  def simulate_prompt_complete(%CallState{handler: nil} = call, _filename, _digits) do
    call |> CallState.clear_pending_action()
  end

  def simulate_prompt_complete(%CallState{handler: handler} = call, filename, digits) do
    call = CallState.clear_pending_action(call)
    call_handler_callback(handler, :handle_prompt_complete, [filename, digits, call], call)
  end

  @doc """
  Simulates recording completion.

  This triggers the handler's `handle_record_complete/3` callback.

  ## Examples

      call = simulate_record_complete(call, "recording.wav", 30_000)

  """
  @spec simulate_record_complete(CallState.t(), String.t(), integer()) :: CallState.t()
  def simulate_record_complete(%CallState{handler: nil} = call, _filename, _duration) do
    call |> CallState.clear_pending_action()
  end

  def simulate_record_complete(%CallState{handler: handler} = call, filename, duration) do
    call = CallState.clear_pending_action(call)
    call_handler_callback(handler, :handle_record_complete, [filename, duration, call], call)
  end

  @doc """
  Simulates the remote party hanging up.

  This triggers the handler's `handle_hangup/1` callback.

  ## Examples

      call = simulate_hangup(call)

  """
  @spec simulate_hangup(CallState.t()) :: CallState.t()
  def simulate_hangup(%CallState{handler: nil} = call) do
    %{call | status: :hangup}
  end

  def simulate_hangup(%CallState{handler: handler} = call) do
    call = %{call | status: :hangup}
    call_handler_callback(handler, :handle_hangup, [call], call)
  end

  @doc """
  Simulates conference join completion.

  This triggers the handler's `handle_conference_join/2` callback.

  ## Examples

      call = simulate_conference_join(call, "room-123")

  """
  @spec simulate_conference_join(CallState.t(), String.t()) :: CallState.t()
  def simulate_conference_join(%CallState{handler: nil} = call, _room) do
    call
  end

  def simulate_conference_join(%CallState{handler: handler} = call, room) do
    call_handler_callback(handler, :handle_conference_join, [room, call], call)
  end

  @doc """
  Simulates conference leave event.

  This triggers the handler's `handle_conference_leave/3` callback.

  ## Examples

      call = simulate_conference_leave(call, "room-123", :normal)
      call = simulate_conference_leave(call, "room-123", :kicked)

  """
  @spec simulate_conference_leave(CallState.t(), String.t(), atom()) :: CallState.t()
  def simulate_conference_leave(%CallState{handler: nil} = call, _room, _reason) do
    call
  end

  def simulate_conference_leave(%CallState{handler: handler} = call, room, reason) do
    call_handler_callback(handler, :handle_conference_leave, [room, reason, call], call)
  end

  @doc """
  Invokes the handler's handle_invite callback.

  This is typically the first step in simulating a call flow.

  ## Examples

      call = Parrot.Test.call_fixture(handler: MyHandler)
      call = invoke_handle_invite(call)

  """
  @spec invoke_handle_invite(CallState.t()) :: CallState.t()
  def invoke_handle_invite(%CallState{handler: nil} = call) do
    call
  end

  def invoke_handle_invite(%CallState{handler: handler} = call) do
    call_handler_callback(handler, :handle_invite, [call], call)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Safely calls a handler callback, handling UndefinedFunctionError gracefully.
  # This is more robust than function_exported?/3 because it works even when
  # the module is defined in test support files that may be loaded lazily.
  defp call_handler_callback(handler, callback, args, default_call) do
    # Ensure the module is loaded
    Code.ensure_loaded(handler)

    try do
      result = apply(handler, callback, args)
      normalize_callback_result(result, default_call)
    rescue
      UndefinedFunctionError ->
        # Callback not defined, return default
        default_call

      FunctionClauseError ->
        # No matching clause for the given args, return default
        default_call
    end
  end

  # Normalizes various return formats from handler callbacks
  defp normalize_callback_result(%CallState{} = call, _default), do: call
  defp normalize_callback_result({:noreply, %CallState{} = call}, _default), do: call
  defp normalize_callback_result({:play, _filename, %CallState{} = call}, _default), do: call

  defp normalize_callback_result({:play, _filename, _opts, %CallState{} = call}, _default),
    do: call

  defp normalize_callback_result({:bridge, _target, %CallState{} = call}, _default), do: call

  defp normalize_callback_result({:bridge, _target, _opts, %CallState{} = call}, _default),
    do: call

  defp normalize_callback_result({:hangup, %CallState{} = call}, _default), do: call
  defp normalize_callback_result(_, default), do: default
end
