defmodule ParrotExampleUas do
  @moduledoc """
  Example UAS (User Agent Server) application.

  This is a minimal SIP answering machine that:
  - Listens for incoming SIP INVITE requests
  - Answers calls with SDP negotiation
  - Plays audio to the caller using ParrotMedia

  ## Running the Example

  From the examples/parrot_example_uas directory:

      # Install dependencies
      mix deps.get

      # Run with default settings (port 5060)
      iex -S mix

      # Run on a different port
      PORT=5080 iex -S mix

  ## Testing with a SIP Client

  Use a SIP softphone (like Twinkle, Linphone, or Zoiper) to call:

      sip:test@<your-ip>:5060

  Or use SIPp:

      sipp -sn uac 127.0.0.1:5060 -m 1

  ## Configuration

  Set these environment variables:

  - `PORT` - SIP listening port (default: 5060)
  - `AUDIO_FILE` - Path to WAV file to play (default: parrot-welcome.wav)

  """

  @doc """
  Returns the current active calls.
  """
  def calls do
    ParrotExampleUas.Server.get_calls()
  end
end
