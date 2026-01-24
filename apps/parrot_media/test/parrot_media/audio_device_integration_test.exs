defmodule ParrotMedia.AudioDeviceIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :slow

  alias ParrotMedia.{MediaSession, MediaSessionSupervisor}

  require Logger

  defmodule TestDeviceHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(args) do
      {:ok, Map.put(args, :events, [])}
    end

    @impl true
    def handle_info({:use_audio_devices, opts}, state) when is_list(opts) do
      input = Keyword.get(opts, :input)
      output = Keyword.get(opts, :output)

      Logger.info(
        "TestDeviceHandler: use_audio_devices - input: #{inspect(input)}, output: #{inspect(output)}"
      )

      updated_state =
        Map.update(
          state,
          :events,
          [{:use_audio_devices, input, output}],
          &[{:use_audio_devices, input, output} | &1]
        )

      {[{:connect_audio_device, input, output}], updated_state}
    end

    @impl true
    def handle_info(msg, state) do
      Logger.info("TestDeviceHandler: Unhandled message: #{inspect(msg)}")
      {:noreply, state}
    end

    @impl true
    def handle_session_start(session_id, _opts, state) do
      Logger.info("TestDeviceHandler: Session started: #{session_id}")
      {:ok, state}
    end

    @impl true
    def handle_offer(_sdp, _direction, state) do
      {:noreply, state}
    end

    @impl true
    def handle_negotiation_complete(_local_sdp, _remote_sdp, _codec, state) do
      {:ok, state}
    end

    @impl true
    def handle_stream_start(_session_id, _direction, state) do
      {:noreply, state}
    end

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      codec = Enum.find(offered, &(&1 in supported)) || :pcmu
      {:ok, codec, state}
    end
  end

  describe "audio device configuration" do
    test "configures output device for incoming audio in Opus pipeline" do
      session_id = "test-audio-device-opus-#{:rand.uniform(10000)}"

      # Start a media session
      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uac,
          media_handler: TestDeviceHandler,
          handler_args: %{},
          local_rtp_port: 30000 + :rand.uniform(10000),
          supported_codecs: [:opus, :pcma]
        )

      # UAC needs to generate offer first
      {:ok, _offer} = MediaSession.generate_offer(pid)

      # Create a mock SDP answer with Opus codec
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 40000 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """

      # Process the answer
      :ok = MediaSession.process_answer(pid, sdp_answer)

      # Send use_audio_devices message
      test_output_device = 42
      send(pid, {:use_audio_devices, [output: test_output_device]})

      Process.sleep(100)

      # Verify the state was updated with device configuration
      {_state_name, data} = :sys.get_state(pid)
      assert data.output_device_id == test_output_device
      assert data.audio_sink == :device

      # Start media to create the pipeline
      :ok = MediaSession.start_media(pid)
      Process.sleep(200)

      # Get state AFTER starting media
      {_state_name_after, data_after} = :sys.get_state(pid)

      # Verify pipeline was created with correct module
      assert data_after.pipeline_module == ParrotMedia.OpusPipeline
      assert data_after.selected_codec == :opus

      # The pipeline should have the audio device configuration
      assert data_after.pipeline_pid != nil
      assert Process.alive?(data_after.pipeline_pid)

      # Clean up
      MediaSession.terminate_session(pid)
    end

    test "configures output device for incoming audio in PCMA pipeline" do
      session_id = "test-audio-device-pcma-#{:rand.uniform(10000)}"

      # Start a media session
      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uac,
          media_handler: TestDeviceHandler,
          handler_args: %{},
          local_rtp_port: 30000 + :rand.uniform(10000),
          supported_codecs: [:opus, :pcma]
        )

      # UAC needs to generate offer first
      {:ok, _offer} = MediaSession.generate_offer(pid)

      # Create a mock SDP answer with PCMA codec
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 40000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      # Process the answer
      :ok = MediaSession.process_answer(pid, sdp_answer)

      # Send use_audio_devices message
      test_output_device = 24
      send(pid, {:use_audio_devices, [output: test_output_device]})

      Process.sleep(100)

      # Verify the state was updated with device configuration
      {_state_name, data} = :sys.get_state(pid)
      assert data.output_device_id == test_output_device
      assert data.audio_sink == :device

      # Start media to create the pipeline
      :ok = MediaSession.start_media(pid)
      Process.sleep(200)

      # Get state AFTER starting media
      {_state_name_after, data_after} = :sys.get_state(pid)

      # Verify pipeline was created with correct module
      assert data_after.pipeline_module == ParrotMedia.AlawPipeline
      assert data_after.selected_codec == :pcma

      # The pipeline should have the audio device configuration
      assert data_after.pipeline_pid != nil
      assert Process.alive?(data_after.pipeline_pid)

      # Clean up
      MediaSession.terminate_session(pid)
    end
  end
end
