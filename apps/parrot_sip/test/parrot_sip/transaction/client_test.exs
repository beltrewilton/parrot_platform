defmodule ParrotSip.Transaction.ClientTest do
  use ExUnit.Case, async: true

  alias ParrotSip.Transaction.Client
  alias ParrotSip.Message
  alias ParrotSip.Headers.{ContentType, Via, From, To, CSeq}

  describe "ACK SDP answer generation" do
    test "ACK includes SDP answer when 2xx response contains SDP offer" do
      # Build an SDP offer (as would be in 2xx response)
      {:ok, sdp_offer} =
        ParrotMedia.Sdp.build_offer(
          local_ip: "192.168.1.100",
          local_port: 10000,
          supported_codecs: [:pcma],
          direction: :sendrecv
        )

      # Create a 2xx response with SDP offer
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        content_type: ContentType.new("application", "sdp"),
        body: sdp_offer,
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.200",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKtest123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      # Build base ACK
      base_ack = %Message{
        type: :request,
        request_uri: "sip:bob@example.com",
        method: :ack,
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.200",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKack789"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :ack}
      }

      # Call the public function to add SDP answer
      ack_with_sdp = Client.maybe_add_sdp_answer(base_ack, response)

      # Verify ACK has SDP answer
      assert ack_with_sdp.body != nil
      assert ack_with_sdp.body != ""
      assert ack_with_sdp.content_type != nil
      assert ack_with_sdp.content_type.type == "application"
      assert ack_with_sdp.content_type.subtype == "sdp"

      # Verify the SDP is valid
      assert String.starts_with?(ack_with_sdp.body, "v=0")
      assert String.contains?(ack_with_sdp.body, "m=audio")
    end

    test "ACK has empty body when 2xx response has no SDP" do
      # Create a 2xx response without SDP
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        content_type: nil,
        body: nil,
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.200",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKtest123"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :invite}
      }

      # Build base ACK
      base_ack = %Message{
        type: :request,
        request_uri: "sip:bob@example.com",
        method: :ack,
        version: "SIP/2.0",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "192.168.1.200",
            port: 5060,
            parameters: %{"branch" => "z9hG4bKack789"}
          }
        ],
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "from123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "to456"}},
        call_id: "call123@example.com",
        cseq: %CSeq{number: 1, method: :ack}
      }

      # Call the public function to add SDP answer
      ack = Client.maybe_add_sdp_answer(base_ack, response)

      # ACK should not have a body since response had no SDP
      assert ack.body == nil or ack.body == ""
    end
  end
end
