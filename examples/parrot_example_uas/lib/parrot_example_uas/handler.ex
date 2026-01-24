defmodule ParrotExampleUas.Handler do
  @moduledoc """
  UA Handler for the example UAS.

  This handler implements the ParrotSip.UA.Handler behaviour to handle
  incoming SIP calls and integrate with ParrotMedia for audio playback.
  """

  use ParrotSip.UA.Handler
  require Logger

  alias ParrotSip.UA
  alias ParrotMedia.MediaSession

  defstruct [:server_pid, :audio_file, :media_sessions]

  # ============================================================================
  # UA.Handler Callbacks
  # ============================================================================

  @impl true
  def init({server_pid, audio_file}) do
    Logger.info("ParrotExampleUas.Handler initialized")
    {:ok, %__MODULE__{
      server_pid: server_pid,
      audio_file: audio_file,
      media_sessions: %{}
    }}
  end

  @impl true
  def handle_incoming(ua, invite, entity, state) do
    Logger.info("Incoming call from: #{entity.remote_uri}")
    Logger.info("  Call-ID: #{entity.call_id}")

    # Extract remote SDP from the INVITE
    remote_sdp = invite.body

    # Create a media session for this call
    session_id = "media_#{entity.id}"

    case start_media_session(session_id, entity, remote_sdp, state) do
      {:ok, media_session, local_sdp} ->
        Logger.info("Media session created, answering call")

        # Answer the call with our SDP
        UA.answer(ua, entity, sdp: local_sdp)

        # Start media playback
        MediaSession.start_media(media_session)

        # Track the media session
        media_sessions = Map.put(state.media_sessions, entity.id, media_session)

        # Notify server
        GenServer.cast(state.server_pid, {:call_started, entity, media_session})

        {:ok, %{state | media_sessions: media_sessions}}

      {:error, reason} ->
        Logger.error("Failed to create media session: #{inspect(reason)}")
        # Reject the call
        UA.reject(ua, entity, 503, "Service Unavailable")
        {:ok, state}
    end
  end

  @impl true
  def handle_answered(_ua, _response, _entity, state) do
    # Not used for UAS - we are the one sending the answer
    {:ok, state}
  end

  @impl true
  def handle_hangup(_ua, _message, entity, state) do
    Logger.info("Call ended: #{entity.call_id}")

    # Stop the media session
    case Map.get(state.media_sessions, entity.id) do
      nil ->
        :ok

      media_session ->
        MediaSession.terminate_session(media_session)
    end

    media_sessions = Map.delete(state.media_sessions, entity.id)

    # Notify server
    GenServer.cast(state.server_pid, {:call_ended, entity.id})

    {:ok, %{state | media_sessions: media_sessions}}
  end

  @impl true
  def handle_cancel(_ua, entity, state) do
    Logger.info("Call cancelled: #{entity.call_id}")

    # Stop the media session if it exists
    case Map.get(state.media_sessions, entity.id) do
      nil -> :ok
      media_session -> MediaSession.terminate_session(media_session)
    end

    media_sessions = Map.delete(state.media_sessions, entity.id)
    GenServer.cast(state.server_pid, {:call_ended, entity.id})

    {:ok, %{state | media_sessions: media_sessions}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp start_media_session(session_id, entity, remote_sdp, state) do
    Logger.info("Starting media session: #{session_id}")

    {:ok, media_session} = MediaSession.start_link(
      id: session_id,
      dialog_id: entity.call_id,
      role: :uas,
      media_handler: ParrotExampleUas.MediaHandler,
      handler_args: %{entity_id: entity.id},
      supported_codecs: [:pcma],
      audio_file: state.audio_file
    )

    # Process the remote SDP offer and get our answer
    case MediaSession.process_offer(media_session, remote_sdp) do
      {:ok, local_sdp} ->
        {:ok, media_session, local_sdp}

      {:error, reason} ->
        MediaSession.terminate_session(media_session)
        {:error, reason}
    end
  end
end
