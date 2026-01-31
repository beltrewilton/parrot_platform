defmodule Parrot.Examples.MiniPBX.Router do
  @moduledoc """
  Main router for the Mini PBX example application.

  Routes SIP requests to appropriate handlers:

  - **1xxx** - Internal extension calls (Extensions handler)
  - **9xxx** - Outbound PSTN calls (Outbound handler)
  - **100** - Auto-attendant IVR

  ## Architecture

      ┌─────────────────────────────────────────────────────────────┐
      │                         Router                              │
      ├─────────────────────────────────────────────────────────────┤
      │  Pipeline: authenticated                                    │
      │    └─ verify_registration plug                              │
      ├─────────────────────────────────────────────────────────────┤
      │  Scope: Internal (192.168.0.0/16)                          │
      │    ├─ 1xxx → Extensions handler                            │
      │    └─ 9xxx → Outbound handler                              │
      ├─────────────────────────────────────────────────────────────┤
      │  Global routes:                                             │
      │    └─ 100 → AutoAttendant handler                          │
      ├─────────────────────────────────────────────────────────────┤
      │  REGISTER → Registration handler                            │
      │  SUBSCRIBE → Presence handler                               │
      └─────────────────────────────────────────────────────────────┘

  ## Example Usage

      # Start the Mini PBX
      {:ok, stack} = Parrot.Examples.MiniPBX.start(port: 5060)

      # Register extension 1001 from pjsua:
      pjsua --registrar "sip:pbx.local:5060" --id "sip:1001@pbx.local"

      # Call auto-attendant:
      pjsua --null-audio "sip:100@pbx.local:5060"
  """

  use Parrot.Router

  alias Parrot.Examples.MiniPBX.{Extensions, Outbound, AutoAttendant, Registration, Presence}

  # ============================================================================
  # Pipelines
  # ============================================================================

  pipeline :authenticated do
    plug :verify_registration
  end

  # ============================================================================
  # Internal Routes (from local network)
  # ============================================================================

  # Scope for internal extensions - requires authentication
  scope "/", from_ip: "192.168.0.0/16" do
    pipe_through :authenticated

    # Internal extension-to-extension calls (1000-1999)
    invite "1xxx", Extensions

    # Outbound PSTN calls (dial 9 + number)
    invite "9xxx", Outbound
  end

  # ============================================================================
  # Global Routes (any source)
  # ============================================================================

  # Auto-attendant - public entry point
  invite "100", AutoAttendant

  # ============================================================================
  # Other Methods
  # ============================================================================

  # Registration handler for REGISTER requests
  register Registration

  # Presence handler for SUBSCRIBE requests
  presence Presence
end
