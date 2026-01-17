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

      # Use self() as mock media_pid to receive messages
      media_pid = self()

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: media_pid,
        sdp_answer: "v=0\r\n"
      }

      {:ok, _updated_call} = ActionExecutor.execute_answer(call, context, [])

      # Should receive start_media message
      assert_receive {:start_media}, 1000
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
      {:ok, mock_synth} = start_mock_synthesizer(fn text, profile, _opts ->
        send(test_pid, {:synthesizer_called, text, profile})
        {:ok, "MOCK_AUDIO_DATA", :wav}
      end)

      # Create mock media_pid that captures play_audio message
      media_pid = spawn(fn ->
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
      {:ok, mock_synth} = start_mock_synthesizer(fn _text, _profile, _opts ->
        {:ok, mock_audio, :wav}
      end)

      # Create mock media_pid to capture the play_audio message
      media_pid = spawn(fn ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, _profile, _opts ->
        {:ok, "audio_data", :wav}
      end)

      media_pid = spawn(fn ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, _profile, _opts ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, _profile, _opts ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, profile, _opts ->
        send(test_pid, {:profile_used, profile})
        {:ok, "audio", :wav}
      end)

      media_pid = spawn(fn ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, profile, _opts ->
        send(test_pid, {:profile_used, profile})
        {:ok, "audio", :wav}
      end)

      media_pid = spawn(fn ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, _profile, _opts ->
        {:ok, "audio_data", :mp3}
      end)

      media_pid = spawn(fn ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, _profile, _opts ->
        {:ok, "audio_data", :wav}
      end)

      media_pid = spawn(fn ->
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

      {:ok, mock_synth} = start_mock_synthesizer(fn _text, _profile, _opts ->
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

      media_pid = spawn(fn ->
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
end
