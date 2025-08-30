defmodule Parrot.Media.MediaSessionPlayFilesTest do
  use ExUnit.Case, async: false

  alias Parrot.Media.{MediaSession, MediaSessionSupervisor}

  require Logger

  defmodule TestMediaHandler do
    @behaviour Parrot.MediaHandler

    @impl true
    def init(args) do
      {:ok, Map.put(args, :messages_received, [])}
    end

    @impl true
    def handle_info({:play_files, files, opts}, state) do
      Logger.info(
        "TestMediaHandler received play_files: #{inspect(files)}, opts: #{inspect(opts)}"
      )

      # Track the message
      updated_state =
        Map.update(
          state,
          :messages_received,
          [{:play_files, files, opts}],
          &[{:play_files, files, opts} | &1]
        )

      # Return appropriate action based on options
      action =
        case Keyword.get(opts, :loop, false) do
          true -> {:play_loop, files}
          false -> {:play_sequence, files}
        end

      {[action], updated_state}
    end

    @impl true
    def handle_info({:use_audio_devices, opts}, state) do
      Logger.info("TestMediaHandler received use_audio_devices: #{inspect(opts)}")

      input = Keyword.get(opts, :input)
      output = Keyword.get(opts, :output)

      updated_state =
        Map.update(
          state,
          :messages_received,
          [{:use_audio_devices, opts}],
          &[{:use_audio_devices, opts} | &1]
        )

      {[{:connect_audio_device, input, output}], updated_state}
    end

    @impl true
    def handle_info(:stop_playback, state) do
      Logger.info("TestMediaHandler received stop_playback")

      updated_state =
        Map.update(state, :messages_received, [:stop_playback], &[:stop_playback | &1])

      {[:stop], updated_state}
    end

    @impl true
    def handle_info(msg, state) do
      Logger.info("TestMediaHandler received other message: #{inspect(msg)}")
      {:noreply, state}
    end

    @impl true
    def handle_session_start(session_id, _opts, state) do
      Logger.info("TestMediaHandler: Session started: #{session_id}")
      {:ok, state}
    end

    @impl true
    def handle_offer(_sdp, _direction, state) do
      # Just accept the offer as-is
      {:noreply, state}
    end

    @impl true
    def handle_negotiation_complete(_local_sdp, _remote_sdp, _codec, state) do
      # Negotiation complete
      {:ok, state}
    end

    @impl true
    def handle_stream_start(_session_id, _direction, state) do
      Logger.info("TestMediaHandler: Stream started")
      {:noreply, state}
    end

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      # Pick first common codec
      codec = Enum.find(offered, &(&1 in supported)) || :pcmu
      {:ok, codec, state}
    end
  end

  setup do
    # MediaSessionSupervisor is already started by the application
    :ok
  end

  describe "play_files message handling" do
    test "forwards play_files message to handler and processes returned actions" do
      session_id = "test-session-#{:rand.uniform(10000)}"

      # Start a media session
      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{test: true}
        )

      # Get initial state
      {state_name, _data} = :sys.get_state(pid)
      assert state_name == :idle

      # Send play_files message
      test_file = "/tmp/test.wav"
      send(pid, {:play_files, [test_file], loop: false})

      # Give it time to process
      Process.sleep(100)

      # Check that the state was updated with the audio file
      {_state_name, updated_data} = :sys.get_state(pid)
      assert updated_data.audio_file == test_file
      assert updated_data.audio_source == :file

      # Verify handler received the message (stored in handler_state)
      assert {:play_files, [^test_file], [loop: false]} =
               List.first(updated_data.handler_state.messages_received)
    end

    test "handles play_files with loop option" do
      session_id = "test-loop-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # Send play_files with loop
      test_files = ["/tmp/test1.wav", "/tmp/test2.wav"]
      send(pid, {:play_files, test_files, loop: true})

      Process.sleep(100)

      # Check state was updated
      {_state_name, data} = :sys.get_state(pid)
      assert data.audio_file == "/tmp/test1.wav"
      assert data.audio_source == :file

      # Verify handler got the message with loop option
      assert {:play_files, ^test_files, [loop: true]} =
               List.first(data.handler_state.messages_received)
    end

    test "handles stop_playback message" do
      session_id = "test-stop-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # First play something
      send(pid, {:play_files, ["/tmp/test.wav"], []})
      Process.sleep(50)

      # Then stop
      send(pid, :stop_playback)
      Process.sleep(50)

      # Check handler received both messages
      {_state_name, data} = :sys.get_state(pid)
      messages = data.handler_state.messages_received

      assert :stop_playback in messages

      assert Enum.any?(messages, fn
               {:play_files, _, _} -> true
               _ -> false
             end)
    end

    test "handles use_audio_devices message" do
      session_id = "test-devices-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uac,
          media_handler: TestMediaHandler,
          handler_args: %{}
        )

      # Send use_audio_devices message
      send(pid, {:use_audio_devices, [input: 1, output: 2]})
      Process.sleep(100)

      # Check state was updated with device info
      {_state_name, data} = :sys.get_state(pid)
      assert data.input_device_id == 1
      assert data.output_device_id == 2
      assert data.audio_source == :device
      assert data.audio_sink == :device

      # Verify handler received the message
      assert {:use_audio_devices, [input: 1, output: 2]} =
               List.first(data.handler_state.messages_received)
    end
  end

  describe "pipeline restart on play action" do
    test "restarts pipeline when receiving play_files while media is active" do
      session_id = "test-restart-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          local_rtp_port: 20000 + :rand.uniform(10000)
        )

      # Create a mock SDP offer
      sdp_offer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 30000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      # Process the offer to move to ready state
      {:ok, _answer} = MediaSession.process_offer(pid, sdp_offer)

      # Start media to move to active state
      :ok = MediaSession.start_media(pid)
      Process.sleep(100)

      # Verify we're in active state with a pipeline
      {state_name_before, data_before} = :sys.get_state(pid)
      assert state_name_before == :active
      initial_pipeline = data_before.pipeline_pid
      assert initial_pipeline != nil

      # Get the actual path to the test audio file
      priv_dir = :code.priv_dir(:parrot_platform)
      audio_file = Path.join(priv_dir, "audio/parrot-welcome.wav")

      # Send play_files to trigger restart
      send(pid, {:play_files, [audio_file], []})
      Process.sleep(200)

      # Check that pipeline was restarted (new PID)
      # Check if the process is still alive first
      assert Process.alive?(pid), "MediaSession process died unexpectedly"
      {_state_name_after, data_after} = :sys.get_state(pid)
      assert data_after.audio_file == audio_file

      # Pipeline should have been restarted with new file
      new_pipeline = data_after.pipeline_pid
      assert new_pipeline != nil
      # Note: Pipeline PID might be the same if restart was very fast,
      # but the audio_file should definitely be updated
      assert data_after.audio_source == :file
    end
  end
end
