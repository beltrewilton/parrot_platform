defmodule ParrotMedia.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_media,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ParrotMedia.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Move all media deps here
      {:membrane_core, "~> 1.0"},
      {:membrane_rtp_plugin, "~> 0.31.0"},
      {:membrane_rtp_format, "~> 0.11.0"},
      {:membrane_file_plugin, "~> 0.17"},
      {:membrane_udp_plugin, "~> 0.14"},
      {:membrane_g711_plugin, "~> 0.1"},
      {:membrane_rtp_g711_plugin,
       github: "byoungdale/membrane_rtp_g711_plugin", branch: "byoungdale/update-rtp-format"},
      {:ex_sdp, "~> 0.17.0"},
      {:membrane_wav_plugin, "~> 0.10"},
      {:membrane_mp3_mad_plugin, "~> 0.18"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20"},
      {:membrane_realtimer_plugin, "~> 0.10.1"},
      {:membrane_portaudio_plugin, "~> 0.19.2"},
      {:membrane_opus_plugin, "~> 0.20.3"},
      {:membrane_rtp_opus_plugin, "~> 0.10.1"}
      # NO dependency on :parrot_sip or :parrot_transport!
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
