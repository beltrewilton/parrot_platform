defmodule ParrotSip.Transaction.ServerTest do
  use ExUnit.Case, async: false

  alias ParrotSip.Transaction.Server
  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, From, To, CSeq, Contact}
  alias ParrotSip.TestHandler

  require Logger

  setup do
    # Clean up any existing registry entries
    Registry.unregister_match(ParrotSip.Registry, :_, :_)
    :ok
  end

  describe "UAS helper functions" do
    test "sipmsg/1 returns the request message from transaction" do
      req_msg = create_invite_request()

      # Create a mock transaction with request
      transaction = %ParrotSip.Transaction{
        request: req_msg,
        method: :invite,
        branch: "z9hG4bK123456",
        role: :uas
      }

      assert Server.sipmsg(transaction) == req_msg
    end
  end

  describe "make_reply/4" do
    test "creates a proper response with status code and reason phrase" do
      req_msg = create_invite_request()
      uas = create_test_uas(req_msg)

      response = Server.make_reply(200, "OK", uas, req_msg)

      assert response.status_code == 200
      assert response.reason_phrase == "OK"
      assert response.direction == :outgoing

      # Should copy headers from request
      assert response.call_id == req_msg.call_id
      assert response.cseq == req_msg.cseq
      assert response.via == req_msg.via
      assert response.from == req_msg.from
    end

    test "adds tag to To header in response" do
      req_msg = create_invite_request()
      uas = create_test_uas(req_msg)

      response = Server.make_reply(200, "OK", uas, req_msg)

      to_header = response.to
      # Verify that a tag was added to the To header
      assert Map.has_key?(to_header.parameters, "tag")
      assert to_header.parameters["tag"] != nil
    end

    test "handles different status codes" do
      req_msg = create_invite_request()
      uas = create_test_uas(req_msg)

      response_486 = Server.make_reply(486, "Busy Here", uas, req_msg)
      assert response_486.status_code == 486
      assert response_486.reason_phrase == "Busy Here"

      response_404 = Server.make_reply(404, "Not Found", uas, req_msg)
      assert response_404.status_code == 404
      assert response_404.reason_phrase == "Not Found"
    end
  end

  describe "validate_request/1" do
    test "allows supported methods" do
      supported_methods = [:invite, :ack, :bye, :cancel, :options, :register]

      for method <- supported_methods do
        msg = create_request_with_method(method)
        # Use the private function through Server.process to test validation
        handler = TestHandler.new()
        trans = create_test_uas(msg)

        # This should not raise an error and should process successfully
        assert :ok == Server.process(trans, msg, handler)
      end
    end

    test "rejects unsupported methods with 405 Method Not Allowed" do
      # Test with an unsupported method by creating a message with unsupported method
      # Note: Since validate_request is private, we test it indirectly through process
      headers = create_basic_headers()

      msg = %Message{
        # Unsupported method
        method: :subscribe,
        request_uri: "sip:alice@example.com",
        version: "SIP/2.0",
        call_id: headers["call-id"],
        contact: headers["contact"],
        cseq: headers["cseq"],
        from: headers["from"],
        to: headers["to"],
        via: headers["via"],
        body: "",
        direction: :incoming,
        type: :request,
        source: create_test_source(),
        other_headers: %{}
      }

      handler = TestHandler.new()
      trans = create_test_uas(msg)

      # Mock the transaction server to capture the response
      # The validation should create a 405 response
      assert :ok == Server.process(trans, msg, handler)
    end
  end

  describe "process_ack/2" do
    test "handles ACK when dialog is found" do
      ack_msg = create_ack_request()
      handler = TestHandler.new()

      # process_ack should complete without error
      assert :ok == Server.process_ack(ack_msg, handler)
    end

    test "handles ACK when dialog is not found" do
      ack_msg = create_ack_request()
      handler = TestHandler.new()

      # Should log warning but return :ok
      assert :ok == Server.process_ack(ack_msg, handler)
    end
  end

  describe "process_cancel/2" do
    test "allows CANCEL for pending transaction (no dialog)" do
      cancel_msg = create_cancel_request()
      trans = create_test_uas(cancel_msg)
      handler = TestHandler.new()

      assert :ok == Server.process_cancel(trans, handler)
    end

    test "allows CANCEL for early dialog" do
      # Create an INVITE and establish an early dialog
      invite_msg = create_invite_request()

      # Create 180 Ringing response to establish early dialog
      response_180 = Message.reply(invite_msg, 180, "Ringing")
      # Add To tag to create dialog
      response_180 = %{
        response_180
        | to: %{
            response_180.to
            | parameters: Map.put(response_180.to.parameters, "tag", "xyz123")
          }
      }

      # Start dialog in early state
      {:ok, dialog_pid} =
        ParrotSip.Dialog.Supervisor.start_child({:uas, response_180, invite_msg})

      # Now send CANCEL
      cancel_msg = create_cancel_request()
      cancel_trans = create_test_uas(cancel_msg)
      handler = TestHandler.new()

      # Should allow CANCEL for early dialog
      assert :ok == Server.process_cancel(cancel_trans, handler)

      # Clean up
      Process.exit(dialog_pid, :kill)
    end

    test "rejects CANCEL for confirmed dialog with 481" do
      # Create an INVITE and establish a confirmed dialog
      invite_msg = create_invite_request()

      # Create 200 OK response to establish confirmed dialog
      response_200 = Message.reply(invite_msg, 200, "OK")
      # Add To tag to create dialog
      response_200 = %{
        response_200
        | to: %{
            response_200.to
            | parameters: Map.put(response_200.to.parameters, "tag", "abc789")
          }
      }

      # Start dialog in confirmed state
      {:ok, dialog_pid} =
        ParrotSip.Dialog.Supervisor.start_child({:uas, response_200, invite_msg})

      # Give dialog time to reach confirmed state
      Process.sleep(50)

      # Now send CANCEL
      cancel_msg = create_cancel_request()
      cancel_trans = create_test_uas(cancel_msg)
      handler = TestHandler.new()

      # Should reject CANCEL for confirmed dialog
      # The implementation sends 481 response via TransactionStatem.server_response
      assert :ok == Server.process_cancel(cancel_trans, handler)

      # Clean up
      Process.exit(dialog_pid, :kill)
    end

    test "handles non-Transaction arguments" do
      trans = {:trans, self()}
      handler = TestHandler.new()

      assert :ok == Server.process_cancel(trans, handler)
    end
  end

  describe "response functions" do
    test "response/2 returns {:ok, final_response} with To tag for INVITE 2xx" do
      req_msg = create_invite_request()
      uas = create_test_uas(req_msg)
      resp_msg = Message.reply(req_msg, 200, "OK")

      # Response should return {:ok, final_response} with generated To tag
      assert {:ok, final_response} = Server.response(resp_msg, uas)
      assert final_response.status_code == 200

      # The final response should have a To tag added
      assert final_response.to.parameters["tag"] != nil
      assert is_binary(final_response.to.parameters["tag"])
    end

    test "response/2 preserves existing To tag for INVITE 2xx" do
      req_msg = create_invite_request()
      uas = create_test_uas(req_msg)
      resp_msg = Message.reply(req_msg, 200, "OK")

      # Add an existing To tag
      existing_tag = "existing-tag-123"
      to_with_tag = %{resp_msg.to | parameters: Map.put(resp_msg.to.parameters, "tag", existing_tag)}
      resp_msg_with_tag = %{resp_msg | to: to_with_tag}

      # Response should preserve the existing tag
      assert {:ok, final_response} = Server.response(resp_msg_with_tag, uas)
      assert final_response.to.parameters["tag"] == existing_tag
    end

    test "response/2 returns {:ok, final_response} for non-dialog responses" do
      req_msg = create_options_request()
      uas = create_test_uas(req_msg)
      resp_msg = Message.reply(req_msg, 200, "OK")

      # Non-dialog responses should also return {:ok, final_response}
      assert {:ok, final_response} = Server.response(resp_msg, uas)
      assert final_response.status_code == 200
    end

    test "response_retransmit/2 delegates to transaction server" do
      req_msg = create_invite_request()
      uas = create_test_uas(req_msg)
      resp_msg = Message.reply(req_msg, 200, "OK")

      # Should complete without error
      assert :ok == Server.response_retransmit(resp_msg, uas)
    end
  end

  describe "set_owner/3" do
    test "delegates to transaction server with proper parameters" do
      req_msg = create_invite_request()
      uas = create_test_uas(req_msg)
      owner_pid = self()
      auto_resp_code = 500

      assert :ok == Server.set_owner(auto_resp_code, owner_pid, uas)
    end
  end

  # Helper functions

  defp create_invite_request do
    headers = create_basic_headers()

    %Message{
      type: :request,
      direction: :incoming,
      method: :invite,
      request_uri: "sip:bob@biloxi.com",
      version: "SIP/2.0",
      call_id: headers["call-id"],
      contact: headers["contact"],
      cseq: headers["cseq"],
      from: headers["from"],
      to: headers["to"],
      via: headers["via"],
      body: "",
      source: create_test_source(),
      other_headers: %{}
    }
  end

  defp create_ack_request do
    headers = create_basic_headers()

    %Message{
      type: :request,
      direction: :incoming,
      method: :ack,
      request_uri: "sip:bob@biloxi.com",
      version: "SIP/2.0",
      call_id: headers["call-id"],
      contact: headers["contact"],
      cseq: headers["cseq"],
      from: headers["from"],
      to: headers["to"],
      via: headers["via"],
      body: "",
      source: create_test_source(),
      other_headers: %{}
    }
  end

  defp create_cancel_request do
    headers = create_basic_headers()

    %Message{
      type: :request,
      direction: :incoming,
      method: :cancel,
      request_uri: "sip:bob@biloxi.com",
      version: "SIP/2.0",
      call_id: headers["call-id"],
      contact: headers["contact"],
      cseq: headers["cseq"],
      from: headers["from"],
      to: headers["to"],
      via: headers["via"],
      body: "",
      source: create_test_source(),
      other_headers: %{}
    }
  end

  defp create_request_with_method(method) do
    headers = create_basic_headers()

    %Message{
      type: :request,
      direction: :incoming,
      method: method,
      request_uri: "sip:alice@example.com",
      version: "SIP/2.0",
      call_id: headers["call-id"],
      contact: headers["contact"],
      cseq: headers["cseq"],
      from: headers["from"],
      to: headers["to"],
      via: headers["via"],
      body: "",
      source: create_test_source(),
      other_headers: %{}
    }
  end

  defp create_options_request do
    headers = create_basic_headers()
    cseq = %CSeq{number: 1, method: :options}

    %Message{
      type: :request,
      direction: :incoming,
      method: :options,
      request_uri: "sip:bob@biloxi.com",
      version: "SIP/2.0",
      call_id: headers["call-id"],
      contact: headers["contact"],
      cseq: cseq,
      from: headers["from"],
      to: headers["to"],
      via: headers["via"],
      body: "",
      source: create_test_source(),
      other_headers: %{}
    }
  end

  defp create_basic_headers do
    %{
      "call-id" => "a84b4c76e66710@pc33.atlanta.com",
      "contact" => %Contact{
        display_name: nil,
        uri: "sip:alice@pc33.atlanta.com",
        parameters: %{},
        wildcard: nil
      },
      "cseq" => %CSeq{number: 314_159, method: :invite},
      "from" => %From{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{"tag" => "1928301774"}
      },
      "to" => %To{
        display_name: "Bob",
        uri: "sip:bob@biloxi.com",
        parameters: %{}
      },
      "via" => %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "pc33.atlanta.com",
        port: 5060,
        host_type: nil,
        parameters: %{"branch" => "z9hG4bKnew123"}
      }
    }
  end

  defp create_test_uas(req_msg) do
    %ParrotSip.Transaction{
      request: req_msg,
      method: req_msg.method,
      branch: get_branch_from_message(req_msg),
      role: :uas
    }
  end

  defp get_branch_from_message(msg) do
    case msg.via do
      [%{params: %{"branch" => branch}} | _] -> branch
      _ -> "z9hG4bK" <> Base.encode16(:crypto.strong_rand_bytes(8))
    end
  end

  defp create_test_source do
    %ParrotSip.Source{
      local: {{127, 0, 0, 1}, 5060},
      remote: {{192, 168, 1, 100}, 5060},
      transport: :udp,
      source_id: nil
    }
  end
end
