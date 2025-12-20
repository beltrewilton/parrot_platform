defmodule ParrotExampleUac do
  @moduledoc """
  Example UAC (User Agent Client) application.

  This is a minimal SIP client that can:
  - Make outbound SIP calls
  - Perform SDP negotiation
  - Stream audio to the remote party using ParrotMedia

  ## Running the Example

  From the examples/parrot_example_uac directory:

      # Install dependencies
      mix deps.get

      # Run with default settings
      iex -S mix

  ## Making a Call

  In the IEx shell:

      # Dial a SIP URI
      ParrotExampleUac.dial("sip:test@192.168.1.100:5060")

      # List active calls
      ParrotExampleUac.calls()

      # Hang up a call
      ParrotExampleUac.hangup("call_id")

  ## Configuration

  Set these environment variables:

  - `PORT` - Local SIP port (default: 5070)
  - `AUDIO_FILE` - Path to WAV file to play (default: parrot-welcome.wav)
  """

  @doc """
  Make an outbound call to the given SIP URI.
  """
  defdelegate dial(uri), to: ParrotExampleUac.Client

  @doc """
  Hang up an active call by ID.
  """
  defdelegate hangup(call_id), to: ParrotExampleUac.Client

  @doc """
  List all active calls.
  """
  defdelegate calls(), to: ParrotExampleUac.Client
end
