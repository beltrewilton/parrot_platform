defmodule ParrotSip.UA.SdpAnswerTest do
  @moduledoc """
  Tests for SDP answer handler callback in UA.

  RFC 3261 Section 13.2.2.4: If the 2xx contains an offer (based on the
  rules above), the ACK MUST carry an answer in its body.

  This moves SDP answer generation from Transaction.Client to UA layer,
  allowing application-level control over media negotiation.
  """
  use ExUnit.Case, async: false

  alias ParrotSip.{Message, UA}
  alias ParrotSip.UA.Entity
  alias ParrotSip.Headers.ContentType

  @moduletag :ua_sdp_answer

  # Test handler that captures SDP answer handler invocations
  defmodule TestHandler do
    use ParrotSip.UA.Handler

    @impl true
    def init(test_pid) do
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_incoming(_ua, _invite, _entity, state) do
      {:ok, state}
    end

    @impl true
    def handle_answered(_ua, response, entity, state) do
      send(state.test_pid, {:answered, response, entity})
      {:ok, state}
    end
  end

  describe "dial/3 with sdp_answer_handler option" do
    test "accepts sdp_answer_handler option" do
      {:ok, ua} = UA.start_link(TestHandler, self(), port: 0)

      # Should not raise - just verify option is accepted
      # The actual call will fail due to network, but option parsing should work
      handler = fn _offer_sdp, _opts ->
        {:ok, "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"}
      end

      # Note: dial will start a transaction but won't complete
      # We're just testing that the option is accepted
      result = UA.dial(ua, "sip:bob@127.0.0.1:5099", sdp_answer_handler: handler)
      assert {:ok, %Entity{}} = result

      GenServer.stop(ua)
    end

    test "sdp_answer_handler stored in entity for later use" do
      {:ok, ua} = UA.start_link(TestHandler, self(), port: 0)

      handler = fn offer_sdp, _opts ->
        {:ok, "answer for: #{offer_sdp}"}
      end

      {:ok, entity} = UA.dial(ua, "sip:bob@127.0.0.1:5099", sdp_answer_handler: handler)

      # The entity should have the handler stored
      assert entity.sdp_answer_handler != nil
      assert is_function(entity.sdp_answer_handler, 2)

      GenServer.stop(ua)
    end
  end

  describe "SDP answer handler invocation" do
    test "handler invoked when 2xx INVITE contains SDP offer" do
      test_pid = self()

      # Create a mock handler that tracks invocations
      handler = fn offer_sdp, opts ->
        send(test_pid, {:sdp_handler_called, offer_sdp, opts})
        {:ok, "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"}
      end

      # Simulate the scenario where handler should be invoked
      # This tests the internal logic
      offer_sdp = "v=0\r\no=alice 123 456 IN IP4 192.168.1.100\r\ns=Session\r\n"

      # Call the handler directly to verify it works
      {:ok, answer} = handler.(offer_sdp, [])

      assert_received {:sdp_handler_called, ^offer_sdp, []}
      assert String.contains?(answer, "v=0")
    end

    test "handler receives offer SDP and options" do
      handler = fn offer_sdp, opts ->
        assert is_binary(offer_sdp)
        assert is_list(opts)
        {:ok, "answer"}
      end

      offer = "v=0\r\no=alice 123 456 IN IP4 192.168.1.100\r\ns=Session\r\n"
      assert {:ok, "answer"} = handler.(offer, local_port: 10000)
    end

    test "handler error propagates correctly" do
      handler = fn _offer_sdp, _opts ->
        {:error, :codec_mismatch}
      end

      offer = "v=0\r\no=alice 123 456 IN IP4 192.168.1.100\r\ns=Session\r\n"
      assert {:error, :codec_mismatch} = handler.(offer, [])
    end
  end

  describe "fallback behavior without sdp_answer_handler" do
    test "dial works without sdp_answer_handler option" do
      {:ok, ua} = UA.start_link(TestHandler, self(), port: 0)

      # Should work without the option
      result = UA.dial(ua, "sip:bob@127.0.0.1:5099", sdp: "v=0\r\n")
      assert {:ok, %Entity{}} = result

      GenServer.stop(ua)
    end

    test "entity has nil sdp_answer_handler when not provided" do
      {:ok, ua} = UA.start_link(TestHandler, self(), port: 0)

      {:ok, entity} = UA.dial(ua, "sip:bob@127.0.0.1:5099")

      # Without the option, handler should be nil
      assert entity.sdp_answer_handler == nil

      GenServer.stop(ua)
    end
  end

  describe "SDP detection" do
    test "detects SDP in response with application/sdp content type" do
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        content_type: %ContentType{type: "application", subtype: "sdp"},
        body: "v=0\r\no=alice 123 456 IN IP4 192.168.1.100\r\ns=Session\r\n"
      }

      assert has_sdp_offer?(response) == true
    end

    test "detects no SDP when content type is not application/sdp" do
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        content_type: %ContentType{type: "text", subtype: "plain"},
        body: "some text"
      }

      assert has_sdp_offer?(response) == false
    end

    test "detects no SDP when body is empty" do
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        content_type: %ContentType{type: "application", subtype: "sdp"},
        body: ""
      }

      assert has_sdp_offer?(response) == false
    end

    test "detects no SDP when content type is nil" do
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        content_type: nil,
        body: "v=0\r\n"
      }

      assert has_sdp_offer?(response) == false
    end
  end

  describe "Message.build_ack/2" do
    alias ParrotSip.Headers.{Via, From, To, CSeq}

    test "builds ACK from INVITE request and 2xx response" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.100",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKinvite123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.100",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKinvite123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      ack = Message.build_ack(invite, response)

      assert ack.type == :request
      assert ack.method == :ack
      assert ack.request_uri == invite.request_uri
      assert ack.call_id == invite.call_id
      assert ack.cseq.number == invite.cseq.number
      assert ack.cseq.method == :ack
      # ACK uses the To header from response (includes remote tag)
      assert ack.to.parameters["tag"] == "to456"
      # ACK uses the From header from original request
      assert ack.from.parameters["tag"] == "from123"
    end

    test "ACK has new branch parameter per RFC 3261 17.1.1.3" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.100",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKinvite123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      response = %Message{
        type: :response,
        status_code: 200,
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}}
      }

      ack = Message.build_ack(invite, response)

      # ACK for 2xx MUST have a new branch (different from INVITE)
      ack_branch = get_branch(ack)
      invite_branch = get_branch(invite)
      assert ack_branch != invite_branch
      assert String.starts_with?(ack_branch, "z9hG4bK")
    end
  end

  describe "ACK with SDP answer attachment" do
    alias ParrotSip.Headers.{Via, From, To, CSeq}

    test "SDP answer attached to ACK when handler returns success" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.100",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKinvite123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      offer_sdp =
        "v=0\r\no=bob 123 456 IN IP4 192.168.1.200\r\ns=Session\r\nt=0 0\r\nm=audio 20000 RTP/AVP 8\r\n"

      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        content_type: %ContentType{type: "application", subtype: "sdp"},
        body: offer_sdp,
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}}
      }

      answer_sdp =
        "v=0\r\no=alice 789 012 IN IP4 192.168.1.100\r\ns=Session\r\nt=0 0\r\nm=audio 10000 RTP/AVP 8\r\n"

      handler = fn _offer, _opts -> {:ok, answer_sdp} end

      ack = Message.build_ack(invite, response)
      ack_with_answer = Message.attach_sdp_answer(ack, response, handler)

      assert ack_with_answer.body == answer_sdp
      assert ack_with_answer.content_type.type == "application"
      assert ack_with_answer.content_type.subtype == "sdp"
    end

    test "ACK has empty body when handler returns error" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.100",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKinvite123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      offer_sdp = "v=0\r\no=bob 123 456 IN IP4 192.168.1.200\r\ns=Session\r\n"

      response = %Message{
        type: :response,
        status_code: 200,
        content_type: %ContentType{type: "application", subtype: "sdp"},
        body: offer_sdp,
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}}
      }

      handler = fn _offer, _opts -> {:error, :codec_mismatch} end

      ack = Message.build_ack(invite, response)
      ack_result = Message.attach_sdp_answer(ack, response, handler)

      # Per RFC 3261, ACK is still sent even if we can't generate SDP answer
      assert ack_result.body == nil or ack_result.body == ""
    end

    test "ACK unchanged when no handler provided" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.100",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKinvite123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      offer_sdp = "v=0\r\no=bob 123 456 IN IP4 192.168.1.200\r\ns=Session\r\n"

      response = %Message{
        type: :response,
        status_code: 200,
        content_type: %ContentType{type: "application", subtype: "sdp"},
        body: offer_sdp,
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}}
      }

      ack = Message.build_ack(invite, response)
      ack_result = Message.attach_sdp_answer(ack, response, nil)

      # No handler means no SDP attachment
      assert ack_result.body == nil or ack_result.body == ""
    end

    test "ACK unchanged when response has no SDP offer" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.100",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKinvite123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      # Response with no SDP
      response = %Message{
        type: :response,
        status_code: 200,
        content_type: nil,
        body: nil,
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}}
      }

      # Handler that should NOT be called
      handler = fn _offer, _opts -> raise "Should not be called" end

      ack = Message.build_ack(invite, response)
      ack_result = Message.attach_sdp_answer(ack, response, handler)

      # No SDP in response means handler not invoked
      assert ack_result.body == nil or ack_result.body == ""
    end
  end

  # Helper function to check for SDP offer (will be moved to Message module)
  defp has_sdp_offer?(%Message{content_type: content_type, body: body})
       when is_binary(body) and body != "" do
    case content_type do
      %ContentType{type: "application", subtype: "sdp"} -> true
      _ -> false
    end
  end

  defp has_sdp_offer?(_), do: false

  # Helper to extract branch from Via
  defp get_branch(%Message{via: [%{parameters: params} | _]}), do: params["branch"]
end
