defmodule ParrotMedia.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for media session discovery
      {Registry, keys: :unique, name: ParrotMedia.Registry},
      # Registry for WebSocket forker discovery by fork_id
      {Registry, keys: :unique, name: ParrotMedia.WsForkerRegistry},
      # Registry for bidirectional WebSocket connection discovery by connection_id
      {Registry, keys: :unique, name: ParrotMedia.BidirectionalRegistry},
      # Media session supervisor
      ParrotMedia.MediaSessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: ParrotMedia.Application]
    Supervisor.start_link(children, opts)
  end
end
