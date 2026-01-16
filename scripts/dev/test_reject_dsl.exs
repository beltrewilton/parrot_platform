# Call rejection test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_reject_dsl.exs
#
# Tests rejecting calls with various SIP status codes.
#
# This script demonstrates how to reject incoming calls with different
# SIP response codes using the Parrot DSL's reject/2 function.
#
# Testing Instructions:
# =====================
#
# Using pjsua (recommended):
#   pjsua --local-port=5090 --null-audio
#
#   Then in pjsua console:
#     m            # Make call
#     sip:486@127.0.0.1:5080   # For 486 Busy Here
#     m
#     sip:603@127.0.0.1:5080   # For 603 Decline
#     m
#     sip:480@127.0.0.1:5080   # For 480 Temporarily Unavailable
#     m
#     sip:403@127.0.0.1:5080   # For 403 Forbidden
#     m
#     sip:anything@127.0.0.1:5080  # For default 486 Busy Here
#
# Using SIPp:
#   # Create a simple UAC scenario file first, then:
#   sipp -sn uac 127.0.0.1:5080 -s 486 -m 1
#   sipp -sn uac 127.0.0.1:5080 -s 603 -m 1
#   sipp -sn uac 127.0.0.1:5080 -s 480 -m 1
#   sipp -sn uac 127.0.0.1:5080 -s 403 -m 1
#
# Expected behavior:
#   - Calls to sip:486@... receive 486 Busy Here
#   - Calls to sip:603@... receive 603 Decline
#   - Calls to sip:480@... receive 480 Temporarily Unavailable
#   - Calls to sip:403@... receive 403 Forbidden
#   - Calls to any other number receive 486 Busy Here (default)

require Logger

# ==============================================================================
# Handler for 486 Busy Here
# ==============================================================================
defmodule RejectBusyHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[RejectBusy] INVITE received from #{call.from} to #{call.to}")
    Logger.info("[RejectBusy] Rejecting with 486 Busy Here")
    IO.puts("\n*** Rejecting call with 486 Busy Here ***\n")

    call |> reject(486)
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[RejectBusy] Call rejected")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler for 603 Decline
# ==============================================================================
defmodule RejectDeclineHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[RejectDecline] INVITE received from #{call.from} to #{call.to}")
    Logger.info("[RejectDecline] Rejecting with 603 Decline")
    IO.puts("\n*** Rejecting call with 603 Decline ***\n")

    call |> reject(603)
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[RejectDecline] Call rejected")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler for 480 Temporarily Unavailable
# ==============================================================================
defmodule RejectUnavailableHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[RejectUnavailable] INVITE received from #{call.from} to #{call.to}")
    Logger.info("[RejectUnavailable] Rejecting with 480 Temporarily Unavailable")
    IO.puts("\n*** Rejecting call with 480 Temporarily Unavailable ***\n")

    call |> reject(480)
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[RejectUnavailable] Call rejected")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler for 403 Forbidden
# ==============================================================================
defmodule RejectForbiddenHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[RejectForbidden] INVITE received from #{call.from} to #{call.to}")
    Logger.info("[RejectForbidden] Rejecting with 403 Forbidden")
    IO.puts("\n*** Rejecting call with 403 Forbidden ***\n")

    call |> reject(403)
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[RejectForbidden] Call rejected")
    {:noreply, call}
  end
end

# ==============================================================================
# Router - routes calls based on dialed number to appropriate reject handler
# ==============================================================================
defmodule TestRejectRouter do
  use Parrot.Router

  # Route based on the dialed number (user part of To URI)
  # Pattern "486" matches sip:486@...
  invite "486", RejectBusyHandler
  invite "603", RejectDeclineHandler
  invite "480", RejectUnavailableHandler
  invite "403", RejectForbiddenHandler

  # Default handler for any other number
  invite "*", RejectBusyHandler
end

# ==============================================================================
# Start the server
# ==============================================================================
IO.puts("""
Starting call rejection DSL test server on port 5080...

Test rejection scenarios by calling:
  - sip:486@127.0.0.1:5080 -> 486 Busy Here
  - sip:603@127.0.0.1:5080 -> 603 Decline
  - sip:480@127.0.0.1:5080 -> 480 Temporarily Unavailable
  - sip:403@127.0.0.1:5080 -> 403 Forbidden
  - sip:*@127.0.0.1:5080   -> 486 Busy Here (default)
""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestRejectRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}")
    IO.puts("Press Ctrl+C to stop\n")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
