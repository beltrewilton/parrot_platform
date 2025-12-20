defmodule ParrotExampleUas.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_example_uas,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ParrotExampleUas.Application, []}
    ]
  end

  defp deps do
    [
      {:parrot_sip, path: "../../apps/parrot_sip"},
      {:parrot_transport, path: "../../apps/parrot_transport"},
      {:parrot_media, path: "../../apps/parrot_media"}
    ]
  end
end
