defmodule ParrotSip.MessageTest do
  use ExUnit.Case

  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, From, To, CSeq, Contact}

  describe "Pattern matching on Message struct fields" do
    test "can pattern match on Via header directly" do
      via = Via.new("proxy.example.com", "udp", 5060, %{"branch" => "z9hG4bK123"})

      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        via: via,
        from: From.new("sip:alice@example.com", "Alice", "tag123"),
        to: To.new("sip:bob@example.com"),
        call_id: "call123@example.com",
        cseq: CSeq.new(1, :invite),
        type: :request,
        direction: :outgoing
      }

      # Direct pattern matching on Via
      assert %Message{via: %Via{host: "proxy.example.com", port: 5060}} = message

      # Pattern match and extract values
      %Message{via: %Via{parameters: %{"branch" => branch}}} = message
      assert branch == "z9hG4bK123"
    end

    test "can pattern match on multiple Via headers (list)" do
      via1 = Via.new("proxy1.example.com", "udp", 5060, %{"branch" => "z9hG4bK111"})
      via2 = Via.new("proxy2.example.com", "tcp", 5061, %{"branch" => "z9hG4bK222"})

      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        via: [via1, via2],
        from: From.new("sip:alice@example.com", "Alice"),
        to: To.new("sip:bob@example.com", "Bob"),
        call_id: "call123@example.com",
        cseq: CSeq.new(1, :invite),
        contact: Contact.new("sip:alice@192.168.1.100:5060"),
        type: :request,
        version: "SIP/2.0"
      }

      # Pattern match on first Via in list
      assert %Message{via: [%Via{host: "proxy1.example.com"} | _rest]} = message

      # Extract top Via using pattern matching
      %Message{via: [top_via | _]} = message
      assert top_via.host == "proxy1.example.com"
      assert top_via.transport == :udp

      binary = Message.to_binary(message)

      # Check that the message starts with the request line
      assert binary =~ ~r/^INVITE sip:bob@example.com SIP\/2.0\r\n/

      # Check that Via header appears first after the request line
      lines = String.split(binary, "\r\n")
      assert Enum.at(lines, 1) =~ ~r/^Via: /

      # Check that Via headers are properly formatted
      assert binary =~
               "Via: SIP/2.0/UDP proxy1.example.com:5060;branch=z9hG4bK111, SIP/2.0/TCP proxy2.example.com:5061;branch=z9hG4bK222\r\n"

      # Check other headers are present and formatted
      assert binary =~ "From: Alice <sip:alice@example.com>\r\n"
      assert binary =~ "To: Bob <sip:bob@example.com>\r\n"
      assert binary =~ "Cseq: 1 INVITE\r\n"
      assert binary =~ "Call-Id: call123@example.com\r\n"
      assert binary =~ "Contact: <sip:alice@192.168.1.100:5060>\r\n"
    end

    test "can pattern match on From and To headers with tags" do
      message = %Message{
        method: :invite,
        from: From.new("sip:alice@example.com", "Alice", %{"tag" => "from123"}),
        to: To.new("sip:bob@example.com", "Bob", %{"tag" => "to456"}),
        call_id: "dialog123",
        cseq: CSeq.new(1, :invite),
        type: :request
      }

      # Pattern match to check if message is in dialog
      assert %Message{
               from: %From{parameters: %{"tag" => from_tag}},
               to: %To{parameters: %{"tag" => to_tag}}
             } = message

      assert from_tag != nil
      assert to_tag != nil
      assert from_tag == "from123"
      assert to_tag == "to456"
    end

    test "serializes message with single Via in struct field" do
      via = Via.new("proxy.example.com", "udp", 5060, %{"branch" => "z9hG4bK123"})

      message = %Message{
        method: :register,
        request_uri: "sip:registrar.example.com",
        version: "SIP/2.0",
        type: :request,
        via: via,
        from: From.new("sip:alice@example.com", nil, "tag456"),
        to: To.new("sip:alice@example.com"),
        cseq: CSeq.new(1, :register),
        call_id: "reg123@example.com"
      }

      # Pattern match on single Via
      assert %Message{via: %Via{host: "proxy.example.com"}} = message

      binary = Message.to_binary(message)

      # Via should be formatted correctly from struct field
      assert binary =~ "Via: SIP/2.0/UDP proxy.example.com:5060;branch=z9hG4bK123\r\n"
    end

    test "can pattern match on CSeq header" do
      message = %Message{
        method: :ack,
        cseq: CSeq.new(42, :invite),
        type: :request
      }

      # Pattern match on CSeq number and method
      assert %Message{cseq: %CSeq{number: 42, method: :invite}} = message
    end

    test "serializes message with struct fields and other_headers" do
      via = Via.new("proxy.example.com", "udp", 5060, %{"branch" => "z9hG4bK999"})

      message = %Message{
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        type: :request,
        via: via,
        from: From.new("sip:alice@example.com", "Alice", "tagABC"),
        to: To.new("sip:bob@example.com"),
        cseq: CSeq.new(1, :invite),
        call_id: "mixed123@example.com",
        contact: Contact.new("sip:alice@host.com"),
        content_type: %ParrotSip.Headers.ContentType{
          type: "application",
          subtype: "sdp",
          parameters: %{}
        },
        content_length: 0,
        max_forwards: 70,
        other_headers: %{
          "user-agent" => "Parrot/1.0"
        },
        body: ""
      }

      binary = Message.to_binary(message)

      # Check all headers are formatted correctly from struct fields
      assert binary =~ "Via: SIP/2.0/UDP proxy.example.com:5060;branch=z9hG4bK999\r\n"
      assert binary =~ "From: Alice <sip:alice@example.com>;tag=tagABC\r\n"
      assert binary =~ "Content-Type: application/sdp\r\n"
      assert binary =~ "Content-Length: 0\r\n"
      assert binary =~ "Max-Forwards: 70\r\n"
      assert binary =~ "User-Agent: Parrot/1.0\r\n"
    end
  end

  describe "Message accessor removal tests" do
    test "direct field access instead of accessor functions" do
      message =
        Message.new_request(:invite, "sip:bob@example.com")
        |> Message.put_from(From.new("sip:alice@example.com", "Alice", %{"tag" => "123"}))
        |> Message.put_to(To.new("sip:bob@example.com", "Bob", %{"tag" => "456"}))
        |> Message.put_call_id("call123@example.com")
        |> Message.put_cseq(CSeq.new(42, :invite))
        |> Message.put_via(Via.new("example.com", "udp", 5060, %{"branch" => "z9hG4bK999"}))
        |> Message.put_contact(Contact.new("sip:alice@192.168.1.1:5060"))

      # Direct field access (no more Message.from/1, Message.to/1, etc.)
      assert ParrotSip.Uri.to_string(message.from.uri) == "sip:alice@example.com"
      assert ParrotSip.Uri.to_string(message.to.uri) == "sip:bob@example.com"
      assert message.call_id == "call123@example.com"
      assert message.cseq.number == 42
      assert message.cseq.method == :invite
      assert message.via.host == "example.com"
      assert ParrotSip.Uri.to_string(message.contact.uri) == "sip:alice@192.168.1.1:5060"

      # Extract branch using pattern matching instead of Message.branch/1
      %Message{via: %Via{parameters: %{"branch" => branch}}} = message
      assert branch == "z9hG4bK999"

      # Extract tags using pattern matching instead of Message.from_tag/1, Message.to_tag/1
      %Message{
        from: %From{parameters: %{"tag" => from_tag}},
        to: %To{parameters: %{"tag" => to_tag}}
      } = message

      assert from_tag == "123"
      assert to_tag == "456"
    end

    test "top_via with pattern matching instead of function" do
      # Single Via in list
      msg1 =
        Message.new_request(:invite, "sip:bob@example.com")
        |> Message.put_via([Via.new("single.com", "udp")])

      assert %Message{via: [%Via{host: "single.com"}]} = msg1

      # Via list with multiple
      msg2 =
        Message.new_request(:invite, "sip:bob@example.com")
        |> Message.put_via([Via.new("first.com", "tcp"), Via.new("second.com", "udp")])

      assert %Message{via: [%Via{host: "first.com"} | _]} = msg2

      # Empty Via list
      msg3 = Message.new_request(:invite, "sip:bob@example.com")
      assert %Message{via: []} = msg3
    end
  end
end
