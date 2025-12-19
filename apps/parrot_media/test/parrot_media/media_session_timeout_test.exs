defmodule ParrotMedia.MediaSessionTimeoutTest do
  @moduledoc """
  Tests for MediaSession gen_statem call timeouts.
  """

  use ExUnit.Case, async: true

  alias ParrotMedia.MediaSession
  alias ParrotMedia.Test.TestMediaHandler

  describe "gen_statem call timeouts" do
    test "process_offer accepts timeout parameter" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_timeout_#{:rand.uniform(100000)}",
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

      # Should work with explicit timeout
      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer, 10_000)
    end

    test "process_offer uses default timeout when not specified" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_default_#{:rand.uniform(100000)}",
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

      # Should work with default timeout (no timeout parameter)
      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)
    end

    test "start_media accepts timeout parameter" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_start_#{:rand.uniform(100000)}",
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

      # Should work with explicit timeout
      :ok = MediaSession.start_media(session, 10_000)
    end
  end
end
