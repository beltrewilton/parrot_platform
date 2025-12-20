defmodule ParrotExampleUas.MediaHandler do
  @moduledoc """
  Media handler for the example UAS.

  Implements ParrotMedia.Handler to handle media events during calls.
  """

  @behaviour ParrotMedia.Handler
  require Logger

  @impl true
  def init(args) do
    {:ok, args}
  end

  @impl true
  def handle_session_start(session_id, _opts, state) do
    Logger.info("Media session started: #{session_id}")
    {:ok, state}
  end

  @impl true
  def handle_session_stop(session_id, reason, state) do
    Logger.info("Media session stopped: #{session_id}, reason: #{inspect(reason)}")
    {:ok, state}
  end

  @impl true
  def handle_offer(_sdp, _direction, state) do
    {:noreply, state}
  end

  @impl true
  def handle_answer(_sdp, _direction, state) do
    {:noreply, state}
  end

  @impl true
  def handle_codec_negotiation(offered, supported, state) do
    # Pick the first mutually supported codec
    codec = Enum.find(offered, &(&1 in supported)) || hd(supported)
    {:ok, codec, state}
  end

  @impl true
  def handle_negotiation_complete(_local, _remote, codec, state) do
    Logger.info("Codec negotiated: #{codec}")
    {:ok, state}
  end

  @impl true
  def handle_stream_start(session_id, direction, state) do
    Logger.info("Stream started: #{session_id}, direction: #{direction}")
    {:noreply, state}
  end

  @impl true
  def handle_stream_stop(session_id, reason, state) do
    Logger.info("Stream stopped: #{session_id}, reason: #{inspect(reason)}")
    {:ok, state}
  end

  @impl true
  def handle_stream_error(session_id, error, state) do
    Logger.error("Stream error: #{session_id}, error: #{inspect(error)}")
    {:continue, state}
  end

  @impl true
  def handle_play_complete(file, state) do
    Logger.info("Playback complete: #{file}")
    # Loop the audio by requesting to play again
    {{:play, file}, state}
  end

  @impl true
  def handle_media_request(request, state) do
    Logger.debug("Media request: #{inspect(request)}")
    {:noreply, state}
  end
end
