defmodule ParrotMiniPbx.Application do
  @moduledoc """
  OTP Application for Mini PBX.

  Starts the supervision tree with:
  - Mnesia (initialized before supervisor starts)
  - MiniPBX Storage (Mnesia-based registration/presence storage)
  - SIP Server (manages the ParrotSip.Stack)

  Note: NonceStore for Digest authentication is started by the :parrot application
  and registered as Parrot.NonceStore.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Start Mnesia before the supervisor (required for Storage)
    :mnesia.start()

    port = Application.get_env(:parrot_mini_pbx, :port, 5060)

    children = [
      # Storage for registrations, voicemails, presence
      Parrot.Examples.MiniPBX.Storage,
      # SIP stack server (NonceStore is started by :parrot application)
      {ParrotMiniPbx.Server, port: port}
    ]

    opts = [strategy: :one_for_one, name: ParrotMiniPbx.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Mini PBX running on port #{port}")
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def stop(_state) do
    Logger.info("Mini PBX stopping")
    :ok
  end
end
