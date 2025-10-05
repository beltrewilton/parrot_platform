defmodule ParrotSip.BasicCallFlowTest do
  @moduledoc """
  Tests to reproduce SiPP integration failures.

  This test simulates what SiPP does:
  1. Send INVITE
  2. Receive 100 Trying (optional)
  3. Receive 200 OK
  4. Send ACK
  5. Wait a bit
  6. Send BYE
  7. Receive 200 OK

  Bug found: ACK handling in the new integration breaks the call flow.
  """
  use ExUnit.Case, async: false

  alias ParrotSip.{Message, Parser, Source, TransactionStatem, Handler, UAS}
  alias ParrotTransport.Types.{IncomingPacket, Metadata}

  @tag :call_flow
  test "INVITE -> 200 OK -> ACK -> BYE flow completes successfully" do
    # Create a test handler that tracks what it receives
    test_pid = self()

    handler = Handler.new(
      __MODULE__.TestHandler,
      %{test_pid: test_pid}
    )

    # Simulate incoming INVITE (using exact format from SiPP logs)
    invite_msg = "INVITE sip:service@127.0.0.1:5060 SIP/2.0\r\n" <>
      "Via: SIP/2.0/UDP 127.0.0.1:5080;branch=z9hG4bK-test-123\r\n" <>
      "From: sipp <sip:sipp@127.0.0.1:5080>;tag=1\r\n" <>
      "To: sut <sip:service@127.0.0.1:5060>\r\n" <>
      "Call-ID: test-call-123\r\n" <>
      "Cseq: 1 INVITE\r\n" <>
      "Contact: sip:sipp@127.0.0.1:5080\r\n" <>
      "Content-Type: application/sdp\r\n" <>
      "Content-Length: 129\r\n" <>
      "\r\n" <>
      "v=0\r\n" <>
      "o=user1 53655765 2353687637 IN IP4 127.0.0.1\r\n" <>
      "s=-\r\n" <>
      "t=0 0\r\n" <>
      "c=IN IP4 127.0.0.1\r\n" <>
      "m=audio 6000 RTP/AVP 0\r\n" <>
      "a=rtpmap:0 PCMU/8000\r\n"

    {:ok, parsed_invite} = Parser.parse(invite_msg)

    source = %Source{
      transport: :udp,
      remote: {{127, 0, 0, 1}, 5080},
      local: {{127, 0, 0, 1}, 5060}
    }

    invite_with_source = Map.put(parsed_invite, :source, source)

    # Process INVITE through transaction layer
    TransactionStatem.server_process(invite_with_source, handler)

    # Wait for INVITE to be processed
    assert_receive {:invite_received, _msg}, 1000

    # Now send ACK (this is where the bug might be)
    ack_msg = "ACK sip:service@127.0.0.1:5060 SIP/2.0\r\n" <>
      "Via: SIP/2.0/UDP 127.0.0.1:5080\r\n" <>
      "From: sipp <sip:sipp@127.0.0.1:5080>;tag=1\r\n" <>
      "To: sut <sip:service@127.0.0.1:5060>;tag=sqp55yqicy\r\n" <>
      "Call-ID: test-call-123\r\n" <>
      "Cseq: 1 ACK\r\n" <>
      "Contact: sip:sipp@127.0.0.1:5080\r\n" <>
      "Content-Length: 0\r\n" <>
      "\r\n"

    {:ok, parsed_ack} = Parser.parse(ack_msg)
    ack_with_source = Map.put(parsed_ack, :source, source)

    # Process ACK
    TransactionStatem.server_process(ack_with_source, handler)

    # Wait for ACK to be processed
    assert_receive {:ack_received, _msg}, 1000

    # Now send BYE
    bye_msg = "BYE sip:service@127.0.0.1:5060 SIP/2.0\r\n" <>
      "Via: SIP/2.0/UDP 127.0.0.1:5080\r\n" <>
      "From: sipp  <sip:sipp@127.0.0.1:5080>;tag=1\r\n" <>
      "To: sut  <sip:service@127.0.0.1:5060>;tag=sqp55yqicy\r\n" <>
      "Call-ID: test-call-123\r\n" <>
      "Cseq: 2 BYE\r\n" <>
      "Contact: sip:sipp@127.0.0.1:5080\r\n" <>
      "Content-Length: 0\r\n" <>
      "\r\n"

    {:ok, parsed_bye} = Parser.parse(bye_msg)
    bye_with_source = Map.put(parsed_bye, :source, source)

    # Process BYE
    TransactionStatem.server_process(bye_with_source, handler)

    # Wait for BYE to be processed
    assert_receive {:bye_received, _msg}, 1000
  end

  # Simple test handler
  defmodule TestHandler do
    @behaviour ParrotSip.Handler

    @impl true
    def transp_request(_msg, _args), do: :process_transaction

    @impl true
    def transaction(_trans, _sip_msg, _args), do: :process_uas

    @impl true
    def transaction_stop(_trans, _result, _args), do: :ok

    @impl true
    def uas_request(uas, sip_msg, args) do
      # Send notification back to test
      send(args.test_pid, {String.to_atom(String.downcase(sip_msg.method)), sip_msg})

      # Generate appropriate response
      response = Message.reply(sip_msg, 501, "Not Implemented")
      UAS.response(response, uas)
      :ok
    end

    @impl true
    def uas_cancel(_uas_id, args) do
      send(args.test_pid, {:cancel_received, nil})
      :ok
    end

    @impl true
    def process_ack(sip_msg, args) do
      send(args.test_pid, {:ack_received, sip_msg})
      :ok
    end

    @impl true
    def handle_invite(uas, sip_msg, args) do
      send(args.test_pid, {:invite_received, sip_msg})

      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 4000 RTP/AVP 8 111
      a=rtpmap:8 PCMA/8000
      a=rtpmap:111 OPUS/48000
      """

      response = Message.reply(sip_msg, 200, "OK")
      response = %{response | body: sdp}
      UAS.response(response, uas)
      :ok
    end

    @impl true
    def handle_bye(uas, sip_msg, args) do
      send(args.test_pid, {:bye_received, sip_msg})

      response = Message.reply(sip_msg, 200, "OK")
      UAS.response(response, uas)
      :ok
    end

    @impl true
    def handle_options(_uas, _sip_msg, _args), do: :ok
    @impl true
    def handle_cancel(_uas, _sip_msg, _args), do: :ok
    @impl true
    def handle_register(_uas, _sip_msg, _args), do: :ok
    @impl true
    def handle_subscribe(_uas, _sip_msg, _args), do: :ok
    @impl true
    def handle_notify(_uas, _sip_msg, _args), do: :ok
    @impl true
    def handle_message(_uas, _sip_msg, _args), do: :ok
    @impl true
    def handle_info(_uas, _sip_msg, _args), do: :ok
  end
end
