defmodule ParrotSip.MessageCreationTest do
  @moduledoc """
  Tests for Message creation functions after refactoring.
  Shows how new_request and new_response work with struct fields.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, From, To, CSeq, Contact}

  describe "new_request/2 and new_request/3" do
    test "creates a request with minimal fields" do
      message = Message.new_request(:invite, "sip:bob@example.com")
      
      assert message.method == :invite
      assert message.request_uri == "sip:bob@example.com"
      assert message.version == "SIP/2.0"
      assert message.type == :request
      assert message.direction == :outgoing
      assert message.body == ""
      
      # All header fields should be nil by default
      assert message.via == nil
      assert message.from == nil
      assert message.to == nil
      assert message.call_id == nil
      assert message.cseq == nil
      assert message.contact == nil
      assert message.route == nil
      assert message.record_route == nil
      assert message.content_type == nil
      assert message.content_length == nil
      assert message.max_forwards == nil
      assert message.other_headers == %{}
    end
    
    test "creates a request with dialog and transaction ids" do
      message = Message.new_request(:invite, "sip:bob@example.com", 
        dialog_id: "dlg123", 
        transaction_id: "txn456"
      )
      
      assert message.dialog_id == "dlg123"
      assert message.transaction_id == "txn456"
    end
    
    test "builds a complete request using helper functions" do
      message = 
        Message.new_request(:invite, "sip:bob@example.com")
        |> Message.put_via(Via.new("proxy.example.com", "udp", 5060, %{"branch" => "z9hG4bK123"}))
        |> Message.put_from(From.new("sip:alice@example.com", "Alice", %{"tag" => "from123"}))
        |> Message.put_to(To.new("sip:bob@example.com", "Bob"))
        |> Message.put_call_id("call123@example.com")
        |> Message.put_cseq(CSeq.new(1, :invite))
        |> Message.put_contact(Contact.new("sip:alice@192.168.1.1:5060"))
        |> Message.put_max_forwards(70)
        |> Message.put_header("User-Agent", "ParrotSip/1.0")
        |> Message.set_body("v=0\r\no=...")
      
      # All fields should be set correctly
      assert message.method == :invite
      assert message.via.host == "proxy.example.com"
      assert message.from.display_name == "Alice"
      assert message.to.display_name == "Bob"
      assert message.call_id == "call123@example.com"
      assert message.cseq.number == 1
      assert ParrotSip.Uri.to_string(message.contact.uri) == "sip:alice@192.168.1.1:5060"
      assert message.max_forwards == 70
      assert message.other_headers["user-agent"] == "ParrotSip/1.0"
      assert message.body == "v=0\r\no=..."
      assert message.content_length == 10
    end
  end
  
  describe "new_response/1 and new_response/2" do
    test "creates a response with status code only" do
      response = Message.new_response(200)
      
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
      assert response.version == "SIP/2.0"
      assert response.type == :response
      assert response.direction == :outgoing
      assert response.body == ""
      
      # All header fields should be nil by default
      assert response.via == nil
      assert response.from == nil
      assert response.to == nil
      assert response.call_id == nil
      assert response.cseq == nil
    end
    
    test "creates a response with custom reason phrase" do
      response = Message.new_response(200, "Okey Dokey")
      
      assert response.status_code == 200
      assert response.reason_phrase == "Okey Dokey"
    end
    
    test "creates a response with options" do
      response = Message.new_response(200, "OK", 
        dialog_id: "dlg789",
        transaction_id: "txn999"
      )
      
      assert response.dialog_id == "dlg789"
      assert response.transaction_id == "txn999"
    end
  end
  
  describe "reply/2 and reply/3" do
    test "creates a response from a request, copying header fields" do
      request = 
        Message.new_request(:invite, "sip:bob@example.com")
        |> Message.put_via(Via.new("client.com", "udp", 5060, %{"branch" => "z9hG4bK123"}))
        |> Message.put_from(From.new("sip:alice@example.com", nil, %{"tag" => "from123"}))
        |> Message.put_to(To.new("sip:bob@example.com"))
        |> Message.put_call_id("call123@example.com")
        |> Message.put_cseq(CSeq.new(1, :invite))
      
      response = Message.reply(request, 200, "OK")
      
      # Response should copy all dialog headers
      assert response.via == request.via
      assert response.from == request.from
      assert response.to == request.to
      assert response.call_id == request.call_id
      assert response.cseq == request.cseq
      
      # Response specific fields
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
      assert response.type == :response
      assert response.method == :invite  # Copied from request
      assert response.request_uri == "sip:bob@example.com"  # Copied from request
    end
    
    test "reply with default reason phrase" do
      request = 
        Message.new_request(:invite, "sip:bob@example.com")
        |> Message.put_from(From.new("sip:alice@example.com"))
        |> Message.put_to(To.new("sip:bob@example.com"))
        |> Message.put_call_id("call123")
        |> Message.put_cseq(CSeq.new(1, :invite))
      
      response = Message.reply(request, 404)
      
      assert response.status_code == 404
      assert response.reason_phrase == "Not Found"
    end
  end
  
  describe "Helper functions" do
    test "put_* functions set individual header fields" do
      message = Message.new_request(:invite, "sip:bob@example.com")
      
      # Test each put function
      message = Message.put_via(message, Via.new("example.com", "udp"))
      assert message.via.host == "example.com"
      
      message = Message.put_from(message, From.new("sip:alice@example.com"))
      assert ParrotSip.Uri.to_string(message.from.uri) == "sip:alice@example.com"
      
      message = Message.put_to(message, To.new("sip:bob@example.com"))
      assert ParrotSip.Uri.to_string(message.to.uri) == "sip:bob@example.com"
      
      message = Message.put_call_id(message, "call123")
      assert message.call_id == "call123"
      
      message = Message.put_cseq(message, CSeq.new(1, :invite))
      assert message.cseq.number == 1
      
      message = Message.put_contact(message, Contact.new("sip:alice@host.com"))
      assert ParrotSip.Uri.to_string(message.contact.uri) == "sip:alice@host.com"
      
      message = Message.put_max_forwards(message, 70)
      assert message.max_forwards == 70
    end
    
    test "add_via works with single via and list" do
      message = Message.new_request(:invite, "sip:bob@example.com")
      
      # Add first via
      message = Message.add_via(message, Via.new("first.com", "udp"))
      assert message.via.host == "first.com"
      
      # Add second via (creates list)
      message = Message.add_via(message, Via.new("second.com", "tcp"))
      assert [%Via{host: "second.com"}, %Via{host: "first.com"}] = message.via
      
      # Add third via (prepends to list)
      message = Message.add_via(message, Via.new("third.com", "tls"))
      assert [%Via{host: "third.com"}, %Via{host: "second.com"}, %Via{host: "first.com"}] = message.via
    end
    
    test "put_header stores unknown headers in other_headers" do
      message = Message.new_request(:invite, "sip:bob@example.com")
      
      message = Message.put_header(message, "X-Custom-Header", "custom-value")
      message = Message.put_header(message, "User-Agent", "MyApp/1.0")
      
      assert message.other_headers["x-custom-header"] == "custom-value"
      assert message.other_headers["user-agent"] == "MyApp/1.0"
    end
    
    test "set_body updates both body and content_length fields" do
      message = Message.new_request(:invite, "sip:bob@example.com")
      
      message = Message.set_body(message, "Hello, World!")
      
      assert message.body == "Hello, World!"
      assert message.content_length == 13
    end
  end
end