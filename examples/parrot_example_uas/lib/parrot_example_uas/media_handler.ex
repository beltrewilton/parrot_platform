defmodule ParrotExampleUas.MediaHandler do
  @moduledoc """
  Media handler implementation for the example UAS application.

  This module demonstrates the new callback-based MediaHandler pattern
  with message-driven media control.
  """

  @behaviour Parrot.MediaHandler
  require Logger

  @impl Parrot.MediaHandler
  def init(_args) do
    Logger.info("[ParrotExampleUas MediaHandler] Initializing")
    # Initialize with clean state - no files configured
    state = %{
      current_state: :init,
      audio_queue: [],
      looping: false,
      files_played: []
    }

    {:ok, state}
  end

  @impl Parrot.MediaHandler
  def handle_session_start(session_id, opts, state) do
    Logger.info("[ParrotExampleUas MediaHandler] Session started: #{session_id}")
    Logger.info("  Options: #{inspect(opts)}")
    {:ok, state}
  end

  @impl Parrot.MediaHandler
  def handle_session_stop(session_id, reason, state) do
    Logger.info(
      "[ParrotExampleUas MediaHandler] Session stopped: #{session_id}, reason: #{inspect(reason)}"
    )

    {:ok, state}
  end

  @impl Parrot.MediaHandler
  def handle_offer(sdp, direction, state) do
    Logger.info("[ParrotExampleUas MediaHandler] Received SDP offer (#{direction})")
    Logger.debug("  SDP: #{String.trim(sdp)}")
    {:noreply, state}
  end

  @impl Parrot.MediaHandler
  def handle_answer(sdp, direction, state) do
    Logger.info("[ParrotExampleUas MediaHandler] Received SDP answer (#{direction})")
    Logger.debug("  SDP: #{String.trim(sdp)}")
    {:noreply, state}
  end

  @impl Parrot.MediaHandler
  def handle_codec_negotiation(offered_codecs, supported_codecs, state) do
    Logger.info("[ParrotExampleUas MediaHandler] Negotiating codecs")
    Logger.info("  Offered: #{inspect(offered_codecs)}")
    Logger.info("  Supported: #{inspect(supported_codecs)}")

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
    Logger.info("[ParrotExampleUas MediaHandler] Negotiation complete with codec: #{codec}")
    {:ok, Map.put(state, :negotiated_codec, codec)}
  end

  @impl Parrot.MediaHandler
  def handle_stream_start(session_id, direction, state) do
    Logger.info("[ParrotExampleUas MediaHandler] Stream started for #{session_id} (#{direction})")

    # Just mark as ready - no automatic playback
    # Files will only play when explicitly requested via messages
    {:noreply, %{state | current_state: :ready}}
  end

  @impl Parrot.MediaHandler
  def handle_stream_stop(session_id, reason, state) do
    Logger.info(
      "[ParrotExampleUas MediaHandler] Stream stopped for #{session_id}, reason: #{inspect(reason)}"
    )

    {:ok, state}
  end

  @impl Parrot.MediaHandler
  def handle_stream_error(session_id, error, state) do
    Logger.error(
      "[ParrotExampleUas MediaHandler] Stream error for #{session_id}: #{inspect(error)}"
    )

    # Continue playing despite errors
    {:continue, state}
  end

  @impl Parrot.MediaHandler
  def handle_play_complete(audio_file, handler_state) do
    Logger.info("[ParrotExampleUas MediaHandler] Playback complete for file: #{audio_file}")

    # Check if we have more files in the queue
    case handler_state.audio_queue do
      [_completed | rest] when rest != [] ->
        # Continue with next file in queue
        {:noreply, %{handler_state | audio_queue: rest}}

      _ ->
        # Queue empty, clear it
        {:noreply, %{handler_state | audio_queue: []}}
    end
  end

  # Pattern matching for play_files with loop option
  @impl Parrot.MediaHandler
  def handle_info({:play_files, files, [loop: true]}, state) do
    Logger.info("[ParrotExampleUas MediaHandler] Received play_files request (loop mode)")
    Logger.info("  Files: #{inspect(files)}")

    existing_files = validate_files(files)
    handle_loop_playback(existing_files, state)
  end

  @impl Parrot.MediaHandler
  def handle_info({:play_files, files, opts}, state) when is_list(opts) do
    Logger.info("[ParrotExampleUas MediaHandler] Received play_files request")
    Logger.info("  Files: #{inspect(files)}")
    Logger.info("  Options: #{inspect(opts)}")

    existing_files = validate_files(files)
    handle_sequence_playback(existing_files, state)
  end

  @impl Parrot.MediaHandler
  def handle_info({:stop_playback}, state) do
    Logger.info("[ParrotExampleUas MediaHandler] Stopping playback")
    {[:stop], %{state | current_state: :stopped, audio_queue: []}}
  end

  @impl Parrot.MediaHandler
  def handle_info(msg, state) do
    Logger.debug("[ParrotExampleUas MediaHandler] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helper functions

  defp select_best_codec(offered, supported) do
    # Codec preference order
    [:opus, :pcmu, :pcma]
    |> Enum.find(&(&1 in offered and &1 in supported))
    |> Kernel.||(find_any_common_codec(offered, supported))
  end

  defp find_any_common_codec(offered, supported) do
    Enum.find(offered, &(&1 in supported))
  end

  defp validate_files(files) do
    Enum.filter(files, fn file ->
      exists = File.exists?(file)
      unless exists, do: Logger.warning("  File not found: #{file}")
      exists
    end)
  end

  defp handle_loop_playback([], state) do
    Logger.warning("  No valid files to play")
    {[], state}
  end

  defp handle_loop_playback(files, state) do
    Logger.info("  Playing files in loop mode")
    {[{:play_loop, files}], %{state | audio_queue: files, current_state: :playing}}
  end

  defp handle_sequence_playback([], state) do
    Logger.warning("  No valid files to play")
    {[], state}
  end

  defp handle_sequence_playback(files, state) do
    Logger.info("  Playing files in sequence")
    {[{:play_sequence, files}], %{state | audio_queue: files, current_state: :playing}}
  end
end
