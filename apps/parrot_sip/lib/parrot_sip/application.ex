defmodule ParrotSip.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for SIP process discovery
      {Registry, keys: :unique, name: ParrotSip.Registry},
      # Transaction supervisor
      ParrotSip.Transaction.Supervisor,
      # Dialog supervisor
      ParrotSip.Dialog.Supervisor,
      # Handler adapter supervisor
      ParrotSip.HandlerAdapter.Supervisor
    ]

    opts = [strategy: :one_for_one, name: ParrotSip.Application]
    Supervisor.start_link(children, opts)
  end
end
