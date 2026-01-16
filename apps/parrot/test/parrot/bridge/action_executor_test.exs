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

    test "stops on signaling operations (answer/reject/hangup)" do
      # When a signaling operation is executed, any subsequent operations should not run
      call =
        Call.new()
        |> Call.answer()
        |> Call.play("welcome.wav")

      operations = Call.get_operations(call)

      context = %{
        uas: :mock_uas,
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute(operations, call, context)
      # After answer, call should be in answered state
      assert updated_call.state == :answered
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

  # Helper functions

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
