defmodule Parrot.Media.MediaSessionIntegrationTest do
  use ExUnit.Case, async: false
  
  alias Parrot.Media.MediaSession
  
  defmodule TestHandler do
    @behaviour Parrot.MediaHandler
    
    @impl true
    def init(args) do
      {:ok, Map.merge(%{files_played: [], looping: false}, args)}
    end
    
    @impl true
    def handle_info({:play_files, files, [loop: true]}, state) do
      {[{:play_loop, files}], %{state | files_played: files, looping: true}}
    end
    
    @impl true
    def handle_info({:play_files, files, opts}, state) when is_list(opts) do
      {[{:play_sequence, files}], %{state | files_played: files, looping: false}}
    end
    
    @impl true
    def handle_info({:stop_playback}, state) do
      {[:stop], %{state | files_played: [], looping: false}}
    end
    
    @impl true
    def handle_info({:connect_microphone}, state) do
      {[{:connect_audio_device, "default", nil}, {:set_audio_source, :device}], 
       Map.put(state, :using_microphone, true)}
    end
    
    @impl true
    def handle_info({:connect_speakers}, state) do
      {[{:connect_audio_device, nil, "default"}, {:set_audio_sink, :device}],
       Map.put(state, :using_speakers, true)}
    end
    
    @impl true
    def handle_info({:connect_audio_devices}, state) do
      actions = [
        {:connect_audio_device, "default", "default"},
        {:set_audio_source, :device},
        {:set_audio_sink, :device}
      ]
      {actions, Map.merge(state, %{using_microphone: true, using_speakers: true})}
    end
    
    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end
    
    @impl true
    def handle_stream_start(_id, _dir, state) do
      {:noreply, state}
    end
    
    @impl true
    def handle_session_start(_id, _opts, state) do
      {:ok, state}
    end
  end
  
  setup do
    # Create a test audio file
    priv_dir = :code.priv_dir(:parrot_platform)
    test_file = Path.join(priv_dir, "audio/parrot-welcome.wav")
    
    {:ok, test_file: test_file}
  end
  
  describe "MediaSession with MediaHandler integration" do
    test "forwards :play_files message to handler" do
      # Start media session with our test handler
      {:ok, session} = MediaSession.start_link(
        id: "test_session_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{}
      )
      
      # Get initial state
      {_state_name, data} = :sys.get_state(session)
      assert data.media_handler == TestHandler
      
      # Send play_files message
      send(session, {:play_files, ["test1.wav", "test2.wav"], loop: false})
      
      # Give it time to process
      Process.sleep(50)
      
      # Check that handler state was updated
      {_state_name, new_data} = :sys.get_state(session)
      assert new_data.handler_state.files_played == ["test1.wav", "test2.wav"]
      assert new_data.handler_state.looping == false
      
      # Cleanup
      GenServer.stop(session)
    end
    
    test "forwards :play_files with loop option" do
      {:ok, session} = MediaSession.start_link(
        id: "test_loop_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{}
      )
      
      # Send play_files with loop
      send(session, {:play_files, ["music.wav"], loop: true})
      
      Process.sleep(50)
      
      # Check that handler processed it as loop
      {_state_name, data} = :sys.get_state(session)
      assert data.handler_state.files_played == ["music.wav"]
      assert data.handler_state.looping == true
      
      GenServer.stop(session)
    end
    
    test "forwards :stop_playback message" do
      {:ok, session} = MediaSession.start_link(
        id: "test_stop_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{files_played: ["something.wav"]}
      )
      
      # Send stop_playback
      send(session, {:stop_playback})
      
      Process.sleep(50)
      
      # Check that handler cleared the files
      {_state_name, data} = :sys.get_state(session)
      assert data.handler_state.files_played == []
      assert data.handler_state.looping == false
      
      GenServer.stop(session)
    end
    
    test "handles handler returning :noreply" do
      {:ok, session} = MediaSession.start_link(
        id: "test_noreply_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{original: true}
      )
      
      # Send unknown message that returns :noreply
      send(session, {:unknown_message, "data"})
      
      Process.sleep(50)
      
      # State should be unchanged
      {_state_name, data} = :sys.get_state(session)
      assert data.handler_state.original == true
      
      GenServer.stop(session)
    end
    
    test "media session processes play actions from handler", %{test_file: test_file} do
      {:ok, session} = MediaSession.start_link(
        id: "test_actions_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{}
      )
      
      # Send play_files that will return play_sequence action
      send(session, {:play_files, [test_file], loop: false})
      
      Process.sleep(50)
      
      # The MediaSession should have processed the action
      {_state_name, data} = :sys.get_state(session)
      # The handler should have updated its state
      assert data.handler_state.files_played == [test_file]
      
      GenServer.stop(session)
    end
  end
  
  # Removed "MediaSession without MediaHandler" tests - MediaHandler is now required
  
  describe "MediaSession with audio device actions" do
    test "handles :connect_microphone message" do
      {:ok, session} = MediaSession.start_link(
        id: "test_mic_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{}
      )
      
      # Send connect_microphone message
      send(session, {:connect_microphone})
      
      Process.sleep(50)
      
      # Check that MediaSession updated its configuration
      {_state_name, data} = :sys.get_state(session)
      assert data.audio_source == :device
      assert data.input_device_id == "default"
      assert data.handler_state.using_microphone == true
      
      GenServer.stop(session)
    end
    
    test "handles :connect_speakers message" do
      {:ok, session} = MediaSession.start_link(
        id: "test_speakers_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{}
      )
      
      # Send connect_speakers message
      send(session, {:connect_speakers})
      
      Process.sleep(50)
      
      # Check that MediaSession updated its configuration
      {_state_name, data} = :sys.get_state(session)
      assert data.audio_sink == :device
      assert data.output_device_id == "default"
      assert data.handler_state.using_speakers == true
      
      GenServer.stop(session)
    end
    
    test "handles :connect_audio_devices message" do
      {:ok, session} = MediaSession.start_link(
        id: "test_both_#{:rand.uniform(10000)}",
        dialog_id: "test_dialog_#{:rand.uniform(10000)}",
        role: :uas,
        media_handler: TestHandler,
        handler_args: %{}
      )
      
      # Send connect_audio_devices message
      send(session, {:connect_audio_devices})
      
      Process.sleep(50)
      
      # Check that MediaSession updated its configuration
      {_state_name, data} = :sys.get_state(session)
      assert data.audio_source == :device
      assert data.audio_sink == :device
      assert data.input_device_id == "default"
      assert data.output_device_id == "default"
      assert data.handler_state.using_microphone == true
      assert data.handler_state.using_speakers == true
      
      GenServer.stop(session)
    end
    
  end
  
end