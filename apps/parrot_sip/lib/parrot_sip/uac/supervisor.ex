defmodule ParrotSip.UAC.Supervisor do
  @moduledoc """
  DynamicSupervisor for UAC entities.

  Each UAC process is supervised with :temporary restart strategy.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_child(opts) do
    spec = {ParrotSip.UAC, opts}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 0)
  end
end
