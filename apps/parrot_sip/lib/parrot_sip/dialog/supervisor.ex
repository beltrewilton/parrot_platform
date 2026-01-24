defmodule ParrotSip.Dialog.Supervisor do
  @moduledoc """
  DynamicSupervisor for SIP dialog state machines.

  Manages DialogStatem processes that track the lifecycle of SIP dialogs (call legs).
  Uses conservative restart limits to surface bugs rather than mask them.
  """

  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def start_child(args) do
    spec = {ParrotSip.DialogStatem, args}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def num_active do
    DynamicSupervisor.count_children(__MODULE__)[:active]
  end

  @impl true
  def init([]) do
    # Use conservative restart limits to surface bugs rather than mask them
    # If dialogs are crashing frequently, it indicates a bug that should be fixed
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 5
    )
  end
end
