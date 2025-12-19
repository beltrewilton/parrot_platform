defmodule ParrotMedia.MonitorRefTrackingTest do
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
      codec = Enum.find(offered, &(&1 in supported)) || hd(supported)
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

  describe "Monitor reference tracking" do
    test "pipeline monitor is stored and cleared properly" do
      session_id = "test_session_#{:rand.uniform(100_000)}"

      {:ok, session} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_1",
          role: :uas,
          media_handler: MinimalHandler,
          supported_codecs: [:pcma],
          audio_file: Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      # Before starting media, pipeline_monitor should be nil
      {_state, data_before} = :sys.get_state(session)
      assert data_before.pipeline_monitor == nil

      # Start media
      :ok = MediaSession.start_media(session)

      # After starting media, pipeline_monitor should be set
      {_state, data_after} = :sys.get_state(session)
      assert data_after.pipeline_monitor != nil
      assert is_reference(data_after.pipeline_monitor)
      assert data_after.pipeline_pid != nil

      # Terminate session (which should demonitor)
      MediaSession.terminate_session(session)

      # Wait for cleanup
      Process.sleep(200)

      # Session should be gone
      refute Process.alive?(session)
    end

    test "pipeline monitor is cleaned up on session termination" do
      # Wait a bit to avoid port conflicts with previous test
      Process.sleep(100)
      session_id = "test_session_#{:rand.uniform(100_000)}"

      {:ok, session} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_1",
          role: :uas,
          media_handler: MinimalHandler,
          supported_codecs: [:pcma],
          audio_file: Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)
      :ok = MediaSession.start_media(session)

      # Get pipeline PID
      {_state, data} = :sys.get_state(session)
      pipeline_pid = data.pipeline_pid
      assert Process.alive?(pipeline_pid)

      # Terminate session
      MediaSession.terminate_session(session)

      # Wait for cleanup
      Process.sleep(100)

      # Pipeline should be terminated
      refute Process.alive?(pipeline_pid)
      refute Process.alive?(session)
    end
  end
end
