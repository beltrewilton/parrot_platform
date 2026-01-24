defmodule ParrotSip.Transaction.Supervisor do
  @moduledoc """
  DynamicSupervisor for SIP transaction state machines.

  Manages TransactionStatem processes that implement RFC 3261 transaction state machines.
  Transaction processes terminate normally as part of their lifecycle.
  """

  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def start_child(args) do
    spec = {ParrotSip.TransactionStatem, args}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def num_active do
    DynamicSupervisor.count_children(__MODULE__)[:active]
  end

  @impl true
  def init([]) do
    # Transaction processes are designed to terminate normally as part of their lifecycle.
    # Normal terminations should not count against restart limits.
    # DynamicSupervisor with :one_for_one handles each child independently.
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
