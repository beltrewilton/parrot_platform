defmodule ParrotSip.HandlerCallbacksTest do
  @moduledoc """
  Tests for rich callback system in ParrotSip.Handler.

  This test suite follows TDD to add method-specific callbacks,
  transaction callbacks, and dialog callbacks to ParrotSip.Handler.
  """

  use ExUnit.Case, async: false

  alias ParrotSip.{Handler, Message, Transaction, UAS}
  alias ParrotSip.Headers.{Via, From, To, CSeq, CallId}

  describe "method-specific callbacks - handle_options/3" do
    test "automatically dispatches to handle_options/3 when OPTIONS request is received" do
      # Setup test handler module with handle_options callback
      defmodule TestOptionsHandler do
        @behaviour ParrotSip.Handler

        # Standard routing callbacks (always the same)
        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok

        # Generic uas_request - should NOT be called if handle_options exists
        def uas_request(_uas, _sip_msg, test_pid) do
          send(test_pid, {:uas_request_called_incorrectly})
          :ok
        end

        # Method-specific callback - should be automatically called
        def handle_options(uas, sip_msg, test_pid) do
          # Send message to test process to prove callback was invoked
          send(test_pid, {:handle_options_called, sip_msg.method})

          # Send 200 OK response
          response = Message.reply(sip_msg, 200, "OK")
          UAS.response(response, uas)
          :ok
        end
      end

      # Build OPTIONS message
      options_msg = build_options_message()

      # Create handler
      handler = Handler.new(TestOptionsHandler, self())

      # Create transaction
      {:ok, transaction} = Transaction.create_non_invite_server(options_msg)

      # Call uas_request - should automatically dispatch to handle_options
      :ok = Handler.uas_request(transaction, options_msg, handler)

      # Verify handle_options was called (NOT generic uas_request)
      assert_receive {:handle_options_called, :options}, 1000
      refute_received {:uas_request_called_incorrectly}
    end

    test "handle_options callback receives correct message details" do
      defmodule TestOptionsMessageHandler do
        @behaviour ParrotSip.Handler

        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok
        def uas_request(_uas, _msg, _args), do: :ok

        # Automatic dispatch should call this
        def handle_options(_uas, sip_msg, test_pid) do
          # Verify message details
          send(test_pid, {:message_details, sip_msg.method, sip_msg.request_uri})
          :ok
        end
      end

      options_msg = build_options_message()
      handler = Handler.new(TestOptionsMessageHandler, self())
      {:ok, transaction} = Transaction.create_non_invite_server(options_msg)

      Handler.uas_request(transaction, options_msg, handler)

      assert_receive {:message_details, :options, "sip:bob@example.com"}, 1000
    end
  end

  describe "method-specific callbacks - handle_invite/3" do
    test "automatically dispatches to handle_invite/3 when INVITE request is received" do
      defmodule TestInviteHandler do
        @behaviour ParrotSip.Handler

        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok

        # Generic callback - should NOT be called
        def uas_request(_uas, _sip_msg, test_pid) do
          send(test_pid, {:uas_request_called_incorrectly})
          :ok
        end

        # Method-specific callback - should be automatically called
        def handle_invite(uas, sip_msg, test_pid) do
          send(test_pid, {:handle_invite_called, sip_msg.method})

          # Send 180 Ringing
          ringing = Message.reply(sip_msg, 180, "Ringing")
          UAS.response(ringing, uas)

          :ok
        end
      end

      invite_msg = build_invite_message()
      handler = Handler.new(TestInviteHandler, self())
      {:ok, transaction} = Transaction.create_invite_server(invite_msg)

      Handler.uas_request(transaction, invite_msg, handler)

      assert_receive {:handle_invite_called, :invite}, 1000
      refute_received {:uas_request_called_incorrectly}
    end
  end

  describe "fallback behavior" do
    test "falls back to uas_request/3 if method-specific callback not implemented" do
      defmodule TestFallbackHandler do
        @behaviour ParrotSip.Handler

        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok

        # Generic uas_request - SHOULD be called for methods without specific handlers
        def uas_request(_uas, sip_msg, test_pid) do
          send(test_pid, {:uas_request_fallback_called, sip_msg.method})
          :ok
        end

        # No handle_options defined - should fall back to uas_request
      end

      options_msg = build_options_message()
      handler = Handler.new(TestFallbackHandler, self())
      {:ok, transaction} = Transaction.create_non_invite_server(options_msg)

      Handler.uas_request(transaction, options_msg, handler)

      # Should fall back to generic uas_request
      assert_receive {:uas_request_fallback_called, :options}, 1000
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
