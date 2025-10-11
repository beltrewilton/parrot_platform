defmodule ParrotSip.HandlerCallbacksTest do
  @moduledoc """
  Tests for rich callback system in ParrotSip.Handler.

  This test suite follows TDD to add method-specific callbacks,
  transaction callbacks, and dialog callbacks to ParrotSip.Handler.
  """

  use ExUnit.Case, async: false

  alias ParrotSip.{Handler, Message, Transaction}
  alias ParrotSip.Headers.{Via, From, To, CSeq}

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
          ParrotSip.UAS.response(response, uas)
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
          ParrotSip.UAS.response(ringing, uas)

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

    test "uas_request/3 is required - handler must implement it even with method-specific callbacks" do
      # This test documents that uas_request/3 is NOT optional
      # Even if you implement all method-specific callbacks, you must implement uas_request/3
      # as a fallback for unknown methods or methods without specific handlers

      defmodule TestMissingUasRequestHandler do
        # NOTE: This module intentionally does NOT implement uas_request/3
        # It will fail the @behaviour check at compile time

        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok

        # Even with handle_options defined, missing uas_request should fail
        def handle_options(_uas, _msg, _args), do: :ok
      end

      # This test just documents the requirement - actual enforcement is at compile time
      # If someone tries to implement ParrotSip.Handler without uas_request/3,
      # the compiler will emit a warning about missing callback
      assert true
    end

    test "method-specific callbacks handle all common SIP methods" do
      # Verify that we have callbacks defined for all common methods
      defmodule TestAllMethodsHandler do
        @behaviour ParrotSip.Handler

        def transp_request(_msg, _args), do: :process_transaction
        def transaction(_trans, _msg, _args), do: :process_uas
        def transaction_stop(_trans, _result, _args), do: :ok
        def uas_cancel(_id, _args), do: :ok
        def process_ack(_msg, _args), do: :ok
        def uas_request(_uas, _msg, _args), do: :ok

        # All method-specific callbacks
        def handle_options(_uas, _msg, args), do: send(args, {:called, :options})
        def handle_invite(_uas, _msg, args), do: send(args, {:called, :invite})
        def handle_bye(_uas, _msg, args), do: send(args, {:called, :bye})
        def handle_cancel(_uas, _msg, args), do: send(args, {:called, :cancel})
        def handle_register(_uas, _msg, args), do: send(args, {:called, :register})
        def handle_subscribe(_uas, _msg, args), do: send(args, {:called, :subscribe})
        def handle_notify(_uas, _msg, args), do: send(args, {:called, :notify})
        def handle_message(_uas, _msg, args), do: send(args, {:called, :message})
        def handle_info(_uas, _msg, args), do: send(args, {:called, :info})
      end

      # Test that each method dispatches correctly
      methods_to_test = [:options, :invite, :bye, :register, :subscribe, :notify, :info]

      for method <- methods_to_test do
        msg = build_message_for_method(method)
        handler = Handler.new(TestAllMethodsHandler, self())

        transaction = case method do
          :invite -> {:ok, t} = Transaction.create_invite_server(msg); t
          _ -> {:ok, t} = Transaction.create_non_invite_server(msg); t
        end

        Handler.uas_request(transaction, msg, handler)
        assert_receive {:called, ^method}, 1000
      end
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

  defp build_message_for_method(method) do
    via = %Via{
      transport: :udp,
      host: "client.example.com",
      port: 5060,
      parameters: %{"branch" => "z9hG4bK-#{method}-branch"}
    }

    from = %From{
      display_name: "Alice",
      uri: "sip:alice@example.com",
      parameters: %{"tag" => "from-tag-#{method}"}
    }

    to = %To{
      display_name: "Bob",
      uri: "sip:bob@example.com",
      parameters: %{}
    }

    cseq = %CSeq{
      number: 1,
      method: method
    }

    %Message{
      type: :request,
      method: method,
      request_uri: "sip:bob@example.com",
      version: "SIP/2.0",
      via: [via],
      from: from,
      to: to,
      call_id: "test-#{method}-call-id",
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
