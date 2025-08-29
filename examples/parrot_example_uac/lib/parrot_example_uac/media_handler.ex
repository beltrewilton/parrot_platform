defmodule ParrotExampleUac.MediaHandler do
  @moduledoc """
  Media handler implementation for the UAC example application.
  
  This handler manages bidirectional audio streaming using PortAudio devices:
  - Captures audio from the microphone (audio_source: :device)
  - Plays received audio through speakers (audio_sink: :device)
  
  Unlike the UAS handler, this does NOT handle file playback.
  It's designed for real-time bidirectional communication.
  """
  
  @behaviour Parrot.MediaHandler
  require Logger
  
  @impl Parrot.MediaHandler
  def init(_args) do
    Logger.info("[UAC MediaHandler] Initializing")
    state = %{
      session_active: false,
      stream_direction: nil,
      negotiated_codec: nil,
      device_info: %{
        input_device: nil,
        output_device: nil
      }
    }
    
    {:ok, state}
  end
  
  @impl Parrot.MediaHandler
  def handle_session_start(session_id, opts, state) do
    Logger.info("[UAC MediaHandler] Session started: #{session_id}")
    Logger.debug("  Options: #{inspect(opts)}")
    
    # Store device info if provided
    updated_state = %{state | 
      session_active: true,
      device_info: %{
        input_device: opts[:input_device_id],
        output_device: opts[:output_device_id]
      }
    }
    
    {:ok, updated_state}
  end
  
  @impl Parrot.MediaHandler
  def handle_session_stop(session_id, reason, state) do
    Logger.info("[UAC MediaHandler] Session stopped: #{session_id}, reason: #{inspect(reason)}")
    {:ok, %{state | session_active: false}}
  end
  
  @impl Parrot.MediaHandler
  def handle_offer(sdp, direction, state) do
    Logger.info("[UAC MediaHandler] Generated SDP offer (#{direction})")
    Logger.debug("  SDP: #{String.trim(sdp)}")
    {:noreply, state}
  end
  
  @impl Parrot.MediaHandler
  def handle_answer(sdp, direction, state) do
    Logger.info("[UAC MediaHandler] Received SDP answer (#{direction})")
    Logger.debug("  SDP: #{String.trim(sdp)}")
    {:noreply, state}
  end
  
  @impl Parrot.MediaHandler
  def handle_codec_negotiation(offered_codecs, supported_codecs, state) do
    Logger.info("[UAC MediaHandler] Negotiating codecs")
    Logger.info("  Offered: #{inspect(offered_codecs)}")
    Logger.info("  Supported: #{inspect(supported_codecs)}")
    
    # Prefer OPUS for better quality, fallback to PCMU/PCMA
    codec = select_best_codec(offered_codecs, supported_codecs)
    
    case codec do
      nil ->
        Logger.error("  No common codec found!")
        {:error, :no_common_codec, state}
      _ ->
        Logger.info("  Selected codec: #{codec}")
        {:ok, codec, state}
    end
  end
  
  @impl Parrot.MediaHandler
  def handle_negotiation_complete(_local_sdp, _remote_sdp, codec, state) do
    Logger.info("[UAC MediaHandler] Negotiation complete with codec: #{codec}")
    {:ok, %{state | negotiated_codec: codec}}
  end
  
  @impl Parrot.MediaHandler
  def handle_stream_start(session_id, direction, state) do
    Logger.info("[UAC MediaHandler] Audio stream started for #{session_id} (#{direction})")
    Logger.info("  Microphone ? Network (sending)")
    Logger.info("  Network ? Speaker (receiving)")
    
    # For UAC with devices, we just let the audio flow through
    # No actions needed - PortAudio handles the device I/O
    {:noreply, %{state | stream_direction: direction}}
  end
  
  @impl Parrot.MediaHandler
  def handle_stream_stop(session_id, reason, state) do
    Logger.info("[UAC MediaHandler] Audio stream stopped for #{session_id}, reason: #{inspect(reason)}")
    {:ok, %{state | stream_direction: nil}}
  end
  
  @impl Parrot.MediaHandler
  def handle_stream_error(session_id, error, state) do
    Logger.error("[UAC MediaHandler] Stream error for #{session_id}: #{inspect(error)}")
    # Continue despite errors for resilience
    {:continue, state}
  end
  
  @impl Parrot.MediaHandler
  def handle_play_complete(_audio_file, state) do
    # This shouldn't be called for UAC since we don't play files
    Logger.warning("[UAC MediaHandler] Unexpected play_complete callback")
    {:noreply, state}
  end
  
  @impl Parrot.MediaHandler
  def handle_info({:use_audio_devices, opts}, state) when is_list(opts) do
    input = Keyword.get(opts, :input)
    output = Keyword.get(opts, :output)
    
    Logger.info("[UAC MediaHandler] Enabling audio devices - input: #{inspect(input)}, output: #{inspect(output)}")
    
    # Return the connect_audio_device action for MediaSession to process
    {[{:connect_audio_device, input, output}], state}
  end
  
  @impl Parrot.MediaHandler
  def handle_info({:use_microphone, device_id}, state) do
    Logger.info("[UAC MediaHandler] Enabling microphone: #{inspect(device_id)}")
    {[{:connect_audio_device, device_id, nil}], state}
  end
  
  @impl Parrot.MediaHandler
  def handle_info({:use_speaker, device_id}, state) do
    Logger.info("[UAC MediaHandler] Enabling speaker: #{inspect(device_id)}")
    {[{:connect_audio_device, nil, device_id}], state}
  end
  
  @impl Parrot.MediaHandler
  def handle_info(:release_audio_devices, state) do
    Logger.info("[UAC MediaHandler] Releasing audio devices")
    {[{:connect_audio_device, nil, nil}], state}
  end
  
  @impl Parrot.MediaHandler
  def handle_info(msg, state) do
    Logger.debug("[UAC MediaHandler] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
  
  # Private helper functions
  
  defp select_best_codec(offered, supported) do
    # Codec preference order for voice communication
    [:opus, :pcmu, :pcma]
    |> Enum.find(&(&1 in offered and &1 in supported))
    |> Kernel.||(find_any_common_codec(offered, supported))
  end
  
  defp find_any_common_codec(offered, supported) do
    Enum.find(offered, &(&1 in supported))
  end
end
