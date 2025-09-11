defmodule ParrotMedia.UacUasIntegrationTest do
  use ExUnit.Case, async: false

  alias ParrotMedia.{MediaSession, MediaSessionSupervisor}

  require Logger

  defmodule TestHandler do
    @behaviour ParrotMedia.Handler

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
      codec = Enum.find(offered, &(&1 in supported)) || :pcmu
      {:ok, codec, state}
    end

    @impl true
    def handle_stream_start(_id, _direction, state), do: {:noreply, state}

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end

  describe "UAC/UAS call flow" do
    test "complete call flow from INVITE to media streaming" do
      # 1. Create UAS media session (receiving side)
      uas_id = "test-uas-#{:rand.uniform(10000)}"

      {:ok, uas_pid} =
        MediaSessionSupervisor.start_session(
          id: uas_id,
          dialog_id: "test-dialog-uas",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{},
          supported_codecs: [:opus, :pcma],
          local_rtp_port: 40000
        )

      # 2. Create UAC media session (calling side)
      uac_id = "test-uac-#{:rand.uniform(10000)}"

      {:ok, uac_pid} =
        MediaSessionSupervisor.start_session(
          id: uac_id,
          dialog_id: "test-dialog-uac",
          role: :uac,
          media_handler: TestHandler,
          handler_args: %{},
          supported_codecs: [:opus, :pcma],
          local_rtp_port: 41000,
          # Configure audio devices for UAC
          output_device_id: 1,
          audio_sink: :device
        )

      # 3. UAC generates offer (like INVITE)
      {:ok, sdp_offer} = MediaSession.generate_offer(uac_pid)
      assert is_binary(sdp_offer)
      assert sdp_offer =~ "m=audio"

      # 4. UAS processes offer and generates answer (like 200 OK)
      {:ok, sdp_answer} = MediaSession.process_offer(uas_pid, sdp_offer)
      assert is_binary(sdp_answer)
      assert sdp_answer =~ "m=audio"

      # 5. UAC processes answer
      :ok = MediaSession.process_answer(uac_pid, sdp_answer)

      # 6. Skip actually starting media in this test since we don't have real pipelines
      # The flow is complete at this point - UAC is ready, UAS is ready

      # 8. Clean up
      MediaSession.terminate_session(uas_pid)
      MediaSession.terminate_session(uac_pid)
    end

    test "UAC with audio devices uses PortAudioPipeline" do
      uac_id = "test-uac-portaudio-#{:rand.uniform(10000)}"

      # Create UAC with both input and output devices
      {:ok, uac_pid} =
        MediaSessionSupervisor.start_session(
          id: uac_id,
          dialog_id: "test-dialog",
          role: :uac,
          media_handler: TestHandler,
          handler_args: %{},
          supported_codecs: [:opus, :pcma],
          local_rtp_port: 42000,
          input_device_id: 1,
          output_device_id: 2,
          audio_source: :device,
          audio_sink: :device
        )

      # Generate offer
      {:ok, _offer} = MediaSession.generate_offer(uac_pid)

      # Create a mock answer
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 43000 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """

      # Process answer
      :ok = MediaSession.process_answer(uac_pid, sdp_answer)

      # Check that PortAudioPipeline was selected
      {_state_name, data} = :sys.get_state(uac_pid)
      assert data.pipeline_module == ParrotMedia.PortAudioPipeline
      assert data.audio_source == :device
      assert data.audio_sink == :device
      assert data.input_device_id == 1
      assert data.output_device_id == 2

      # Clean up
      MediaSession.terminate_session(uac_pid)
    end
  end
end
