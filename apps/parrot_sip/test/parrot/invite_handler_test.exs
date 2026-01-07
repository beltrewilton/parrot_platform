defmodule Parrot.InviteHandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.InviteHandler

  describe "behaviour callbacks" do
    test "defines handle_invite/1 as required callback" do
      callbacks = InviteHandler.behaviour_info(:callbacks)
      assert {:handle_invite, 1} in callbacks
    end

    test "defines core callbacks from Task 4.1 spec" do
      callbacks = InviteHandler.behaviour_info(:callbacks)

      # Core callbacks required by Task 4.1
      core_callbacks = [
        {:handle_invite, 1},
        {:handle_play_complete, 2},
        {:handle_dtmf, 2},
        {:handle_bridge_complete, 2},
        {:handle_fork_complete, 2},
        {:handle_record_complete, 3},
        {:handle_hangup, 1}
      ]

      for callback <- core_callbacks do
        assert callback in callbacks,
               "Expected #{inspect(callback)} to be in callbacks"
      end
    end

    test "handle_invite/1 is NOT optional (required)" do
      optional = InviteHandler.behaviour_info(:optional_callbacks)
      refute {:handle_invite, 1} in optional
    end

    test "core callbacks are marked optional" do
      optional = InviteHandler.behaviour_info(:optional_callbacks)

      expected_optional = [
        {:handle_play_complete, 2},
        {:handle_dtmf, 2},
        {:handle_bridge_complete, 2},
        {:handle_fork_complete, 2},
        {:handle_record_complete, 3},
        {:handle_hangup, 1}
      ]

      for callback <- expected_optional do
        assert callback in optional,
               "Expected #{inspect(callback)} to be optional"
      end
    end
  end

  describe "implementing the behaviour" do
    defmodule MinimalHandler do
      @behaviour Parrot.InviteHandler

      @impl true
      def handle_invite(call), do: call
    end

    defmodule FullHandler do
      @behaviour Parrot.InviteHandler

      @impl true
      def handle_invite(call), do: Map.put(call, :handled, true)

      @impl true
      def handle_play_complete(_filename, call), do: call

      @impl true
      def handle_dtmf(_digits, call), do: call

      @impl true
      def handle_bridge_complete(_result, call), do: call

      @impl true
      def handle_fork_complete(_result, call), do: call

      @impl true
      def handle_record_complete(_filename, _duration, call), do: call

      @impl true
      def handle_hangup(call), do: {:noreply, call}
    end

    test "minimal handler compiles with only handle_invite/1" do
      assert function_exported?(MinimalHandler, :handle_invite, 1)
    end

    test "full handler can implement core callbacks" do
      assert function_exported?(FullHandler, :handle_invite, 1)
      assert function_exported?(FullHandler, :handle_play_complete, 2)
      assert function_exported?(FullHandler, :handle_dtmf, 2)
      assert function_exported?(FullHandler, :handle_bridge_complete, 2)
      assert function_exported?(FullHandler, :handle_fork_complete, 2)
      assert function_exported?(FullHandler, :handle_record_complete, 3)
      assert function_exported?(FullHandler, :handle_hangup, 1)
    end

    test "handle_invite returns map" do
      result = FullHandler.handle_invite(%{test: true})
      assert is_map(result)
      assert result.handled == true
    end
  end

  describe "use macro provides defaults and imports" do
    defmodule HandlerWithUseMacro do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(invite) do
        invite
        |> answer()
        |> assign(:greeted, true)
        |> play("welcome.wav")
      end

      @impl true
      def handle_play_complete("welcome.wav", call), do: call |> hangup()
      def handle_play_complete(_file, call), do: {:noreply, call}

      @impl true
      def handle_dtmf("1", call), do: call |> play("option-1.wav")
      def handle_dtmf(:timeout, call), do: call |> play("goodbye.wav")
      def handle_dtmf(_digit, call), do: call |> play("invalid.wav")
    end

    defmodule MinimalHandlerWithUse do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(invite), do: invite |> reject(486)
    end

    test "use macro imports pipeline operations" do
      invite = %{to: "sip:100@pbx.local", assigns: %{}}
      result = HandlerWithUseMacro.handle_invite(invite)

      assert result.__answered__ == true
      assert result.assigns[:greeted] == true
      assert result.__play__ == ["welcome.wav"]
    end

    test "use macro provides default handle_play_complete" do
      call = %{assigns: %{}}
      result = MinimalHandlerWithUse.handle_play_complete("any.wav", call)
      assert {:noreply, ^call} = result
    end

    test "use macro provides default handle_dtmf" do
      call = %{assigns: %{}}
      result = MinimalHandlerWithUse.handle_dtmf("5", call)
      assert {:noreply, ^call} = result
    end

    test "use macro provides default handle_bridge_complete" do
      call = %{assigns: %{}}
      result = MinimalHandlerWithUse.handle_bridge_complete(:answered, call)
      assert {:noreply, ^call} = result
    end

    test "use macro provides default handle_fork_complete" do
      call = %{assigns: %{}}
      result = MinimalHandlerWithUse.handle_fork_complete(:no_answer, call)
      assert {:noreply, ^call} = result
    end

    test "use macro provides default handle_record_complete" do
      call = %{assigns: %{}}
      result = MinimalHandlerWithUse.handle_record_complete("/tmp/file.wav", 1000, call)
      assert {:noreply, ^call} = result
    end

    test "use macro provides default handle_hangup" do
      call = %{assigns: %{}}
      result = MinimalHandlerWithUse.handle_hangup(call)
      assert {:noreply, ^call} = result
    end

    test "handler can override defaults" do
      call = %{assigns: %{}}
      result = HandlerWithUseMacro.handle_play_complete("welcome.wav", call)
      assert result.__hangup__ == true
    end
  end

  describe "pipeline operations" do
    test "answer/1 marks call as answered" do
      call = %{assigns: %{}}
      result = InviteHandler.answer(call)
      assert result.__answered__ == true
    end

    test "answer/2 accepts options" do
      call = %{assigns: %{}}
      result = InviteHandler.answer(call, codecs: [:opus])
      assert result.__answered__ == true
      assert result.__answer_opts__ == [codecs: [:opus]]
    end

    test "reject/2 marks call as rejected" do
      call = %{assigns: %{}}
      result = InviteHandler.reject(call, 486)
      assert result.__rejected__ == 486
    end

    test "hangup/1 marks call for hangup" do
      call = %{assigns: %{}}
      result = InviteHandler.hangup(call)
      assert result.__hangup__ == true
    end

    test "assign/3 adds value to assigns" do
      call = %{assigns: %{}}
      result = InviteHandler.assign(call, :key, "value")
      assert result.assigns[:key] == "value"
    end

    test "play/2 with single file" do
      call = %{assigns: %{}}
      result = InviteHandler.play(call, "file.wav")
      assert result.__play__ == ["file.wav"]
    end

    test "play/3 with options" do
      call = %{assigns: %{}}
      result = InviteHandler.play(call, "music.wav", loop: true)
      assert result.__play__ == ["music.wav"]
      assert result.__play_opts__ == [loop: true]
    end

    test "record/2 starts recording" do
      call = %{assigns: %{}}
      result = InviteHandler.record(call, "/tmp/recording.wav")
      assert result.__record__ == "/tmp/recording.wav"
    end

    test "collect_dtmf/2 collects DTMF" do
      call = %{assigns: %{}}
      result = InviteHandler.collect_dtmf(call, max: 4, timeout: 5_000)
      assert result.__collect_dtmf__ == [max: 4, timeout: 5_000]
    end

    test "bridge/2 bridges to destination" do
      call = %{assigns: %{}}
      result = InviteHandler.bridge(call, "sip:dest@somewhere")
      assert result.__bridge__ == "sip:dest@somewhere"
    end

    test "fork/2 forks to multiple destinations" do
      call = %{assigns: %{}}
      destinations = [{"sip:alice@device1", []}, {"sip:alice@device2", []}]
      result = InviteHandler.fork(call, destinations)
      assert result.__fork__ == destinations
    end
  end
end
