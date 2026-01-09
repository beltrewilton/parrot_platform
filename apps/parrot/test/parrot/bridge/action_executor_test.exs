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
      {:ok, _updated_call} = ActionExecutor.execute_play(call, context, files, [loop: true])

      assert_receive {:play_files, ^files, [loop: true]}
    end

    test "returns error when media_pid is nil" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      assert {:error, :no_media_session} = ActionExecutor.execute_play(call, context, "test.wav", [])
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
    test "updates call state to :terminated" do
      call = Call.new(state: :answered)

      context = %{
        uas: self(),
        sip_msg: build_invite_message(),
        media_pid: nil
      }

      {:ok, updated_call} = ActionExecutor.execute_hangup(call, context)
      assert updated_call.state == :terminated
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
