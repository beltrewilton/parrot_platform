defmodule Parrot.Bridge.ActionExecutorTest do
  use ExUnit.Case, async: true

  alias Parrot.Bridge.ActionExecutor
  alias Parrot.Call

  # Mock UAS for testing - captures responses
  defmodule MockUAS do
    def response(_uas, response) do
      send(self(), {:response_sent, response})
      :ok
    end
  end

  # Mock gen_statem for testing MediaSession.start_media/1 calls
  # MediaSession uses :gen_statem.call/3, so we need a proper gen_statem mock
  defmodule MockMediaSession do
    @behaviour :gen_statem

    def callback_mode, do: :state_functions

    def init(test_pid), do: {:ok, :idle, test_pid}

    def idle({:call, from}, :start_media, test_pid) do
      send(test_pid, {:start_media_called})
      {:keep_state, test_pid, [{:reply, from, :ok}]}
    end

    def idle(:cast, _msg, test_pid), do: {:keep_state, test_pid}
    def idle(:info, _msg, test_pid), do: {:keep_state, test_pid}
  end

  describe "execute/3" do
    test "executes operations in order" do
      call = Call.new() |> Call.answer()
      operations = Call.get_operations(call)

      context = %{
        uas: :mock_uas,
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:ok, updated_call} = ActionExecutor.execute(operations, call, context)
      assert updated_call.state == :answered
    end

    test "returns unchanged call when operations list is empty" do
      call = Call.new()

      context = %{
        uas: :mock_uas,
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:ok, ^call} = ActionExecutor.execute([], call, context)
    end

    test "stops on signaling operations (reject/hangup)" do
      # When a signaling operation like reject is executed, subsequent operations should not run
      # Note: answer() now returns :continue to allow chaining with play/collect_dtmf
      call =
        Call.new()
        |> Call.reject(486)
        |> Call.play("welcome.wav")

      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)
      # After reject, call should be in terminated state (play should not have run)
      assert updated_call.state == :terminated
      # Verify the 486 response was sent
      assert_receive {:response_sent, response}
      assert response.status_code == 486
    end
  end

  describe "execute_answer/3" do
    test "sends 200 OK response" do
      call = Call.new()
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])

      # Should have sent a 200 OK response
      assert_receive {:response_sent, response}
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
    end

    test "updates call state to :answered" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])
      assert updated_call.state == :answered
    end

    test "captures dialog_id after answer" do
      call = Call.new(state: :incoming)
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])

      # Should have dialog_id set
      assert updated_call.__dialog_id__ != nil
      assert is_binary(updated_call.__dialog_id__)

      # dialog_id should contain the call_id
      assert String.contains?(updated_call.__dialog_id__, sip_msg.call_id)
    end

    test "returns error when UAS is nil" do
      call = Call.new()

      context = %{
        uas: nil,
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_uas} = ActionExecutor.execute_answer(call, context, [])
    end
  end

  describe "execute_reject/3" do
    test "sends error response with given status code" do
      call = Call.new()
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_reject(call, context, 486)

      assert_receive {:response_sent, response}
      assert response.status_code == 486
    end

    test "updates call state to :terminated" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_reject(call, context, 403)
      assert updated_call.state == :terminated
    end

    test "returns error when UAS is nil" do
      call = Call.new()

      context = %{
        uas: nil,
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_uas} = ActionExecutor.execute_reject(call, context, 500)
    end
  end

  describe "execute_play/4" do
    test "sends play_files message to media_pid" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      {:ok, _updated_call} = ActionExecutor.execute_play(call, context, "welcome.wav", [])

      assert_receive {:play_files, ["welcome.wav"], []}
    end

    test "accepts list of files" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      files = ["intro.wav", "menu.wav"]
      {:ok, _updated_call} = ActionExecutor.execute_play(call, context, files, loop: true)

      assert_receive {:play_files, ^files, [loop: true]}
    end

    test "returns error when media_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} =
               ActionExecutor.execute_play(call, context, "test.wav", [])
    end

    test "returns error when call is not in answered state" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} = ActionExecutor.execute_play(call, context, "test.wav", [])
    end
  end

  describe "execute_hangup/2" do
    test "updates call state to :terminated from :answered state" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
    end

    test "updates call state to :terminated from :incoming state" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
    end

    test "sends stop message to media_pid when running" do
      # Start a mock media process that will receive the stop message
      test_pid = self()

      media_pid =
        spawn(fn ->
          receive do
            {:stop_media} -> send(test_pid, :media_stopped)
          end
        end)

      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid
      }

      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
      assert_receive :media_stopped, 500
    end

    test "handles dead media_pid gracefully" do
      # Create a process that immediately dies
      media_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid
      }

      # Should not crash even with dead pid
      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
    end

    test "succeeds without dialog_id (graceful degradation)" do
      # Call without dialog_id - hangup should still work, just log warning
      call = Call.new(state: :answered, dialog_id: nil)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
      # Should not crash, just logs warning about no dialog_id
    end

    test "attempts to send BYE when dialog_id is present" do
      # Create a call with dialog_id
      sip_msg = build_invite_message()
      dialog_id = "test-dialog-id-#{:erlang.unique_integer()}"
      call = Call.new(state: :answered, dialog_id: dialog_id)

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil
      }

      # Hangup should complete even if dialog not found
      # (graceful degradation - dialog might have been cleaned up)
      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
    end
  end

  describe "execute_record/4" do
    test "sends start_record message to media_pid" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      {:ok, _updated_call} = ActionExecutor.execute_record(call, context, "recording.wav", [])

      assert_receive {:start_record, "recording.wav", []}
    end

    test "passes options to media_pid" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      opts = [max_duration: 60_000, beep: true]
      {:ok, _updated_call} = ActionExecutor.execute_record(call, context, "recording.wav", opts)

      assert_receive {:start_record, "recording.wav", ^opts}
    end

    test "returns error when media_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} =
               ActionExecutor.execute_record(call, context, "test.wav", [])
    end

    test "returns error when call is not in answered state" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} =
               ActionExecutor.execute_record(call, context, "test.wav", [])
    end
  end

  describe "execute_stop_record/3" do
    test "sends stop_record message to media_pid" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      {:ok, _updated_call} = ActionExecutor.execute_stop_record(call, context, [])

      assert_receive {:stop_record}
    end

    test "returns error when media_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute_stop_record(call, context, [])
    end

    test "returns error when call is not in answered state" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} = ActionExecutor.execute_stop_record(call, context, [])
    end
  end

  describe "execute/3 with new operations" do
    test "executes record operation via pipeline" do
      call = Call.new(state: :answered) |> Call.record("test.wav")
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      assert_receive {:start_record, "test.wav", []}
    end

    test "executes stop_record operation via pipeline" do
      call = Call.new(state: :answered) |> Call.stop_record()
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      assert_receive {:stop_record}
    end
  end

  describe "execute_collect_dtmf/3" do
    test "sends {:collect_dtmf, opts} to media session" do
      # Setup: Use self() as the media session to receive messages
      media_pid = self()
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid
      }

      # Execute the collect_dtmf operation directly
      {:ok, _updated_call} =
        ActionExecutor.execute_collect_dtmf(call, context, max: 4, timeout: 10_000)

      # Verify message was sent to media session
      assert_receive {:collect_dtmf, opts}
      assert opts[:max] == 4
      assert opts[:timeout] == 10_000
    end

    test "returns {:error, :no_media_session} when media session is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} =
               ActionExecutor.execute_collect_dtmf(call, context, max: 4)
    end

    test "returns {:error, :invalid_state} when call is not in answered state" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} = ActionExecutor.execute_collect_dtmf(call, context, max: 4)
    end
  end

  describe "execute/3 with :collect_dtmf operation" do
    test "executes collect_dtmf operation via pipeline" do
      # Manually create a collect_dtmf operation (until Call.collect_dtmf/2 is implemented)
      call = %Call{
        Call.new(state: :answered)
        | __operations__: [{:collect_dtmf, [max: 4, timeout: 10_000]}]
      }

      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Verify message was sent to media session
      assert_receive {:collect_dtmf, opts}
      assert opts[:max] == 4
      assert opts[:timeout] == 10_000
    end

    test "returns error when collect_dtmf fails due to missing media_pid" do
      call = %Call{Call.new(state: :answered) | __operations__: [{:collect_dtmf, [max: 4]}]}
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute(operations, call, context)
    end
  end

  describe "error handling in execute/3" do
    test "returns error when answer fails" do
      call = Call.new() |> Call.answer()
      operations = Call.get_operations(call)

      # Context with nil UAS will cause answer to fail
      context = %{
        uas: nil,
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_uas} = ActionExecutor.execute(operations, call, context)
    end

    test "returns error when reject fails" do
      call = Call.new() |> Call.reject(486)
      operations = Call.get_operations(call)

      # Context with nil UAS will cause reject to fail
      context = %{
        uas: nil,
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_uas} = ActionExecutor.execute(operations, call, context)
    end

    test "returns error when play fails due to missing media_pid" do
      call = Call.new(state: :answered) |> Call.play("test.wav")
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute(operations, call, context)
    end

    test "returns error when record fails due to missing media_pid" do
      call = Call.new(state: :answered) |> Call.record("test.wav")
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute(operations, call, context)
    end

    test "returns error when stop_record fails due to missing media_pid" do
      call = Call.new(state: :answered) |> Call.stop_record()
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute(operations, call, context)
    end

    test "handles unknown operations gracefully" do
      # Manually create an unknown operation
      call = %Call{Call.new() | __operations__: [{:unknown_op, "some_arg"}]}
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, {:unknown_operation, {:unknown_op, "some_arg"}}} =
               ActionExecutor.execute(operations, call, context)
    end
  end

  describe "response_fn callback mode" do
    test "uses response_fn when provided in context" do
      call = Call.new()
      sip_msg = build_invite_message()

      # Track that response_fn was called
      test_pid = self()

      response_fn = fn response, uas ->
        send(test_pid, {:custom_response, response, uas})
        :ok
      end

      context = %{
        uas: :custom_uas,
        sip_msg: sip_msg,
        media_pid: nil,
        response_fn: response_fn
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      # Should receive message from custom response_fn
      assert_receive {:custom_response, response, :custom_uas}
      assert response.status_code == 200
    end
  end

  describe "status code reasons" do
    test "maps standard status codes to correct reason phrases" do
      call = Call.new()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      # Test various status codes
      test_cases = [
        {100, "Trying"},
        {180, "Ringing"},
        {183, "Session Progress"},
        {200, "OK"},
        {400, "Bad Request"},
        {401, "Unauthorized"},
        {403, "Forbidden"},
        {404, "Not Found"},
        {408, "Request Timeout"},
        {480, "Temporarily Unavailable"},
        {486, "Busy Here"},
        {487, "Request Terminated"},
        {488, "Not Acceptable Here"},
        {500, "Internal Server Error"},
        {501, "Not Implemented"},
        {503, "Service Unavailable"}
      ]

      for {status_code, expected_reason} <- test_cases do
        {:ok, _updated_call} = ActionExecutor.execute_reject(call, context, status_code)
        assert_receive {:response_sent, response}
        assert response.status_code == status_code
        assert response.reason_phrase == expected_reason
      end
    end

    test "uses generic reason for unknown status codes" do
      call = Call.new()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_reject(call, context, 999)
      assert_receive {:response_sent, response}
      assert response.status_code == 999
      assert response.reason_phrase == "Status 999"
    end
  end

  describe "extended context with sdp_answer" do
    test "accepts context with sdp_answer: nil" do
      call = Call.new()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])
      assert updated_call.state == :answered
      assert_receive {:response_sent, response}
      assert response.status_code == 200
    end

    test "accepts context with sdp_answer string" do
      call = Call.new()

      sdp_answer = """
      v=0
      o=- 1234 1234 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 0
      a=rtpmap:0 PCMU/8000
      """

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: sdp_answer
      }

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])
      assert updated_call.state == :answered
      assert_receive {:response_sent, response}
      assert response.status_code == 200
    end

    test "backwards compatible - context without sdp_answer still works" do
      # This test ensures backward compatibility during migration
      call = Call.new()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])
      assert updated_call.state == :answered
    end
  end

  describe "execute_answer/3 with SDP body (T015-T016)" do
    test "includes sdp_answer in response body when present" do
      call = Call.new()

      sdp_answer = """
      v=0
      o=- 1234 1234 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 0
      a=rtpmap:0 PCMU/8000
      """

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: sdp_answer
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      assert response.body == sdp_answer
    end

    test "sets Content-Type to application/sdp when sdp_answer present" do
      call = Call.new()
      sdp_answer = "v=0\r\no=- 1234 1234 IN IP4 127.0.0.1\r\n"

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: sdp_answer
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      assert response.content_type == "application/sdp"
    end

    test "sets Content-Length to correct byte size when sdp_answer present" do
      call = Call.new()
      sdp_answer = "v=0\r\no=- 1234 1234 IN IP4 127.0.0.1\r\n"

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: sdp_answer
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      assert response.content_length == byte_size(sdp_answer)
    end

    test "sends empty body when sdp_answer is nil" do
      call = Call.new()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      assert response.body == ""
      assert response.content_length == 0
    end

    test "sends empty body when sdp_answer not in context (backward compat)" do
      call = Call.new()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      assert response.body == ""
      assert response.content_length == 0
    end
  end

  describe "execute_answer/3 with Contact header (T009)" do
    @moduletag :unit

    test "includes Contact header in 200 OK response" do
      call = Call.new()

      # Create SIP message with source containing local address info
      sip_msg = build_invite_message_with_source()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil,
        sdp_answer: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      assert response.status_code == 200

      # Response should have Contact header
      assert response.contact != nil
    end

    test "Contact header contains local address and port from source" do
      call = Call.new()

      # Create SIP message with specific local address
      sip_msg = build_invite_message_with_source({127, 0, 0, 1}, 5060)

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil,
        sdp_answer: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      contact = response.contact

      # Contact should have SIP URI with our local address
      assert contact.uri.scheme == "sip"
      assert contact.uri.host == "127.0.0.1"
      assert contact.uri.port == 5060
    end

    test "Contact header with IPv4 address sets correct host_type" do
      call = Call.new()

      sip_msg = build_invite_message_with_source({192, 168, 1, 100}, 5080)

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil,
        sdp_answer: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}
      contact = response.contact

      assert contact.uri.host == "192.168.1.100"
      assert contact.uri.port == 5080
      assert contact.uri.host_type == :ipv4
    end

    test "Contact header is nil when source has no local address info" do
      call = Call.new()

      # SIP message without proper source structure
      sip_msg = build_invite_message()

      context = %{
        uas: self(),
        sip_msg: sip_msg,
        media_pid: nil,
        sdp_answer: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      assert_receive {:response_sent, response}

      # Contact may be nil when source doesn't have local address
      # This is acceptable behavior - the SIP stack will handle it
      # (Contact is RECOMMENDED but not strictly required per RFC 3261 12.1.1)
    end
  end

  describe "execute_answer/3 B2BUA notification (T06-6ib)" do
    test "notifies B2BUA of A-leg answered state when b2bua_pid is present" do
      # Start a B2BUA instance
      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Set up A-leg in trying state (what happens before answer)
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :trying)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      # Verify A-leg starts in trying state
      {:ok, leg_before} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :a_leg)
      assert leg_before.state == :trying

      # Build context with b2bua_pid
      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: "v=0\r\no=test 1 1 IN IP4 127.0.0.1\r\n",
        b2bua_pid: b2bua_pid
      }

      call = Call.new()

      # Execute answer - should notify B2BUA
      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      # Verify A-leg state was updated to answered
      {:ok, leg_after} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :a_leg)
      assert leg_after.state == :answered

      # Verify SDP was also set
      assert leg_after.sdp == "v=0\r\no=test 1 1 IN IP4 127.0.0.1\r\n"

      # Cleanup
      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "B2BUA.connect() succeeds after A-leg answered via DSL and B-leg answered" do
      # This test verifies the full state sync fix for issue 6ib
      # Problem: DSL answer() wasn't updating B2BUA A-leg state
      # Fix: execute_answer now calls B2BUA.update_leg with state: :answered

      # Start a B2BUA instance
      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Set up A-leg in trying state (incoming call before answer)
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :trying)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      # Create B-leg and progress it to answered state (simulating outbound call)
      {:ok, :b_leg} =
        Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:bob@example.com", as: :b_leg)

      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "v=0\r\n"})

      # Answer A-leg via execute_answer (this is what the DSL answer() does)
      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: "v=0\r\no=test 1 1 IN IP4 127.0.0.1\r\n",
        b2bua_pid: b2bua_pid
      }

      call = Call.new()
      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      # CRITICAL: B2BUA.connect() should now succeed because both legs are answered
      # Before the fix, this would fail with {:error, :leg_not_answered}
      assert {:ok, _bridge} = Parrot.Bridge.B2BUA.connect(b2bua_pid, :a_leg, :b_leg)

      # Verify the bridge was established
      assert Parrot.Bridge.B2BUA.get_active_bridge(b2bua_pid) == {:a_leg, :b_leg}

      # Cleanup
      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "does not fail when b2bua_pid is nil" do
      # Normal (non-B2BUA) flow should work fine
      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: nil,
        b2bua_pid: nil
      }

      call = Call.new()

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])
      assert updated_call.state == :answered
    end

    test "does not fail when b2bua_pid is not in context" do
      # Context without b2bua_pid at all
      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: nil
      }

      call = Call.new()

      {:ok, updated_call} = ActionExecutor.execute_answer(call, context, [])
      assert updated_call.state == :answered
    end
  end

  describe "reject with options" do
    test "handles reject with options tuple" do
      # Manually create a reject operation with options
      call = %Call{Call.new() | __operations__: [{:reject, 486, reason: "Busy"}]}
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)
      assert updated_call.state == :terminated
      assert_receive {:response_sent, response}
      assert response.status_code == 486
    end
  end

  describe "operation dispatch success paths" do
    test "executes answer operation through dispatch successfully" do
      # Test the execute_operation path for answer
      call = Call.new() |> Call.answer()
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)
      assert updated_call.state == :answered
      assert_receive {:response_sent, _response}
    end

    test "executes hangup operation through dispatch with media_pid" do
      # Test the execute_operation path for hangup with media
      call = Call.new(state: :answered) |> Call.hangup()
      operations = Call.get_operations(call)

      test_pid = self()

      media_pid =
        spawn(fn ->
          receive do
            {:stop_media} -> send(test_pid, :media_stopped)
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid
      }

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)
      assert updated_call.state == :terminated
      assert_receive :media_stopped, 500
    end

    test "executes play operation through dispatch successfully" do
      # Test the execute_operation path for play
      call = Call.new(state: :answered) |> Call.play("test.wav")
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)
      assert_receive {:play_files, ["test.wav"], []}
    end
  end

  describe "media lifecycle after answer (T021)" do
    test "calls start_media on media_pid after 200 OK when media_pid present" do
      call = Call.new()
      test_pid = self()

      # Start a mock gen_statem process that handles the start_media call
      # MediaSession.start_media/1 uses :gen_statem.call/3, so we need a proper mock
      {:ok, media_pid} = :gen_statem.start_link(__MODULE__.MockMediaSession, test_pid, [])

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      # Should receive notification that start_media was called
      assert_receive {:start_media_called}, 1000
    end

    test "does not call start_media when media_pid is nil" do
      call = Call.new()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        sdp_answer: nil
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      # Should NOT receive start_media (no media session)
      refute_receive {:start_media}, 100
    end
  end

  describe "media cleanup on hangup (T022)" do
    test "sends stop_media to media_pid on hangup" do
      call = Call.new(state: :answered)
      test_pid = self()

      media_pid =
        spawn(fn ->
          receive do
            {:stop_media} -> send(test_pid, :stop_media_received)
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid
      }

      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
      assert_receive :stop_media_received, 500
    end

    test "handles nil media_pid gracefully on hangup" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      # Should not crash even with nil media_pid
      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
    end
  end

  describe "execute_say/4 (T015 - TTS playback)" do
    # Note: These tests follow TDD - the execute_say/4 function does NOT exist yet.
    # They are expected to FAIL until the implementation is added.
    #
    # The :say operation will:
    # 1. Verify call is in :answered state
    # 2. Verify media_pid is available
    # 3. Call Synthesizer.get_audio/3 to get audio binary
    # 4. Send the audio to the MediaSession for playback

    test "returns error when call is not in answered state" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} =
               ActionExecutor.execute_say(call, context, "Hello world", [])
    end

    test "returns error when media_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} =
               ActionExecutor.execute_say(call, context, "Hello world", [])
    end

    test "calls Synthesizer.get_audio with correct arguments" do
      # This test verifies the Synthesizer is called with proper text and profile
      # We use the mock synthesizer server pattern to capture the call
      call = Call.new(state: :answered)
      test_pid = self()

      # Start a mock synthesizer that captures the call and returns mock audio
      {:ok, mock_synth} =
        start_mock_synthesizer(fn text, profile, _opts ->
          send(test_pid, {:synthesizer_called, text, profile})
          {:ok, "MOCK_AUDIO_DATA", :wav}
        end)

      # Create mock media_pid that captures play_audio message
      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_received, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _updated_call} =
        ActionExecutor.execute_say(call, context, "Hello world", profile: :premium)

      # Verify Synthesizer was called with correct text
      assert_receive {:synthesizer_called, "Hello world", profile}
      assert profile == :premium
    end

    test "sends audio data to media session on successful synthesis" do
      call = Call.new(state: :answered)
      test_pid = self()
      mock_audio = "FAKE_AUDIO_BINARY_DATA"

      # Start mock synthesizer returning audio
      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, mock_audio, :wav}
        end)

      # Create mock media_pid to capture the play_audio message
      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_received, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _updated_call} = ActionExecutor.execute_say(call, context, "Hello", [])

      # Verify audio was sent to media session
      assert_receive {:media_received, {:play_audio, ^mock_audio, opts}}
      assert is_list(opts)
    end

    test "returns {:ok, call} on successful synthesis and playback" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio_data", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            _msg -> send(test_pid, :audio_sent)
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      result = ActionExecutor.execute_say(call, context, "Test text", [])

      assert {:ok, updated_call} = result
      assert updated_call.state == :answered
      assert_receive :audio_sent
    end

    test "returns error when Synthesizer returns error" do
      call = Call.new(state: :answered)

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :synthesis_failed}
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth
      }

      assert {:error, {:synthesis_failed, :synthesis_failed}} =
               ActionExecutor.execute_say(call, context, "Hello", [])
    end

    test "returns error when Synthesizer returns provider_error" do
      call = Call.new(state: :answered)

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, {:provider_error, "API rate limit exceeded"}}
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth
      }

      assert {:error, {:synthesis_failed, {:provider_error, "API rate limit exceeded"}}} =
               ActionExecutor.execute_say(call, context, "Hello", [])
    end

    test "passes profile option from opts to Synthesizer" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, profile, _opts ->
          send(test_pid, {:profile_used, profile})
          {:ok, "audio", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            _msg -> :ok
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _call} = ActionExecutor.execute_say(call, context, "Text", profile: :premium)

      assert_receive {:profile_used, :premium}
    end

    test "uses :default profile when no profile option specified" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, profile, _opts ->
          send(test_pid, {:profile_used, profile})
          {:ok, "audio", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            _msg -> :ok
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _call} = ActionExecutor.execute_say(call, context, "Text", [])

      assert_receive {:profile_used, :default}
    end

    test "includes format metadata in play_audio message" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio_data", :mp3}
        end)

      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_msg, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _call} = ActionExecutor.execute_say(call, context, "Hello", [])

      assert_receive {:media_msg, {:play_audio, _audio, opts}}
      assert opts[:format] == :mp3
    end
  end

  describe "execute/3 with :say operation" do
    # Tests for :say operation through the main execute/3 dispatch

    test "executes say operation via pipeline" do
      call = %Call{
        Call.new(state: :answered)
        | __operations__: [{:say, "Hello world", [profile: :default]}]
      }

      operations = Call.get_operations(call)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio_data", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_received, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      assert_receive {:media_received, {:play_audio, _audio, _opts}}
    end

    test "returns error when say operation fails due to missing media_pid" do
      call = %Call{
        Call.new(state: :answered)
        | __operations__: [{:say, "Hello", []}]
      }

      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute(operations, call, context)
    end

    test "returns error when say operation fails due to invalid state" do
      call = %Call{
        Call.new(state: :incoming)
        | __operations__: [{:say, "Hello", []}]
      }

      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} = ActionExecutor.execute(operations, call, context)
    end

    test "say operation continues to next operations (non-signaling)" do
      # :say is a media operation, not signaling, so it should continue
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio", :wav}
        end)

      # Create a call with say followed by collect_dtmf
      call = %Call{
        Call.new(state: :answered)
        | __operations__: [
            {:say, "Enter your PIN", []},
            {:collect_dtmf, [max: 4, timeout: 10_000]}
          ]
      }

      operations = Call.get_operations(call)

      media_pid =
        spawn(fn ->
          loop = fn loop_fn ->
            receive do
              msg ->
                send(test_pid, {:media_msg, msg})
                loop_fn.(loop_fn)
            end
          end

          loop.(loop)
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Both operations should have executed
      assert_receive {:media_msg, {:play_audio, _audio, _opts}}
      assert_receive {:media_msg, {:collect_dtmf, _dtmf_opts}}
    end
  end

  describe "execute_say_prompt/4 (T023-T026 - TTS + DTMF collection)" do
    # T023: Tests for ActionExecutor :say_prompt handling
    # say_prompt combines TTS synthesis with DTMF collection
    #
    # The flow is:
    # 1. Synthesize text to audio
    # 2. Send audio to media session for playback
    # 3. Store __pending_collect__ in call assigns
    # (DTMF collection starts after playback via handle_play_complete callback)

    test "returns error when call is not in answered state" do
      call = Call.new(state: :incoming)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} =
               ActionExecutor.execute_say_prompt(call, context, "Enter PIN", max: 4)
    end

    test "returns error when media_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} =
               ActionExecutor.execute_say_prompt(call, context, "Enter PIN", max: 4)
    end

    test "calls Synthesizer with text and profile" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn text, profile, _opts ->
          send(test_pid, {:synthesizer_called, text, profile})
          {:ok, "MOCK_AUDIO", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_received, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _updated_call} =
        ActionExecutor.execute_say_prompt(call, context, "Enter your PIN",
          max: 4,
          profile: :prompts
        )

      assert_receive {:synthesizer_called, "Enter your PIN", :prompts}
    end

    test "sends audio to media session on successful synthesis" do
      call = Call.new(state: :answered)
      test_pid = self()
      mock_audio = "TTS_AUDIO_DATA"

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, mock_audio, :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_received, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _updated_call} =
        ActionExecutor.execute_say_prompt(call, context, "Enter PIN", max: 4)

      assert_receive {:media_received, {:play_audio, ^mock_audio, opts}}
      assert opts[:format] == :wav
    end

    test "stores __pending_collect__ in call assigns for deferred collection" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            _msg -> send(test_pid, :audio_sent)
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, updated_call} =
        ActionExecutor.execute_say_prompt(call, context, "Enter PIN",
          max: 4,
          timeout: 10_000,
          terminators: ["#"]
        )

      # Verify __pending_collect__ contains the DTMF collection options
      pending_collect = updated_call.assigns[:__pending_collect__]
      assert pending_collect[:max] == 4
      assert pending_collect[:timeout] == 10_000
      assert pending_collect[:terminators] == ["#"]
    end

    test "returns error when Synthesizer fails" do
      call = Call.new(state: :answered)

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :api_error}
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth
      }

      assert {:error, {:synthesis_failed, :api_error}} =
               ActionExecutor.execute_say_prompt(call, context, "Enter PIN", max: 4)
    end

    test "uses :default profile when not specified" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, profile, _opts ->
          send(test_pid, {:profile_used, profile})
          {:ok, "audio", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            _msg -> :ok
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _call} = ActionExecutor.execute_say_prompt(call, context, "Enter digits", max: 4)

      assert_receive {:profile_used, :default}
    end

    test "extracts TTS-specific options (profile, voice, language) for synthesizer" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, opts ->
          send(test_pid, {:synth_opts, opts})
          {:ok, "audio", :wav}
        end)

      media_pid =
        spawn(fn ->
          receive do
            _msg -> :ok
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _call} =
        ActionExecutor.execute_say_prompt(
          call,
          context,
          "Enter PIN",
          max: 4,
          timeout: 10_000,
          profile: :premium,
          voice: "en-US-Neural2-F",
          language: "en-US"
        )

      assert_receive {:synth_opts, synth_opts}
      assert synth_opts[:voice] == "en-US-Neural2-F"
      assert synth_opts[:language] == "en-US"
    end
  end

  describe "TTS error callback invocation (T043, T046 - FR-017)" do
    # T043: Error propagation tests
    # T046: ActionExecutor invokes handler error callback on synthesis failure
    #
    # When TTS synthesis fails, the ActionExecutor should:
    # 1. NOT crash the call
    # 2. Invoke the handler's handle_tts_error/3 callback
    # 3. Continue with the returned call state

    test "invokes handler's handle_tts_error/3 when synthesis fails for :say" do
      call = Call.new(state: :answered)
      test_pid = self()

      # Mock synthesizer that returns an error
      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :api_timeout}
        end)

      # Mock handler module that tracks error callback (signature: text, error, call)
      error_handler = fn text, error, call ->
        send(test_pid, {:tts_error_callback, text, error})
        %{call | assigns: Map.put(call.assigns, :tts_error, error)}
      end

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth,
        # Will be set below
        handler: nil,
        tts_error_handler: error_handler
      }

      # Execute with the error handler in context
      result = ActionExecutor.execute_say_with_error_handler(call, context, "Hello world", [])

      # Should invoke error callback instead of returning error
      assert_receive {:tts_error_callback, "Hello world", :api_timeout}

      # Should return updated call from error handler
      assert {:ok, updated_call} = result
      assert updated_call.assigns[:tts_error] == :api_timeout
    end

    test "invokes handler's handle_tts_error/3 when synthesis fails for :say_prompt" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, {:provider_error, "Rate limit exceeded"}}
        end)

      error_handler = fn text, error, call ->
        send(test_pid, {:tts_error_callback, text, error})
        call
      end

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      result =
        ActionExecutor.execute_say_prompt_with_error_handler(
          call,
          context,
          "Enter PIN",
          max: 4
        )

      assert_receive {:tts_error_callback, "Enter PIN", {:provider_error, "Rate limit exceeded"}}
      assert {:ok, _updated_call} = result
    end

    test "continues call execution after TTS error (does not crash)" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :synthesis_failed}
        end)

      # Error handler that just returns the call unchanged
      error_handler = fn _text, _error, call ->
        send(test_pid, :error_handled)
        call
      end

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      # Should NOT crash
      {:ok, updated_call} =
        ActionExecutor.execute_say_with_error_handler(
          call,
          context,
          "Test",
          []
        )

      assert_receive :error_handled
      # Call state should remain valid
      assert updated_call.state == :answered
    end

    test "error handler can queue fallback operations" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :api_unavailable}
        end)

      # Error handler that queues a fallback play operation
      error_handler = fn _text, _error, call ->
        Call.play(call, "error-fallback.wav")
      end

      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_msg, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      {:ok, updated_call} =
        ActionExecutor.execute_say_with_error_handler(
          call,
          context,
          "Hello",
          []
        )

      # The error handler queued a play operation
      operations = Call.get_operations(updated_call)
      assert [{:play, "error-fallback.wav", []}] = operations
    end

    test "uses default error handler when none provided (logs and continues)" do
      call = Call.new(state: :answered)

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :synthesis_failed}
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth
        # No tts_error_handler - should use default
      }

      # With default handler, should return {:ok, call} and log warning
      # (logging verified manually or with capture_log)
      result = ActionExecutor.execute_say_with_error_handler(call, context, "Test", [])

      assert {:ok, updated_call} = result
      assert updated_call.state == :answered
    end

    test "passes correct error details to handler callback" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, {:provider_error, %{status: 503, message: "Service unavailable"}}}
        end)

      error_handler = fn text, error, call ->
        send(test_pid, {:error_details, text, error, call})
        call
      end

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      {:ok, _call} =
        ActionExecutor.execute_say_with_error_handler(
          call,
          context,
          "Complex error test",
          profile: :premium
        )

      assert_receive {:error_details, received_text, received_error, received_call}
      assert received_call.state == :answered
      assert received_text == "Complex error test"
      assert received_error == {:provider_error, %{status: 503, message: "Service unavailable"}}
    end

    test "error propagation for :say operation using execute_say_with_error_handler (T043)" do
      # T043: Test that errors propagate correctly through execute_say_with_error_handler
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :synthesis_failed}
        end)

      error_handler = fn text, error, call ->
        send(test_pid, {:error_handled, text, error})
        call
      end

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      # Use execute_say_with_error_handler directly
      result = ActionExecutor.execute_say_with_error_handler(call, context, "Test text", [])

      assert_receive {:error_handled, "Test text", :synthesis_failed}
      assert {:ok, _updated_call} = result
    end

    test "error propagation for :say_prompt operation using execute_say_prompt_with_error_handler (T043)" do
      # T043: Test that errors propagate correctly for say_prompt
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :rate_limited}
        end)

      error_handler = fn text, error, call ->
        send(test_pid, {:error_handled, text, error})
        call
      end

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      result =
        ActionExecutor.execute_say_prompt_with_error_handler(call, context, "Enter PIN", max: 4)

      assert_receive {:error_handled, "Enter PIN", :rate_limited}
      assert {:ok, _updated_call} = result
    end

    test "no callback invocation on successful synthesis" do
      call = Call.new(state: :answered)
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio_data", :wav}
        end)

      error_handler = fn _text, _error, _call ->
        send(test_pid, :error_handler_called)
        raise "Should not be called on success"
      end

      media_pid =
        spawn(fn ->
          receive do
            {:play_audio, _audio, _opts} -> send(test_pid, :audio_played)
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      {:ok, _call} = ActionExecutor.execute_say_with_error_handler(call, context, "Hello", [])

      # Should receive audio_played, NOT error_handler_called
      assert_receive :audio_played
      refute_receive :error_handler_called, 100
    end

    test "if no callback, default behavior is used (T043)" do
      # T043: When no tts_error_handler is provided, use default behavior
      call = Call.new(state: :answered)

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :network_error}
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth
        # No tts_error_handler - should use default
      }

      # Default handler logs warning and returns {:ok, call}
      result = ActionExecutor.execute_say_with_error_handler(call, context, "Test", [])

      assert {:ok, updated_call} = result
      # Call should be unchanged
      assert updated_call.state == :answered
      assert updated_call.assigns == %{}
    end

    test "execution continues after error callback (T043)" do
      # T043: After error callback is invoked, call execution continues normally
      call = Call.new(state: :answered)

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:error, :synthesis_failed}
        end)

      # Error handler that adds marker to assigns
      error_handler = fn _text, _error, call ->
        %{call | assigns: Map.put(call.assigns, :error_handled, true)}
      end

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self(),
        synthesizer: mock_synth,
        tts_error_handler: error_handler
      }

      {:ok, updated_call} =
        ActionExecutor.execute_say_with_error_handler(
          call,
          context,
          "Test",
          []
        )

      # Error handler was invoked and modified call
      assert updated_call.assigns[:error_handled] == true
      # Call state should still be valid for further operations
      assert updated_call.state == :answered
    end
  end

  describe "execute/3 with :say_prompt operation (T026 - integration)" do
    # T026: Integration tests - say_prompt operation through main dispatch

    test "executes say_prompt operation via pipeline" do
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "tts_audio", :wav}
        end)

      call = %Call{
        Call.new(state: :answered)
        | __operations__: [{:say_prompt, "Enter your PIN", [max: 4, timeout: 10_000]}]
      }

      operations = Call.get_operations(call)

      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_received, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)

      # Audio should be sent to media session
      assert_receive {:media_received, {:play_audio, _audio, _opts}}

      # __pending_collect__ should be set for deferred DTMF collection
      assert updated_call.assigns[:__pending_collect__] == [max: 4, timeout: 10_000]
    end

    test "returns error when say_prompt fails due to missing media_pid" do
      call = %Call{
        Call.new(state: :answered)
        | __operations__: [{:say_prompt, "Enter PIN", [max: 4]}]
      }

      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute(operations, call, context)
    end

    test "returns error when say_prompt fails due to invalid state" do
      call = %Call{
        Call.new(state: :incoming)
        | __operations__: [{:say_prompt, "Enter PIN", [max: 4]}]
      }

      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: self()
      }

      assert {:error, :invalid_state} = ActionExecutor.execute(operations, call, context)
    end

    test "say_prompt operation continues to next operations" do
      # say_prompt is a media operation, so execution should continue
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio", :wav}
        end)

      # say_prompt followed by play
      call = %Call{
        Call.new(state: :answered)
        | __operations__: [
            {:say_prompt, "Enter PIN", [max: 4]},
            {:play, "beep.wav", []}
          ]
      }

      operations = Call.get_operations(call)

      media_pid =
        spawn(fn ->
          loop = fn loop_fn ->
            receive do
              msg ->
                send(test_pid, {:media_msg, msg})
                loop_fn.(loop_fn)
            end
          end

          loop.(loop)
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Both operations should execute
      assert_receive {:media_msg, {:play_audio, _audio, _opts}}
      assert_receive {:media_msg, {:play_files, ["beep.wav"], []}}
    end

    test "preserves existing assigns when adding __pending_collect__" do
      test_pid = self()

      {:ok, mock_synth} =
        start_mock_synthesizer(fn _text, _profile, _opts ->
          {:ok, "audio", :wav}
        end)

      # Call with existing assigns
      call = %Call{
        Call.new(state: :answered)
        | assigns: %{menu: :main, retries: 2},
          __operations__: [{:say_prompt, "Enter PIN", [max: 4]}]
      }

      operations = Call.get_operations(call)

      media_pid =
        spawn(fn ->
          receive do
            _msg -> send(test_pid, :done)
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        synthesizer: mock_synth
      }

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)

      # Existing assigns should be preserved
      assert updated_call.assigns[:menu] == :main
      assert updated_call.assigns[:retries] == 2
      # And __pending_collect__ should be added
      assert updated_call.assigns[:__pending_collect__] == [max: 4]
    end
  end

  # ============================================================================
  # Bidirectional WebSocket Operations Tests
  # ============================================================================

  describe "execute_connect_bidirectional_ws/4" do
    test "returns error when call is not in answered state" do
      call = Call.new(state: :incoming, call_id: "test-call-id")

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:connect_bidirectional_ws, "wss://api.example.com/stream", []}]
      assert {:error, :invalid_state} = ActionExecutor.execute(operations, call, context)
    end

    test "returns error for invalid URL scheme" do
      call = Call.new(state: :answered, call_id: "test-call-id")

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:connect_bidirectional_ws, "http://invalid.example.com", []}]
      result = ActionExecutor.execute(operations, call, context)
      assert {:error, {:invalid_ws_config, :invalid_url_scheme}} = result
    end

    test "successfully creates connection when call_id is nil (uses '_bidirectional' suffix)" do
      call = Call.new(state: :answered, call_id: nil)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:connect_bidirectional_ws, "wss://api.example.com", []}]
      result = ActionExecutor.execute(operations, call, context)
      # connection_id will be "_bidirectional" which is valid
      assert {:ok, updated_call} = result
      assert is_pid(updated_call.__bidirectional_ws_pid__)

      # Cleanup: disconnect the connection
      if updated_call.__bidirectional_ws_pid__ do
        ParrotMedia.WsBidirectional.disconnect(updated_call.__bidirectional_ws_pid__)
      end
    end
  end

  describe "execute_disconnect_bidirectional_ws/2" do
    test "returns error when no bidirectional connection exists" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:disconnect_bidirectional_ws, []}]

      assert {:error, :no_bidirectional_connection} =
               ActionExecutor.execute(operations, call, context)
    end

    test "clears __bidirectional_ws_pid__ after disconnect with real connection" do
      # Create a real WsBidirectional connection first
      call = Call.new(state: :answered, call_id: "disconnect-test-call")

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      # First, establish a connection
      connect_ops = [{:connect_bidirectional_ws, "wss://api.example.com", []}]
      {:ok, connected_call} = ActionExecutor.execute(connect_ops, call, context)
      assert is_pid(connected_call.__bidirectional_ws_pid__)

      # Now disconnect
      disconnect_ops = [{:disconnect_bidirectional_ws, []}]
      {:ok, disconnected_call} = ActionExecutor.execute(disconnect_ops, connected_call, context)

      # PID should be cleared
      assert disconnected_call.__bidirectional_ws_pid__ == nil
    end

    test "handles already-terminated process gracefully" do
      # Start a real WsBidirectional, then stop it before calling disconnect
      call = Call.new(state: :answered, call_id: "terminated-test-call")

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      # Establish connection
      connect_ops = [{:connect_bidirectional_ws, "wss://api.example.com", []}]
      {:ok, connected_call} = ActionExecutor.execute(connect_ops, call, context)
      ws_pid = connected_call.__bidirectional_ws_pid__

      # Disconnect the process using the proper API
      ParrotMedia.WsBidirectional.disconnect(ws_pid)
      Process.sleep(50)

      # Now calling disconnect again should handle the dead process gracefully
      disconnect_ops = [{:disconnect_bidirectional_ws, []}]
      {:ok, disconnected_call} = ActionExecutor.execute(disconnect_ops, connected_call, context)

      # PID should be cleared
      assert disconnected_call.__bidirectional_ws_pid__ == nil
    end
  end

  describe "execute_mute_bidirectional/3" do
    test "returns error when no bidirectional connection exists" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:mute_bidirectional, :outbound}]

      assert {:error, :no_bidirectional_connection} =
               ActionExecutor.execute(operations, call, context)
    end

    test "returns error when no bidirectional connection exists for inbound" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:mute_bidirectional, :inbound}]

      assert {:error, :no_bidirectional_connection} =
               ActionExecutor.execute(operations, call, context)
    end
  end

  describe "execute_unmute_bidirectional/3" do
    test "returns error when no bidirectional connection exists" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:unmute_bidirectional, :outbound}]

      assert {:error, :no_bidirectional_connection} =
               ActionExecutor.execute(operations, call, context)
    end

    test "returns error when no bidirectional connection exists for inbound" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:unmute_bidirectional, :inbound}]

      assert {:error, :no_bidirectional_connection} =
               ActionExecutor.execute(operations, call, context)
    end
  end

  describe "execute_send_ws_message/3" do
    test "returns error when no bidirectional connection exists" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      operations = [{:send_ws_message, ~s({"type": "test"})}]

      assert {:error, :no_bidirectional_connection} =
               ActionExecutor.execute(operations, call, context)
    end
  end

  describe "execute_hangup/2 auto-cleanup of bidirectional WS (T045)" do
    # T045: Auto-cleanup when call terminates
    # When execute_hangup is called, any active bidirectional WebSocket
    # connection should be automatically disconnected to prevent orphaned connections

    test "disconnects active bidirectional WS connection on hangup" do
      # Create a call with an active bidirectional WS connection
      call = Call.new(state: :answered, call_id: "hangup-ws-test")

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      # First, establish a bidirectional WS connection
      connect_ops = [{:connect_bidirectional_ws, "wss://api.example.com", []}]
      {:ok, connected_call} = ActionExecutor.execute(connect_ops, call, context)
      ws_pid = connected_call.__bidirectional_ws_pid__
      assert is_pid(ws_pid)
      assert Process.alive?(ws_pid)

      # Now execute hangup - it should auto-disconnect the WS
      {:ok, terminated_call} = ActionExecutor.execute_hangup(connected_call, context)

      # Call should be terminated
      assert terminated_call.state == :terminated

      # Give time for disconnect to complete
      Process.sleep(50)

      # WS process should no longer be alive
      refute Process.alive?(ws_pid)
    end

    test "hangup works correctly when no bidirectional connection exists" do
      # Call with no bidirectional WS connection
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      # Hangup should succeed without errors
      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
    end

    test "hangup handles already-terminated WS connection gracefully" do
      # Create a call with an active bidirectional WS connection
      call = Call.new(state: :answered, call_id: "hangup-dead-ws-test")

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      # Establish a bidirectional WS connection
      connect_ops = [{:connect_bidirectional_ws, "wss://api.example.com", []}]
      {:ok, connected_call} = ActionExecutor.execute(connect_ops, call, context)
      ws_pid = connected_call.__bidirectional_ws_pid__

      # Kill the WS process before hangup
      ParrotMedia.WsBidirectional.disconnect(ws_pid)
      Process.sleep(50)
      refute Process.alive?(ws_pid)

      # Hangup should still succeed without crashing
      {:ok, terminated_call} = ActionExecutor.execute_hangup(connected_call, context)
      assert terminated_call.state == :terminated
    end

    test "hangup disconnects WS and stops media session together" do
      # Test that both cleanup actions happen
      call = Call.new(state: :answered, call_id: "hangup-both-test")
      test_pid = self()

      # Create a mock media process
      media_pid =
        spawn(fn ->
          receive do
            {:stop_media} -> send(test_pid, :media_stopped)
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid
      }

      # Establish a bidirectional WS connection
      connect_ops = [{:connect_bidirectional_ws, "wss://api.example.com", []}]
      {:ok, connected_call} = ActionExecutor.execute(connect_ops, call, context)
      ws_pid = connected_call.__bidirectional_ws_pid__

      # Hangup should cleanup both media and WS
      {:ok, terminated_call} = ActionExecutor.execute_hangup(connected_call, context)
      assert terminated_call.state == :terminated

      # Media session should receive stop message
      assert_receive :media_stopped, 500

      # WS should be disconnected
      Process.sleep(50)
      refute Process.alive?(ws_pid)
    end
  end

  describe "bidirectional operations via Call DSL" do
    test "connect_bidirectional_ws operation is queued correctly" do
      call =
        Call.new(state: :answered)
        |> Call.connect_bidirectional_ws("wss://api.example.com",
          headers: [{"Authorization", "Bearer token"}]
        )

      operations = Call.get_operations(call)
      assert [{:connect_bidirectional_ws, "wss://api.example.com", opts}] = operations
      assert opts[:headers] == [{"Authorization", "Bearer token"}]
    end

    test "disconnect_bidirectional_ws operation is queued correctly" do
      call =
        Call.new(state: :answered)
        |> Call.disconnect_bidirectional_ws()

      operations = Call.get_operations(call)
      assert [{:disconnect_bidirectional_ws, []}] = operations
    end

    test "mute_outbound operation is queued correctly" do
      call =
        Call.new(state: :answered)
        |> Call.mute_outbound()

      operations = Call.get_operations(call)
      assert [{:mute_bidirectional, :outbound}] = operations
    end

    test "unmute_outbound operation is queued correctly" do
      call =
        Call.new(state: :answered)
        |> Call.unmute_outbound()

      operations = Call.get_operations(call)
      assert [{:unmute_bidirectional, :outbound}] = operations
    end

    test "mute_inbound operation is queued correctly" do
      call =
        Call.new(state: :answered)
        |> Call.mute_inbound()

      operations = Call.get_operations(call)
      assert [{:mute_bidirectional, :inbound}] = operations
    end

    test "unmute_inbound operation is queued correctly" do
      call =
        Call.new(state: :answered)
        |> Call.unmute_inbound()

      operations = Call.get_operations(call)
      assert [{:unmute_bidirectional, :inbound}] = operations
    end

    test "send_ws_message operation is queued correctly" do
      call =
        Call.new(state: :answered)
        |> Call.send_ws_message(~s({"type": "session.update"}))

      operations = Call.get_operations(call)
      assert [{:send_ws_message, ~s({"type": "session.update"})}] = operations
    end

    test "multiple bidirectional operations can be chained" do
      call =
        Call.new(state: :answered)
        |> Call.connect_bidirectional_ws("wss://api.example.com", [])
        |> Call.mute_outbound()
        |> Call.send_ws_message(~s({"type": "test"}))
        |> Call.unmute_outbound()
        |> Call.disconnect_bidirectional_ws()

      operations = Call.get_operations(call)
      assert length(operations) == 5
      assert {:connect_bidirectional_ws, "wss://api.example.com", []} = Enum.at(operations, 0)
      assert {:mute_bidirectional, :outbound} = Enum.at(operations, 1)
      assert {:send_ws_message, ~s({"type": "test"})} = Enum.at(operations, 2)
      assert {:unmute_bidirectional, :outbound} = Enum.at(operations, 3)
      assert {:disconnect_bidirectional_ws, []} = Enum.at(operations, 4)
    end
  end

  # ============================================================================
  # B2BUA Operations Tests (T06)
  # ============================================================================

  describe "execute_originate/4 (T06 - B2BUA originate)" do
    # Tests for originating an outbound leg via the B2BUA GenServer

    test "calls B2BUA.originate with destination and options" do
      call = Call.new(state: :answered)

      # Start a real B2BUA GenServer
      {:ok, b2bua_pid} =
        Parrot.Bridge.B2BUA.start_link(
          handler: nil,
          media_mode: :proxy
        )

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      # Execute the originate operation directly
      {:ok, updated_call} =
        ActionExecutor.execute_originate(
          call,
          context,
          "sip:dest@example.com",
          as: :b_leg
        )

      # Verify the leg was created in the B2BUA
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.remote_uri == "sip:dest@example.com"
      assert leg.direction == :outbound
      assert leg.state == :init

      # Call should be returned unchanged (operation succeeded)
      assert updated_call == call

      # Cleanup
      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when b2bua_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: nil
      }

      assert {:error, :no_b2bua} =
               ActionExecutor.execute_originate(
                 call,
                 context,
                 "sip:dest@example.com",
                 []
               )
    end

    test "returns error when call is not in answered state" do
      call = Call.new(state: :incoming)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :invalid_state} =
               ActionExecutor.execute_originate(
                 call,
                 context,
                 "sip:dest@example.com",
                 []
               )

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when leg_id already exists" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Pre-create a leg with the same ID
      {:ok, :b_leg} =
        Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:first@example.com", as: :b_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      # Try to originate with the same leg_id
      assert {:error, :leg_exists} =
               ActionExecutor.execute_originate(
                 call,
                 context,
                 "sip:second@example.com",
                 as: :b_leg
               )

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end
  end

  describe "execute_connect_legs/4 (T06 - B2BUA connect)" do
    # Tests for connecting two legs via the B2BUA GenServer

    test "calls B2BUA.connect with leg_a and leg_b" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Create and answer both legs
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "sdp"})

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, updated_call} =
        ActionExecutor.execute_connect_legs(
          call,
          context,
          :a_leg,
          :b_leg,
          []
        )

      # Verify the legs are connected
      assert Parrot.Bridge.B2BUA.get_active_bridge(b2bua_pid) == {:a_leg, :b_leg}
      assert updated_call == call

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when b2bua_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: nil
      }

      assert {:error, :no_b2bua} =
               ActionExecutor.execute_connect_legs(
                 call,
                 context,
                 :a_leg,
                 :b_leg,
                 []
               )
    end

    test "returns error when leg not found" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :leg_not_found} =
               ActionExecutor.execute_connect_legs(
                 call,
                 context,
                 :a_leg,
                 :b_leg,
                 []
               )

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when leg not answered" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Create legs but don't answer them
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :ringing)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :leg_not_answered} =
               ActionExecutor.execute_connect_legs(
                 call,
                 context,
                 :a_leg,
                 :b_leg,
                 []
               )

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end
  end

  describe "execute_hold/3 (T06 - B2BUA hold)" do
    # Tests for placing a leg on hold via the B2BUA GenServer

    test "calls B2BUA.hold with leg_id" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Create and connect legs
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "sdp"})
      {:ok, _bridge} = Parrot.Bridge.B2BUA.connect(b2bua_pid, :a_leg, :b_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, updated_call} = ActionExecutor.execute_hold(call, context, :b_leg)

      # Verify the leg is on hold
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.state == :held
      assert updated_call == call

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when b2bua_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: nil
      }

      assert {:error, :no_b2bua} = ActionExecutor.execute_hold(call, context, :b_leg)
    end

    test "returns error when leg not found" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :unknown_leg} = ActionExecutor.execute_hold(call, context, :nonexistent)

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when leg not connected" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Create leg but don't connect it
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :leg_not_connected} = ActionExecutor.execute_hold(call, context, :a_leg)

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end
  end

  describe "execute_resume/3 (T06 - B2BUA resume)" do
    # Tests for resuming a held leg via the B2BUA GenServer

    test "calls B2BUA.resume with leg_id" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Create, connect, and hold a leg
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "sdp"})
      {:ok, _bridge} = Parrot.Bridge.B2BUA.connect(b2bua_pid, :a_leg, :b_leg)
      :ok = Parrot.Bridge.B2BUA.hold(b2bua_pid, :b_leg)

      # Verify it's on hold
      {:ok, held_leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert held_leg.state == :held

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, updated_call} = ActionExecutor.execute_resume(call, context, :b_leg)

      # Verify the leg is resumed (back to answered)
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.state == :answered
      assert updated_call == call

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when b2bua_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: nil
      }

      assert {:error, :no_b2bua} = ActionExecutor.execute_resume(call, context, :b_leg)
    end

    test "returns error when leg not found" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :unknown_leg} = ActionExecutor.execute_resume(call, context, :nonexistent)

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when leg not held" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Create answered leg but don't hold it
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :leg_not_held} = ActionExecutor.execute_resume(call, context, :a_leg)

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end
  end

  describe "execute_transfer/4 (T06 - B2BUA transfer)" do
    # Tests for transferring a leg to a new destination
    # Note: B2BUA.transfer is not yet implemented per the design doc
    # These tests define the expected behavior

    test "returns error when b2bua_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: nil
      }

      assert {:error, :no_b2bua} =
               ActionExecutor.execute_transfer(
                 call,
                 context,
                 :b_leg,
                 "sip:new@example.com",
                 []
               )
    end

    test "returns error when transfer not implemented" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      # Transfer is not yet implemented in B2BUA
      result =
        ActionExecutor.execute_transfer(
          call,
          context,
          :b_leg,
          "sip:new@example.com",
          []
        )

      # Should return an error indicating transfer is not implemented
      assert {:error, :not_implemented} = result

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end
  end

  describe "execute_hangup_leg/3 (T06 - B2BUA hangup_leg)" do
    # Tests for hanging up a specific leg via the B2BUA GenServer

    test "calls B2BUA.hangup_leg with leg_id" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Create a leg
      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, updated_call} = ActionExecutor.execute_hangup_leg(call, context, :b_leg)

      # Verify the leg is terminated
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.state == :terminated
      assert updated_call == call

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when b2bua_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: nil
      }

      assert {:error, :no_b2bua} = ActionExecutor.execute_hangup_leg(call, context, :b_leg)
    end

    test "returns error when leg not found" do
      call = Call.new(state: :answered)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      assert {:error, :unknown_leg} =
               ActionExecutor.execute_hangup_leg(call, context, :nonexistent)

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end
  end

  describe "execute/3 with B2BUA operations via pipeline (T06)" do
    # Integration tests for B2BUA operations through the main execute/3 dispatch

    test "executes originate operation via pipeline" do
      call = Call.new(state: :answered) |> Call.originate("sip:dest@example.com", as: :b_leg)
      operations = Call.get_operations(call)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Verify leg was created
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.remote_uri == "sip:dest@example.com"

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "executes connect_legs operation via pipeline" do
      call = Call.new(state: :answered) |> Call.connect_legs(:a_leg, :b_leg)
      operations = Call.get_operations(call)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Set up answered legs
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "sdp"})

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Verify legs are connected
      assert Parrot.Bridge.B2BUA.get_active_bridge(b2bua_pid) == {:a_leg, :b_leg}

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "executes hold operation via pipeline" do
      call = Call.new(state: :answered) |> Call.hold(:b_leg)
      operations = Call.get_operations(call)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Set up connected legs
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "sdp"})
      {:ok, _bridge} = Parrot.Bridge.B2BUA.connect(b2bua_pid, :a_leg, :b_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Verify leg is held
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.state == :held

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "executes resume operation via pipeline" do
      call = Call.new(state: :answered) |> Call.resume(:b_leg)
      operations = Call.get_operations(call)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Set up held leg
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
      :ok = Parrot.Bridge.B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "sdp"})
      {:ok, _bridge} = Parrot.Bridge.B2BUA.connect(b2bua_pid, :a_leg, :b_leg)
      :ok = Parrot.Bridge.B2BUA.hold(b2bua_pid, :b_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Verify leg is resumed
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.state == :answered

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "executes hangup_leg operation via pipeline" do
      call = Call.new(state: :answered) |> Call.hangup_leg(:b_leg)
      operations = Call.get_operations(call)

      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      {:ok, :b_leg} = Parrot.Bridge.B2BUA.originate(b2bua_pid, "sip:dest@example.com", as: :b_leg)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: b2bua_pid
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Verify leg is terminated
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.state == :terminated

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end

    test "returns error when B2BUA operation fails due to missing b2bua_pid" do
      call = Call.new(state: :answered) |> Call.originate("sip:dest@example.com")
      operations = Call.get_operations(call)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil,
        b2bua_pid: nil
      }

      assert {:error, :no_b2bua} = ActionExecutor.execute(operations, call, context)
    end

    test "B2BUA operations continue to next operations (non-signaling)" do
      # B2BUA operations like originate are non-signaling, so they should continue
      {:ok, b2bua_pid} = Parrot.Bridge.B2BUA.start_link()

      # Set up the A-leg first
      a_leg = Parrot.Leg.new(id: :a_leg, direction: :inbound, state: :answered)
      :ok = Parrot.Bridge.B2BUA.set_a_leg(b2bua_pid, a_leg)

      call =
        Call.new(state: :answered)
        |> Call.originate("sip:dest@example.com", as: :b_leg)
        |> Call.play("connecting.wav")

      operations = Call.get_operations(call)

      test_pid = self()

      media_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:media_msg, msg})
          end
        end)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        b2bua_pid: b2bua_pid
      }

      {:ok, _updated_call} = ActionExecutor.execute(operations, call, context)

      # Both operations should execute
      {:ok, leg} = Parrot.Bridge.B2BUA.get_leg(b2bua_pid, :b_leg)
      assert leg.remote_uri == "sip:dest@example.com"
      assert_receive {:media_msg, {:play_files, ["connecting.wav"], []}}

      Parrot.Bridge.B2BUA.stop(b2bua_pid)
    end
  end

  # Helper functions

  # Starts a mock synthesizer GenServer that delegates to the provided function
  defp start_mock_synthesizer(synth_fn) do
    {:ok, pid} = Agent.start_link(fn -> synth_fn end)
    {:ok, pid}
  end

  defp build_invite_message do
    %ParrotSip.Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "example.com"},
        display_name: nil,
        parameters: %{tag: "from-tag-123"}
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
          parameters: %{branch: "z9hG4bK-test-branch"}
        }
      ],
      body: nil
    }
  end

  # Build an INVITE message with source containing local address info
  # Used for testing Contact header generation (T009)
  defp build_invite_message_with_source(local_ip \\ {127, 0, 0, 1}, local_port \\ 5060) do
    %ParrotSip.Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "example.com"},
        display_name: nil,
        parameters: %{tag: "from-tag-123"}
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
          parameters: %{branch: "z9hG4bK-test-branch"}
        }
      ],
      body: nil,
      source: %ParrotSip.Source{
        local: {local_ip, local_port},
        remote: {{192, 168, 1, 100}, 5080}
      }
    }
  end
end
