defmodule ParrotMiniPbx do
  @moduledoc """
  Mini PBX - A demonstration SIP PBX built with Parrot.

  This is a standalone example application showing how to build a complete
  PBX using the Parrot DSL framework. It demonstrates:

  - **Registration**: Extensions 1001-1010 can register with password = extension
  - **Extension Calls**: Dial 1xxx for internal extension-to-extension calls
  - **Auto-Attendant**: Dial 100 for the main IVR menu
  - **Presence**: BLF (Busy Lamp Field) support via SUBSCRIBE/PUBLISH

  ## Quick Start

      # Start Mini PBX (from this directory)
      cd examples/parrot_mini_pbx
      iex -S mix

      # Or with custom port
      PORT=5070 iex -S mix

  ## Testing with pjsua

  Register an extension:

      pjsua --null-audio --no-tcp --local-port=5090 \\
        --registrar="sip:127.0.0.1:5060" \\
        --id="sip:1001@pbx.local" \\
        --realm="*" --username="1001" --password="1001"

  Should show `Registration: code=200 OK`.

  ## Demo Credentials

  | Extension | Password |
  |-----------|----------|
  | 1001      | 1001     |
  | 1002      | 1002     |
  | ...       | ...      |
  | 1010      | 1010     |

  ## Public API

  - `ParrotMiniPbx.get_port/0` - Get the actual bound SIP port
  - `ParrotMiniPbx.registrations/0` - List all current registrations
  - `ParrotMiniPbx.clear_all/0` - Clear all registrations (useful for testing)
  """

  alias Parrot.Examples.MiniPBX.Storage

  @doc """
  Returns the port the SIP stack is listening on.

  ## Example

      iex> ParrotMiniPbx.get_port()
      5060
  """
  @spec get_port() :: non_neg_integer()
  def get_port do
    ParrotMiniPbx.Server.get_port()
  end

  @doc """
  Returns a list of all current registrations.

  ## Example

      iex> ParrotMiniPbx.registrations()
      [
        %{aor: "sip:1001@pbx.local", contact: "sip:1001@192.168.1.100:5090", expires: 3600}
      ]
  """
  @spec registrations() :: [map()]
  def registrations do
    # Get all registrations for known extensions
    for ext <- ["1001", "1002", "1003", "1004", "1005", "1006", "1007", "1008", "1009", "1010"],
        aor = "sip:#{ext}@pbx.local",
        {:ok, regs} = Storage.get_registrations(aor),
        reg <- regs do
      %{aor: aor, contact: reg.contact, expires: reg.expires}
    end
  end

  @doc """
  Clears all registrations, voicemails, presence state, and subscriptions.

  Useful for resetting state during development or testing.

  ## Example

      iex> ParrotMiniPbx.clear_all()
      :ok
  """
  @spec clear_all() :: :ok
  def clear_all do
    Storage.clear_all()
  end
end
