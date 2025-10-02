defmodule ParrotTransport.Supervisor do
  @moduledoc """
  Top-level supervisor for the ParrotTransport application.

  Manages a DynamicSupervisor for listener processes (UDP, TCP, TLS).
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: ParrotTransport.ListenerSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end