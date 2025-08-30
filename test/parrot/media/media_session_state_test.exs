defmodule Parrot.Media.MediaSessionStateTest do
  use ExUnit.Case, async: false

  alias Parrot.Media.{MediaSession, MediaSessionSupervisor}

  require Logger

  defmodule MinimalHandler do
    @behaviour Parrot.MediaHandler

    @impl true
    def init(args), do: {:ok, args}

    @impl true
    def handle_session_start(_id, _opts, state), do: {:ok, state}

    @impl true
    def handle_offer(_sdp, _direction, state), do: {:noreply, state}

    @impl true
    def handle_negotiation_complete(_local, _remote, _codec, state), do: {:ok, state}

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      codec = Enum.find(offered, &(&1 in supported)) || :pcma
      {:ok, codec, state}
    end

    @impl true
    def handle_stream_start(_id, _direction, state), do: {:noreply, state}

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end

  describe "MediaSession state transitions" do
    test "UAC state flow: idle -> negotiating -> ready" do
      uac_id = "test-state-uac-#{:rand.uniform(10000)}"

      {:ok, uac_pid} =
        MediaSessionSupervisor.start_session(
          id: uac_id,
          dialog_id: "test-dialog",
          role: :uac,
          media_handler: MinimalHandler,
          handler_args: %{},
          supported_codecs: [:pcma],
          local_rtp_port: 45000
        )

      # Generate offer transitions to negotiating
      {:ok, _offer} = MediaSession.generate_offer(uac_pid)

      # Process answer transitions to ready
      mock_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 46000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      :ok = MediaSession.process_answer(uac_pid, mock_answer)

      # Clean up
      MediaSession.terminate_session(uac_pid)
    end

    test "UAS state flow: idle -> ready" do
      uas_id = "test-state-uas-#{:rand.uniform(10000)}"

      {:ok, uas_pid} =
        MediaSessionSupervisor.start_session(
          id: uas_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: MinimalHandler,
          handler_args: %{},
          supported_codecs: [:pcma],
          local_rtp_port: 47000
        )

      # Process offer transitions to ready
      mock_offer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 48000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(uas_pid, mock_offer)

      # Clean up
      MediaSession.terminate_session(uas_pid)
    end
  end
end
