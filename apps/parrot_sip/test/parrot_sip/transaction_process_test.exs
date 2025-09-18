defmodule ParrotSip.Transaction.ProcessTest do
  use ExUnit.Case, async: true
  
  alias ParrotSip.Transaction
  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, CSeq}
  
  describe "process_message/1" do
    test "processes a new INVITE request and creates server transaction" do
      invite = %Message{
        type: :request,
        method: :invite,
        request_uri: "sip:bob@example.com",
        headers: %{
          "via" => [%Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "alice.com",
            port: 5060,
            parameters: %{"branch" => "z9hG4bK776asdhds"}
          }],
          "from" => ["Alice <sip:alice@alice.com>;tag=1928301774"],
          "to" => ["Bob <sip:bob@example.com>"],
          "call-id" => ["a84b4c76e66710@pc33.alice.com"],
          "cseq" => %CSeq{number: 314159, method: :invite}
        }
      }
      
      result = Transaction.process_message(invite)
      
      # The supervisor is started in tests, so the transaction is created successfully
      assert :ok = result
    end
    
    test "processes ACK request without creating transaction" do
      ack = %Message{
        type: :request,
        method: :ack,
        request_uri: "sip:bob@example.com",
        headers: %{
          "via" => [%Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "alice.com",
            port: 5060,
            parameters: %{"branch" => "z9hG4bK776asdhds"}
          }],
          "from" => ["Alice <sip:alice@alice.com>;tag=1928301774"],
          "to" => ["Bob <sip:bob@example.com>;tag=xyz789"],
          "call-id" => ["a84b4c76e66710@pc33.alice.com"],
          "cseq" => %CSeq{number: 314159, method: :ack}
        }
      }
      
      result = Transaction.process_message(ack)
      assert {:error, :no_transaction} = result
    end
    
    test "processes response with matching transaction" do
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        headers: %{
          "via" => ["SIP/2.0/UDP alice.com:5060;branch=z9hG4bK776asdhds"],
          "from" => ["Alice <sip:alice@alice.com>;tag=1928301774"],
          "to" => ["Bob <sip:bob@example.com>;tag=xyz789"],
          "call-id" => ["a84b4c76e66710@pc33.alice.com"],
          "cseq" => %CSeq{number: 314159, method: :invite}
        }
      }
      
      result = Transaction.process_message(response)
      # No matching transaction in registry
      assert {:error, :no_transaction} = result
    end
    
    test "handles response with no Via header" do
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        headers: %{
          "from" => ["Alice <sip:alice@alice.com>;tag=1928301774"],
          "to" => ["Bob <sip:bob@example.com>;tag=xyz789"],
          "call-id" => ["a84b4c76e66710@pc33.alice.com"],
          "cseq" => %CSeq{number: 314159, method: :invite}
        }
      }
      
      result = Transaction.process_message(response)
      assert {:error, :no_transaction} = result
    end
    
    test "handles response with Via but no branch" do
      response = %Message{
        type: :response,
        status_code: 200,
        reason_phrase: "OK",
        headers: %{
          "via" => ["SIP/2.0/UDP alice.com:5060"],
          "from" => ["Alice <sip:alice@alice.com>;tag=1928301774"],
          "to" => ["Bob <sip:bob@example.com>;tag=xyz789"],
          "call-id" => ["a84b4c76e66710@pc33.alice.com"],
          "cseq" => %CSeq{number: 314159, method: :invite}
        }
      }
      
      result = Transaction.process_message(response)
      assert {:error, :no_transaction} = result
    end
    
    test "handles invalid message type" do
      invalid = %Message{
        type: :invalid
      }
      
      result = Transaction.process_message(invalid)
      assert {:error, :invalid_message_type} = result
    end
  end
  
  describe "get_state/1" do
    test "returns error when transaction not found" do
      result = Transaction.get_state("nonexistent_id")
      assert {:error, :not_found} = result
    end
    
    # Note: Testing actual state retrieval would require starting a transaction
    # process and registering it, which is more of an integration test
  end
end