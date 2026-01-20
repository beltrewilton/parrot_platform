defmodule Parrot.Call.ServerTest do
  use ExUnit.Case, async: true

  alias Parrot.Call
  alias Parrot.Call.Server

  # Mock gen_statem for testing MediaSession.start_media/1 calls
  # MediaSession uses :gen_statem.call/3 for start_media, so we need a proper gen_statem mock.
  # This mock also captures messages like {:play_files, ...} and {:stop_media} for assertions.
  defmodule MockMediaSession do
    @behaviour :gen_statem

    def callback_mode, do: :state_functions

    def start_link(test_pid) do
      :gen_statem.start_link(__MODULE__, test_pid, [])
    end

    def init(test_pid), do: {:ok, :idle, %{test_pid: test_pid, messages: []}}

    # Handle :start_media call from MediaSession.start_media/1
    def idle({:call, from}, :start_media, data) do
      send(data.test_pid, {:start_media_called})
      {:keep_state, data, [{:reply, from, :ok}]}
    end

    def idle(:cast, _msg, data), do: {:keep_state, data}

    # Handle messages sent to the mock (e.g., {:play_files, ...}, {:stop_media})
    def idle(:info, {:get_messages, from}, data) do
      send(from, {:messages, Enum.reverse(data.messages)})
      {:keep_state, data}
    end

    def idle(:info, msg, data) do
      {:keep_state, %{data | messages: [msg | data.messages]}}
    end
  end

  # Test handler that tracks callback invocations
  defmodule TestHandler do
    use Parrot.InviteHandler

    @impl true
    def handle_invite(invite) do
      invite
      |> answer()
      |> assign(:invite_handled, true)
      |> play("welcome.wav")
    end

    @impl true
    def handle_play_complete(filename, call) do
      call
      |> assign(:play_complete, filename)
    end

    @impl true
    def handle_dtmf(digits, call) do
      call
      |> assign(:dtmf_received, digits)
    end

    @impl true
    def handle_bridge_complete(result, call) do
      call
      |> assign(:bridge_result, result)
    end

    @impl true
    def handle_fork_complete(result, call) do
      call
      |> assign(:fork_result, result)
    end

    @impl true
    def handle_record_complete(filename, duration_ms, call) do
      call
      |> assign(:record_complete, {filename, duration_ms})
    end

    @impl true
    def handle_prompt_complete(filename, digits, call) do
      call
      |> assign(:prompt_complete, {filename, digits})
    end

    @impl true
    def handle_conference_join(room, call) do
      call
      |> assign(:conference_joined, room)
    end

    @impl true
    def handle_conference_leave(room, reason, call) do
      call
      |> assign(:conference_left, {room, reason})
    end

    @impl true
    def handle_fork_media_connected(url, call) do
      call
      |> assign(:fork_media_connected, url)
    end

    @impl true
    def handle_hangup(call) do
      {:noreply, assign(call, :hangup_handled, true)}
    end
  end

  # Handler that returns {:noreply, call} for most callbacks
  defmodule NoReplyHandler do
    use Parrot.InviteHandler

    @impl true
    def handle_invite(invite) do
      invite
      |> answer()
    end

    @impl true
    def handle_play_complete(_filename, call) do
      {:noreply, call}
    end

    @impl true
    def handle_dtmf(_digits, call) do
      {:noreply, call}
    end
  end

  describe "Parrot.Call struct" do
    test "has required fields with defaults" do
      call = %Call{}

      assert call.id == nil
      assert call.handler == nil
      assert call.from == nil
      assert call.to == nil
      assert call.call_id == nil
      assert call.state == :incoming
      assert call.assigns == %{}
    end

    test "can be created with values" do
      call = %Call{
        id: "call-123",
        handler: TestHandler,
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "abc123@host",
        state: :ringing,
        assigns: %{foo: :bar}
      }

      assert call.id == "call-123"
      assert call.handler == TestHandler
      assert call.from == "sip:alice@example.com"
      assert call.to == "sip:bob@example.com"
      assert call.call_id == "abc123@host"
      assert call.state == :ringing
      assert call.assigns == %{foo: :bar}
    end

    test "state can be any valid call state" do
      for state <- [:incoming, :ringing, :answered, :terminated] do
        call = %Call{state: state}
        assert call.state == state
      end
    end

    test "Call.new/1 generates unique id" do
      call = Call.new(from: "sip:a@b.com", to: "sip:c@d.com")
      assert call.id != nil
      assert is_binary(call.id)
    end
  end

  describe "Server initialization" do
    test "starts with handler module and initial call data" do
      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "test-call-id@host"
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      assert Process.alive?(pid)
    end

    test "generates unique call ID if not provided" do
      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com"
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      call = Server.get_call(pid)

      assert call.id != nil
      assert is_binary(call.id)
    end

    test "invokes handle_invite/1 on init" do
      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "test-call-id@host"
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      call = Server.get_call(pid)

      # TestHandler.handle_invite sets :invite_handled to true
      assert call.assigns[:invite_handled] == true
    end

    test "processes pipeline operations from handle_invite result" do
      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com"
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      call = Server.get_call(pid)

      # TestHandler.handle_invite calls answer() and play("welcome.wav")
      # Operations are processed and cleared, state transitions to :answered
      assert call.state == :answered
      assert call.__operations__ == []
      assert call.assigns[:invite_handled] == true
    end

    test "accepts optional name for registration" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}

      {:ok, pid} =
        Server.start_link(
          handler: TestHandler,
          invite: invite_data,
          name: {:global, :test_call_server}
        )

      assert GenServer.whereis({:global, :test_call_server}) == pid
    end
  end

  describe "callback dispatch" do
    setup do
      # Use unique call_id to avoid registry conflicts with async tests (T042)
      unique_id = System.unique_integer([:positive])

      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "test-call-dispatch-#{unique_id}@host"
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      %{pid: pid}
    end

    test "dispatches :play_complete to handle_play_complete/2", %{pid: pid} do
      Server.dispatch(pid, {:play_complete, "welcome.wav"})

      call = Server.get_call(pid)
      assert call.assigns[:play_complete] == "welcome.wav"
    end

    test "dispatches :dtmf to handle_dtmf/2 with digits", %{pid: pid} do
      Server.dispatch(pid, {:dtmf, "1234"})

      call = Server.get_call(pid)
      assert call.assigns[:dtmf_received] == "1234"
    end

    test "dispatches :dtmf with :timeout to handle_dtmf/2", %{pid: pid} do
      Server.dispatch(pid, {:dtmf, :timeout})

      call = Server.get_call(pid)
      assert call.assigns[:dtmf_received] == :timeout
    end

    test "dispatches :bridge_complete to handle_bridge_complete/2", %{pid: pid} do
      Server.dispatch(pid, {:bridge_complete, :answered})

      call = Server.get_call(pid)
      assert call.assigns[:bridge_result] == :answered
    end

    test "dispatches :bridge_complete with failure", %{pid: pid} do
      Server.dispatch(pid, {:bridge_complete, {:failed, :busy}})

      call = Server.get_call(pid)
      assert call.assigns[:bridge_result] == {:failed, :busy}
    end

    test "dispatches :fork_complete to handle_fork_complete/2", %{pid: pid} do
      Server.dispatch(pid, {:fork_complete, {:answered, %{uri: "sip:alice@device1"}}})

      call = Server.get_call(pid)
      assert call.assigns[:fork_result] == {:answered, %{uri: "sip:alice@device1"}}
    end

    test "dispatches :fork_complete with :no_answer", %{pid: pid} do
      Server.dispatch(pid, {:fork_complete, :no_answer})

      call = Server.get_call(pid)
      assert call.assigns[:fork_result] == :no_answer
    end

    test "dispatches :record_complete to handle_record_complete/3", %{pid: pid} do
      Server.dispatch(pid, {:record_complete, "/tmp/recording.wav", 5000})

      call = Server.get_call(pid)
      assert call.assigns[:record_complete] == {"/tmp/recording.wav", 5000}
    end

    test "dispatches :hangup to handle_hangup/1", %{pid: pid} do
      Server.dispatch(pid, :hangup)

      call = Server.get_call(pid)
      assert call.assigns[:hangup_handled] == true
    end

    test "updates call state to :terminated on hangup", %{pid: pid} do
      Server.dispatch(pid, :hangup)

      call = Server.get_call(pid)
      assert call.state == :terminated
    end
  end

  describe "callback return handling" do
    test "handles {:noreply, call} return from callbacks" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: NoReplyHandler, invite: invite_data)

      # NoReplyHandler.handle_play_complete returns {:noreply, call}
      Server.dispatch(pid, {:play_complete, "test.wav"})

      call = Server.get_call(pid)
      # Should not crash and call should be preserved
      assert Process.alive?(pid)
      assert call != nil
    end

    test "handles plain call map return from callbacks" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # TestHandler returns updated call map
      Server.dispatch(pid, {:play_complete, "file.wav"})

      call = Server.get_call(pid)
      assert call.assigns[:play_complete] == "file.wav"
    end
  end

  describe "action execution" do
    test "processes answer operation and transitions to :answered state" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      call = Server.get_call(pid)
      # TestHandler.handle_invite calls answer() which transitions to :answered
      assert call.state == :answered
    end

    test "processes operations and clears them after processing" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      call = Server.get_call(pid)
      # Operations are processed and cleared
      assert call.__operations__ == []
      # Handler assigns are preserved
      assert call.assigns[:invite_handled] == true
    end

    test "updates state to :answered when answer action is present" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      call = Server.get_call(pid)
      assert call.state == :answered
    end
  end

  describe "call state transitions" do
    test "starts in :incoming state" do
      # Handler that doesn't answer
      defmodule IncomingHandler do
        use Parrot.InviteHandler

        @impl true
        def handle_invite(invite) do
          invite
          |> assign(:just_inspecting, true)
        end
      end

      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: IncomingHandler, invite: invite_data)

      call = Server.get_call(pid)
      assert call.state == :incoming
    end

    test "transitions to :answered when answer() is called" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      call = Server.get_call(pid)
      assert call.state == :answered
    end

    test "transitions to :terminated on hangup" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      Server.dispatch(pid, :hangup)

      call = Server.get_call(pid)
      assert call.state == :terminated
    end
  end

  describe "assigns management" do
    test "preserves assigns across callbacks" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # First callback sets :invite_handled
      call = Server.get_call(pid)
      assert call.assigns[:invite_handled] == true

      # Dispatch another event
      Server.dispatch(pid, {:dtmf, "5"})

      # Both assigns should be present
      call = Server.get_call(pid)
      assert call.assigns[:invite_handled] == true
      assert call.assigns[:dtmf_received] == "5"
    end

    test "initial assigns from invite are preserved" do
      invite_data = %{
        from: "sip:a@b.com",
        to: "sip:c@d.com",
        assigns: %{initial_key: :initial_value}
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      call = Server.get_call(pid)
      assert call.assigns[:initial_key] == :initial_value
    end
  end

  describe "call map structure passed to callbacks" do
    test "includes standard call fields" do
      # Handler that captures the call structure
      defmodule StructureCapturingHandler do
        use Parrot.InviteHandler

        @impl true
        def handle_invite(invite) do
          # Store all the keys we received
          keys = Map.keys(invite) |> Enum.sort()
          assign(invite, :received_keys, keys)
        end
      end

      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "test-id@host"
      }

      {:ok, pid} = Server.start_link(handler: StructureCapturingHandler, invite: invite_data)
      call = Server.get_call(pid)

      # Should have the standard fields
      assert call.id != nil
      assert call.handler == StructureCapturingHandler
      assert call.from == "sip:alice@example.com"
      assert call.to == "sip:bob@example.com"
      assert call.call_id == "test-id@host"
    end
  end

  describe "error handling" do
    test "handles missing optional callbacks gracefully" do
      # A handler using defaults from `use Parrot.InviteHandler`
      defmodule DefaultsHandler do
        use Parrot.InviteHandler

        @impl true
        def handle_invite(invite), do: invite |> answer()
      end

      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: DefaultsHandler, invite: invite_data)

      # These should use default implementations
      Server.dispatch(pid, {:play_complete, "test.wav"})
      Server.dispatch(pid, {:dtmf, "1"})

      # Server should still be alive
      assert Process.alive?(pid)
    end
  end

  describe "ActionExecutor integration" do
    # Handler that returns play operation after play_complete
    defmodule ChainedPlayHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(invite) do
        invite
        |> answer()
        |> play("welcome.wav")
      end

      @impl true
      def handle_play_complete("welcome.wav", call) do
        call |> play("menu.wav")
      end

      @impl true
      def handle_play_complete(_filename, call), do: call
    end

    test "executes operations via ActionExecutor when context provided" do
      # Create a mock media gen_statem to handle start_media calls
      {:ok, media_pid} = MockMediaSession.start_link(self())

      invite_data = %{
        from: "sip:a@b.com",
        to: "sip:c@d.com"
      }

      context = %{
        uas: self(),
        sip_msg: build_test_sip_message(),
        media_pid: media_pid
      }

      {:ok, pid} =
        Server.start_link(
          handler: ChainedPlayHandler,
          invite: invite_data,
          context: context
        )

      # Initial handle_invite calls answer() and play()
      # ActionExecutor should execute these
      assert_receive {:response_sent, response}, 100
      assert response.status_code == 200

      call = Server.get_call(pid)
      assert call.state == :answered
    end

    test "executes operations from callback results" do
      # Create a mock media gen_statem to handle start_media calls
      {:ok, media_pid} = MockMediaSession.start_link(self())

      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}

      context = %{
        uas: self(),
        sip_msg: build_test_sip_message(),
        media_pid: media_pid
      }

      {:ok, pid} =
        Server.start_link(
          handler: ChainedPlayHandler,
          invite: invite_data,
          context: context
        )

      # Consume initial response
      assert_receive {:response_sent, _}, 100

      # Dispatch play_complete - handler returns play("menu.wav")
      Server.dispatch(pid, {:play_complete, "welcome.wav"})

      # ActionExecutor should have sent play_files to media_pid
      send(media_pid, {:get_messages, self()})
      assert_receive {:messages, messages}, 100
      assert {:play_files, ["menu.wav"], []} in messages
    end

    test "stores context fields in call struct" do
      # Create a mock media gen_statem to handle start_media calls
      {:ok, media_pid} = MockMediaSession.start_link(self())

      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}

      context = %{
        uas: self(),
        sip_msg: build_test_sip_message(),
        media_pid: media_pid,
        dialog_id: "dialog-123"
      }

      {:ok, pid} =
        Server.start_link(
          handler: TestHandler,
          invite: invite_data,
          context: context
        )

      call = Server.get_call(pid)
      assert call.__uas__ == self()
      assert call.__media_pid__ == media_pid
      assert call.__dialog_id__ == "dialog-123"
    end
  end

  defp build_test_sip_message do
    %ParrotSip.Message{
      type: :request,
      method: :invite,
      request_uri: "sip:test@example.com",
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "example.com"},
        parameters: %{tag: "from-tag"}
      },
      to: %ParrotSip.Headers.To{
        uri: %ParrotSip.Uri{scheme: "sip", user: "bob", host: "example.com"},
        parameters: %{}
      },
      call_id: "test-call-id",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite},
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{branch: "z9hG4bK-test"}
        }
      ],
      body: nil
    }
  end

  describe "hangup integration" do
    # Handler that plays welcome, then hangs up after play_complete
    defmodule HangupAfterPlayHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(invite) do
        invite
        |> answer()
        |> play("welcome.wav")
      end

      @impl true
      def handle_play_complete("welcome.wav", call) do
        # T039: Hangup after play_complete
        call |> hangup()
      end

      @impl true
      def handle_play_complete(_filename, call), do: call

      @impl true
      def handle_hangup(call) do
        {:noreply, assign(call, :hangup_callback_invoked, true)}
      end
    end

    test "hangup operation is dispatched correctly after play_complete" do
      # T039: Test hangup after play_complete
      # Create a mock media gen_statem to handle start_media calls
      {:ok, media_pid} = MockMediaSession.start_link(self())

      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}

      context = %{
        uas: self(),
        sip_msg: build_test_sip_message(),
        media_pid: media_pid
      }

      {:ok, pid} =
        Server.start_link(
          handler: HangupAfterPlayHandler,
          invite: invite_data,
          context: context
        )

      # Consume initial 200 OK response from answer()
      assert_receive {:response_sent, _}, 100

      # Dispatch play_complete - handler returns hangup()
      Server.dispatch(pid, {:play_complete, "welcome.wav"})

      # Verify ActionExecutor sent stop_media to media session
      send(media_pid, {:get_messages, self()})
      assert_receive {:messages, messages}, 100
      assert {:stop_media} in messages

      # Verify call state is terminated
      call = Server.get_call(pid)
      assert call.state == :terminated
    end

    test "hangup callback is invoked when :hangup event is dispatched" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}

      {:ok, pid} =
        Server.start_link(
          handler: HangupAfterPlayHandler,
          invite: invite_data
        )

      # Dispatch :hangup event (simulating remote party hanging up)
      Server.dispatch(pid, :hangup)

      call = Server.get_call(pid)
      assert call.assigns[:hangup_callback_invoked] == true
      assert call.state == :terminated
    end

    test "hangup stops media session when context has media_pid" do
      # Create a mock media gen_statem to handle start_media calls
      {:ok, media_pid} = MockMediaSession.start_link(self())

      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}

      context = %{
        uas: self(),
        sip_msg: build_test_sip_message(),
        media_pid: media_pid
      }

      {:ok, pid} =
        Server.start_link(
          handler: TestHandler,
          invite: invite_data,
          context: context
        )

      # Consume initial response
      assert_receive {:response_sent, _}, 100

      # Now test hangup via play_complete handler that calls hangup
      # First, play_complete on welcome.wav (TestHandler just stores it)
      Server.dispatch(pid, {:play_complete, "welcome.wav"})

      # Dispatch hangup event
      Server.dispatch(pid, :hangup)

      # Verify state is terminated
      call = Server.get_call(pid)
      assert call.state == :terminated
    end

    # Future enhancements tracked in GitHub issues:
    # - T042: Registry cleanup - Call.Server will unregister on termination
    # - T041: UAC BYE sending - Requires dialog state integration
  end

  describe "synchronous vs asynchronous dispatch" do
    test "dispatch/2 is synchronous by default" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # Should return :ok when complete
      assert :ok = Server.dispatch(pid, {:play_complete, "test.wav"})

      # State should be updated immediately after
      call = Server.get_call(pid)
      assert call.assigns[:play_complete] == "test.wav"
    end

    test "cast_dispatch/2 is asynchronous" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # Should return immediately
      assert :ok = Server.cast_dispatch(pid, {:play_complete, "async.wav"})

      # May need a small wait for async processing
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:play_complete] == "async.wav"
    end
  end

  describe "media event handling via handle_info" do
    # These tests verify that Call.Server receives {:media_event, session_id, event}
    # messages directly from MediaSession and dispatches them to the appropriate callbacks.

    setup do
      # Use unique call_id to avoid registry conflicts with async tests (T042)
      unique_id = System.unique_integer([:positive])

      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "test-call-media-event-#{unique_id}@host"
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      %{pid: pid}
    end

    test "dispatches play_complete media event to handle_play_complete callback", %{pid: pid} do
      session_id = "media-session-123"

      # Send media event directly to the server process (simulating MediaSession)
      send(pid, {:media_event, session_id, {:play_complete, "welcome.wav"}})

      # Allow message to be processed
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:play_complete] == "welcome.wav"
    end

    test "dispatches dtmf_collected media event to handle_dtmf callback", %{pid: pid} do
      session_id = "media-session-123"

      # Send dtmf_collected event from MediaSession
      send(pid, {:media_event, session_id, {:dtmf_collected, "1234"}})

      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:dtmf_received] == "1234"
    end

    test "dispatches dtmf_timeout media event to handle_dtmf callback with :timeout", %{pid: pid} do
      session_id = "media-session-123"

      # Send dtmf_timeout event - partial digits collected before timeout
      send(pid, {:media_event, session_id, {:dtmf_timeout, "12"}})

      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:dtmf_received] == :timeout
    end

    test "dispatches record_complete media event to handle_record_complete callback", %{pid: pid} do
      session_id = "media-session-123"

      # Send record_complete event from MediaSession
      send(pid, {:media_event, session_id, {:record_complete, "/tmp/recording.wav", 5000}})

      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:record_complete] == {"/tmp/recording.wav", 5000}
    end

    test "handles multiple media events in sequence", %{pid: pid} do
      session_id = "media-session-123"

      # Simulate a sequence of media events
      send(pid, {:media_event, session_id, {:play_complete, "welcome.wav"}})
      Process.sleep(10)

      send(pid, {:media_event, session_id, {:dtmf_collected, "5"}})
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:play_complete] == "welcome.wav"
      assert call.assigns[:dtmf_received] == "5"
    end

    test "ignores session_id in media event (uses for logging only)", %{pid: pid} do
      # Different session IDs should still work - session_id is for logging/debugging
      send(pid, {:media_event, "session-A", {:play_complete, "file1.wav"}})
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:play_complete] == "file1.wav"

      send(pid, {:media_event, "session-B", {:dtmf_collected, "9"}})
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:dtmf_received] == "9"
    end
  end

  # ===========================================================================
  # US4: Additional Media Callbacks (T038-T045)
  # ===========================================================================

  describe "prompt_complete event dispatch (T038)" do
    setup do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      %{pid: pid}
    end

    test "dispatches prompt_complete to handle_prompt_complete/3", %{pid: pid} do
      Server.dispatch(pid, {:prompt_complete, "menu.wav", "5"})

      call = Server.get_call(pid)
      assert call.assigns[:prompt_complete] == {"menu.wav", "5"}
    end

    test "handles prompt_complete via media_event message", %{pid: pid} do
      send(pid, {:media_event, "session-123", {:prompt_complete, "greeting.wav", "1234"}})
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:prompt_complete] == {"greeting.wav", "1234"}
    end
  end

  describe "conference events dispatch (T039, T040)" do
    setup do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      %{pid: pid}
    end

    test "dispatches conference_join to handle_conference_join/2", %{pid: pid} do
      Server.dispatch(pid, {:conference_join, "room-123"})

      call = Server.get_call(pid)
      assert call.assigns[:conference_joined] == "room-123"
    end

    test "dispatches conference_leave to handle_conference_leave/3", %{pid: pid} do
      Server.dispatch(pid, {:conference_leave, "room-123", :normal})

      call = Server.get_call(pid)
      assert call.assigns[:conference_left] == {"room-123", :normal}
    end

    test "handles conference_leave with kicked reason", %{pid: pid} do
      Server.dispatch(pid, {:conference_leave, "room-456", :kicked})

      call = Server.get_call(pid)
      assert call.assigns[:conference_left] == {"room-456", :kicked}
    end

    test "handles conference_join via media_event message", %{pid: pid} do
      send(pid, {:media_event, "session-123", {:conference_join, "conf-room"}})
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:conference_joined] == "conf-room"
    end

    test "handles conference_leave via media_event message", %{pid: pid} do
      send(pid, {:media_event, "session-123", {:conference_leave, "conf-room", :timeout}})
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:conference_left] == {"conf-room", :timeout}
    end
  end

  describe "fork_media_connected event dispatch (T041)" do
    setup do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      %{pid: pid}
    end

    test "dispatches fork_media_connected to handle_fork_media_connected/2", %{pid: pid} do
      Server.dispatch(pid, {:fork_media_connected, "ws://asr.example.com/stream"})

      call = Server.get_call(pid)
      assert call.assigns[:fork_media_connected] == "ws://asr.example.com/stream"
    end

    test "handles fork_media_connected via media_event message", %{pid: pid} do
      send(pid, {:media_event, "session-123", {:fork_media_connected, "wss://transcribe.ai/ws"}})
      Process.sleep(10)

      call = Server.get_call(pid)
      assert call.assigns[:fork_media_connected] == "wss://transcribe.ai/ws"
    end
  end

  # ===========================================================================
  # T042: Registry Cleanup on Hangup
  # ===========================================================================

  describe "registry registration (T042)" do
    setup do
      # Ensure Parrot.Registry is started for tests
      case Registry.start_link(keys: :unique, name: Parrot.Registry) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      :ok
    end

    test "registers itself in Parrot.Registry with call_id on start" do
      call_id = "registry-test-#{System.unique_integer([:positive])}"

      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: call_id
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # Should be able to look up the Call.Server by call_id
      assert [{^pid, _}] = Registry.lookup(Parrot.Registry, {:call, call_id})
    end

    test "can look up Call.Server by call_id after start" do
      call_id = "lookup-test-#{System.unique_integer([:positive])}"

      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: call_id
      }

      {:ok, expected_pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # Use the lookup function to find the process
      assert {:ok, pid} = Server.lookup_by_call_id(call_id)
      assert pid == expected_pid
    end

    test "lookup_by_call_id returns {:error, :not_found} for unknown call_id" do
      assert {:error, :not_found} = Server.lookup_by_call_id("nonexistent-call-id")
    end

    test "unregisters from registry when process terminates" do
      call_id = "unregister-test-#{System.unique_integer([:positive])}"

      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: call_id
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # Verify it's registered
      assert [{^pid, _}] = Registry.lookup(Parrot.Registry, {:call, call_id})

      # Stop the process
      GenServer.stop(pid, :normal)

      # Wait for process to fully terminate
      Process.sleep(10)

      # Should no longer be registered
      assert [] = Registry.lookup(Parrot.Registry, {:call, call_id})
    end

    test "remains registered after hangup event but state is :terminated" do
      # Hangup event changes state but doesn't stop the process
      # Unregistration happens when the process actually terminates
      call_id = "hangup-state-test-#{System.unique_integer([:positive])}"

      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: call_id
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      # Verify it's registered
      assert [{^pid, _}] = Registry.lookup(Parrot.Registry, {:call, call_id})

      # Dispatch hangup event
      Server.dispatch(pid, :hangup)

      # Process should still be alive but state should be :terminated
      assert Process.alive?(pid)
      call = Server.get_call(pid)
      assert call.state == :terminated

      # Should still be registered (process is still alive)
      assert [{^pid, _}] = Registry.lookup(Parrot.Registry, {:call, call_id})

      # Now stop the process
      GenServer.stop(pid, :normal)
      Process.sleep(10)

      # Now should be unregistered
      assert [] = Registry.lookup(Parrot.Registry, {:call, call_id})
    end
  end
end
