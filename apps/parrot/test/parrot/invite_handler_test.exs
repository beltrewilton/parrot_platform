defmodule Parrot.InviteHandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.Call

  describe "behaviour definition" do
    test "defines handle_invite/1 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_invite, 1} in callbacks
    end

    test "defines handle_play_complete/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_play_complete, 2} in callbacks
    end

    test "defines handle_dtmf/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_dtmf, 2} in callbacks
    end

    test "defines handle_prompt_complete/3 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_prompt_complete, 3} in callbacks
    end

    test "defines handle_bridge_complete/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_bridge_complete, 2} in callbacks
    end

    test "defines handle_fork_complete/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_fork_complete, 2} in callbacks
    end

    test "defines handle_record_complete/3 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_record_complete, 3} in callbacks
    end

    test "defines handle_conference_join/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_conference_join, 2} in callbacks
    end

    test "defines handle_conference_leave/3 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_conference_leave, 3} in callbacks
    end

    test "defines handle_fork_media_connected/2 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_fork_media_connected, 2} in callbacks
    end

    test "defines handle_hangup/1 callback" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert {:handle_hangup, 1} in callbacks
    end

    test "defines all 11 expected callbacks" do
      callbacks = Parrot.InviteHandler.behaviour_info(:callbacks)
      assert length(callbacks) == 11
    end
  end

  describe "use Parrot.InviteHandler" do
    defmodule MinimalHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> play("welcome.wav")
      end
    end

    test "provides default handle_play_complete/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_play_complete("file.wav", call)
    end

    test "provides default handle_dtmf/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_dtmf("1", call)
    end

    test "provides default handle_prompt_complete/3 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_prompt_complete("file.wav", "123", call)
    end

    test "provides default handle_bridge_complete/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_bridge_complete(:answered, call)
    end

    test "provides default handle_fork_complete/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_fork_complete(:answered, call)
    end

    test "provides default handle_record_complete/3 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_record_complete("file.wav", 5000, call)
    end

    test "provides default handle_conference_join/2 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_conference_join("room-123", call)
    end

    test "provides default handle_conference_leave/3 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_conference_leave("room-123", :normal, call)
    end

    test "provides default handle_fork_media_connected/2 implementation" do
      call = Call.new()

      assert {:noreply, ^call} =
               MinimalHandler.handle_fork_media_connected("wss://service.com", call)
    end

    test "provides default handle_hangup/1 implementation" do
      call = Call.new()
      assert {:noreply, ^call} = MinimalHandler.handle_hangup(call)
    end

    test "imports Parrot.Call functions for pipeline operations" do
      invite = Call.new(from: "sip:alice@example.com", to: "sip:100@pbx.local")
      result = MinimalHandler.handle_invite(invite)

      # Verify the pipeline operations were applied
      operations = Call.get_operations(result)
      assert [{:answer, []}, {:play, "welcome.wav", []}] = operations
    end
  end

  describe "overriding callbacks" do
    defmodule CustomHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> assign(:menu, :main)
        |> play("welcome.wav")
      end

      def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
        call
        |> assign(:menu, :sales)
        |> play("sales-menu.wav")
      end

      def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
        call
        |> assign(:menu, :support)
        |> bridge("sip:support@internal")
      end

      def handle_dtmf(:timeout, call) do
        call |> play("goodbye.wav")
      end

      def handle_dtmf(_digit, call) do
        call |> play("invalid-option.wav")
      end

      def handle_play_complete("goodbye.wav", call) do
        call |> hangup()
      end

      def handle_play_complete(_filename, call) do
        {:noreply, call}
      end

      def handle_hangup(call) do
        # Custom cleanup logic
        {:noreply, %{call | assigns: Map.put(call.assigns, :cleaned_up, true)}}
      end
    end

    test "handle_invite returns pipeline with answer and play" do
      invite = Call.new(from: "sip:alice@example.com", to: "sip:100@pbx.local")
      result = CustomHandler.handle_invite(invite)

      assert result.assigns == %{menu: :main}
      operations = Call.get_operations(result)
      assert [{:answer, []}, {:play, "welcome.wav", []}] = operations
    end

    test "handle_dtmf pattern matches on digit and assigns" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("1", call)

      assert result.assigns.menu == :sales
      operations = Call.get_operations(result)
      assert [{:play, "sales-menu.wav", []}] = operations
    end

    test "handle_dtmf routes to sales menu on digit 1" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("1", call)

      assert result.assigns.menu == :sales
    end

    test "handle_dtmf routes to support on digit 2" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("2", call)

      assert result.assigns.menu == :support
      operations = Call.get_operations(result)
      assert [{:bridge, "sip:support@internal", []}] = operations
    end

    test "handle_dtmf handles timeout" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf(:timeout, call)

      operations = Call.get_operations(result)
      assert [{:play, "goodbye.wav", []}] = operations
    end

    test "handle_dtmf handles invalid digits with fallback" do
      call = Call.new(assigns: %{menu: :main})
      result = CustomHandler.handle_dtmf("9", call)

      operations = Call.get_operations(result)
      assert [{:play, "invalid-option.wav", []}] = operations
    end

    test "handle_play_complete can trigger hangup" do
      call = Call.new()
      result = CustomHandler.handle_play_complete("goodbye.wav", call)

      operations = Call.get_operations(result)
      assert [{:hangup, []}] = operations
    end

    test "handle_play_complete with other files returns noreply" do
      call = Call.new()
      assert {:noreply, ^call} = CustomHandler.handle_play_complete("welcome.wav", call)
    end

    test "handle_hangup can perform custom cleanup" do
      call = Call.new(assigns: %{menu: :main})
      {:noreply, result} = CustomHandler.handle_hangup(call)

      assert result.assigns.cleaned_up == true
    end
  end

  describe "pattern matching on call state" do
    defmodule StatefulHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> assign(:retries, 0)
        |> play("welcome.wav")
      end

      def handle_dtmf(:timeout, %{assigns: %{retries: retries}} = call) when retries < 3 do
        call
        |> assign(:retries, retries + 1)
        |> play("please-try-again.wav")
      end

      def handle_dtmf(:timeout, call) do
        call
        |> play("goodbye.wav")
        |> hangup()
      end
    end

    test "increments retry counter on timeout" do
      call = Call.new(assigns: %{retries: 0})
      result = StatefulHandler.handle_dtmf(:timeout, call)

      assert result.assigns.retries == 1
      operations = Call.get_operations(result)
      assert [{:play, "please-try-again.wav", []}] = operations
    end

    test "hangs up after max retries" do
      call = Call.new(assigns: %{retries: 3})
      result = StatefulHandler.handle_dtmf(:timeout, call)

      operations = Call.get_operations(result)
      assert [{:play, "goodbye.wav", []}, {:hangup, []}] = operations
    end

    test "allows multiple retries before hanging up" do
      # First timeout
      call = Call.new(assigns: %{retries: 0})
      call = StatefulHandler.handle_dtmf(:timeout, call)
      assert call.assigns.retries == 1

      # Second timeout - need to clear operations for next iteration
      call = %{call | __operations__: []}
      call = StatefulHandler.handle_dtmf(:timeout, call)
      assert call.assigns.retries == 2

      # Third timeout
      call = %{call | __operations__: []}
      call = StatefulHandler.handle_dtmf(:timeout, call)
      assert call.assigns.retries == 3

      # Fourth timeout - should hangup
      call = %{call | __operations__: []}
      result = StatefulHandler.handle_dtmf(:timeout, call)
      operations = Call.get_operations(result)
      assert [{:play, "goodbye.wav", []}, {:hangup, []}] = operations
    end
  end

  describe "bridge completion handling" do
    defmodule BridgeHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> bridge("sip:dest@somewhere")
      end

      def handle_bridge_complete(:answered, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :bridged, true)}}
      end

      def handle_bridge_complete({:failed, :busy}, call) do
        call |> play("user-busy.wav")
      end

      def handle_bridge_complete({:failed, :no_answer}, call) do
        call |> play("no-answer.wav")
      end
    end

    test "handles successful bridge" do
      call = Call.new()
      {:noreply, result} = BridgeHandler.handle_bridge_complete(:answered, call)

      assert result.assigns.bridged == true
    end

    test "handles busy failure" do
      call = Call.new()
      result = BridgeHandler.handle_bridge_complete({:failed, :busy}, call)

      operations = Call.get_operations(result)
      assert [{:play, "user-busy.wav", []}] = operations
    end

    test "handles no_answer failure" do
      call = Call.new()
      result = BridgeHandler.handle_bridge_complete({:failed, :no_answer}, call)

      operations = Call.get_operations(result)
      assert [{:play, "no-answer.wav", []}] = operations
    end
  end

  describe "conference handling" do
    defmodule ConferenceHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> assign(:room, "room-123")
      end

      def handle_conference_join(room, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :in_conference, room)}}
      end

      def handle_conference_leave(room, reason, call) do
        {:noreply,
         %{call | assigns: Map.merge(call.assigns, %{left_room: room, leave_reason: reason})}}
      end
    end

    test "tracks conference join" do
      call = Call.new()
      {:noreply, result} = ConferenceHandler.handle_conference_join("room-123", call)

      assert result.assigns.in_conference == "room-123"
    end

    test "tracks conference leave with reason" do
      call = Call.new()
      {:noreply, result} = ConferenceHandler.handle_conference_leave("room-123", :kicked, call)

      assert result.assigns.left_room == "room-123"
      assert result.assigns.leave_reason == :kicked
    end
  end

  describe "recording handling" do
    defmodule RecordingHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
        |> record("voicemail.wav", max_duration: 60_000)
      end

      def handle_record_complete(filename, duration, call) do
        {:noreply,
         %{
           call
           | assigns:
               Map.merge(call.assigns, %{
                 recording: filename,
                 duration: duration
               })
         }}
      end
    end

    test "tracks recording completion with metadata" do
      call = Call.new()
      {:noreply, result} = RecordingHandler.handle_record_complete("voicemail.wav", 30_000, call)

      assert result.assigns.recording == "voicemail.wav"
      assert result.assigns.duration == 30_000
    end
  end

  describe "media fork handling" do
    defmodule MediaForkHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        invite
        |> answer()
      end

      def handle_fork_media_connected(url, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :ai_stream, url)}}
      end
    end

    test "tracks media fork connection" do
      call = Call.new()

      {:noreply, result} =
        MediaForkHandler.handle_fork_media_connected("wss://ai-service.com/stream", call)

      assert result.assigns.ai_stream == "wss://ai-service.com/stream"
    end
  end

  describe "prompt complete handling" do
    defmodule PromptHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        # Note: prompt/3 DSL is blocked pending MediaSession DTMF support
        # This test only verifies the callback handling
        invite
        |> answer()
        |> play("enter-pin.wav")
      end

      def handle_prompt_complete("enter-pin.wav", digits, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :pin, digits)}}
      end

      def handle_prompt_complete(_filename, _digits, call) do
        {:noreply, call}
      end
    end

    test "captures collected digits from prompt callback" do
      call = Call.new()
      {:noreply, result} = PromptHandler.handle_prompt_complete("enter-pin.wav", "1234", call)

      assert result.assigns.pin == "1234"
    end
  end

  describe "fork complete handling" do
    defmodule ForkHandler do
      use Parrot.InviteHandler

      def handle_invite(invite) do
        destinations = [
          {"sip:alice@device1", []},
          {"sip:alice@device2", []}
        ]

        invite
        |> answer()
        |> fork(destinations, strategy: :first_answer)
      end

      def handle_fork_complete({:answered, destination}, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :answered_by, destination)}}
      end

      def handle_fork_complete({:failed, reason}, call) do
        call |> play("all-lines-busy.wav")
      end
    end

    test "tracks which destination answered" do
      call = Call.new()

      {:noreply, result} =
        ForkHandler.handle_fork_complete({:answered, "sip:alice@device2"}, call)

      assert result.assigns.answered_by == "sip:alice@device2"
    end

    test "handles all destinations failing" do
      call = Call.new()
      result = ForkHandler.handle_fork_complete({:failed, :all_busy}, call)

      operations = Call.get_operations(result)
      assert [{:play, "all-lines-busy.wav", []}] = operations
    end
  end
end
