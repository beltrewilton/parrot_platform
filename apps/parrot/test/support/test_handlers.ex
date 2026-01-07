defmodule TestHelperHandler do
  @moduledoc """
  Test handler that mimics a simple IVR for testing Parrot.Test helpers.
  """

  alias Parrot.Test.CallState

  def handle_invite(call) do
    call
    |> CallState.record_action(:answer)
    |> CallState.put_assign(:menu, :main)
    |> CallState.record_action({:play, "welcome.wav"})
  end

  def handle_play_complete("welcome.wav", call) do
    call
    |> CallState.record_action({:prompt, "main-menu.wav", collect: [max: 1]})
  end

  def handle_play_complete("goodbye.wav", call) do
    call
    |> CallState.record_action(:hangup)
  end

  def handle_play_complete(_filename, call), do: call

  def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
    call
    |> CallState.put_assign(:menu, :sales)
    |> CallState.record_action({:play, "sales-menu.wav"})
  end

  def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
    call
    |> CallState.put_assign(:menu, :support)
    |> CallState.record_action({:bridge, "sip:support@internal"})
  end

  def handle_dtmf(:timeout, call) do
    call
    |> CallState.record_action({:play, "goodbye.wav"})
  end

  def handle_dtmf(_digit, call), do: call

  def handle_bridge_complete(:answered, call) do
    call
    |> CallState.put_assign(:bridge_answered, true)
  end

  def handle_bridge_complete({:failed, :busy}, call) do
    call
    |> CallState.record_action({:play, "user-busy.wav"})
  end

  def handle_bridge_complete({:failed, :no_answer}, call) do
    call
    |> CallState.record_action({:play, "no-answer.wav"})
  end

  def handle_bridge_complete(_result, call), do: call

  def handle_hangup(call) do
    call
    |> CallState.put_assign(:hangup_handled, true)
  end
end

defmodule NoInviteHandler do
  @moduledoc """
  Handler without handle_invite for testing error case.
  """

  def handle_dtmf(_digit, call), do: call
end
