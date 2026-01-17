defmodule Parrot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The Parrot framework is started explicitly by adding
    # {Parrot, router: ..., transports: [...]} to your supervision tree.
    # This application just ensures the parrot app is loaded.
    #
    # TTS services are started here so they're available to all Parrot applications
    children = [
      # TTS Cache (ETS backend) - must start before Synthesizer
      Parrot.TTS.Cache.ETS,
      # TTS Synthesizer GenServer
      Parrot.TTS.Synthesizer
    ]

    opts = [strategy: :one_for_one, name: Parrot.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
