defmodule ParrotSip.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for SIP process discovery
      {Registry, keys: :unique, name: ParrotSip.Registry},
      # Transport handler for message-based communication with transport layer
      {ParrotSip.TransportHandler, [name: ParrotSip.TransportHandler]},
      # Transaction supervisor
      ParrotSip.Transaction.Supervisor,
      # Dialog supervisor
      ParrotSip.Dialog.Supervisor,
      # Subscription supervisor - RFC 6665 event subscriptions
      ParrotSip.Subscription.Supervisor,
      # NOTE: ParrotSip.Presence.Server removed - functionality consolidated into
      # Parrot.Subscription.Server which handles the full SUBSCRIBE/NOTIFY flow
      # UAS supervisor - incoming call legs
      ParrotSip.UAS.Supervisor,
      # UAC supervisor - outgoing call legs
      ParrotSip.UAC.Supervisor
    ]

    opts = [strategy: :one_for_one, name: ParrotSip.Application]
    Supervisor.start_link(children, opts)
  end
end
