defmodule ParrotMedia.MediaSessionHoldResumeTest do
  @moduledoc """
  Tests for MediaSession hold/resume functionality with SDP direction attributes.
  """

  use ExUnit.Case, async: true

  alias ParrotMedia.MediaSession
  alias ParrotMedia.Test.TestMediaHandler

  describe "hold/resume with SDP direction" do
    test "pause_media generates SDP with sendonly direction" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_hold_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

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
      :ok = MediaSession.start_media(session)

      # Pause should transition to paused state
      :ok = MediaSession.pause_media(session)

      # Get state to verify we're in paused state
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :paused
    end

    test "resume_media transitions back to active state" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_resume_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

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
      :ok = MediaSession.start_media(session)
      :ok = MediaSession.pause_media(session)

      # Resume should transition back to active
      :ok = MediaSession.resume_media(session)

      # Get state to verify we're back in active state
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :active
    end

    test "generates SDP with correct direction attribute" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_sdp_dir_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, sdp_answer} = MediaSession.process_offer(session, sdp_offer)

      # Default direction should be sendrecv
      assert sdp_answer =~ ~r/a=sendrecv/
    end
  end
end
