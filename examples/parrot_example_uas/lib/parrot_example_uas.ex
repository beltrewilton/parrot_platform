defmodule ParrotExampleUas do
  @moduledoc """
  Example SIP application built using Parrot Framework.
  This demonstrates how to build a simple UAS (User Agent Server) that answers calls and plays audio.
  """

  use Parrot.UasHandler
  require Logger

  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 5060)

    Logger.info("Starting ParrotExampleUas on port #{port}")
    Logger.info("Connect your SIP client to sip:service@<your-ip>:#{port}")

    # Start the SIP transport with our handler
    # Handler controls logging configuration:
    # - log_level: Controls the log level for transport messages (:debug, :info, :warning, :error)
    # - sip_trace: When true, logs full SIP messages regardless of log level
    handler = Parrot.Sip.Handler.new(
      Parrot.Sip.HandlerAdapter.Core,
      {__MODULE__, %{calls: %{}}},
      log_level: :info,      # Only show info and above from transport
      sip_trace: true        # But always show full SIP messages for debugging
    )

    case Parrot.Sip.Transport.StateMachine.start_udp(%{
      handler: handler,
      listen_port: port
    }) do
      :ok ->
        Logger.info("ParrotExampleUas started successfully!")
        :ok
      {:error, {:already_started, _pid}} = error ->
        Logger.info("ParrotExampleUas already running on port #{port}")
        error
    end
  end

  # Transaction callbacks for INVITE state machine
  @impl true
  def handle_transaction_invite_trying(_request, _transaction, _state) do
    Logger.info("[ParrotExampleUas] INVITE transaction: trying")
    :noreply
  end

  @impl true
  def handle_transaction_invite_proceeding(request, _transaction, state) do
    Logger.info("[ParrotExampleUas] INVITE transaction: proceeding")
    # Process the INVITE in the proceeding state
    process_invite(request, state)
  end

  @impl true
  def handle_transaction_invite_completed(_request, _transaction, _state) do
    Logger.info("[ParrotExampleUas] INVITE transaction: completed")
    :noreply
  end

  # Main SIP method handlers
  @impl true
  def handle_invite(request, state) do
    Logger.info("[ParrotExampleUas] Direct INVITE handler called")
    process_invite(request, state)
  end

  @impl true
  def handle_ack(nil, _state), do: :noreply
  
  def handle_ack(request, _state) do
    Logger.info("[ParrotExampleUas] ACK received")

    dialog_id = Parrot.Sip.Dialog.from_message(request)
    start_media_for_dialog(dialog_id)
    :noreply
  end
  
  defp start_media_for_dialog(dialog_id) do
    with [{_pid, {media_session_id, media_pid}}] <- Registry.lookup(Parrot.Registry, {:my_app_media, dialog_id.call_id}) do
      Logger.info("[ParrotExampleUas] Starting media playback for session: #{media_session_id}")
      
      # Get the audio file path
      priv_dir = :code.priv_dir(:parrot_platform)
      audio_file = Path.join(priv_dir, "audio/parrot-welcome.wav")
      
      Task.start(fn ->
        Process.sleep(100)
        # Start the media pipeline
        Parrot.Media.MediaSession.start_media(media_session_id)
        
        # Wait a bit for the pipeline to be ready
        Process.sleep(100)
        
        # Now send the message to play the file
        Logger.info("[ParrotExampleUas] Sending play_files message to media handler")
        send(media_pid, {:play_files, [audio_file], loop: false})
      end)
    else
      [] -> Logger.warning("[ParrotExampleUas] No media session found for call: #{dialog_id.call_id}")
    end
  end

  @impl true
  def handle_bye(nil, _state), do: {:respond, 200, "OK", %{}, ""}
  
  def handle_bye(request, _state) do
    Logger.info("[ParrotExampleUas] BYE received, ending call")
    
    request
    |> Parrot.Sip.Dialog.from_message()
    |> cleanup_media_session()
    
    {:respond, 200, "OK", %{}, ""}
  end
  
  defp cleanup_media_session(dialog_id) do
    case Registry.lookup(Parrot.Registry, {:my_app_media, dialog_id.call_id}) do
      [{_pid, {media_session_id, _media_pid}}] ->
        terminate_media_session(media_session_id)
        Registry.unregister(Parrot.Registry, {:my_app_media, dialog_id.call_id})
      [] ->
        Logger.info("[ParrotExampleUas] No media session found for call: #{dialog_id.call_id}")
    end
  end
  
  defp terminate_media_session(media_session_id) do
    Logger.info("[ParrotExampleUas] Terminating media session: #{media_session_id}")
    
    try do
      Parrot.Media.MediaSession.terminate_session(media_session_id)
    rescue
      RuntimeError ->
        Logger.warning("[ParrotExampleUas] Media session #{media_session_id} already terminated")
    end
  end

  @impl true
  def handle_cancel(_request, _state) do
    Logger.info("[ParrotExampleUas] CANCEL received")
    {:respond, 200, "OK", %{}, ""}
  end

  @impl true
  def handle_options(_request, _state) do
    Logger.info("[ParrotExampleUas] OPTIONS received")
    allow_methods = "INVITE, ACK, BYE, CANCEL, OPTIONS, INFO"
    {:respond, 200, "OK", %{"Allow" => allow_methods}, ""}
  end

  @impl true
  def handle_register(_request, _state) do
    Logger.info("[ParrotExampleUas] REGISTER received")
    {:respond, 200, "OK", %{}, ""}
  end

  # This is the SIP INFO method handler
  @impl true
  def handle_info(_request, state) do
    Logger.info("[ParrotExampleUas] INFO request received")
    {:respond, 200, "OK", %{}, "", state}
  end


  defp process_invite(nil, _state) do
    Logger.error("[ParrotExampleUas] Cannot process nil INVITE")
    {:respond, 500, "Internal Server Error", %{}, ""}
  end

  defp process_invite(request, _state) do
    log_invite_from(request)
    
    dialog_id = Parrot.Sip.Dialog.from_message(request)
    dialog_id_str = Parrot.Sip.Dialog.to_string(dialog_id)
    media_session_id = "media_#{dialog_id_str}"

    with {:ok, media_pid} <- start_media_session(media_session_id, dialog_id_str),
         {:ok, sdp_answer} <- Parrot.Media.MediaSession.process_offer(media_session_id, request.body) do
      Logger.info("[ParrotExampleUas] Call accepted, SDP negotiated")
      
      # Register both the session ID and PID for later use
      Registry.register(Parrot.Registry, {:my_app_media, dialog_id.call_id}, {media_session_id, media_pid})
      
      {:respond, 200, "OK", %{}, sdp_answer}
    else
      {:error, :sdp_negotiation_failed = reason} ->
        Logger.error("[ParrotExampleUas] SDP negotiation failed: #{inspect(reason)}")
        {:respond, 488, "Not Acceptable Here", %{}, ""}
      {:error, reason} ->
        Logger.error("[ParrotExampleUas] Failed to create media session: #{inspect(reason)}")
        {:respond, 500, "Internal Server Error", %{}, ""}
    end
  end
  
  defp log_invite_from(%{headers: %{"from" => from}}) do
    caller = from.display_name || from.uri.user
    Logger.info("[ParrotExampleUas] Processing INVITE from: #{caller}")
  end
  
  defp start_media_session(session_id, dialog_id) do
    Parrot.Media.MediaSessionSupervisor.start_session(
      id: session_id,
      dialog_id: dialog_id,
      role: :uas,
      owner: self(),
      media_handler: ParrotExampleUas.MediaHandler,
      handler_args: %{},  # No initial configuration needed
      supported_codecs: [:opus, :pcma],  # Prefer OPUS, fallback to G.711 A-law
      # IP configuration - defaults to auto-detect
      # Configure as needed for your network environment:
      local_ip: :auto  # Use :auto or specify IP like "192.168.1.100"
      # advertised_ip: "203.0.113.1"  # Uncomment for NAT scenarios
    )
  end

end
