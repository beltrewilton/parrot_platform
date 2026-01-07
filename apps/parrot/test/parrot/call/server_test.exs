defmodule Parrot.Call.ServerTest do
  use ExUnit.Case, async: true

  alias Parrot.Call
  alias Parrot.Call.Server

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

    test "extracts pending actions from handle_invite result" do
      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com"
      }

      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)
      call = Server.get_call(pid)

      # TestHandler.handle_invite calls answer() and play("welcome.wav")
      assert call.__answered__ == true
      assert call.__play__ == ["welcome.wav"]
    end

    test "accepts optional name for registration" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}

      {:ok, pid} = Server.start_link(
        handler: TestHandler,
        invite: invite_data,
        name: {:global, :test_call_server}
      )

      assert GenServer.whereis({:global, :test_call_server}) == pid
    end
  end

  describe "callback dispatch" do
    setup do
      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "test-call@host"
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
    test "detects answer action from call map" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      call = Server.get_call(pid)
      # TestHandler.handle_invite calls answer()
      assert call.__answered__ == true
    end

    test "detects play action from call map" do
      invite_data = %{from: "sip:a@b.com", to: "sip:c@d.com"}
      {:ok, pid} = Server.start_link(handler: TestHandler, invite: invite_data)

      call = Server.get_call(pid)
      # TestHandler.handle_invite calls play("welcome.wav")
      assert call.__play__ == ["welcome.wav"]
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
end
