# Test SDP offer/answer negotiation using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_sdp_negotiation.exs
#
# This script demonstrates:
# - Normal SDP negotiation flow (INVITE with SDP offer -> 200 OK with SDP answer)
# - Logging the negotiated codec and media parameters
# - Using handle_sdp_error/2 callback for error scenarios
# - Displaying media session info after answer
#
# Test with pjsua:
#   pjsua --null-audio sip:test@127.0.0.1:5080

require Logger

defmodule TestSdpNegotiationHandler do
  @moduledoc """
  Handler that demonstrates SDP negotiation flow with detailed logging.
  """
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("""
    [SDP-Test] ========================================
    [SDP-Test] INVITE received
    [SDP-Test] From: #{call.from}
    [SDP-Test] To: #{call.to}
    [SDP-Test] Call-ID: #{call.call_id}
    [SDP-Test] ========================================
    """)

    # Log that SDP negotiation will happen automatically via Bridge.Handler
    # The MediaSession is created and process_offer is called before we get here
    Logger.info("[SDP-Test] SDP negotiation completed by Bridge.Handler")
    Logger.info("[SDP-Test] MediaSession created for call_#{call.call_id}")

    # Look up the media session to display negotiation results
    session_id = "call_#{call.call_id}"
    display_media_session_info(session_id)

    # Answer the call - the 200 OK will include the SDP answer
    Logger.info("[SDP-Test] Answering call with SDP answer in 200 OK")

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[SDP-Test] Playback complete: #{file}")
    Logger.info("[SDP-Test] Hanging up call")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("""
    [SDP-Test] ========================================
    [SDP-Test] Call ended
    [SDP-Test] Call-ID: #{call.call_id}
    [SDP-Test] ========================================
    """)
    {:noreply, call}
  end

  @impl true
  def handle_sdp_error(reason, call) do
    # This callback is invoked when SDP negotiation fails
    # Common reasons:
    # - :codec_mismatch - No common codec between offer and server
    # - :invalid_sdp - Malformed SDP in INVITE body
    # - :media_session_error - MediaSession creation failed
    Logger.error("""
    [SDP-Test] ========================================
    [SDP-Test] SDP NEGOTIATION FAILED
    [SDP-Test] Reason: #{inspect(reason)}
    [SDP-Test] Call-ID: #{call.call_id}
    [SDP-Test] From: #{call.from}
    [SDP-Test] ========================================
    """)

    case reason do
      :codec_mismatch ->
        Logger.error("[SDP-Test] No common codec found between offer and server capabilities")
        Logger.error("[SDP-Test] Server supports: PCMU (0), PCMA (8)")
        Logger.error("[SDP-Test] Rejecting with 488 Not Acceptable Here")
        call |> reject(488)

      :invalid_sdp ->
        Logger.error("[SDP-Test] Malformed SDP in INVITE body")
        Logger.error("[SDP-Test] Rejecting with 400 Bad Request")
        call |> reject(400)

      :media_session_error ->
        Logger.error("[SDP-Test] Failed to create MediaSession")
        Logger.error("[SDP-Test] Rejecting with 500 Internal Server Error")
        call |> reject(500)

      _other ->
        Logger.error("[SDP-Test] Unknown SDP error, rejecting with 488")
        call |> reject(488)
    end
  end

  # Display media session info after SDP negotiation
  defp display_media_session_info(session_id) do
    case Registry.lookup(ParrotMedia.Registry, {:media_session, session_id}) do
      [{pid, _}] ->
        # Get state info from the media session
        try do
          state_info = :gen_statem.call(pid, :get_state, 5000)
          Logger.info("""
          [SDP-Test] ----------------------------------------
          [SDP-Test] MEDIA SESSION INFO
          [SDP-Test] Session ID: #{state_info.id}
          [SDP-Test] Dialog ID: #{state_info.dialog_id}
          [SDP-Test] Role: #{state_info.role}
          [SDP-Test] State: #{state_info.state}
          [SDP-Test] Has Local SDP: #{state_info.has_local_sdp}
          [SDP-Test] Has Remote SDP: #{state_info.has_remote_sdp}
          [SDP-Test] Pipeline Active: #{state_info.pipeline_active}
          [SDP-Test] ----------------------------------------
          """)
        rescue
          e ->
            Logger.warning("[SDP-Test] Could not get media session state: #{inspect(e)}")
        end

      [] ->
        Logger.warning("[SDP-Test] Media session not found: #{session_id}")
    end
  end
end

defmodule TestSdpNegotiationRouter do
  use Parrot.Router

  invite("*", TestSdpNegotiationHandler)
end

# Configuration banner
IO.puts("""

================================================================================
  SDP NEGOTIATION TEST SERVER
================================================================================

This server demonstrates SDP offer/answer negotiation in the Parrot DSL.

When a call arrives:
1. Bridge.Handler extracts SDP offer from INVITE body
2. MediaSession is created and process_offer() generates SDP answer
3. The handler's handle_invite/1 is called with the call struct
4. answer() sends 200 OK with the SDP answer in the body
5. After ACK, media flows using the negotiated codec

Supported codecs: PCMU (G.711 u-law), PCMA (G.711 A-law)

If SDP negotiation fails (e.g., no common codec), handle_sdp_error/2 is called.

================================================================================
""")

IO.puts("Starting SDP negotiation test server on port 5080...")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestSdpNegotiationRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("""

    Server listening on port #{port}

    Test with pjsua (software phone):
      pjsua --null-audio sip:test@127.0.0.1:#{port}

    Or with SIPp (SIP testing tool):
      sipp -sf test/sipp/scenarios/uac_invite_sdp.xml 127.0.0.1:#{port}

    Watch the logs to see:
    - SDP offer extraction from INVITE
    - Codec negotiation (PCMU/PCMA selection)
    - SDP answer generation
    - Media session state transitions

    Press Ctrl+C to stop

    """)

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
