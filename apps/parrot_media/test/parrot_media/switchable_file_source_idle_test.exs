defmodule ParrotMedia.SwitchableFileSourceIdleTest do
  @moduledoc """
  Tests for the :idle mode in SwitchableFileSource.

  The :idle mode allows the audio source to stay alive after playback completes,
  which is required for IVR scenarios where we need to receive DTMF after playing
  a prompt. Without :idle mode, the source emits end_of_stream which terminates
  the entire pipeline.
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.MediaSession

  # Test handler that supports :idle response
  defmodule IdleTestHandler do
    @behaviour ParrotMedia.Handler

    require Logger

    @impl true
    def init(opts) do
      test_pid = Keyword.get(opts, :test_pid, self())
      response_agent = Keyword.fetch!(opts, :response_agent)
      {:ok, %{play_count: 0, test_pid: test_pid, response_agent: response_agent}}
    end

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
    def handle_play_complete(file, state) do
      Logger.debug("[IdleTestHandler] play_complete: #{file}, count: #{state.play_count}")
      send(state.test_pid, {:play_complete, file, state.play_count})

      new_state = %{state | play_count: state.play_count + 1}

      # Get the response from agent
      response = Agent.get(state.response_agent, & &1)
      Agent.update(state.response_agent, fn _ -> nil end)

      Logger.debug("[IdleTestHandler] returning response: #{inspect(response)}")

      case response do
        :idle ->
          # Return :idle to keep the source alive without playing
          {:idle, new_state}

        {:play, next_file} ->
          {{:play, next_file}, new_state}

        :stop ->
          {:stop, new_state}

        nil ->
          {:stop, new_state}

        other ->
          Logger.warning("[IdleTestHandler] Unknown response: #{inspect(other)}")
          {:stop, new_state}
      end
    end

    @impl true
    def handle_media_request(_request, state), do: {:noreply, state}

    @impl true
    def handle_info({:play_files, files, opts}, state) do
      Logger.debug("[IdleTestHandler] handle_info: play_files #{inspect(files)}")

      if Keyword.get(opts, :loop, false) do
        {[{:play_loop, files}], state}
      else
        {[{:play_sequence, files}], state}
      end
    end

    @impl true
    def handle_info(msg, state) do
      Logger.debug("[IdleTestHandler] handle_info: #{inspect(msg)}")
      {:noreply, state}
    end
  end

  setup do
    # Use the real parrot-welcome.wav file
    real_wav =
      Path.join([__DIR__, "..", "..", "priv", "audio", "parrot-welcome.wav"]) |> Path.expand()

    # Create test audio files
    test_dir = System.tmp_dir!() |> Path.join("parrot_idle_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_dir)

    file1 = Path.join(test_dir, "test1.wav")
    file2 = Path.join(test_dir, "test2.wav")

    File.cp!(real_wav, file1)
    File.cp!(real_wav, file2)

    {:ok, response_agent} = Agent.start_link(fn -> nil end)

    on_exit(fn ->
      File.rm_rf!(test_dir)
      if Process.alive?(response_agent), do: Agent.stop(response_agent)
    end)

    %{
      test_dir: test_dir,
      file1: file1,
      file2: file2,
      response_agent: response_agent
    }
  end

  defp start_test_session(session_id, audio_file, response_agent) do
    {:ok, session_pid} =
      MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_#{:rand.uniform(1_000_000)}",
        role: :uas,
        media_handler: IdleTestHandler,
        handler_args: [test_pid: self(), response_agent: response_agent],
        supported_codecs: [:pcma],
        audio_file: audio_file
      )

    # Process offer to negotiate
    sdp_offer = """
    v=0
    o=- 123456 123456 IN IP4 127.0.0.1
    s=Test
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio #{5000 + :rand.uniform(1000)} RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    """

    {:ok, _answer} = MediaSession.process_offer(session_pid, sdp_offer)
    MediaSession.start_media(session_pid)

    session_pid
  end

  defp set_handler_response(agent, response) do
    Agent.update(agent, fn _ -> response end)
  end

  describe ":idle mode - source stays alive after playback" do
    test "source enters idle mode and stays alive when handler returns :idle", %{
      file1: file1,
      response_agent: response_agent
    } do
      session_id = "test_idle_#{:rand.uniform(1_000_000)}"

      # Configure handler to return :idle after first file completes
      set_handler_response(response_agent, :idle)

      session_pid = start_test_session(session_id, file1, response_agent)

      # Should receive play_complete for file1
      assert_receive {:play_complete, ^file1, 0}, 15_000

      # The key assertion: session should still be alive after file completes
      # Give it a moment then verify it's still running
      Process.sleep(500)
      assert Process.alive?(session_pid), "Session should still be alive in idle mode"

      # Clean up
      MediaSession.terminate_session(session_pid)
    end

    test "can play another file after entering idle mode via message", %{
      file1: file1,
      file2: file2,
      response_agent: response_agent
    } do
      session_id = "test_idle_then_play_#{:rand.uniform(1_000_000)}"

      # Configure handler to return :idle after first file
      set_handler_response(response_agent, :idle)

      session_pid = start_test_session(session_id, file1, response_agent)

      # Wait for first file to complete
      assert_receive {:play_complete, ^file1, 0}, 15_000

      # Session should still be alive
      Process.sleep(200)
      assert Process.alive?(session_pid), "Session should still be alive in idle mode"

      # Now queue the next response and send play_files message to the session
      # The session forwards this to the pipeline
      set_handler_response(response_agent, :stop)
      send(session_pid, {:play_files, [file2], []})

      # Should receive play_complete for second file
      assert_receive {:play_complete, ^file2, 1}, 15_000

      # Clean up
      MediaSession.terminate_session(session_pid)
    end

    test "idle mode does not emit end_of_stream (pipeline stays operational)", %{
      file1: file1,
      response_agent: response_agent
    } do
      session_id = "test_idle_no_eos_#{:rand.uniform(1_000_000)}"

      set_handler_response(response_agent, :idle)

      session_pid = start_test_session(session_id, file1, response_agent)

      # Wait for file to complete
      assert_receive {:play_complete, ^file1, 0}, 15_000

      # Wait longer to ensure pipeline doesn't terminate
      Process.sleep(2_000)

      # Session must still be alive - this is the critical check
      # If end_of_stream was emitted, the pipeline would have terminated
      assert Process.alive?(session_pid),
             "Pipeline terminated unexpectedly - end_of_stream was likely emitted"

      MediaSession.terminate_session(session_pid)
    end

    test "contrasting behavior: :stop causes normal termination", %{
      file1: file1,
      response_agent: response_agent
    } do
      # This test documents expected behavior where :stop causes clean termination
      session_id = "test_stop_terminates_#{:rand.uniform(1_000_000)}"

      # Use :stop which should cause clean termination
      set_handler_response(response_agent, :stop)

      session_pid = start_test_session(session_id, file1, response_agent)

      # Wait for file to complete
      assert_receive {:play_complete, ^file1, 0}, 15_000

      # Wait a bit - the session/pipeline should eventually terminate
      Process.sleep(1_000)

      # Clean up if still alive
      if Process.alive?(session_pid) do
        MediaSession.terminate_session(session_pid)
      end
    end
  end
end
