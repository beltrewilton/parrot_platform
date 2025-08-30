defmodule ParrotExampleUas.SipHandler do
  @moduledoc """
  SIP Handler for the UAS (User Agent Server).
  
  This module handles incoming SIP protocol events for a server that
  receives calls. Unlike the UAC handler, this one actually processes
  incoming requests like INVITE, ACK, and BYE.
  
  ## Main Responsibilities
  
  - Processing incoming INVITE requests
  - Handling ACK to complete call setup
  - Processing BYE to terminate calls
  - Managing SIP dialog state
  
  The handler works in conjunction with the MediaHandler to coordinate
  SIP signaling with media session management.
  """
  
  require Logger
  
  alias Parrot.Sip.Message
  alias Parrot.Sip.Headers.{Via, Contact, To}
  alias Parrot.Media.{MediaSession, MediaSessionSupervisor}
  
  @doc """
  Handles incoming SIP requests (INVITE, ACK, BYE, etc.).
  This is the main entry point for UAS functionality.
  """
  def transp_request(%Message{type: :request} = request, _owner_pid) do
    case request.method do
      :invite ->
        handle_invite(request)
      
      :ack ->
        handle_ack(request)
      
      :bye ->
        handle_bye(request)
      
      :cancel ->
        handle_cancel(request)
      
      :options ->
        handle_options(request)
      
      method ->
        Logger.warning("UAS SipHandler: Unhandled #{method} request")
        :ignore
    end
  end
  
  @doc """
  Handles SIP responses. UAS typically doesn't process responses.
  """
  def transp_response(_msg, _owner_pid) do
    # UAS doesn't typically handle responses
    :ignore
  end
  
  @doc """
  Handles transport errors.
  """
  def transp_error(error, reason, _owner_pid) do
    Logger.error("UAS SipHandler: Transport error: #{inspect(error)}, reason: #{inspect(reason)}")
    :ok
  end
  
  # Private functions for handling specific request types
  
  defp handle_invite(request) do
    Logger.info("UAS SipHandler: Processing INVITE from #{get_caller(request)}")
    
    dialog_id = Parrot.Sip.Dialog.from_message(request)
    dialog_id_str = Parrot.Sip.Dialog.to_string(dialog_id)
    media_session_id = "media_#{dialog_id_str}"
    
    # Start media session and process SDP offer
    with {:ok, media_pid} <- start_media_session(media_session_id, dialog_id_str),
         {:ok, sdp_answer} <- MediaSession.process_offer(media_session_id, request.body) do
      
      Logger.info("UAS SipHandler: Call accepted, SDP negotiated")
      
      # Register the session for later use (e.g., when ACK arrives)
      Registry.register(
        Parrot.Registry,
        {:uas_media, dialog_id.call_id},
        {media_session_id, media_pid}
      )
      
      # Send 200 OK with SDP answer
      {:respond, 200, "OK", %{}, sdp_answer}
    else
      {:error, :sdp_negotiation_failed} ->
        Logger.error("UAS SipHandler: SDP negotiation failed")
        {:respond, 488, "Not Acceptable Here", %{}, ""}
      
      {:error, reason} ->
        Logger.error("UAS SipHandler: Failed to create media session: #{inspect(reason)}")
        {:respond, 500, "Internal Server Error", %{}, ""}
    end
  end
  
  defp handle_ack(request) do
    Logger.info("UAS SipHandler: ACK received")
    
    dialog_id = Parrot.Sip.Dialog.from_message(request)
    
    # Start media streaming
    case Registry.lookup(Parrot.Registry, {:uas_media, dialog_id.call_id}) do
      [{_pid, {media_session_id, media_pid}}] ->
        Logger.info("UAS SipHandler: Starting media for session: #{media_session_id}")
        
        # Start the media pipeline
        MediaSession.start_media(media_session_id)
        
        # Send message to play welcome audio
        Task.start(fn ->
          Process.sleep(100)  # Small delay to ensure pipeline is ready
          
          priv_dir = :code.priv_dir(:parrot_platform)
          audio_file = Path.join(priv_dir, "audio/parrot-welcome.wav")
          
          Logger.info("UAS SipHandler: Sending play_files message to media handler")
          send(media_pid, {:play_files, [audio_file], loop: false})
        end)
      
      [] ->
        Logger.warning("UAS SipHandler: No media session found for ACK")
    end
    
    :noreply
  end
  
  defp handle_bye(request) do
    Logger.info("UAS SipHandler: BYE received")
    
    dialog_id = Parrot.Sip.Dialog.from_message(request)
    
    # Stop media session
    case Registry.lookup(Parrot.Registry, {:uas_media, dialog_id.call_id}) do
      [{_pid, {media_session_id, _media_pid}}] ->
        Logger.info("UAS SipHandler: Terminating media session: #{media_session_id}")
        MediaSession.terminate_session(media_session_id)
        Registry.unregister(Parrot.Registry, {:uas_media, dialog_id.call_id})
      
      [] ->
        Logger.warning("UAS SipHandler: No media session found for BYE")
    end
    
    # Send 200 OK response to BYE
    {:respond, 200, "OK", %{}, ""}
  end
  
  defp handle_cancel(request) do
    Logger.info("UAS SipHandler: CANCEL received")
    
    # Clean up any pending INVITE transaction
    # In a real implementation, you'd cancel the INVITE transaction
    
    {:respond, 200, "OK", %{}, ""}
  end
  
  defp handle_options(request) do
    Logger.info("UAS SipHandler: OPTIONS received")
    
    # Respond with capabilities
    headers = %{
      "allow" => "INVITE, ACK, BYE, CANCEL, OPTIONS",
      "accept" => "application/sdp",
      "supported" => "replaces, timer"
    }
    
    {:respond, 200, "OK", headers, ""}
  end
  
  # Helper functions
  
  defp get_caller(%{headers: %{"from" => from}}) do
    from.display_name || from.uri.user || "Unknown"
  end
  
  defp start_media_session(session_id, dialog_id) do
    MediaSessionSupervisor.start_session(
      id: session_id,
      dialog_id: dialog_id,
      role: :uas,
      owner: self(),
      media_handler: ParrotExampleUas.MediaHandler,
      handler_args: %{},
      supported_codecs: [:opus, :pcma],
      local_ip: :auto
    )
  end
  
  # Required callbacks for the handler behaviour
  def process_ack(_msg, _state), do: :ignore
  def transaction(_event, _id, _state), do: :ignore
  def transaction_stop(_event, _id, _state), do: :ignore
  def uas_cancel(_msg, _state), do: :ignore
  def uas_request(_msg, _dialog_id, _state), do: :ignore
end