defmodule ParrotSipTest do
  use ExUnit.Case, async: true
  doctest ParrotSip

  alias ParrotSip.{Message, Headers}

  describe "parse_message/1" do
    test "parses a valid INVITE request" do
      raw = """
      INVITE sip:bob@biloxi.com SIP/2.0\r
      Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds\r
      From: Alice <sip:alice@atlanta.com>;tag=1928301774\r
      To: Bob <sip:bob@biloxi.com>\r
      Call-ID: a84b4c76e66710@pc33.atlanta.com\r
      CSeq: 314159 INVITE\r
      Max-Forwards: 70\r
      Content-Length: 0\r
      \r
      """

      assert {:ok, message} = ParrotSip.parse_message(raw)
      assert message.method == :invite
      assert message.type == :request
      assert message.request_uri == "sip:bob@biloxi.com"
      assert is_list(message.via)
      assert length(message.via) == 1
      assert hd(message.via).host == "pc33.atlanta.com"
    end

    test "parses a valid 200 OK response" do
      raw = """
      SIP/2.0 200 OK\r
      Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds\r
      From: Alice <sip:alice@atlanta.com>;tag=1928301774\r
      To: Bob <sip:bob@biloxi.com>;tag=a6c85cf\r
      Call-ID: a84b4c76e66710@pc33.atlanta.com\r
      CSeq: 314159 INVITE\r
      Content-Length: 0\r
      \r
      """

      assert {:ok, message} = ParrotSip.parse_message(raw)
      assert message.type == :response
      assert message.status_code == 200
      assert message.reason_phrase == "OK"
      assert is_list(message.via)
    end

    test "returns error for malformed message" do
      assert {:error, _} = ParrotSip.parse_message("not a valid SIP message")
    end

    test "returns error for empty binary" do
      assert {:error, _} = ParrotSip.parse_message("")
    end

    test "parses message with multiple Via headers" do
      raw = """
      INVITE sip:bob@biloxi.com SIP/2.0\r
      Via: SIP/2.0/UDP proxy.atlanta.com;branch=z9hG4bK1234\r
      Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK5678\r
      From: Alice <sip:alice@atlanta.com>;tag=1928301774\r
      To: Bob <sip:bob@biloxi.com>\r
      Call-ID: a84b4c76e66710@pc33.atlanta.com\r
      CSeq: 314159 INVITE\r
      Max-Forwards: 70\r
      Content-Length: 0\r
      \r
      """

      assert {:ok, message} = ParrotSip.parse_message(raw)
      assert length(message.via) == 2
      assert hd(message.via).host == "proxy.atlanta.com"
    end
  end

  describe "serialize_message/1" do
    test "serializes a request message to binary" do
      message = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@biloxi.com",
        version: "SIP/2.0",
        via: [
          %Headers.Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "pc33.atlanta.com",
            port: nil,
            host_type: :hostname,
            parameters: %{"branch" => "z9hG4bK776asdhds"}
          }
        ],
        from: %Headers.From{
          display_name: "Alice",
          uri: "sip:alice@atlanta.com",
          parameters: %{"tag" => "1928301774"}
        },
        to: %Headers.To{
          display_name: "Bob",
          uri: "sip:bob@biloxi.com",
          parameters: %{}
        },
        call_id: "a84b4c76e66710@pc33.atlanta.com",
        cseq: %Headers.CSeq{number: 314159, method: :invite},
        max_forwards: 70,
        content_length: 0,
        body: "",
        other_headers: %{}
      }

      binary = ParrotSip.serialize_message(message)
      assert is_binary(binary)
      assert binary =~ "INVITE sip:bob@biloxi.com SIP/2.0"
      assert binary =~ "Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds"
      assert binary =~ "From: Alice <sip:alice@atlanta.com>;tag=1928301774"
      assert binary =~ "CSeq: 314159 INVITE"
    end

    test "serializes a response message to binary" do
      message = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        version: "SIP/2.0",
        via: [
          %Headers.Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "pc33.atlanta.com",
            port: nil,
            host_type: :hostname,
            parameters: %{"branch" => "z9hG4bK776asdhds"}
          }
        ],
        from: %Headers.From{
          display_name: "Alice",
          uri: "sip:alice@atlanta.com",
          parameters: %{"tag" => "1928301774"}
        },
        to: %Headers.To{
          display_name: "Bob",
          uri: "sip:bob@biloxi.com",
          parameters: %{"tag" => "a6c85cf"}
        },
        call_id: "a84b4c76e66710@pc33.atlanta.com",
        cseq: %Headers.CSeq{number: 314159, method: :invite},
        content_length: 0,
        body: "",
        other_headers: %{}
      }

      binary = ParrotSip.serialize_message(message)
      assert is_binary(binary)
      assert binary =~ "SIP/2.0 200 OK"
      assert binary =~ "Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds"
    end

    test "round-trip parse and serialize preserves message" do
      raw = """
      INVITE sip:bob@biloxi.com SIP/2.0\r
      Via: SIP/2.0/UDP pc33.atlanta.com;branch=z9hG4bK776asdhds\r
      From: Alice <sip:alice@atlanta.com>;tag=1928301774\r
      To: Bob <sip:bob@biloxi.com>\r
      Call-ID: a84b4c76e66710@pc33.atlanta.com\r
      CSeq: 314159 INVITE\r
      Max-Forwards: 70\r
      Content-Length: 0\r
      \r
      """

      {:ok, message} = ParrotSip.parse_message(raw)
      serialized = ParrotSip.serialize_message(message)
      {:ok, reparsed} = ParrotSip.parse_message(serialized)

      assert reparsed.method == message.method
      assert reparsed.request_uri == message.request_uri
      assert length(reparsed.via) == length(message.via)
    end
  end

  describe "create_dialog/2" do
    test "creates a UAC dialog from INVITE" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@biloxi.com",
        from: %Headers.From{
          display_name: "Alice",
          uri: "sip:alice@atlanta.com",
          parameters: %{"tag" => "1928301774"}
        },
        to: %Headers.To{
          display_name: "Bob",
          uri: "sip:bob@biloxi.com",
          parameters: %{"tag" => "a6c85cf"}
        },
        call_id: "a84b4c76e66710@pc33.atlanta.com",
        cseq: %Headers.CSeq{number: 1, method: :invite}
      }

      assert {:ok, dialog} = ParrotSip.create_dialog(invite, :uac)
      assert dialog.call_id == "a84b4c76e66710@pc33.atlanta.com"
      assert dialog.local_tag == "1928301774"
      assert dialog.remote_tag == "a6c85cf"
    end

    test "creates a UAS dialog from INVITE" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@biloxi.com",
        from: %Headers.From{
          display_name: "Alice",
          uri: "sip:alice@atlanta.com",
          parameters: %{"tag" => "1928301774"}
        },
        to: %Headers.To{
          display_name: "Bob",
          uri: "sip:bob@biloxi.com",
          parameters: %{"tag" => "a6c85cf"}
        },
        call_id: "a84b4c76e66710@pc33.atlanta.com",
        cseq: %Headers.CSeq{number: 1, method: :invite}
      }

      assert {:ok, dialog} = ParrotSip.create_dialog(invite, :uas)
      assert dialog.call_id == "a84b4c76e66710@pc33.atlanta.com"
      # For UAS, tags are swapped
      assert dialog.local_tag == "a6c85cf"
      assert dialog.remote_tag == "1928301774"
    end

    test "returns error for non-INVITE message" do
      register = %Message{
        type: :request,
        method: :register,
        from: %Headers.From{uri: "sip:alice@atlanta.com", parameters: %{"tag" => "123"}},
        to: %Headers.To{uri: "sip:alice@atlanta.com", parameters: %{}},
        call_id: "test123",
        cseq: %Headers.CSeq{number: 1, method: :register}
      }

      assert {:error, _} = ParrotSip.create_dialog(register, :uac)
    end

    test "returns error when missing required dialog fields" do
      incomplete_invite = %Message{
        type: :request,
        method: :invite,
        from: %Headers.From{uri: "sip:alice@atlanta.com", parameters: %{}},
        # Missing tag in From
        to: %Headers.To{uri: "sip:bob@biloxi.com", parameters: %{}},
        call_id: "test123",
        cseq: %Headers.CSeq{number: 1, method: :invite}
      }

      assert {:error, _} = ParrotSip.create_dialog(incomplete_invite, :uac)
    end
  end

  describe "get_transaction_state/1" do
    test "returns :not_found for non-existent transaction" do
      assert {:error, :not_found} = ParrotSip.get_transaction_state("nonexistent-transaction-id")
    end

    test "returns :not_found for invalid transaction ID format" do
      assert {:error, :not_found} = ParrotSip.get_transaction_state("invalid:format")
    end

    test "returns :not_found for empty transaction ID" do
      assert {:error, :not_found} = ParrotSip.get_transaction_state("")
    end

    # Note: Testing actual transaction states would require setting up
    # a full transaction process, which is better tested in integration tests
    # or in the transaction_statem_test.exs file
  end

  describe "API timeout behavior" do
    test "parse_message does not accept timeout parameter" do
      # Verify parse_message/1 only has arity 1
      refute function_exported?(ParrotSip, :parse_message, 2)
    end

    test "serialize_message does not accept timeout parameter" do
      # Verify serialize_message/1 only has arity 1
      refute function_exported?(ParrotSip, :serialize_message, 2)
    end

    test "create_dialog does not accept timeout parameter" do
      # Verify create_dialog/2 only has arity 2
      refute function_exported?(ParrotSip, :create_dialog, 3)
    end

    test "get_transaction_state does not accept timeout parameter" do
      # Verify get_transaction_state/1 only has arity 1
      refute function_exported?(ParrotSip, :get_transaction_state, 2)
    end

    # send_request and send_response accept optional timeout as 3rd parameter
    test "send_request accepts timeout parameter" do
      assert function_exported?(ParrotSip, :send_request, 3)
    end

    test "send_response accepts timeout parameter" do
      assert function_exported?(ParrotSip, :send_response, 3)
    end
  end

  describe "module metadata" do
    test "module exists and is loaded" do
      assert Code.ensure_loaded?(ParrotSip)
    end

    test "module has documentation" do
      {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(ParrotSip)
      assert moduledoc =~ "SIP protocol implementation"
    end

    test "all public functions are exported" do
      exports = ParrotSip.__info__(:functions)

      assert Keyword.has_key?(exports, :send_request)
      assert Keyword.has_key?(exports, :send_response)
      assert Keyword.has_key?(exports, :parse_message)
      assert Keyword.has_key?(exports, :serialize_message)
      assert Keyword.has_key?(exports, :create_dialog)
      assert Keyword.has_key?(exports, :get_transaction_state)
    end
  end
end
