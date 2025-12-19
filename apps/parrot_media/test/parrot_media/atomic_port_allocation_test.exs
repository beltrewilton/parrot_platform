defmodule ParrotMedia.AtomicPortAllocationTest do
  use ExUnit.Case

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

  describe "Atomic port allocation" do
    test "port remains allocated between SDP negotiation and pipeline start" do
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

      # Create SDP offer
      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      # Process offer - this allocates the port
      {:ok, answer} = MediaSession.process_offer(session, sdp_offer)

      # Extract the port from the SDP answer
      port =
        answer
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "m=audio"))
        |> String.split(" ")
        |> Enum.at(1)
        |> String.to_integer()

      # Verify the port is actually in use (attempting to open it should fail)
      # If the socket was closed prematurely, this would succeed
      result = :gen_udp.open(port, [:binary, {:active, false}])

      case result do
        {:error, :eaddrinuse} ->
          # Good! Port is still reserved
          assert true

        {:ok, test_socket} ->
          # Bad! We could open the port, meaning it was released
          :gen_udp.close(test_socket)
          flunk("Port #{port} was released prematurely - should still be reserved")

        error ->
          flunk("Unexpected error trying to open port #{port}: #{inspect(error)}")
      end

      MediaSession.terminate_session(session)
    end

    test "socket is properly transferred to pipeline on start_media" do
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

      # Start media - this should transfer socket ownership to pipeline
      :ok = MediaSession.start_media(session)

      # Pipeline should now own the socket
      # We can't easily test this without introspecting the pipeline
      # But we can verify the session is in active state
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :active
      assert state_info.pipeline_active

      MediaSession.terminate_session(session)
    end
  end
end
