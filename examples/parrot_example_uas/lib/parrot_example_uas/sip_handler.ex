defmodule ParrotExampleUas.SipHandler do
  @moduledoc """
  SIP Handler for the UAS (User Agent Server).
  
  This module handles incoming SIP protocol events for a server that
  receives calls. It processes INVITE, ACK, BYE, and other SIP methods.
  
  ## Main Responsibilities
  
  - Processing incoming INVITE requests and generating SDP answers
  - Handling ACK to complete call setup and start media
  - Processing BYE to terminate calls
  - Managing SIP dialog state
  - Coordinating with MediaHandler for audio playback
  """
  
  use Parrot.UasHandler
  require Logger
  
  alias Parrot.Media.{MediaSession, MediaSessionSupervisor}
  alias ParrotExampleUas.MediaHandler
  
  # Transaction callbacks for INVITE state machine
  @impl true
  def handle_transaction_invite_trying(_request, _transaction, _state) do
    Logger.info("[UAS SipHandler] INVITE transaction: trying")
    :noreply
  end
  
  @impl true
  def handle_transaction_invite_proceeding(request, _transaction, state) do
    Logger.info("[UAS SipHandler] INVITE transaction: proceeding")
    # Process the INVITE in the proceeding state
    process_invite(request, state)
  end
  
  @impl true
  def handle_transaction_invite_completed(_request, _transaction, _state) do
    Logger.info("[UAS SipHandler] INVITE transaction: completed")
    :noreply
  end
  
  # Main SIP method handlers
  @impl true
  def handle_invite(request, state) do
    Logger.info("[UAS SipHandler] Direct INVITE handler called")
    process_invite(request, state)
  end
  
  @impl true
  def handle_ack(nil, _state), do: :noreply
  
  def handle_ack(request, _state) do
    Logger.info("[UAS SipHandler] ACK received")
    
    dialog_id = Parrot.Sip.Dialog.from_message(request)
    start_media_for_dialog(dialog_id)
    :noreply
  end
  
  @impl true
  def handle_bye(nil, _state), do: {:respond, 200, "OK", %{}, ""}
  
  def handle_bye(request, state) do
    Logger.info("[UAS SipHandler] BYE received, ending call")
    
    dialog_id = Parrot.Sip.Dialog.from_message(request)
    cleanup_media_session(dialog_id)
    
    # Notify parent process if configured
    if parent = state[:parent] do
      send(parent, {:call_ended, dialog_id.call_id})
    end
    
    {:respond, 200, "OK", %{}, ""}
  end
  
  @impl true
  def handle_cancel(_request, _state) do
    Logger.info("[UAS SipHandler] CANCEL received")
    {:respond, 200, "OK", %{}, ""}
  end
  
  @impl true
  def handle_options(_request, _state) do
    Logger.info("[UAS SipHandler] OPTIONS received")
    allow_methods = "INVITE, ACK, BYE, CANCEL, OPTIONS, INFO"
    {:respond, 200, "OK", %{"Allow" => allow_methods}, ""}
  end
  
  @impl true
  def handle_register(_request, _state) do
    Logger.info("[UAS SipHandler] REGISTER received")
    {:respond, 200, "OK", %{}, ""}
  end
  
  # This is the SIP INFO method handler
  @impl true
  def handle_info(_request, state) do
    Logger.info("[UAS SipHandler] INFO request received")
    {:respond, 200, "OK", %{}, "", state}
  end
  
  # Private functions
  
  defp process_invite(nil, _state) do
    Logger.error("[UAS SipHandler] Cannot process nil INVITE")
    {:respond, 500, "Internal Server Error", %{}, ""}
  end
  
  defp process_invite(request, state) do
    log_invite_from(request)
    
    dialog_id = Parrot.Sip.Dialog.from_message(request)
    dialog_id_str = Parrot.Sip.Dialog.to_string(dialog_id)
    media_session_id = "media_#{dialog_id_str}"
    
    with {:ok, media_pid} <- start_media_session(media_session_id, dialog_id_str),
         {:ok, sdp_answer} <- MediaSession.process_offer(media_session_id, request.body) do
      
      Logger.info("[UAS SipHandler] Call accepted, SDP negotiated")
      
      # Register the session for later use (e.g., when ACK arrives)
      Registry.register(
        Parrot.Registry,
        {:uas_media, dialog_id.call_id},
        {media_session_id, media_pid}
      )
      
      # Notify parent process if configured
      if parent = state[:parent] do
        send(parent, {:call_started, dialog_id.call_id, media_session_id})
      end
      
      {:respond, 200, "OK", %{}, sdp_answer}
    else
      {:error, :sdp_negotiation_failed} ->
        Logger.error("[UAS SipHandler] SDP negotiation failed")
        {:respond, 488, "Not Acceptable Here", %{}, ""}
      
      {:error, reason} ->
        Logger.error("[UAS SipHandler] Failed to create media session: #{inspect(reason)}")
        {:respond, 500, "Internal Server Error", %{}, ""}
    end
  end
  
  defp log_invite_from(%{headers: %{"from" => from}}) do
    caller = from.display_name || from.uri.user || "Unknown"
    Logger.info("[UAS SipHandler] Processing INVITE from: #{caller}")
  end
  
  defp start_media_session(session_id, dialog_id) do
    MediaSessionSupervisor.start_session(
      id: session_id,
      dialog_id: dialog_id,
      role: :uas,
      owner: self(),
      media_handler: MediaHandler,
      handler_args: %{},
      supported_codecs: [:opus, :pcma],
      local_ip: :auto
    )
  end
  
  defp start_media_for_dialog(dialog_id) do
    with [{_pid, {media_session_id, media_pid}}] <-
           Registry.lookup(Parrot.Registry, {:uas_media, dialog_id.call_id}) do
      Logger.info("[UAS SipHandler] Starting media for session: #{media_session_id}")
      
      # Get the audio file path
      priv_dir = :code.priv_dir(:parrot_platform)
      audio_file = Path.join(priv_dir, "audio/parrot-welcome.wav")
      
      Task.start(fn ->
        # Start the media pipeline
        MediaSession.start_media(media_session_id)
        
        # Send message to play the file
        Logger.info("[UAS SipHandler] Sending play_files message to media handler")
        send(media_pid, {:play_files, [audio_file], loop: true})
      end)
    else
      [] ->
        Logger.warning("[UAS SipHandler] No media session found for call: #{dialog_id.call_id}")
    end
  end
  
  defp cleanup_media_session(dialog_id) do
    case Registry.lookup(Parrot.Registry, {:uas_media, dialog_id.call_id}) do
      [{_pid, {media_session_id, _media_pid}}] ->
        terminate_media_session(media_session_id)
        Registry.unregister(Parrot.Registry, {:uas_media, dialog_id.call_id})
      
      [] ->
        Logger.info("[UAS SipHandler] No media session found for call: #{dialog_id.call_id}")
    end
  end
  
  defp terminate_media_session(media_session_id) do
    Logger.info("[UAS SipHandler] Terminating media session: #{media_session_id}")
    
    try do
      MediaSession.terminate_session(media_session_id)
    rescue
      RuntimeError ->
        Logger.warning("[UAS SipHandler] Media session #{media_session_id} already terminated")
    end
  end
end