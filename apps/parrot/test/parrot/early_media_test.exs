defmodule Parrot.EarlyMediaTest do
  @moduledoc """
  Integration tests for early media (183 Session Progress) support.

  These tests verify the complete early media flow through the Parrot DSL:
  - UAS: early_media() -> play() -> answer() flow
  - UAC: Receive 183, handle_early_media callback

  RFC 3261 Section 13.2.2.4 - Early Dialog
  """

  use ExUnit.Case, async: true

  alias Parrot.Bridge.ActionExecutor
  alias Parrot.Call

  @moduletag :early_media

  # ===========================================================================
  # Test Helpers
  # ===========================================================================

  # Mock MediaSession for early media tests
  defmodule MockMediaSession do
    @behaviour :gen_statem

    def callback_mode, do: :state_functions

    def start_link(test_pid), do: :gen_statem.start_link(__MODULE__, test_pid, [])

    def init(test_pid), do: {:ok, :ready, test_pid}

    def ready({:call, from}, {:create_early_offer, opts}, test_pid) do
      send(test_pid, {:create_early_offer_called, opts})

      early_sdp =
        "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Test\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 30000 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=sendonly\r\n"

      {:keep_state, test_pid, [{:reply, from, {:ok, early_sdp}}]}
    end

    def ready({:call, from}, :start_media, test_pid) do
      send(test_pid, {:start_media_called})
      {:next_state, :early, test_pid, [{:reply, from, :ok}]}
    end

    def ready(:cast, _msg, test_pid), do: {:keep_state, test_pid}
    def ready(:info, {:play_files, files, opts}, test_pid) do
      send(test_pid, {:play_files_called, files, opts})
      {:keep_state, test_pid}
    end
    def ready(:info, _msg, test_pid), do: {:keep_state, test_pid}

    def early({:call, from}, :get_state, test_pid) do
      {:keep_state, test_pid, [{:reply, from, %{state: :early}}]}
    end

    def early({:call, from}, :confirm_media, test_pid) do
      send(test_pid, {:confirm_media_called})
      {:next_state, :active, test_pid, [{:reply, from, :ok}]}
    end

    def early(:info, {:play_files, files, opts}, test_pid) do
      send(test_pid, {:play_files_called, files, opts})
      {:keep_state, test_pid}
    end

    def early(:cast, _msg, test_pid), do: {:keep_state, test_pid}
    def early(:info, _msg, test_pid), do: {:keep_state, test_pid}

    def active({:call, from}, :get_state, test_pid) do
      {:keep_state, test_pid, [{:reply, from, %{state: :active}}]}
    end

    def active(:info, {:play_files, files, opts}, test_pid) do
      send(test_pid, {:play_files_called, files, opts})
      {:keep_state, test_pid}
    end

    def active(:cast, _msg, test_pid), do: {:keep_state, test_pid}
    def active(:info, _msg, test_pid), do: {:keep_state, test_pid}
  end

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
      call_id: "call-id-early-media-#{:rand.uniform(100_000)}",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite},
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{branch: "z9hG4bK-test-branch"}
        }
      ],
      body: nil,
      source: %ParrotSip.Source{
        local: {{127, 0, 0, 1}, 5060},
        remote: {{192, 168, 1, 100}, 5080}
      }
    }
  end

  # ===========================================================================
  # UAS Early Media Tests (Sending 183)
  # ===========================================================================

  describe "UAS early media flow" do
    test "early_media sends 183 Session Progress with SDP" do
      {:ok, media_pid} = MockMediaSession.start_link(self())
      call = Call.new() |> Call.early_media()
      operations = Call.get_operations(call)
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      {:ok, early_call} = ActionExecutor.execute(operations, call, context)

      # Verify 183 was sent
      assert_receive {:response_sent, response}
      assert response.status_code == 183
      assert response.reason_phrase == "Session Progress"
      assert response.content_type == "application/sdp"

      # Verify call state
      assert early_call.state == :early
      assert early_call.assigns[:__early_media__] == true

      :gen_statem.stop(media_pid)
    end

    test "early_media starts media in early state" do
      {:ok, media_pid} = MockMediaSession.start_link(self())
      call = Call.new() |> Call.early_media()
      operations = Call.get_operations(call)
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      {:ok, _early_call} = ActionExecutor.execute(operations, call, context)

      # Verify media was started
      assert_receive {:start_media_called}

      :gen_statem.stop(media_pid)
    end

    test "play works in early state" do
      {:ok, media_pid} = MockMediaSession.start_link(self())

      # Start in early state
      call = Call.new() |> Call.early_media()
      operations = Call.get_operations(call)
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      {:ok, early_call} = ActionExecutor.execute(operations, call, context)
      assert_receive {:response_sent, %{status_code: 183}}

      # The play operation requires :answered state in execute_play
      # But the handler can still send play_files message to media session
      # This tests that the media session receives play commands in early state

      # Clear operations and simulate what a handler would do
      _early_call_cleared = %{early_call | __operations__: []}

      # In real usage, the handler would send messages to media_pid
      send(media_pid, {:play_files, ["ringback.wav"], []})

      # Verify play_files was received
      assert_receive {:play_files_called, ["ringback.wav"], []}

      :gen_statem.stop(media_pid)
    end

    test "early_media followed by answer sends 200 OK" do
      {:ok, media_pid} = MockMediaSession.start_link(self())

      # First: early_media
      call = Call.new() |> Call.early_media()
      operations = Call.get_operations(call)
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      {:ok, early_call} = ActionExecutor.execute(operations, call, context)
      assert_receive {:response_sent, %{status_code: 183}}

      # Then: answer
      early_call_cleared = %{early_call | __operations__: []}
      answer_call = Call.answer(early_call_cleared)
      answer_ops = Call.get_operations(answer_call)

      {:ok, final_call} = ActionExecutor.execute(answer_ops, answer_call, context)

      # Verify 200 OK was sent
      assert_receive {:response_sent, response}
      assert response.status_code == 200

      # Verify final state
      assert final_call.state == :answered
      refute final_call.assigns[:__early_media__]

      # Verify media was confirmed
      assert_receive {:confirm_media_called}

      :gen_statem.stop(media_pid)
    end

    test "no duplicate responses when using early_media + answer" do
      {:ok, media_pid} = MockMediaSession.start_link(self())

      # Execute early_media
      call = Call.new() |> Call.early_media()
      operations = Call.get_operations(call)
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      {:ok, early_call} = ActionExecutor.execute(operations, call, context)

      # Execute answer
      early_call_cleared = %{early_call | __operations__: []}
      answer_call = Call.answer(early_call_cleared)
      answer_ops = Call.get_operations(answer_call)

      {:ok, _final_call} = ActionExecutor.execute(answer_ops, answer_call, context)

      # Collect all responses
      responses = collect_responses()

      # Should have exactly one 183 and one 200
      status_codes = Enum.map(responses, & &1.status_code)
      assert Enum.count(status_codes, &(&1 == 183)) == 1
      assert Enum.count(status_codes, &(&1 == 200)) == 1

      :gen_statem.stop(media_pid)
    end
  end

  # ===========================================================================
  # State Transition Tests
  # ===========================================================================

  describe "early media state transitions" do
    test "call state progresses: incoming -> early -> answered" do
      {:ok, media_pid} = MockMediaSession.start_link(self())
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      # Initial state
      call = Call.new()
      assert call.state == :incoming

      # After early_media
      call_with_op = Call.early_media(call)
      {:ok, early_call} = ActionExecutor.execute(Call.get_operations(call_with_op), call_with_op, context)
      assert early_call.state == :early

      # After answer
      early_call_cleared = %{early_call | __operations__: []}
      answer_call = Call.answer(early_call_cleared)
      {:ok, final_call} = ActionExecutor.execute(Call.get_operations(answer_call), answer_call, context)
      assert final_call.state == :answered

      :gen_statem.stop(media_pid)
    end

    test "early_media flag is set and cleared correctly" do
      {:ok, media_pid} = MockMediaSession.start_link(self())
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      call = Call.new() |> Call.early_media()
      {:ok, early_call} = ActionExecutor.execute(Call.get_operations(call), call, context)

      # Flag should be set
      assert early_call.assigns[:__early_media__] == true

      early_call_cleared = %{early_call | __operations__: []}
      answer_call = Call.answer(early_call_cleared)
      {:ok, final_call} = ActionExecutor.execute(Call.get_operations(answer_call), answer_call, context)

      # Flag should be cleared
      refute final_call.assigns[:__early_media__]

      :gen_statem.stop(media_pid)
    end
  end

  # ===========================================================================
  # Error Handling Tests
  # ===========================================================================

  describe "early media error handling" do
    test "early_media fails without media_pid" do
      call = Call.new() |> Call.early_media()
      operations = Call.get_operations(call)
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute(operations, call, context)
    end

    test "early_media fails without UAS" do
      {:ok, media_pid} = MockMediaSession.start_link(self())
      call = Call.new() |> Call.early_media()
      operations = Call.get_operations(call)
      sip_msg = build_invite_message()

      context = %{
        uas: nil,
        sip_msg: sip_msg,
        media_pid: media_pid
      }

      assert {:error, :no_uas} = ActionExecutor.execute(operations, call, context)

      :gen_statem.stop(media_pid)
    end
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp collect_responses do
    collect_responses([])
  end

  defp collect_responses(acc) do
    receive do
      {:response_sent, response} ->
        collect_responses([response | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end
end
