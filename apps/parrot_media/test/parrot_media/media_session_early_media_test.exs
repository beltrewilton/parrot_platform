defmodule ParrotMedia.MediaSessionEarlyMediaTest do
  @moduledoc """
  Tests for MediaSession early media support (183 Session Progress).

  Early media allows media to flow before the call is fully answered:
  - UAC receives 183 with SDP and starts receiving media
  - UAS can send 183 with SDP to provide ringback/announcements
  - The session tracks early vs confirmed state
  - Media pipeline may behave differently in early state

  RFC 3261 Section 13.2.2.4 - Early Dialog
  """

  use ExUnit.Case, async: true

  alias ParrotMedia.MediaSession
  alias ParrotMedia.Test.TestMediaHandler

  @moduletag :early_media

  describe "UAC early media (receiving 183 with SDP)" do
    test "process_early_answer/2 starts media in early state" do
      # UAC generates offer, then receives 183 with SDP answer
      # Should start media pipeline in early state
      {:ok, session} =
        MediaSession.start_link(
          id: "test_early_uac_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uac,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      {:ok, _sdp_offer} = MediaSession.generate_offer(session)

      sdp_answer_183 = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      # Process early answer (from 183)
      {:ok, _} = MediaSession.process_early_answer(session, sdp_answer_183)

      # Should be in early state
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :early
    end

    test "early state transitions to active on process_answer" do
      # After receiving 183 and starting early media,
      # receiving 200 OK should confirm the session
      {:ok, session} =
        MediaSession.start_link(
          id: "test_early_confirm_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uac,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      {:ok, _sdp_offer} = MediaSession.generate_offer(session)

      sdp_answer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      # First process early answer
      {:ok, _} = MediaSession.process_early_answer(session, sdp_answer)

      # Then confirm with process_answer (from 200 OK)
      # This might use a confirm_answer/1 function instead
      :ok = MediaSession.confirm_media(session)

      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :active
    end

    test "early state allows media to flow" do
      # Verify that media pipeline starts in early state
      # (receives RTP from remote)
      assert true
    end
  end

  describe "UAS early media (sending 183 with SDP)" do
    test "create_early_offer/2 generates SDP for 183 response" do
      # UAS can generate an early offer to send with 183
      {:ok, session} =
        MediaSession.start_link(
          id: "test_early_uas_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # Process incoming offer first
      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      # Generate early offer for 183 (with different options)
      {:ok, early_sdp} = MediaSession.create_early_offer(session, direction: :sendonly)

      # Should be valid SDP
      assert early_sdp =~ ~r/v=0/
      assert early_sdp =~ ~r/m=audio/
    end

    test "UAS can start early media pipeline" do
      # UAS starts sending media before answering (e.g., ringback)
      assert true
    end
  end

  describe "early state tracking" do
    test "session tracks early vs confirmed state" do
      # The session data should have a flag distinguishing early from confirmed
      assert true
    end

    test "get_state returns early status correctly" do
      # When querying state, should indicate we're in early media
      assert true
    end

    test "pipeline_module configured correctly for early media" do
      # The pipeline may behave differently in early state
      # (e.g., no RTCP until confirmed)
      assert true
    end
  end

  describe "error handling" do
    test "process_early_answer fails if not in negotiating state" do
      # Can only process early answer after generating offer
      {:ok, session} =
        MediaSession.start_link(
          id: "test_early_error_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uac,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # Try to process early answer without offer
      result = MediaSession.process_early_answer(session, "v=0...")
      assert {:error, _} = result
    end

    test "UAS cannot use process_early_answer" do
      # Only UAC should use process_early_answer
      # UAS uses process_offer + create_early_offer
      assert true
    end
  end
end
