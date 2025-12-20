defmodule ParrotExampleUac.Application do
  @moduledoc """
  Example UAC (User Agent Client) application.

  This application demonstrates how to use ParrotSip.UA with ParrotMedia
  to make outbound SIP calls.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:parrot_example_uac, :port, 5070)
    audio_file = Application.get_env(:parrot_example_uac, :audio_file, default_audio())

    Logger.info("Starting ParrotExampleUac on port #{port}")
    Logger.info("Audio file: #{audio_file}")

    children = [
      # Start the UA with our handler
      {ParrotExampleUac.Client, port: port, audio_file: audio_file}
    ]

    opts = [strategy: :one_for_one, name: ParrotExampleUac.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp default_audio do
    Path.join(:code.priv_dir(:parrot_media), "audio/parrot-welcome.wav")
  end
end
