defmodule ParrotMedia.OpusSdpTest do
  use ExUnit.Case, async: false

  alias ParrotMedia.MediaSession

  # Test handler for minimal setup
  defmodule MinimalHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_session_start(_session_id, _opts, state), do: {:ok, state}

    @impl true
    def handle_session_stop(_session_id, _reason, state), do: {:ok, state}

    @impl true
    def handle_offer(_sdp, _direction, state), do: {:noreply, state}

    @impl true
    def handle_answer(_sdp, _direction, state), do: {:noreply, state}

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      # Prefer opus if available
      codec = if :opus in offered and :opus in supported do
        :opus
      else
        Enum.find(offered, &(&1 in supported)) || hd(supported)
      end
      {:ok, codec, state}
    end

    @impl true
    def handle_negotiation_complete(_local, _remote, _codec, state), do: {:ok, state}

    @impl true
    def handle_stream_start(_session_id, _direction, state), do: {:noreply, state}

    @impl true
    def handle_stream_stop(_session_id, _reason, state), do: {:ok, state}

    @impl true
    def handle_stream_error(_session_id, _error, state), do: {:continue, state}

    @impl true
    def handle_play_complete(_file, state), do: {:noreply, state}

    @impl true
    def handle_media_request(_request, state), do: {:noreply, state}
  end

  describe "Opus SDP configuration" do
    test "Opus SDP answer includes mono channels (1 not 2)" do
      session_id = "test_session_#{:rand.uniform(100_000)}"

      {:ok, session} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_1",
          role: :uas,
          media_handler: MinimalHandler,
          supported_codecs: [:opus],
          audio_file: Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """

      {:ok, answer} = MediaSession.process_offer(session, sdp_offer)

      # Verify the answer uses mono (opus/48000 or opus/48000/1, but NOT opus/48000/2)
      # ExSDP omits the /1 suffix since 1 channel is the default
      assert answer =~ ~r/a=rtpmap:111 opus\/48000($|[^\/])/,
             "Expected opus/48000 (mono, /1 is implied) but got:\n#{answer}"

      refute answer =~ ~r/a=rtpmap:111 opus\/48000\/2/,
             "Should not have opus/48000/2 (stereo) but got:\n#{answer}"

      MediaSession.terminate_session(session)
      Process.sleep(100)
    end

    test "Opus SDP answer includes ptime attribute" do
      session_id = "test_session_#{:rand.uniform(100_000)}"

      {:ok, session} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_1",
          role: :uas,
          media_handler: MinimalHandler,
          supported_codecs: [:opus],
          audio_file: Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """

      {:ok, answer} = MediaSession.process_offer(session, sdp_offer)

      # Verify the answer includes ptime:20 attribute
      assert answer =~ ~r/a=ptime:20/,
             "Expected a=ptime:20 in SDP answer but got:\n#{answer}"

      MediaSession.terminate_session(session)
      Process.sleep(100)
    end

    test "Opus SDP answer includes fmtp with stereo=0 and useinbandfec=1" do
      session_id = "test_session_#{:rand.uniform(100_000)}"

      {:ok, session} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_1",
          role: :uas,
          media_handler: MinimalHandler,
          supported_codecs: [:opus],
          audio_file: Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """

      {:ok, answer} = MediaSession.process_offer(session, sdp_offer)

      # Verify the answer includes fmtp with correct parameters
      assert answer =~ ~r/a=fmtp:111.*stereo=0/,
             "Expected a=fmtp:111 with stereo=0 but got:\n#{answer}"

      assert answer =~ ~r/a=fmtp:111.*useinbandfec=1/,
             "Expected a=fmtp:111 with useinbandfec=1 but got:\n#{answer}"

      MediaSession.terminate_session(session)
      Process.sleep(100)
    end
  end
end
