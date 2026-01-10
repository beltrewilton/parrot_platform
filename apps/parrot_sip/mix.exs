defmodule ParrotSip.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_sip,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_pattern: "**/*_test.exs"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {ParrotSip.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_parsec, "~> 1.3"},
      {:phoenix_pubsub, "~> 2.1"},
      {:parrot_transport, in_umbrella: true},
      {:parrot_media, in_umbrella: true, only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/sipp/support"]
  defp elixirc_paths(_), do: ["lib"]
end
