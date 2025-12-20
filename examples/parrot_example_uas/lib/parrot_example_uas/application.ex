defmodule ParrotExampleUas.Application do
  @moduledoc """
  Example UAS (User Agent Server) application.

  This application demonstrates how to use ParrotSip.UA with ParrotMedia
  to create a SIP answering machine that plays audio to callers.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:parrot_example_uas, :port, 5060)
    audio_file = Application.get_env(:parrot_example_uas, :audio_file, default_audio())

    Logger.info("Starting ParrotExampleUas on port #{port}")
    Logger.info("Audio file: #{audio_file}")

    children = [
      # Start the UA with our handler
      {ParrotExampleUas.Server, port: port, audio_file: audio_file}
    ]

    opts = [strategy: :one_for_one, name: ParrotExampleUas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp default_audio do
    # Use the parrot welcome audio from parrot_media
    Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
  end
end
