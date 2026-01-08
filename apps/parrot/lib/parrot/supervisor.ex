defmodule Parrot.Supervisor do
  @moduledoc """
  Top-level supervisor for the Parrot VoIP framework.

  This supervisor manages all Parrot components including routers,
  transports, and any runtime state needed for the DSL framework.
  """

  use Supervisor

  @doc """
  Starts the Parrot supervisor with the given options.

  ## Options

  * `:router` - Required. The router module for call routing.
  * `:transports` - Required. List of transport configurations.
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Store configuration in persistent_term for fast access
    :persistent_term.put(:parrot_config, opts)

    children = [
      # Registry for Parrot process discovery
      {Registry, keys: :unique, name: Parrot.Registry},
      # Task supervisor for async operations (e.g., presence notifications)
      {Task.Supervisor, name: Parrot.TaskSupervisor},
      # Registration expiry timer manager
      {Parrot.Registration.ExpiryManager, name: Parrot.Registration.ExpiryManager}
      # Future children will include:
      # - Router process
      # - Transport manager
      # - Call supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
