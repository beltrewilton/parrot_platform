defmodule ParrotMedia.MediaSessionIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :slow

  alias ParrotMedia.MediaSession

  defmodule TestHandler do
    # Uses default implementations for handle_session_start, handle_codec_negotiation,
    # handle_negotiation_complete, handle_stream_start - only override what we need
    use ParrotMedia.Handler

    @impl true
    def init(args) do
      {:ok, Map.merge(%{files_played: [], looping: false, test_pid: nil}, args)}
    end

    @impl true
    def handle_info({:play_files, files, [loop: true]}, state) do
      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :play_loop, files})
      {[{:play_loop, files}], %{state | files_played: files, looping: true}}
    end

    @impl true
    def handle_info({:play_files, files, opts}, state) when is_list(opts) do
      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :play_sequence, files})
      {[{:play_sequence, files}], %{state | files_played: files, looping: false}}
    end

    @impl true
    def handle_info({:stop_playback}, state) do
      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :stop})
      {[:stop], %{state | files_played: [], looping: false}}
    end

    @impl true
    def handle_info({:use_audio_devices, opts}, state) when is_list(opts) do
      input = Keyword.get(opts, :input, "default")
      output = Keyword.get(opts, :output, "default")

      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :use_audio_devices, opts})

      actions = [{:connect_audio_device, input, output}]

      {actions,
       Map.merge(state, %{using_microphone: input != nil, using_speakers: output != nil})}
    end

    @impl true
    def handle_info({:use_microphone, device_id}, state) do
      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :use_microphone, device_id})
      {[{:connect_audio_device, device_id, nil}], Map.put(state, :using_microphone, true)}
    end

    @impl true
    def handle_info({:use_speaker, device_id}, state) do
      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :use_speaker, device_id})
      {[{:connect_audio_device, nil, device_id}], Map.put(state, :using_speakers, true)}
    end

    @impl true
    def handle_info(:release_audio_devices, state) do
      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :release_audio_devices})
      {[{:connect_audio_device, nil, nil}],
       Map.merge(state, %{using_microphone: false, using_speakers: false})}
    end

    @impl true
    def handle_info(_msg, state) do
      if state[:test_pid], do: send(state.test_pid, {:handler_processed, :unknown})
      {:noreply, state}
    end
  end

  setup do
    # Create a test audio file
    priv_dir = :code.priv_dir(:parrot_media)
    test_file = Path.join(priv_dir, "audio/parrot-welcome.wav")

    {:ok, test_file: test_file}
  end

  describe "MediaSession with MediaHandler integration" do
    test "forwards :play_files message to handler" do
      # Start media session with our test handler
      {:ok, session} =
        MediaSession.start_link(
          id: "test_session_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{test_pid: self()}
        )

      # Send play_files message
      send(session, {:play_files, ["test1.wav", "test2.wav"], loop: false})

      # Verify handler processed the message
      assert_receive {:handler_processed, :play_sequence, ["test1.wav", "test2.wav"]}, 1000

      # Cleanup
      GenServer.stop(session)
    end

    test "forwards :play_files with loop option" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_loop_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{test_pid: self()}
        )

      # Send play_files with loop
      send(session, {:play_files, ["music.wav"], loop: true})

      # Verify handler processed it as loop
      assert_receive {:handler_processed, :play_loop, ["music.wav"]}, 1000

      GenServer.stop(session)
    end

    test "forwards :stop_playback message" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_stop_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{files_played: ["something.wav"], test_pid: self()}
        )

      # Send stop_playback
      send(session, {:stop_playback})

      # Verify handler processed the stop
      assert_receive {:handler_processed, :stop}, 1000

      GenServer.stop(session)
    end

    test "handles handler returning :noreply" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_noreply_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{original: true, test_pid: self()}
        )

      # Send unknown message that returns :noreply
      send(session, {:unknown_message, "data"})

      # Verify handler received it (and returned :noreply)
      assert_receive {:handler_processed, :unknown}, 1000

      # Session should still be functional
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :idle

      GenServer.stop(session)
    end

    test "media session processes play actions from handler", %{test_file: test_file} do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_actions_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{test_pid: self()}
        )

      # Send play_files that will return play_sequence action
      send(session, {:play_files, [test_file], loop: false})

      # Verify handler processed the action
      assert_receive {:handler_processed, :play_sequence, [^test_file]}, 1000

      GenServer.stop(session)
    end
  end

  # Removed "MediaSession without MediaHandler" tests - MediaHandler is now required

  describe "MediaSession with audio device actions" do
    test "handles :use_microphone message" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_mic_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{test_pid: self()}
        )

      # Send use_microphone message
      send(session, {:use_microphone, "default"})

      # Verify handler processed the message
      assert_receive {:handler_processed, :use_microphone, "default"}, 1000

      # Session should still be functional and in idle state
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :idle

      GenServer.stop(session)
    end

    test "handles :use_speaker message" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_speakers_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{test_pid: self()}
        )

      # Send use_speaker message
      send(session, {:use_speaker, "default"})

      # Verify handler processed the message
      assert_receive {:handler_processed, :use_speaker, "default"}, 1000

      # Session should still be functional and in idle state
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :idle

      GenServer.stop(session)
    end

    test "handles :use_audio_devices message" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_both_#{:rand.uniform(10000)}",
          dialog_id: "test_dialog_#{:rand.uniform(10000)}",
          role: :uas,
          media_handler: TestHandler,
          handler_args: %{test_pid: self()}
        )

      # Send use_audio_devices message
      send(session, {:use_audio_devices, [input: "default", output: "default"]})

      # Verify handler processed the message with correct options
      assert_receive {:handler_processed, :use_audio_devices, [input: "default", output: "default"]}, 1000

      # Session should still be functional and in idle state
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.state == :idle

      GenServer.stop(session)
    end
  end
end
