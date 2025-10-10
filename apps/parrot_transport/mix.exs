defmodule ParrotTransport.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_transport,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {ParrotTransport.Application, []}
    ]
  end

  defp deps do
    [
      # No deps on other parrot apps!
      # Transport is the bottom layer
      {:cowboy, "~> 2.10"},
      {:gun, "~> 2.0", only: :test}
    ]
  end
  
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
