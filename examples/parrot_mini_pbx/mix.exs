defmodule ParrotMiniPbx.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_mini_pbx,
      version: "0.1.0",
      # Share build artifacts with umbrella for faster builds
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
      extra_applications: [:logger, :mnesia],
      mod: {ParrotMiniPbx.Application, []}
    ]
  end

  defp deps do
    [
      {:parrot, path: "../../apps/parrot"},
      {:parrot_sip, path: "../../apps/parrot_sip"},
      {:parrot_transport, path: "../../apps/parrot_transport"}
    ]
  end
end
