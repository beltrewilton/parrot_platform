defmodule Parrot.TestTest do
  use ExUnit.Case, async: true
  use Parrot.Test

  alias Parrot.Test.CallState

  # ===========================================================================
  # Test Fixtures
  # ===========================================================================

  describe "call_fixture/0" do
    test "creates a call state with default values" do
      call = call_fixture()

      assert %CallState{} = call
      assert call.from == "sip:test@example.com"
      assert call.to == "sip:100@local"
      assert call.assigns == %{}
      assert call.status == :ringing
      assert call.actions == []
      assert call.handler == nil
      assert is_binary(call.id)
    end
  end

  describe "call_fixture/1" do
    test "accepts custom assigns" do
      call = call_fixture(assigns: %{menu: :main, retries: 0})

      assert call.assigns == %{menu: :main, retries: 0}
    end

    test "accepts custom from URI" do
      call = call_fixture(from: "sip:alice@example.com")

      assert call.from == "sip:alice@example.com"
    end

    test "accepts custom to URI" do
      call = call_fixture(to: "sip:sales@internal")

      assert call.to == "sip:sales@internal"
    end

    test "accepts custom status" do
      call = call_fixture(status: :answered)

      assert call.status == :answered
    end

    test "accepts custom handler" do
      call = call_fixture(handler: TestHelperHandler)

      assert call.handler == TestHelperHandler
    end

    test "accepts custom ID" do
      call = call_fixture(id: "custom-id-123")

      assert call.id == "custom-id-123"
    end

    test "accepts multiple options" do
      call =
        call_fixture(
          id: "test-123",
          from: "sip:alice@example.com",
          to: "sip:bob@example.com",
          assigns: %{priority: :high},
          status: :answered,
          handler: TestHelperHandler
        )

      assert call.id == "test-123"
      assert call.from == "sip:alice@example.com"
      assert call.to == "sip:bob@example.com"
      assert call.assigns == %{priority: :high}
      assert call.status == :answered
      assert call.handler == TestHelperHandler
    end
  end

  # ===========================================================================
  # CallState Module Tests
  # ===========================================================================

  describe "CallState.record_action/2" do
    test "records actions in reverse order" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "file1.wav"})
        |> CallState.record_action({:play, "file2.wav"})

      # Actions stored in reverse order (newest first)
      assert call.actions == [{:play, "file2.wav"}, {:play, "file1.wav"}]
    end
  end

  describe "CallState.get_actions/1" do
    test "returns actions in chronological order" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "file1.wav"})
        |> CallState.record_action({:play, "file2.wav"})
        |> CallState.record_action(:answer)

      actions = CallState.get_actions(call)

      assert actions == [{:play, "file1.wav"}, {:play, "file2.wav"}, :answer]
    end
  end

  describe "CallState.has_action?/2" do
    test "finds exact action match" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "welcome.wav"})

      assert CallState.has_action?(call, {:play, "welcome.wav"})
      refute CallState.has_action?(call, {:play, "other.wav"})
    end

    test "matches play action with regex" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "main-menu.wav"})

      assert CallState.has_action?(call, ~r/menu/)
      refute CallState.has_action?(call, ~r/welcome/)
    end

    test "matches bridge action with regex" do
      call =
        call_fixture()
        |> CallState.record_action({:bridge, "sip:sales@internal"})

      assert CallState.has_action?(call, {:bridge, ~r/sales/})
      refute CallState.has_action?(call, {:bridge, ~r/support/})
    end
  end

  describe "CallState.put_assign/3 and get_assign/3" do
    test "sets and gets assign values" do
      call =
        call_fixture()
        |> CallState.put_assign(:menu, :main)
        |> CallState.put_assign(:retries, 0)

      assert CallState.get_assign(call, :menu) == :main
      assert CallState.get_assign(call, :retries) == 0
    end

    test "returns default for missing assign" do
      call = call_fixture()

      assert CallState.get_assign(call, :missing) == nil
      assert CallState.get_assign(call, :missing, :default) == :default
    end
  end

  # ===========================================================================
  # Assertion Tests
  # ===========================================================================

  describe "assert_played/2" do
    test "passes when exact file was played" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "welcome.wav"})

      assert_played(call, "welcome.wav")
    end

    test "passes when file with options was played" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "music.wav", loop: true})

      assert_played(call, "music.wav")
    end

    test "passes with regex pattern" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "main-menu-v2.wav"})

      assert_played(call, ~r/menu/)
    end

    test "fails when file was not played" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected file "welcome.wav" to be played/, fn ->
        assert_played(call, "welcome.wav")
      end
    end

    test "fails when regex doesn't match any played file" do
      call =
        call_fixture()
        |> CallState.record_action({:play, "welcome.wav"})

      assert_raise ExUnit.AssertionError, ~r/Expected a file matching/, fn ->
        assert_played(call, ~r/menu/)
      end
    end
  end

  describe "assert_bridged/2" do
    test "passes when bridged to exact target" do
      call =
        call_fixture()
        |> CallState.record_action({:bridge, "sip:sales@internal"})

      assert_bridged(call, "sip:sales@internal")
    end

    test "passes when bridged with options" do
      call =
        call_fixture()
        |> CallState.record_action({:bridge, "sip:dest@example.com", timeout: 30_000})

      assert_bridged(call, "sip:dest@example.com")
    end

    test "passes with regex pattern" do
      call =
        call_fixture()
        |> CallState.record_action({:bridge, "sip:sales-queue@internal"})

      assert_bridged(call, ~r/sales/)
    end

    test "fails when not bridged to target" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected bridge to/, fn ->
        assert_bridged(call, "sip:sales@internal")
      end
    end
  end

  describe "assert_answered/1" do
    test "passes when call was answered" do
      call =
        call_fixture()
        |> CallState.record_action(:answer)

      assert_answered(call)
    end

    test "fails when call was not answered" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected call to be answered/, fn ->
        assert_answered(call)
      end
    end
  end

  describe "assert_rejected/2" do
    test "passes when call was rejected with status" do
      call =
        call_fixture()
        |> CallState.record_action({:reject, 486})

      assert_rejected(call, 486)
    end

    test "fails when call was not rejected" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected call to be rejected with status 486/, fn ->
        assert_rejected(call, 486)
      end
    end

    test "fails when rejected with different status" do
      call =
        call_fixture()
        |> CallState.record_action({:reject, 404})

      assert_raise ExUnit.AssertionError, ~r/Expected call to be rejected with status 486/, fn ->
        assert_rejected(call, 486)
      end
    end
  end

  describe "assert_hung_up/1" do
    test "passes when call was hung up" do
      call =
        call_fixture()
        |> CallState.record_action(:hangup)

      assert_hung_up(call)
    end

    test "fails when call was not hung up" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected call to be hung up/, fn ->
        assert_hung_up(call)
      end
    end
  end

  describe "assert_assign/3" do
    test "passes when assign has expected value" do
      call = call_fixture(assigns: %{menu: :main})

      assert_assign(call, :menu, :main)
    end

    test "fails when assign has different value" do
      call = call_fixture(assigns: %{menu: :support})

      assert_raise ExUnit.AssertionError, ~r/Expected assigns\[:menu\] to be :main/, fn ->
        assert_assign(call, :menu, :main)
      end
    end

    test "fails when assign is missing" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected assigns\[:menu\] to be :main/, fn ->
        assert_assign(call, :menu, :main)
      end
    end
  end

  describe "assert_collecting_dtmf/1" do
    test "passes when DTMF collection was started" do
      call =
        call_fixture()
        |> CallState.record_action({:collect_dtmf, [max: 4]})

      assert_collecting_dtmf(call)
    end

    test "fails when DTMF collection was not started" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected DTMF collection to be started/, fn ->
        assert_collecting_dtmf(call)
      end
    end
  end

  describe "assert_prompted/2" do
    test "passes when prompt was started" do
      call =
        call_fixture()
        |> CallState.record_action({:prompt, "enter-pin.wav", collect: [max: 4]})

      assert_prompted(call, "enter-pin.wav")
    end

    test "fails when prompt was not started" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected prompt with file/, fn ->
        assert_prompted(call, "enter-pin.wav")
      end
    end
  end

  describe "assert_recording/2" do
    test "passes when recording was started" do
      call =
        call_fixture()
        |> CallState.record_action({:record, "recording.wav"})

      assert_recording(call, "recording.wav")
    end

    test "passes when recording was started with options" do
      call =
        call_fixture()
        |> CallState.record_action({:record, "recording.wav", max_duration: 60_000})

      assert_recording(call, "recording.wav")
    end

    test "fails when recording was not started" do
      call = call_fixture()

      assert_raise ExUnit.AssertionError, ~r/Expected recording to file/, fn ->
        assert_recording(call, "recording.wav")
      end
    end
  end

  # ===========================================================================
  # Simulator Tests
  # ===========================================================================

  describe "simulate_dtmf/2" do
    test "returns unchanged call when no handler" do
      call = call_fixture()
      result = simulate_dtmf(call, "1")

      assert result == call
    end

    test "invokes handler's handle_dtmf/2 callback" do
      call = call_fixture(handler: TestHelperHandler, assigns: %{menu: :main})
      result = simulate_dtmf(call, "1")

      # TestHelperHandler adds a play action and updates assigns
      assert CallState.has_action?(result, {:play, "sales-menu.wav"})
      assert CallState.get_assign(result, :menu) == :sales
    end

    test "handles timeout" do
      call = call_fixture(handler: TestHelperHandler)
      result = simulate_dtmf(call, :timeout)

      assert CallState.has_action?(result, {:play, "goodbye.wav"})
    end
  end

  describe "simulate_play_complete/2" do
    test "returns unchanged call when no handler" do
      call = call_fixture()
      result = simulate_play_complete(call, "welcome.wav")

      assert result == call
    end

    test "invokes handler's handle_play_complete/2 callback" do
      call = call_fixture(handler: TestHelperHandler)
      result = simulate_play_complete(call, "welcome.wav")

      assert CallState.has_action?(result, {:prompt, "main-menu.wav", collect: [max: 1]})
    end

    test "clears pending action" do
      call =
        call_fixture()
        |> CallState.set_pending_action({:play, "welcome.wav"})

      result = simulate_play_complete(call, "welcome.wav")

      assert result.pending_action == nil
    end
  end

  describe "simulate_bridge_result/2" do
    test "returns unchanged call when no handler" do
      call = call_fixture()
      result = simulate_bridge_result(call, :answered)

      assert result == call
    end

    test "invokes handler's handle_bridge_complete/2 on answered" do
      call = call_fixture(handler: TestHelperHandler, assigns: %{extension: "100"})
      result = simulate_bridge_result(call, :answered)

      # Handler sets bridge_answered assign
      assert CallState.get_assign(result, :bridge_answered) == true
    end

    test "invokes handler's handle_bridge_complete/2 on failed" do
      call = call_fixture(handler: TestHelperHandler)
      result = simulate_bridge_result(call, {:failed, :busy})

      assert CallState.has_action?(result, {:play, "user-busy.wav"})
    end

    test "clears pending action" do
      call =
        call_fixture()
        |> CallState.set_pending_action({:bridge, "sip:dest@example.com"})

      result = simulate_bridge_result(call, :answered)

      assert result.pending_action == nil
    end
  end

  describe "simulate_prompt_complete/3" do
    test "returns unchanged call when no handler" do
      call = call_fixture()
      result = simulate_prompt_complete(call, "enter-pin.wav", "1234")

      assert result == call
    end

    test "clears pending action" do
      call =
        call_fixture()
        |> CallState.set_pending_action({:prompt, "enter-pin.wav", collect: [max: 4]})

      result = simulate_prompt_complete(call, "enter-pin.wav", "1234")

      assert result.pending_action == nil
    end
  end

  describe "simulate_record_complete/3" do
    test "returns unchanged call when no handler" do
      call = call_fixture()
      result = simulate_record_complete(call, "recording.wav", 30_000)

      assert result == call
    end

    test "clears pending action" do
      call =
        call_fixture()
        |> CallState.set_pending_action({:record, "recording.wav"})

      result = simulate_record_complete(call, "recording.wav", 30_000)

      assert result.pending_action == nil
    end
  end

  describe "simulate_hangup/1" do
    test "sets status to hangup when no handler" do
      call = call_fixture()
      result = simulate_hangup(call)

      assert result.status == :hangup
    end

    test "invokes handler's handle_hangup/1 callback" do
      call = call_fixture(handler: TestHelperHandler, assigns: %{extension: "100"})
      result = simulate_hangup(call)

      assert CallState.get_assign(result, :hangup_handled) == true
    end
  end

  describe "invoke_handle_invite/1" do
    test "returns unchanged call when no handler" do
      call = call_fixture()
      result = invoke_handle_invite(call)

      assert result == call
    end

    test "invokes handler's handle_invite/1 callback" do
      call = call_fixture(handler: TestHelperHandler)
      result = invoke_handle_invite(call)

      assert CallState.has_action?(result, :answer)
      assert CallState.has_action?(result, {:play, "welcome.wav"})
    end
  end

  # ===========================================================================
  # simulate_call/1 Tests
  # ===========================================================================

  describe "simulate_call/1" do
    test "creates call and invokes handle_invite" do
      {:ok, call} = Parrot.Test.simulate_call(handler: TestHelperHandler, to: "sip:100@local")

      assert call.to == "sip:100@local"
      assert CallState.has_action?(call, :answer)
      assert CallState.has_action?(call, {:play, "welcome.wav"})
    end

    test "returns error when handler doesn't have handle_invite" do
      {:error, reason} = Parrot.Test.simulate_call(handler: NoInviteHandler)

      assert reason == {:callback_not_defined, :handle_invite}
    end

    test "raises when handler is missing" do
      assert_raise KeyError, ~r/:handler/, fn ->
        Parrot.Test.simulate_call(to: "sip:100@local")
      end
    end
  end
end

# Test helper handlers are defined in test/support/test_handlers.ex
