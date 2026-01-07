defmodule Parrot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The Parrot framework is started explicitly by adding
    # {Parrot, router: ..., transports: [...]} to your supervision tree.
    # This application just ensures the parrot app is loaded.
    children = []

    opts = [strategy: :one_for_one, name: Parrot.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
