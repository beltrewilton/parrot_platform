defmodule Parrot.DSL.MediaHandler do
  @moduledoc """
  Default media handler for the Parrot DSL layer.

  This module implements the `ParrotMedia.Handler` behaviour and provides
  a simple media handler that:
  - Accepts silence as audio source (no incoming media processing)
  - Can play audio files when requested
  - Supports media forking for ASR/transcription

  ## Usage

  This handler is automatically used by the Bridge.Handler when setting up
  MediaSession for incoming calls. You don't need to interact with it directly.

  ## Media Operations

  The handler responds to these messages:
  - `{:play_files, [file_list], opts}` - Play audio files
  - `:stop_playback` - Stop current playback
  - `:stop` - Stop the media handler
  """

  @behaviour ParrotMedia.Handler

  require Logger

  # Codecs we have pipelines for in ParrotMedia
  # - :pcmu (G.711 mu-law) -> AlawPipeline (TODO: should be UlawPipeline)
  # - :pcma (G.711 A-law)  -> AlawPipeline
  # - :opus                -> OpusPipeline
  @supported_codecs [:pcmu, :pcma, :opus]

  # ===========================================================================
  # Required Callbacks
  # ===========================================================================

  @impl true
  def init(args) do
    Logger.debug("[DSL.MediaHandler] Initializing with args: #{inspect(args)}")
    {:ok, %{call_id: Map.get(args, :call_id), playing: false}}
  end

  @impl true
  def handle_session_start(_session_id, _opts, state) do
    Logger.debug("[DSL.MediaHandler] Session started")
    {:ok, state}
  end

  @impl true
  def handle_codec_negotiation(offered_codecs, _session_config, state) do
    # Find first offered codec that we actually support (have pipelines for)
    Logger.debug("[DSL.MediaHandler] Codec negotiation: offered=#{inspect(offered_codecs)}, supported=#{inspect(@supported_codecs)}")

    case Enum.find(offered_codecs, &(&1 in @supported_codecs)) do
      nil ->
        Logger.warning("[DSL.MediaHandler] No common codec: offered=#{inspect(offered_codecs)}")
        {:error, :no_common_codec, state}

      codec ->
        Logger.debug("[DSL.MediaHandler] Selected codec: #{inspect(codec)}")
        {:ok, codec, state}
    end
  end

  @impl true
  def handle_negotiation_complete(_local_sdp, _remote_sdp, _selected_codec, state) do
    Logger.debug("[DSL.MediaHandler] Negotiation complete")
    {:ok, state}
  end

  @impl true
  def handle_stream_start(_session_id, _direction, state) do
    Logger.debug("[DSL.MediaHandler] Stream started")
    {:noreply, state}
  end

  # ===========================================================================
  # SDP Negotiation Callbacks
  # ===========================================================================

  @impl true
  def handle_offer(_sdp_offer, _direction, state) do
    # Accept the offer as-is (no modification needed)
    Logger.debug("[DSL.MediaHandler] Handling SDP offer")
    {:noreply, state}
  end

  # ===========================================================================
  # Optional Callbacks (implemented for media control)
  # ===========================================================================

  @impl true
  def handle_play_complete(file, state) do
    Logger.debug("[DSL.MediaHandler] Play complete: #{file}")
    # Return :idle to keep the pipeline alive for DTMF collection and other operations.
    # Without :idle, the SwitchableFileSource emits end_of_stream which terminates the
    # entire pipeline, making it impossible to receive DTMF after playing a prompt.
    {:idle, %{state | playing: false}}
  end

  @impl true
  def handle_info({:play_files, files, opts}, state) do
    Logger.debug("[DSL.MediaHandler] Play files: #{inspect(files)} opts: #{inspect(opts)}")

    if Keyword.get(opts, :loop, false) do
      {[{:play_loop, files}], %{state | playing: true}}
    else
      {[{:play_sequence, files}], %{state | playing: true}}
    end
  end

  @impl true
  def handle_info(:stop_playback, state) do
    Logger.debug("[DSL.MediaHandler] Stop playback")
    {[:stop], %{state | playing: false}}
  end

  @impl true
  def handle_info({:start_media}, state) do
    Logger.debug("[DSL.MediaHandler] Start media")
    {:noreply, state}
  end

  @impl true
  def handle_info({:stop_media}, state) do
    Logger.debug("[DSL.MediaHandler] Stop media")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[DSL.MediaHandler] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
