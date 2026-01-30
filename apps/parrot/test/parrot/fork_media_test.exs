defmodule Parrot.ForkMediaTest do
  @moduledoc """
  Integration tests for media forking functionality at the DSL level.

  Tests the full fork lifecycle from Parrot.Call operations through
  ActionExecutor to MediaSession.
  """
  use ExUnit.Case, async: false

  alias Parrot.Call
  alias Parrot.Bridge.ActionExecutor

  # Mock MediaSession that tracks fork operations
  defmodule MockMediaSession do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def init(opts) do
      test_pid = Keyword.get(opts, :test_pid)

      {:ok,
       %{
         test_pid: test_pid,
         forks: %{},
         fork_counter: 0
       }}
    end

    def handle_call({:fork_media, destination, opts}, _from, state) do
      fork_id = Keyword.get(opts, :fork_id) || "fork-#{state.fork_counter + 1}"

      if state.test_pid do
        send(state.test_pid, {:fork_media_called, destination, opts})
      end

      new_forks = Map.put(state.forks, fork_id, %{destination: destination, opts: opts})
      new_state = %{state | forks: new_forks, fork_counter: state.fork_counter + 1}

      {:reply, {:ok, fork_id}, new_state}
    end

    def handle_call({:stop_fork_media, fork_id}, _from, state) do
      if state.test_pid do
        send(state.test_pid, {:stop_fork_media_called, fork_id})
      end

      if Map.has_key?(state.forks, fork_id) do
        new_forks = Map.delete(state.forks, fork_id)
        {:reply, :ok, %{state | forks: new_forks}}
      else
        {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call(:list_forks, _from, state) do
      {:reply, Map.keys(state.forks), state}
    end
  end

  describe "fork_media DSL" do
    test "fork_media/2 creates operation with destination" do
      call =
        %Call{}
        |> Call.fork_media("wss://transcription.example.com/audio")

      operations = Call.get_operations(call)
      assert [{:fork_media, "wss://transcription.example.com/audio", []}] = operations
    end

    test "fork_media/2 supports WebSocket URLs" do
      call =
        %Call{}
        |> Call.fork_media("wss://api.openai.com/v1/realtime")

      operations = Call.get_operations(call)
      assert [{:fork_media, "wss://api.openai.com/v1/realtime", []}] = operations
    end

    test "fork_media/2 supports ws:// URLs" do
      call =
        %Call{}
        |> Call.fork_media("ws://localhost:8080/audio")

      operations = Call.get_operations(call)
      assert [{:fork_media, "ws://localhost:8080/audio", []}] = operations
    end

    test "fork_media/2 supports IP tuple destinations" do
      call =
        %Call{}
        |> Call.fork_media({{192, 168, 1, 100}, 5004})

      operations = Call.get_operations(call)
      assert [{:fork_media, {{192, 168, 1, 100}, 5004}, []}] = operations
    end

    test "fork_media/3 accepts direction option" do
      call =
        %Call{}
        |> Call.fork_media("wss://example.com/audio", direction: :rx)

      operations = Call.get_operations(call)
      assert [{:fork_media, "wss://example.com/audio", [direction: :rx]}] = operations
    end

    test "fork_media/3 accepts label option" do
      call =
        %Call{}
        |> Call.fork_media("wss://example.com/audio", label: "transcription")

      operations = Call.get_operations(call)
      assert [{:fork_media, "wss://example.com/audio", [label: "transcription"]}] = operations
    end

    test "fork_media/3 accepts format option" do
      call =
        %Call{}
        |> Call.fork_media("wss://example.com/audio", format: :pcma)

      operations = Call.get_operations(call)
      assert [{:fork_media, "wss://example.com/audio", [format: :pcma]}] = operations
    end

    test "fork_media/3 accepts fork_id option" do
      call =
        %Call{}
        |> Call.fork_media("wss://example.com/audio", fork_id: "custom-fork-id")

      operations = Call.get_operations(call)
      assert [{:fork_media, "wss://example.com/audio", [fork_id: "custom-fork-id"]}] = operations
    end

    test "fork_media/3 accepts multiple options" do
      call =
        %Call{}
        |> Call.fork_media("wss://example.com/audio",
          direction: :both,
          label: "recording",
          format: :opus
        )

      operations = Call.get_operations(call)

      assert [{:fork_media, "wss://example.com/audio", opts}] = operations
      assert Keyword.get(opts, :direction) == :both
      assert Keyword.get(opts, :label) == "recording"
      assert Keyword.get(opts, :format) == :opus
    end

    test "stop_fork_media/2 creates operation with fork_id" do
      call =
        %Call{}
        |> Call.stop_fork_media("fork-abc123")

      operations = Call.get_operations(call)
      assert [{:stop_fork_media, "fork-abc123"}] = operations
    end
  end

  describe "fork_media execution" do
    setup do
      {:ok, mock_pid} = MockMediaSession.start_link(test_pid: self())
      {:ok, media_pid: mock_pid}
    end

    test "execute_fork_media creates fork via MediaSession", %{media_pid: media_pid} do
      call = %{Call.new() | state: :answered}
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      {:ok, updated_call} =
        ActionExecutor.execute_fork_media(
          call,
          context,
          "wss://example.com/audio",
          direction: :rx
        )

      assert_receive {:fork_media_called, "wss://example.com/audio", [direction: :rx]}
      assert updated_call.assigns[{:fork, "wss://example.com/audio"}] == "fork-1"
    end

    test "execute_fork_media with IP tuple destination", %{media_pid: media_pid} do
      call = %{Call.new() | state: :answered}
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      destination = {{10, 0, 0, 1}, 5000}

      {:ok, updated_call} =
        ActionExecutor.execute_fork_media(call, context, destination, [])

      assert_receive {:fork_media_called, {{10, 0, 0, 1}, 5000}, []}
      assert updated_call.assigns[{:fork, destination}] == "fork-1"
    end

    test "execute_stop_fork_media removes fork", %{media_pid: media_pid} do
      call = %{Call.new() | state: :answered}
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      # First create a fork
      {:ok, call_with_fork} =
        ActionExecutor.execute_fork_media(call, context, "wss://example.com/audio", [])

      assert_receive {:fork_media_called, _, _}

      # Then stop it
      {:ok, _updated_call} =
        ActionExecutor.execute_stop_fork_media(call_with_fork, context, "fork-1")

      assert_receive {:stop_fork_media_called, "fork-1"}
    end

    test "execute_fork_media fails when not in answered state", %{media_pid: media_pid} do
      call = Call.new()
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      result = ActionExecutor.execute_fork_media(call, context, "wss://example.com/audio", [])

      assert {:error, :invalid_state} = result
    end

    test "execute_fork_media fails without media session" do
      call = %{Call.new() | state: :answered}
      context = %{media_pid: nil, sip_msg: build_invite_message(), uas: nil}

      result = ActionExecutor.execute_fork_media(call, context, "wss://example.com/audio", [])

      assert {:error, :no_media_session} = result
    end
  end

  describe "fork_media pipeline execution" do
    setup do
      {:ok, mock_pid} = MockMediaSession.start_link(test_pid: self())
      {:ok, media_pid: mock_pid}
    end

    test "executes fork_media in operation pipeline", %{media_pid: media_pid} do
      call =
        %{Call.new() | state: :answered}
        |> Call.fork_media("wss://example.com/audio", direction: :rx)

      operations = Call.get_operations(call)
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)

      assert_receive {:fork_media_called, "wss://example.com/audio", [direction: :rx]}
      assert updated_call.assigns[{:fork, "wss://example.com/audio"}] == "fork-1"
    end

    test "executes multiple fork_media operations", %{media_pid: media_pid} do
      call =
        %{Call.new() | state: :answered}
        |> Call.fork_media("wss://transcription.example.com/audio", label: "transcription")
        |> Call.fork_media("wss://recording.example.com/audio", label: "recording")

      operations = Call.get_operations(call)
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)

      assert_receive {:fork_media_called, "wss://transcription.example.com/audio",
                      [label: "transcription"]}

      assert_receive {:fork_media_called, "wss://recording.example.com/audio",
                      [label: "recording"]}

      assert updated_call.assigns[{:fork, "wss://transcription.example.com/audio"}] == "fork-1"
      assert updated_call.assigns[{:fork, "wss://recording.example.com/audio"}] == "fork-2"
    end

    test "executes fork and stop in sequence", %{media_pid: media_pid} do
      call =
        %{Call.new() | state: :answered}
        |> Call.fork_media("wss://example.com/audio")
        |> Call.stop_fork_media("fork-1")

      operations = Call.get_operations(call)
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      assert_receive {:fork_media_called, "wss://example.com/audio", []}
      assert_receive {:stop_fork_media_called, "fork-1"}
    end
  end

  describe "InviteHandler callbacks" do
    defmodule TestForkHandler do
      use Parrot.InviteHandler

      def handle_invite(call) do
        call
        |> answer()
        |> fork_media("wss://transcription.example.com/audio", direction: :rx)
      end

      def handle_fork_media_connected(fork_id, call) do
        {:noreply, %{call | assigns: Map.put(call.assigns, :connected_fork, fork_id)}}
      end

      def handle_fork_media_error(fork_id, reason, call) do
        {:noreply,
         %{
           call
           | assigns: Map.put(call.assigns, :fork_error, {fork_id, reason})
         }}
      end
    end

    test "handle_fork_media_connected callback receives fork_id" do
      call = Call.new()
      {:noreply, updated_call} = TestForkHandler.handle_fork_media_connected("fork-abc123", call)

      assert updated_call.assigns.connected_fork == "fork-abc123"
    end

    test "handle_fork_media_error callback receives fork_id and reason" do
      call = Call.new()

      {:noreply, updated_call} =
        TestForkHandler.handle_fork_media_error("fork-abc123", :connection_refused, call)

      assert updated_call.assigns.fork_error == {"fork-abc123", :connection_refused}
    end

    test "handler can use fork_media in handle_invite" do
      call = Call.new()
      result = TestForkHandler.handle_invite(call)

      operations = Call.get_operations(result)

      assert [
               {:answer, []},
               {:fork_media, "wss://transcription.example.com/audio", [direction: :rx]}
             ] = operations
    end
  end

  describe "concurrent forks" do
    setup do
      {:ok, mock_pid} = MockMediaSession.start_link(test_pid: self())
      {:ok, media_pid: mock_pid}
    end

    test "supports multiple concurrent forks", %{media_pid: media_pid} do
      call =
        %{Call.new() | state: :answered}
        |> Call.fork_media("wss://asr.example.com/audio", label: "asr", direction: :rx)
        |> Call.fork_media("wss://recording.example.com/audio", label: "recording")
        |> Call.fork_media({{192, 168, 1, 50}, 5000}, label: "rtp-backup")

      operations = Call.get_operations(call)
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)

      # All three forks should be created
      assert_receive {:fork_media_called, "wss://asr.example.com/audio", _}
      assert_receive {:fork_media_called, "wss://recording.example.com/audio", _}
      assert_receive {:fork_media_called, {{192, 168, 1, 50}, 5000}, _}

      # All fork IDs should be stored
      assert updated_call.assigns[{:fork, "wss://asr.example.com/audio"}] == "fork-1"
      assert updated_call.assigns[{:fork, "wss://recording.example.com/audio"}] == "fork-2"
      assert updated_call.assigns[{:fork, {{192, 168, 1, 50}, 5000}}] == "fork-3"
    end

    test "can stop individual forks", %{media_pid: media_pid} do
      # First create multiple forks
      call =
        %{Call.new() | state: :answered}
        |> Call.fork_media("wss://asr.example.com/audio")
        |> Call.fork_media("wss://recording.example.com/audio")

      operations = Call.get_operations(call)
      context = %{media_pid: media_pid, sip_msg: build_invite_message(), uas: nil}

      {:ok, call_with_forks} = ActionExecutor.execute(operations, call, context)

      # Clear the mailbox
      receive do
        {:fork_media_called, _, _} -> :ok
      end

      receive do
        {:fork_media_called, _, _} -> :ok
      end

      # Now stop just one fork
      call_stop_one =
        call_with_forks
        |> Call.stop_fork_media("fork-1")

      stop_operations = Call.get_operations(call_stop_one)
      {:ok, _updated} = ActionExecutor.execute(stop_operations, call_with_forks, context)

      # Only fork-1 should be stopped
      assert_receive {:stop_fork_media_called, "fork-1"}
      refute_receive {:stop_fork_media_called, "fork-2"}
    end
  end

  # Helper to build a minimal SIP INVITE message for testing
  defp build_invite_message do
    %ParrotSip.Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "example.com"},
        display_name: nil,
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %ParrotSip.Headers.To{
        uri: %ParrotSip.Uri{scheme: "sip", user: "bob", host: "example.com"},
        display_name: nil,
        parameters: %{}
      },
      call_id: "call-id-12345",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite},
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-test-branch"}
        }
      ],
      body: nil,
      source: nil
    }
  end
end
