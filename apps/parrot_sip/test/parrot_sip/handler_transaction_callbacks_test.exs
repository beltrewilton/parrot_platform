defmodule ParrotSip.HandlerTransactionCallbacksTest do
  @moduledoc """
  Tests for transaction state callbacks in ParrotSip.Handler.

  This test suite follows TDD to add transaction state change callbacks:
  - handle_transaction_trying/3
  - handle_transaction_proceeding/3
  - handle_transaction_completed/3
  - handle_transaction_confirmed/3
  """

  use ExUnit.Case, async: false

  alias ParrotSip.{Handler, Message, Transaction, TransactionStatem}
  alias ParrotSip.Headers.{Via, From, To, CSeq}

  describe "transaction state callbacks - handle_transaction_trying/3" do
    test "automatically calls handle_transaction_trying when transaction enters trying state" do
      # Setup test handler module with transaction state callback
      defmodule TestTryingHandler do
        @behaviour ParrotSip.Handler

        # Standard routing callbacks
        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok
        def uas_request(_uas, _msg, _args), do: :ok

        # Transaction state callback - should be called when entering :trying state
        def handle_transaction_trying(trans, sip_msg, test_pid) do
          send(test_pid, {:transaction_trying, trans.id, sip_msg.method})
          :ok
        end
      end

      options_msg = build_options_message()
      handler = Handler.new(TestTryingHandler, self())

      # Create transaction and start state machine - should enter :trying state and trigger callback
      {:ok, transaction} = Transaction.create_non_invite_server(options_msg)
      {:ok, _pid} = TransactionStatem.start_link([transaction, handler])

      # Give it a moment for state machine to process
      :timer.sleep(100)

      # Verify callback was called
      assert_receive {:transaction_trying, _trans_id, :options}, 1000
    end
  end

  describe "transaction state callbacks - handle_transaction_proceeding/3" do
    test "automatically calls handle_transaction_proceeding when sending provisional response" do
      defmodule TestProceedingHandler do
        @behaviour ParrotSip.Handler

        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok

        def uas_request(uas, sip_msg, test_pid) do
          # Send 180 Ringing - should trigger proceeding state
          response = Message.reply(sip_msg, 180, "Ringing")
          ParrotSip.Transaction.Server.response(response, uas)
          send(test_pid, :sent_180)
          :ok
        end

        # Should be called when transaction moves to :proceeding
        def handle_transaction_proceeding(trans, sip_msg, test_pid) do
          send(test_pid, {:transaction_proceeding, trans.id, sip_msg.method})
          :ok
        end
      end

      invite_msg = build_invite_message()
      handler = Handler.new(TestProceedingHandler, self())
      {:ok, transaction} = Transaction.create_invite_server(invite_msg)
      {:ok, trans_pid} = TransactionStatem.start_link([transaction, handler])

      # Wait for transaction to be ready
      :timer.sleep(100)

      # Send the request through the UAS to trigger proceeding state
      Handler.uas_request(transaction, invite_msg, handler)

      # Wait for provisional response
      assert_receive :sent_180, 1000
      :timer.sleep(50)

      # Verify proceeding callback was called
      assert_receive {:transaction_proceeding, _trans_id, :invite}, 1000

      # Clean up
      Process.exit(trans_pid, :normal)
    end
  end

  describe "transaction state callbacks - handle_transaction_completed/3" do
    test "automatically calls handle_transaction_completed when sending final response" do
      defmodule TestCompletedHandler do
        @behaviour ParrotSip.Handler

        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok

        def uas_request(uas, sip_msg, test_pid) do
          # Send 200 OK - should trigger completed state
          response = Message.reply(sip_msg, 200, "OK")
          ParrotSip.Transaction.Server.response(response, uas)
          send(test_pid, :sent_200)
          :ok
        end

        # Should be called when transaction moves to :completed
        def handle_transaction_completed(trans, sip_msg, test_pid) do
          send(test_pid, {:transaction_completed, trans.id, sip_msg.method})
          :ok
        end
      end

      options_msg = build_options_message()
      handler = Handler.new(TestCompletedHandler, self())
      {:ok, transaction} = Transaction.create_non_invite_server(options_msg)
      {:ok, trans_pid} = TransactionStatem.start_link([transaction, handler])

      # Wait for transaction to be ready
      :timer.sleep(100)

      # Send request through UAS to trigger completed state
      Handler.uas_request(transaction, options_msg, handler)

      # Wait for final response
      assert_receive :sent_200, 1000
      :timer.sleep(50)

      # Verify completed callback was called
      assert_receive {:transaction_completed, _trans_id, :options}, 1000

      # Clean up
      Process.exit(trans_pid, :normal)
    end
  end

  # Helper functions to build SIP messages

  defp build_options_message do
    via = %Via{
      transport: :udp,
      host: "client.example.com",
      port: 5060,
      parameters: %{"branch" => "z9hG4bK-test-branch"}
    }

    from = %From{
      display_name: "Alice",
      uri: "sip:alice@example.com",
      parameters: %{"tag" => "from-tag-123"}
    }

    to = %To{
      display_name: "Bob",
      uri: "sip:bob@example.com",
      parameters: %{}
    }

    cseq = %CSeq{
      number: 1,
      method: :options
    }

    %Message{
      type: :request,
      method: :options,
      request_uri: "sip:bob@example.com",
      version: "SIP/2.0",
      via: [via],
      from: from,
      to: to,
      call_id: "test-call-id-123",
      cseq: cseq,
      max_forwards: 70,
      content_length: 0,
      body: ""
    }
  end

  defp build_invite_message do
    via = %Via{
      transport: :udp,
      host: "client.example.com",
      port: 5060,
      parameters: %{"branch" => "z9hG4bK-invite-branch"}
    }

    from = %From{
      display_name: "Alice",
      uri: "sip:alice@example.com",
      parameters: %{"tag" => "from-tag-456"}
    }

    to = %To{
      display_name: "Bob",
      uri: "sip:bob@example.com",
      parameters: %{}
    }

    cseq = %CSeq{
      number: 1,
      method: :invite
    }

    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      version: "SIP/2.0",
      via: [via],
      from: from,
      to: to,
      call_id: "test-invite-call-id",
      cseq: cseq,
      max_forwards: 70,
      content_length: 0,
      body: ""
    }
  end
end
