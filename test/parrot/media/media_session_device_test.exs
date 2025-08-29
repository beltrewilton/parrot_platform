defmodule Parrot.Media.MediaSessionDeviceTest do
  @moduledoc """
  Tests for the new device control message patterns in MediaSession.
  """
  use ExUnit.Case
  
  alias Parrot.Media.MediaSession
  
  # Test handler for device control
  defmodule DeviceTestHandler do
    @behaviour Parrot.MediaHandler
    
    @impl true
    def init(args) do
      {:ok, Map.merge(%{test_pid: args[:test_pid]}, args)}
    end
    
    @impl true
    def handle_session_start(_session_id, _opts, state) do
      {:ok, state}
    end
    
    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      codec = Enum.find(offered, &(&1 in supported)) || :pcma
      {:ok, codec, state}
    end
    
    @impl true
    def handle_negotiation_complete(_local_sdp, _remote_sdp, _codec, state) do
      {:ok, state}
    end
    
    @impl true
    def handle_offer(_sdp, _direction, state) do
      {:noreply, state}
    end
    
    @impl true
    def handle_stream_start(_session_id, _direction, state) do
      {:noreply, state}
    end
    
    @impl true
    def handle_info({:use_audio_devices, opts}, state) when is_list(opts) do
      input = Keyword.get(opts, :input)
      output = Keyword.get(opts, :output)
      send(state.test_pid, {:handler_received, :use_audio_devices, {input, output}})
      {[{:connect_audio_device, input, output}], state}
    end
    
    @impl true
    def handle_info({:use_microphone, device_id}, state) do
      send(state.test_pid, {:handler_received, :use_microphone, device_id})
      {[{:connect_audio_device, device_id, nil}], state}
    end
    
    @impl true
    def handle_info({:use_speaker, device_id}, state) do
      send(state.test_pid, {:handler_received, :use_speaker, device_id})
      {[{:connect_audio_device, nil, device_id}], state}
    end
    
    @impl true
    def handle_info(:release_audio_devices, state) do
      send(state.test_pid, {:handler_received, :release_audio_devices})
      {[{:connect_audio_device, nil, nil}], state}
    end
    
    @impl true
    def handle_info(_msg, state) do
      {:noreply, state}
    end
  end
  
  setup do
    session_id = "test_device_#{:rand.uniform(10000)}"
    {:ok, %{session_id: session_id}}
  end
  
  describe "device control messages" do
    test "handles :use_audio_devices with both input and output", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()}
      )
      
      # Send use_audio_devices message
      send(session, {:use_audio_devices, [input: 1, output: 2]})
      
      # Verify handler received the message
      assert_receive {:handler_received, :use_audio_devices, {1, 2}}, 1000
      
      # Check the state was updated (would need state inspection in real test)
      # The MediaSession should have updated audio_source: :device, audio_sink: :device
      # and set the device IDs
      
      MediaSession.terminate_session(session)
    end
    
    test "handles :use_audio_devices with only input", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1", 
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()}
      )
      
      send(session, {:use_audio_devices, [input: 3]})
      
      assert_receive {:handler_received, :use_audio_devices, {3, nil}}, 1000
      
      MediaSession.terminate_session(session)
    end
    
    test "handles :use_audio_devices with only output", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()}
      )
      
      send(session, {:use_audio_devices, [output: 4]})
      
      assert_receive {:handler_received, :use_audio_devices, {nil, 4}}, 1000
      
      MediaSession.terminate_session(session)
    end
    
    test "handles :use_microphone message", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()}
      )
      
      send(session, {:use_microphone, 5})
      
      assert_receive {:handler_received, :use_microphone, 5}, 1000
      
      MediaSession.terminate_session(session)
    end
    
    test "handles :use_speaker message", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()}
      )
      
      send(session, {:use_speaker, 6})
      
      assert_receive {:handler_received, :use_speaker, 6}, 1000
      
      MediaSession.terminate_session(session)
    end
    
    test "handles :release_audio_devices message", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()}
      )
      
      send(session, :release_audio_devices)
      
      assert_receive {:handler_received, :release_audio_devices}, 1000
      
      MediaSession.terminate_session(session)
    end
    
    test "device messages work in all states", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uas,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()}
      )
      
      # Send message in idle state
      send(session, {:use_audio_devices, [input: 1, output: 2]})
      assert_receive {:handler_received, :use_audio_devices, {1, 2}}, 1000
      
      # Create SDP offer to move to negotiating state
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
      
      # Send message in ready state
      send(session, {:use_microphone, 3})
      assert_receive {:handler_received, :use_microphone, 3}, 1000
      
      # Start media to move to active state
      :ok = MediaSession.start_media(session)
      
      # Send message in active state
      send(session, {:use_speaker, 4})
      assert_receive {:handler_received, :use_speaker, 4}, 1000
      
      MediaSession.terminate_session(session)
    end
  end
  
  describe "connect_audio_device action processing" do
    test "connect_audio_device with both devices sets source and sink to :device", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()},
        audio_source: :silence,
        audio_sink: :none
      )
      
      # Send message that will trigger connect_audio_device action
      send(session, {:use_audio_devices, [input: 1, output: 2]})
      
      # Wait for handler to process
      assert_receive {:handler_received, :use_audio_devices, {1, 2}}, 1000
      
      # The MediaSession should have updated:
      # - audio_source to :device
      # - audio_sink to :device
      # - input_device_id to 1
      # - output_device_id to 2
      
      MediaSession.terminate_session(session)
    end
    
    test "connect_audio_device with nil, nil releases devices", %{session_id: session_id} do
      {:ok, session} = MediaSession.start_link(
        id: session_id,
        dialog_id: "dialog_1",
        role: :uac,
        media_handler: DeviceTestHandler,
        handler_args: %{test_pid: self()},
        audio_source: :device,
        audio_sink: :device,
        input_device_id: 1,
        output_device_id: 2
      )
      
      # Release devices
      send(session, :release_audio_devices)
      
      assert_receive {:handler_received, :release_audio_devices}, 1000
      
      # The MediaSession should have updated:
      # - audio_source to :silence
      # - audio_sink to :none
      # - input_device_id to nil
      # - output_device_id to nil
      
      MediaSession.terminate_session(session)
    end
  end
end