defmodule Parrot.Media.PortAudioPipelineSelectionTest do
  use ExUnit.Case, async: false
  
  alias Parrot.Media.{MediaSession, MediaSessionSupervisor}
  
  require Logger
  
  defmodule TestHandler do
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
      codec = Enum.find(offered, &(&1 in supported)) || :pcmu
      {:ok, codec, state}
    end
    
    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end
  
  describe "PortAudioPipeline selection" do
    test "uses PortAudioPipeline when output device is configured at initialization" do
      session_id = "test-portaudio-output-#{:rand.uniform(10000)}"
      
      # Start UAC session with output device configured
      {:ok, pid} = MediaSessionSupervisor.start_session(
        id: session_id,
        dialog_id: "test-dialog",
        role: :uac,
        media_handler: TestHandler,
        handler_args: %{},
        supported_codecs: [:opus, :pcma],
        local_rtp_port: 30000 + :rand.uniform(10000),
        # Configure output device
        output_device_id: 1,
        audio_sink: :device
      )
      
      # Generate offer
      {:ok, _offer} = MediaSession.generate_offer(pid)
      
      # Process answer with Opus
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 40000 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """
      
      :ok = MediaSession.process_answer(pid, sdp_answer)
      
      # Check the pipeline module was set to PortAudioPipeline
      {_state_name, data} = :sys.get_state(pid)
      assert data.pipeline_module == Parrot.Media.PortAudioPipeline
      assert data.audio_sink == :device
      assert data.output_device_id == 1
      
      # Clean up
      MediaSession.terminate_session(pid)
    end
    
    test "uses PortAudioPipeline when input device is configured at initialization" do
      session_id = "test-portaudio-input-#{:rand.uniform(10000)}"
      
      # Start UAC session with input device configured
      {:ok, pid} = MediaSessionSupervisor.start_session(
        id: session_id,
        dialog_id: "test-dialog",
        role: :uac,
        media_handler: TestHandler,
        handler_args: %{},
        supported_codecs: [:opus, :pcma],
        local_rtp_port: 30000 + :rand.uniform(10000),
        # Configure input device
        input_device_id: 2,
        audio_source: :device
      )
      
      # Generate offer
      {:ok, _offer} = MediaSession.generate_offer(pid)
      
      # Process answer
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 40000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """
      
      :ok = MediaSession.process_answer(pid, sdp_answer)
      
      # Check the pipeline module was set to PortAudioPipeline
      {_state_name, data} = :sys.get_state(pid)
      assert data.pipeline_module == Parrot.Media.PortAudioPipeline
      assert data.audio_source == :device
      assert data.input_device_id == 2
      
      # Clean up
      MediaSession.terminate_session(pid)
    end
    
    test "uses PortAudioPipeline for both input and output devices" do
      session_id = "test-portaudio-both-#{:rand.uniform(10000)}"
      
      # Start UAC session with both devices configured
      {:ok, pid} = MediaSessionSupervisor.start_session(
        id: session_id,
        dialog_id: "test-dialog",
        role: :uac,
        media_handler: TestHandler,
        handler_args: %{},
        supported_codecs: [:opus, :pcma],
        local_rtp_port: 30000 + :rand.uniform(10000),
        # Configure both devices
        input_device_id: 3,
        output_device_id: 4,
        audio_source: :device,
        audio_sink: :device
      )
      
      # Generate offer
      {:ok, _offer} = MediaSession.generate_offer(pid)
      
      # Process answer
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 40000 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """
      
      :ok = MediaSession.process_answer(pid, sdp_answer)
      
      # Check the pipeline module was set to PortAudioPipeline
      {_state_name, data} = :sys.get_state(pid)
      assert data.pipeline_module == Parrot.Media.PortAudioPipeline
      assert data.audio_source == :device
      assert data.audio_sink == :device
      assert data.input_device_id == 3
      assert data.output_device_id == 4
      
      # Clean up
      MediaSession.terminate_session(pid)
    end
    
    test "uses OpusPipeline when no audio devices configured (Opus codec)" do
      session_id = "test-opus-no-devices-#{:rand.uniform(10000)}"
      
      # Start UAC session without audio devices
      {:ok, pid} = MediaSessionSupervisor.start_session(
        id: session_id,
        dialog_id: "test-dialog",
        role: :uac,
        media_handler: TestHandler,
        handler_args: %{},
        supported_codecs: [:opus, :pcma],
        local_rtp_port: 30000 + :rand.uniform(10000)
        # No audio device configuration
      )
      
      # Generate offer
      {:ok, _offer} = MediaSession.generate_offer(pid)
      
      # Process answer with Opus
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 40000 RTP/AVP 111
      a=rtpmap:111 opus/48000/2
      """
      
      :ok = MediaSession.process_answer(pid, sdp_answer)
      
      # Check the pipeline module was set to OpusPipeline (NOT PortAudioPipeline)
      {_state_name, data} = :sys.get_state(pid)
      assert data.pipeline_module == Parrot.Media.OpusPipeline
      assert data.audio_source == :silence
      assert data.audio_sink == :none
      
      # Clean up
      MediaSession.terminate_session(pid)
    end
    
    test "uses AlawPipeline when no audio devices configured (PCMA codec)" do
      session_id = "test-alaw-no-devices-#{:rand.uniform(10000)}"
      
      # Start UAC session without audio devices
      {:ok, pid} = MediaSessionSupervisor.start_session(
        id: session_id,
        dialog_id: "test-dialog",
        role: :uac,
        media_handler: TestHandler,
        handler_args: %{},
        supported_codecs: [:pcma],
        local_rtp_port: 30000 + :rand.uniform(10000)
        # No audio device configuration
      )
      
      # Generate offer
      {:ok, _offer} = MediaSession.generate_offer(pid)
      
      # Process answer with PCMA
      sdp_answer = """
      v=0
      o=- 123 456 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 40000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """
      
      :ok = MediaSession.process_answer(pid, sdp_answer)
      
      # Check the pipeline module was set to AlawPipeline (NOT PortAudioPipeline)
      {_state_name, data} = :sys.get_state(pid)
      assert data.pipeline_module == Parrot.Media.AlawPipeline
      assert data.audio_source == :silence
      assert data.audio_sink == :none
      
      # Clean up
      MediaSession.terminate_session(pid)
    end
  end
end