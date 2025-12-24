defmodule ParrotMedia.PipelineFileSwitchingTest do
  use ExUnit.Case, async: false

  alias ParrotMedia.MediaSession

  # Test handler that implements ParrotMedia.Handler behavior
  defmodule TestFileHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(opts) do
      test_pid = Keyword.get(opts, :test_pid, self())
      response_agent = Keyword.fetch!(opts, :response_agent)
      {:ok, %{play_count: 0, test_pid: test_pid, response_agent: response_agent}}
    end

    @impl true
    def handle_session_start(_session_id, _opts, state) do
      {:ok, state}
    end

    @impl true
    def handle_session_stop(_session_id, _reason, state) do
      {:ok, state}
    end

    @impl true
    def handle_offer(_sdp, _direction, state) do
      {:noreply, state}
    end

    @impl true
    def handle_answer(_sdp, _direction, state) do
      {:noreply, state}
    end

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      codec = Enum.find(offered, &(&1 in supported)) || hd(supported)
      {:ok, codec, state}
    end

    @impl true
    def handle_negotiation_complete(_local, _remote, _codec, state) do
      {:ok, state}
    end

    @impl true
    def handle_stream_start(_session_id, _direction, state) do
      {:noreply, state}
    end

    @impl true
    def handle_stream_stop(_session_id, _reason, state) do
      {:ok, state}
    end

    @impl true
    def handle_stream_error(_session_id, _error, state) do
      {:continue, state}
    end

    @impl true
    def handle_play_complete(file, state) do
      # Send message to test process
      send(state.test_pid, {:play_complete, file, state.play_count})

      # Increment play count
      new_state = %{state | play_count: state.play_count + 1}

      # Check if we have a response queued
      response = Agent.get(state.response_agent, & &1)
      Agent.update(state.response_agent, fn _ -> nil end)

      case response do
        nil ->
          {:stop, new_state}

        {:play, next_file} ->
          {{:play, next_file}, new_state}

        {:play_unwrapped, next_file} ->
          {:play, next_file}

        {:play_sequence, files} ->
          {{:play_sequence, files}, new_state}

        {:play_sequence_unwrapped, files} ->
          {:play_sequence, files}

        {:play_loop, files} ->
          {{:play_loop, files}, new_state}

        {:play_loop_unwrapped, files} ->
          {:play_loop, files}

        :stop ->
          {:stop, new_state}

        :noreply ->
          {:noreply, new_state}
      end
    end

    @impl true
    def handle_media_request(_request, state) do
      {:noreply, state}
    end

    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end
  end

  setup do
    # Use the real parrot-welcome.wav file from priv/audio
    real_wav =
      Path.join([__DIR__, "..", "..", "priv", "audio", "parrot-welcome.wav"]) |> Path.expand()

    # Create test audio files by copying the real WAV
    test_dir = System.tmp_dir!() |> Path.join("parrot_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_dir)

    file1 = Path.join(test_dir, "test1.wav")
    file2 = Path.join(test_dir, "test2.wav")
    file3 = Path.join(test_dir, "test3.wav")
    non_wav = Path.join(test_dir, "test.mp3")

    # Copy the real WAV file
    File.cp!(real_wav, file1)
    File.cp!(real_wav, file2)
    File.cp!(real_wav, file3)
    File.write!(non_wav, "not a wav file")

    # Start Agent for cross-process communication
    {:ok, response_agent} = Agent.start_link(fn -> nil end)

    on_exit(fn ->
      File.rm_rf!(test_dir)
      Agent.stop(response_agent)
    end)

    %{
      test_dir: test_dir,
      file1: file1,
      file2: file2,
      file3: file3,
      non_wav: non_wav,
      response_agent: response_agent
    }
  end

  defp start_test_session(session_id, audio_file, codec \\ :pcma, response_agent) do
    {:ok, session_pid} =
      MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_#{:rand.uniform(1_000_000)}",
        role: :uas,
        media_handler: TestFileHandler,
        handler_args: [test_pid: self(), response_agent: response_agent],
        supported_codecs: [codec],
        audio_file: audio_file
      )

    # Process offer to negotiate
    codec_num = if codec == :pcma, do: 8, else: 111
    codec_name = if codec == :pcma, do: "PCMA/8000", else: "opus/48000"

    sdp_offer = """
    v=0
    o=- 123456 123456 IN IP4 127.0.0.1
    s=Test
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio #{5000 + :rand.uniform(1000)} RTP/AVP #{codec_num}
    a=rtpmap:#{codec_num} #{codec_name}
    """

    {:ok, _answer} = MediaSession.process_offer(session_pid, sdp_offer)
    MediaSession.start_media(session_pid)

    session_pid
  end

  defp set_handler_response(agent, response) do
    Agent.update(agent, fn _ -> response end)
  end

  describe "file validation - AlawPipeline" do
    test "rejects non-existent file", %{file1: file1, response_agent: response_agent} do
      session_id = "test_validation_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play, "/nonexistent/file.wav"})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should play file1, then fail on invalid file and terminate
      assert_receive {:play_complete, ^file1, 0}, 15000

      # Should NOT receive play_complete for invalid file
      refute_receive {:play_complete, _, _}, 2000

      # Clean up
      MediaSession.terminate_session(session_pid)
    end

    test "rejects empty file path", %{file1: file1, response_agent: response_agent} do
      session_id = "test_empty_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play, ""})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      assert_receive {:play_complete, ^file1, 0}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end

    test "rejects non-WAV file", %{file1: file1, non_wav: non_wav, response_agent: response_agent} do
      session_id = "test_non_wav_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play, non_wav})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      assert_receive {:play_complete, ^file1, 0}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end
  end

  describe "play_sequence handling - AlawPipeline" do
    test "plays sequence of files", %{
      file1: file1,
      file2: file2,
      file3: file3,
      response_agent: response_agent
    } do
      session_id = "test_sequence_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_sequence, [file2, file3]})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should receive play_complete for file1, then file2, then file3
      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      assert_receive {:play_complete, ^file3, 2}, 15000

      # No more files, should stop
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end

    test "handles unwrapped play_sequence", %{
      file1: file1,
      file2: file2,
      response_agent: response_agent
    } do
      session_id = "test_sequence_unwrapped_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_sequence_unwrapped, [file2]})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end

    test "rejects empty sequence", %{file1: file1, response_agent: response_agent} do
      session_id = "test_empty_sequence_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_sequence, []})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should receive play_complete for file1, then terminate (empty sequence)
      assert_receive {:play_complete, ^file1, 0}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end
  end

  describe "play_loop handling - AlawPipeline" do
    test "loops through files", %{
      file1: file1,
      file2: file2,
      file3: file3,
      response_agent: response_agent
    } do
      session_id = "test_loop_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_loop, [file2, file3]})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should play file1, then file2, file3, file2, file3... in a loop
      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      assert_receive {:play_complete, ^file3, 2}, 15000

      # Loop should restart
      assert_receive {:play_complete, ^file2, 3}, 15000
      assert_receive {:play_complete, ^file3, 4}, 5000

      # Verify another loop iteration
      assert_receive {:play_complete, ^file2, 5}, 15000

      # Stop the session
      MediaSession.terminate_session(session_pid)
    end

    test "handles unwrapped play_loop", %{
      file1: file1,
      file2: file2,
      response_agent: response_agent
    } do
      session_id = "test_loop_unwrapped_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_loop_unwrapped, [file2]})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should loop file2
      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      assert_receive {:play_complete, ^file2, 2}, 15000
      assert_receive {:play_complete, ^file2, 3}, 15000

      # Stop the session
      MediaSession.terminate_session(session_pid)
    end

    test "rejects empty loop", %{file1: file1, response_agent: response_agent} do
      session_id = "test_empty_loop_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_loop, []})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should receive play_complete for file1, then terminate
      assert_receive {:play_complete, ^file1, 0}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end
  end

  describe "unwrapped return values - AlawPipeline" do
    test "handles unwrapped :play", %{file1: file1, file2: file2, response_agent: response_agent} do
      session_id = "test_unwrapped_play_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_unwrapped, file2})

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should play both files
      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end

    test "handles :noreply return", %{file1: file1, response_agent: response_agent} do
      session_id = "test_noreply_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, :noreply)

      session_pid = start_test_session(session_id, file1, :pcma, response_agent)

      # Should play file1, then terminate
      assert_receive {:play_complete, ^file1, 0}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end
  end

  describe "OpusPipeline file switching" do
    test "switches files with OpusPipeline", %{
      file1: file1,
      file2: file2,
      response_agent: response_agent
    } do
      session_id = "test_opus_switch_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play, file2})

      session_pid = start_test_session(session_id, file1, :opus, response_agent)

      # Should play both files
      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end

    test "plays sequence with OpusPipeline", %{
      file1: file1,
      file2: file2,
      file3: file3,
      response_agent: response_agent
    } do
      session_id = "test_opus_sequence_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_sequence, [file2, file3]})

      session_pid = start_test_session(session_id, file1, :opus, response_agent)

      # Should play all files in sequence
      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      assert_receive {:play_complete, ^file3, 2}, 15000
      refute_receive {:play_complete, _, _}, 2000

      MediaSession.terminate_session(session_pid)
    end

    test "loops files with OpusPipeline", %{
      file1: file1,
      file2: file2,
      response_agent: response_agent
    } do
      session_id = "test_opus_loop_#{:rand.uniform(1_000_000)}"
      set_handler_response(response_agent, {:play_loop, [file2]})

      session_pid = start_test_session(session_id, file1, :opus, response_agent)

      # Should loop file2
      assert_receive {:play_complete, ^file1, 0}, 15000
      assert_receive {:play_complete, ^file2, 1}, 15000
      assert_receive {:play_complete, ^file2, 2}, 15000
      assert_receive {:play_complete, ^file2, 3}, 15000

      # Stop the session
      MediaSession.terminate_session(session_pid)
    end
  end
end
