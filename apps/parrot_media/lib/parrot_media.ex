defmodule ParrotMedia do
  @moduledoc """
  Media handling for RTP streams and SDP negotiation.

  This module provides the main API for media operations including:
  - RTP packet handling
  - SDP offer/answer generation
  - Media session management
  - Codec negotiation
  """

  @doc """
  Starts a media session.

  ## Options
    * `:id` - Unique session identifier
    * `:role` - Either `:uac` or `:uas`
    * `:media_handler` - Module implementing media handler behavior
    * `:handler_args` - Arguments for the media handler
  """
  def start_session(opts) do
    ParrotMedia.MediaSessionSupervisor.start_session(opts)
  end

  @doc """
  Stops a media session.
  """
  def stop_session(session_id) do
    ParrotMedia.MediaSessionSupervisor.stop_session(session_id)
  end

  @doc """
  Generates an SDP offer for a media session.
  """
  def generate_offer(session_id, opts \\ []) do
    GenServer.call(via_tuple(session_id), {:generate_offer, opts})
  end

  @doc """
  Processes an SDP offer and generates an answer.
  """
  def process_offer(session_id, sdp_offer) do
    GenServer.call(via_tuple(session_id), {:process_offer, sdp_offer})
  end

  @doc """
  Processes an SDP answer.
  """
  def process_answer(session_id, sdp_answer) do
    GenServer.call(via_tuple(session_id), {:process_answer, sdp_answer})
  end

  @doc """
  Starts media flow for a session.
  """
  def start_media(session_id) do
    GenServer.call(via_tuple(session_id), :start_media)
  end

  @doc """
  Stops media flow for a session.
  """
  def stop_media(session_id) do
    GenServer.call(via_tuple(session_id), :stop_media)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {ParrotMedia.Registry, {:media_session, session_id}}}
  end
end
