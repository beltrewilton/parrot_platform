defmodule ParrotTransport.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for transport process discovery
      {Registry, keys: :unique, name: ParrotTransport.Registry},
      # Transport supervisor
      ParrotTransport.Supervisor
    ]

    opts = [strategy: :one_for_one, name: ParrotTransport.Application]
    Supervisor.start_link(children, opts)
  end
end
