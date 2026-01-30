defmodule ParrotMedia.Test.TestMediaHandler do
  @moduledoc """
  Simple media handler for testing MediaSession functionality.
  """
  @behaviour ParrotMedia.Handler

  def init(args) do
    {:ok, args}
  end

  def handle_session_start(_session_id, _opts, state) do
    {:ok, state}
  end

  def handle_offer(_sdp, _direction, state) do
    {:noreply, state}
  end

  def handle_answer(_sdp, _direction, state) do
    {:ok, state}
  end

  def handle_stream_start(_session_id, _direction, state) do
    {:noreply, state}
  end

  def handle_stream_stop(_reason, state) do
    {:ok, state}
  end

  def handle_dtmf(_digit, state) do
    {:noreply, state}
  end

  def handle_play_complete(_file, state) do
    {:noreply, state}
  end

  def handle_record_complete(_file, state) do
    {:noreply, state}
  end

  def handle_error(_error, state) do
    {:noreply, state}
  end

  def handle_codec_negotiation(offered, supported, state) do
    # Pick the first common codec, or return error if none found
    case Enum.find(supported, fn c -> c in offered end) do
      nil -> {:error, :no_common_codec, state}
      codec -> {:ok, codec, state}
    end
  end

  def handle_negotiation_complete(_answer, _offer, _codec, state) do
    {:ok, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
