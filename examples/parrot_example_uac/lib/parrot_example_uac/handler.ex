defmodule ParrotExampleUac.Handler do
  @moduledoc """
  UA Handler for the example UAC.

  This handler implements the ParrotSip.UA.Handler behaviour to handle
  call progress and completion for outbound calls.
  """

  use ParrotSip.UA.Handler
  require Logger

  defstruct [:client_pid, :audio_file]

  # ============================================================================
  # UA.Handler Callbacks
  # ============================================================================

  @impl true
  def init({client_pid, audio_file}) do
    Logger.info("ParrotExampleUac.Handler initialized")
    {:ok, %__MODULE__{
      client_pid: client_pid,
      audio_file: audio_file
    }}
  end

  @impl true
  def handle_incoming(_ua, _invite, _entity, state) do
    # UAC doesn't handle incoming calls
    {:ok, state}
  end

  @impl true
  def handle_ringing(_ua, _response, entity, state) do
    Logger.info("Call ringing: #{entity.id}")
    {:ok, state}
  end

  @impl true
  def handle_answered(_ua, response, entity, state) do
    Logger.info("Call answered: #{entity.id}")

    # Extract SDP from response and notify client
    remote_sdp = response.body
    GenServer.cast(state.client_pid, {:call_answered, entity, remote_sdp})

    {:ok, state}
  end

  @impl true
  def handle_rejected(_ua, response, entity, state) do
    Logger.info("Call rejected: #{entity.id}, status: #{response.status_code}")
    GenServer.cast(state.client_pid, {:call_ended, entity.id})
    {:ok, state}
  end

  @impl true
  def handle_hangup(_ua, _message, entity, state) do
    Logger.info("Call ended: #{entity.id}")
    GenServer.cast(state.client_pid, {:call_ended, entity.id})
    {:ok, state}
  end

  @impl true
  def handle_cancel(_ua, entity, state) do
    Logger.info("Call cancelled: #{entity.id}")
    GenServer.cast(state.client_pid, {:call_ended, entity.id})
    {:ok, state}
  end
end
