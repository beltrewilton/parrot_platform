defmodule ParrotMedia.MediaSessionPlayFilesTest do
  use ExUnit.Case, async: false

  alias ParrotMedia.{MediaSession, MediaSessionSupervisor}

  require Logger

  defmodule TestMediaHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(args) do
      # Notify test process that handler was initialized
      if test_pid = args[:test_pid] do
        send(test_pid, {:handler_initialized, args})
      end

      {:ok, args}
    end

    @impl true
    def handle_info({:play_files, files, opts}, state) do
      Logger.info(
        "TestMediaHandler received play_files: #{inspect(files)}, opts: #{inspect(opts)}"
      )

      # Notify test process
      if test_pid = state[:test_pid] do
        send(test_pid, {:handler_processed, :play_files, files, opts})
      end

      # Return appropriate action based on options
      action =
        case Keyword.get(opts, :loop, false) do
          true -> {:play_loop, files}
          false -> {:play_sequence, files}
        end

      {[action], state}
    end

    @impl true
    def handle_info({:use_audio_devices, opts}, state) do
      Logger.info("TestMediaHandler received use_audio_devices: #{inspect(opts)}")

      # Notify test process
      if test_pid = state[:test_pid] do
        send(test_pid, {:handler_processed, :use_audio_devices, opts})
      end

      input = Keyword.get(opts, :input)
      output = Keyword.get(opts, :output)

      {[{:connect_audio_device, input, output}], state}
    end

    @impl true
    def handle_info(:stop_playback, state) do
      Logger.info("TestMediaHandler received stop_playback")

      # Notify test process
      if test_pid = state[:test_pid] do
        send(test_pid, {:handler_processed, :stop_playback})
      end

      {[:stop], state}
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
          handler_args: %{test_pid: self()}
        )

      # Verify initial state via public API
      state_info = :gen_statem.call(pid, :get_state)
      assert state_info.state == :idle

      # Send play_files message
      test_file = "/tmp/test.wav"
      send(pid, {:play_files, [test_file], loop: false})

      # Verify handler processed the message
      assert_receive {:handler_processed, :play_files, [^test_file], [loop: false]}, 1000
    end

    test "handles play_files with loop option" do
      session_id = "test-loop-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{test_pid: self()}
        )

      # Send play_files with loop
      test_files = ["/tmp/test1.wav", "/tmp/test2.wav"]
      send(pid, {:play_files, test_files, loop: true})

      # Verify handler got the message with loop option
      assert_receive {:handler_processed, :play_files, ^test_files, [loop: true]}, 1000
    end

    test "handles stop_playback message" do
      session_id = "test-stop-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{test_pid: self()}
        )

      # First play something
      send(pid, {:play_files, ["/tmp/test.wav"], []})

      # Verify handler received play_files
      assert_receive {:handler_processed, :play_files, ["/tmp/test.wav"], []}, 1000

      # Then stop
      send(pid, :stop_playback)

      # Verify handler received stop_playback
      assert_receive {:handler_processed, :stop_playback}, 1000
    end

    test "handles use_audio_devices message" do
      session_id = "test-devices-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uac,
          media_handler: TestMediaHandler,
          handler_args: %{test_pid: self()}
        )

      # Send use_audio_devices message
      send(pid, {:use_audio_devices, [input: 1, output: 2]})

      # Verify handler received the message
      assert_receive {:handler_processed, :use_audio_devices, [input: 1, output: 2]}, 1000
    end
  end

  describe "pipeline restart on play action" do
    @tag :skip
    test "restarts pipeline when receiving play_files while media is active" do
      session_id = "test-restart-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{test_pid: self()},
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

      # Verify we're in active state with a pipeline via public API
      state_info_before = :gen_statem.call(pid, :get_state)
      assert state_info_before.state == :active
      assert state_info_before.pipeline_active == true

      # Get the actual path to the test audio file
      priv_dir = :code.priv_dir(:parrot_media)
      audio_file = Path.join(priv_dir, "audio/parrot-welcome.wav")

      # Send play_files to trigger restart
      send(pid, {:play_files, [audio_file], []})

      # Verify handler processed the play_files message
      assert_receive {:handler_processed, :play_files, [^audio_file], []}, 1000

      # Check if the process is still alive
      assert Process.alive?(pid), "MediaSession process died unexpectedly"

      # Verify state is still active with pipeline via public API
      state_info_after = :gen_statem.call(pid, :get_state)
      assert state_info_after.state == :active
      assert state_info_after.pipeline_active == true
    end
  end
end
