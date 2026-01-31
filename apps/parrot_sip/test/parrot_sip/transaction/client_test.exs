defmodule ParrotSip.Transaction.ClientTest do
  @moduledoc """
  Tests for Transaction.Client module.

  Note: SDP answer generation has been moved to the Message and UA modules.
  See apps/parrot_sip/test/parrot_sip/ua_sdp_answer_test.exs for SDP handling tests.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.Transaction.Client
  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, From, To, CSeq}

  describe "send_ack/2" do
    test "accepts ACK message and destination" do
      # Build a simple ACK message
      ack = %Message{
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

      # send_ack returns :ok even if transport handler is not available
      # (it logs a warning in that case)
      result = Client.send_ack(ack, {"192.168.1.200", 5060})
      assert result == :ok
    end

    test "handles IP tuple in destination" do
      ack = %Message{
        type: :request,
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
        cseq: %CSeq{number: 1, method: :ack}
      }

      # IP tuple destination should be converted to string
      result = Client.send_ack(ack, {{192, 168, 1, 200}, 5060})
      assert result == :ok
    end
  end
end
