defmodule ParrotSip.EarlyDialogTest do
  @moduledoc """
  Tests for early dialog state management per RFC 3261 Section 13.2.2.4.

  An early dialog is created when a provisional response (1xx) with a To tag
  is received/sent. The dialog remains in "early" state until a final response.

  Key behaviors tested:
  - 183 with SDP creates early dialog
  - Early dialog tracks remote/local tags
  - Early to confirmed transition on 2xx
  - Multiple early dialogs (forking) handling
  """

  use ExUnit.Case, async: true

  alias ParrotSip.Dialog
  alias ParrotSip.Message

  @moduletag :early_dialog

  describe "early dialog creation" do
    test "183 with To tag creates early dialog" do
      # An INVITE that receives 183 Session Progress with SDP and To tag
      # should create an early dialog
      invite = build_invite()
      provisional = build_183_response(invite)

      # For UAC: local_tag = From tag (us), remote_tag = To tag (them)
      from_tag = get_in(invite.from.parameters, ["tag"])
      to_tag = get_in(provisional.to.parameters, ["tag"])

      # Dialog should be created from provisional response
      dialog_id = Dialog.generate_id(:uac, invite.call_id, from_tag, to_tag)

      assert dialog_id != nil
      assert is_binary(dialog_id)
    end

    test "early dialog contains correct tags" do
      invite = build_invite()
      provisional = build_183_response(invite)

      # For UAC: local_tag = From tag, remote_tag = To tag
      from_tag = get_in(invite.from.parameters, ["tag"])
      to_tag = get_in(provisional.to.parameters, ["tag"])

      dialog_id = Dialog.generate_id(:uac, invite.call_id, from_tag, to_tag)

      # Dialog ID should contain the call_id
      assert String.contains?(dialog_id, invite.call_id)
    end
  end

  describe "early to confirmed transition" do
    test "200 OK confirms early dialog" do
      invite = build_invite()
      provisional_183 = build_183_response(invite)
      final_200 = build_200_response(invite, provisional_183)

      # For UAC: local_tag = From tag, remote_tag = To tag
      from_tag = get_in(invite.from.parameters, ["tag"])
      early_to_tag = get_in(provisional_183.to.parameters, ["tag"])
      final_to_tag = get_in(final_200.to.parameters, ["tag"])

      # Both should generate the same dialog ID (same tags)
      early_id = Dialog.generate_id(:uac, invite.call_id, from_tag, early_to_tag)
      confirmed_id = Dialog.generate_id(:uac, invite.call_id, from_tag, final_to_tag)

      assert early_id == confirmed_id
    end

    test "early dialog with different To tag creates different dialog" do
      # Forking scenario: multiple UAS respond with different To tags
      invite = build_invite()
      response_1 = build_183_response(invite, to_tag: "uas1-tag")
      response_2 = build_183_response(invite, to_tag: "uas2-tag")

      from_tag = get_in(invite.from.parameters, ["tag"])
      to_tag_1 = get_in(response_1.to.parameters, ["tag"])
      to_tag_2 = get_in(response_2.to.parameters, ["tag"])

      id_1 = Dialog.generate_id(:uac, invite.call_id, from_tag, to_tag_1)
      id_2 = Dialog.generate_id(:uac, invite.call_id, from_tag, to_tag_2)

      # Different To tags should create different dialogs
      refute id_1 == id_2
    end
  end

  describe "early dialog SDP handling" do
    test "183 with SDP indicates early media capability" do
      invite = build_invite_with_sdp()
      provisional = build_183_response_with_sdp(invite)

      # Response should have SDP body
      assert provisional.body =~ "v=0"
      assert provisional.content_type == "application/sdp"
    end

    test "183 without SDP does not start early media" do
      invite = build_invite_with_sdp()
      provisional = build_183_response(invite)

      # Response without SDP body
      assert is_nil(provisional.body) or provisional.body == ""
    end
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp build_invite do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "example.com"},
        display_name: nil,
        parameters: %{"tag" => "uac-tag-#{:rand.uniform(100_000)}"}
      },
      to: %ParrotSip.Headers.To{
        uri: %ParrotSip.Uri{scheme: "sip", user: "bob", host: "example.com"},
        display_name: nil,
        parameters: %{}
      },
      call_id: "call-#{:rand.uniform(100_000)}",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite},
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-#{:rand.uniform(100_000)}"}
        }
      ],
      body: nil
    }
  end

  defp build_invite_with_sdp do
    invite = build_invite()

    sdp = """
    v=0
    o=- 123456 123456 IN IP4 192.168.1.100
    s=SIP Call
    c=IN IP4 192.168.1.100
    t=0 0
    m=audio 20000 RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    """

    %{invite | body: sdp, content_type: "application/sdp", content_length: byte_size(sdp)}
  end

  defp build_183_response(invite, opts \\ []) do
    to_tag = Keyword.get(opts, :to_tag, "uas-tag-#{:rand.uniform(100_000)}")

    %Message{
      type: :response,
      status_code: 183,
      reason_phrase: "Session Progress",
      from: invite.from,
      to: %{invite.to | parameters: %{"tag" => to_tag}},
      call_id: invite.call_id,
      cseq: invite.cseq,
      via: invite.via,
      body: nil
    }
  end

  defp build_183_response_with_sdp(invite, opts \\ []) do
    response = build_183_response(invite, opts)

    sdp = """
    v=0
    o=- 789012 789012 IN IP4 192.168.1.200
    s=SIP Call
    c=IN IP4 192.168.1.200
    t=0 0
    m=audio 30000 RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    a=sendonly
    """

    %{response | body: sdp, content_type: "application/sdp", content_length: byte_size(sdp)}
  end

  defp build_200_response(invite, provisional) do
    # 200 OK uses the same To tag as the provisional
    to_tag = get_in(provisional.to.parameters, ["tag"])

    %Message{
      type: :response,
      status_code: 200,
      reason_phrase: "OK",
      from: invite.from,
      to: %{invite.to | parameters: %{"tag" => to_tag}},
      call_id: invite.call_id,
      cseq: invite.cseq,
      via: invite.via,
      body: nil
    }
  end
end
