# Error handling test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_error_handling.exs
#
# This script demonstrates various error handling scenarios in the Parrot DSL:
# - Handler crashes (resulting in 500 Internal Server Error)
# - SDP negotiation errors (handle_sdp_error/2 callback, 488 Not Acceptable Here)
# - Missing audio file handling (graceful degradation)
# - Timeout handling during operations
#
# Testing Instructions:
# =====================
#
# Using pjsua (recommended):
#   pjsua --local-port=5090 --null-audio
#
#   Then in pjsua console:
#     m                               # Make call
#     sip:crash@127.0.0.1:5080        # Handler raises exception -> 500
#     m
#     sip:sdp_error@127.0.0.1:5080    # Simulated SDP failure -> 488
#     m
#     sip:missing_file@127.0.0.1:5080 # Play non-existent file -> graceful handling
#     m
#     sip:timeout@127.0.0.1:5080      # Long operation timeout -> recovery
#     m
#     sip:custom_error@127.0.0.1:5080 # Custom error code handling
#
# Using SIPp:
#   sipp -sn uac 127.0.0.1:5080 -s crash -m 1
#   sipp -sn uac 127.0.0.1:5080 -s sdp_error -m 1
#   sipp -sn uac 127.0.0.1:5080 -s missing_file -m 1
#   sipp -sn uac 127.0.0.1:5080 -s timeout -m 1
#   sipp -sn uac 127.0.0.1:5080 -s custom_error -m 1
#
# Expected behavior:
#   - crash: Receives 500 Internal Server Error (handler exception)
#   - sdp_error: Receives 488 Not Acceptable Here (SDP negotiation failed)
#   - missing_file: Call answers, but playback fails gracefully
#   - timeout: Simulates slow operation with recovery
#   - custom_error: Custom handle_sdp_error callback with 406 response

require Logger

# ==============================================================================
# Handler that intentionally crashes to test 500 response
# ==============================================================================
defmodule CrashHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[CrashHandler] INVITE received from #{call.from}")
    Logger.warning("[CrashHandler] About to intentionally crash...")
    IO.puts("\n*** CrashHandler: Raising exception to trigger 500 error ***\n")

    # This will cause the handler to crash, resulting in a 500 response
    raise "Intentional crash for testing error handling!"

    # Never reached
    call |> answer()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[CrashHandler] Call ended (crashed)")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler that demonstrates handle_sdp_error/2 callback
# ==============================================================================
defmodule SdpErrorHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[SdpErrorHandler] INVITE received from #{call.from}")
    # This won't be called if SDP negotiation fails upstream
    # But we can demonstrate the default reject behavior
    IO.puts("\n*** SdpErrorHandler: Normal INVITE handling ***")
    IO.puts("*** (SDP error would be handled by handle_sdp_error/2 before this) ***\n")

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @doc """
  Called when SDP negotiation fails (e.g., codec mismatch, invalid SDP).

  This callback demonstrates proper error handling:
  1. Log the error for debugging
  2. Return appropriate response code (488 by default)
  """
  @impl true
  def handle_sdp_error(reason, call) do
    Logger.warning("[SdpErrorHandler] SDP negotiation failed: #{inspect(reason)}")
    IO.puts("\n*** SdpErrorHandler: handle_sdp_error invoked ***")
    IO.puts("*** Reason: #{inspect(reason)} ***")
    IO.puts("*** Rejecting with 488 Not Acceptable Here ***\n")

    # Default behavior: reject with 488 Not Acceptable Here
    # You could also:
    # - Log to external monitoring system
    # - Try alternative codec negotiation
    # - Return different status codes based on reason
    call |> reject(488)
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[SdpErrorHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[SdpErrorHandler] Call ended")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler with custom SDP error handling (different response code)
# ==============================================================================
defmodule CustomSdpErrorHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[CustomSdpErrorHandler] INVITE received from #{call.from}")
    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @doc """
  Custom SDP error handler that returns 406 Not Acceptable instead of 488.

  Demonstrates how to customize error responses based on business logic.
  """
  @impl true
  def handle_sdp_error(reason, call) do
    Logger.error("[CustomSdpErrorHandler] SDP negotiation failed: #{inspect(reason)}")
    IO.puts("\n*** CustomSdpErrorHandler: Custom error handling ***")
    IO.puts("*** Reason: #{inspect(reason)} ***")
    IO.puts("*** Rejecting with 406 Not Acceptable (custom response) ***\n")

    # Log detailed error information for debugging
    Logger.info("[CustomSdpErrorHandler] Call details:")
    Logger.info("  From: #{call.from}")
    Logger.info("  To: #{call.to}")
    Logger.info("  Call-ID: #{call.call_id}")

    # Return custom error code
    call |> reject(406)
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[CustomSdpErrorHandler] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[CustomSdpErrorHandler] Call ended")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler that attempts to play a non-existent file
# ==============================================================================
defmodule MissingFileHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[MissingFileHandler] INVITE received from #{call.from}")
    IO.puts("\n*** MissingFileHandler: Attempting to play non-existent file ***")
    IO.puts("*** File: priv/audio/this_file_does_not_exist.wav ***\n")

    call
    |> answer()
    |> play("priv/audio/this_file_does_not_exist.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    # This may or may not be called depending on how the media layer handles errors
    Logger.info("[MissingFileHandler] Playback event for: #{file}")
    IO.puts("\n*** MissingFileHandler: Playback complete or failed ***")
    IO.puts("*** Hanging up gracefully ***\n")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[MissingFileHandler] Call ended")
    IO.puts("\n*** MissingFileHandler: Call terminated ***\n")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler that simulates a timeout scenario
# ==============================================================================
defmodule TimeoutHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[TimeoutHandler] INVITE received from #{call.from}")
    IO.puts("\n*** TimeoutHandler: Simulating slow operation ***")
    IO.puts("*** Sleeping for 2 seconds before answering ***\n")

    # Simulate a slow database lookup or external service call
    # In production, this might be an async operation with timeout handling
    Process.sleep(2_000)

    Logger.info("[TimeoutHandler] Slow operation completed, answering call")
    IO.puts("\n*** TimeoutHandler: Slow operation completed ***")
    IO.puts("*** Answering and playing audio ***\n")

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[TimeoutHandler] Playback complete: #{file}")
    IO.puts("\n*** TimeoutHandler: Playback complete, demonstrating recovery ***")

    # Store timeout state in assigns for demonstration
    call
    |> assign(:recovered_from_slow_op, true)
    |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    recovered = Map.get(call.assigns, :recovered_from_slow_op, false)
    Logger.info("[TimeoutHandler] Call ended (recovered: #{recovered})")
    IO.puts("\n*** TimeoutHandler: Call ended ***")
    IO.puts("*** Recovery state: #{recovered} ***\n")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler demonstrating graceful error recovery patterns
# ==============================================================================
defmodule GracefulRecoveryHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[GracefulRecovery] INVITE received from #{call.from}")
    IO.puts("\n*** GracefulRecovery: Demonstrating recovery patterns ***\n")

    # Initialize retry counter in assigns
    call
    |> assign(:retry_count, 0)
    |> assign(:max_retries, 3)
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(_file, call) do
    retry_count = Map.get(call.assigns, :retry_count, 0)
    max_retries = Map.get(call.assigns, :max_retries, 3)

    Logger.info("[GracefulRecovery] Playback complete, retry_count=#{retry_count}")
    IO.puts("\n*** GracefulRecovery: Playback complete ***")
    IO.puts("*** Retry count: #{retry_count}/#{max_retries} ***\n")

    if retry_count < max_retries do
      # Could retry or proceed with next operation
      call |> hangup()
    else
      # Max retries exceeded, terminate gracefully
      Logger.warning("[GracefulRecovery] Max retries exceeded, terminating")
      call |> hangup()
    end
  end

  @impl true
  def handle_sdp_error(reason, call) do
    Logger.error("[GracefulRecovery] SDP error: #{inspect(reason)}")
    IO.puts("\n*** GracefulRecovery: SDP error occurred ***")
    IO.puts("*** Reason: #{inspect(reason)} ***")
    IO.puts("*** Using graceful degradation - rejecting with 488 ***\n")

    # Graceful degradation: could attempt alternative codecs or fallback
    call |> reject(488)
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[GracefulRecovery] Call ended gracefully")
    IO.puts("\n*** GracefulRecovery: Call ended ***\n")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler that demonstrates logging patterns during errors
# ==============================================================================
defmodule LoggingDemoHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[LoggingDemo] INVITE received")
    Logger.debug("[LoggingDemo] Full call details: #{inspect(call, pretty: true)}")
    IO.puts("\n*** LoggingDemo: Demonstrating logging patterns ***\n")

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_sdp_error(reason, call) do
    # Demonstrate different logging levels for error scenarios
    Logger.error("[LoggingDemo] SDP error: #{inspect(reason)}")
    Logger.warning("[LoggingDemo] Call will be rejected due to SDP failure")
    Logger.info("[LoggingDemo] Caller info: from=#{call.from}")
    Logger.debug("[LoggingDemo] Full error context: reason=#{inspect(reason)}, call_id=#{call.call_id}")

    IO.puts("\n*** LoggingDemo: Error logged at multiple levels ***")
    IO.puts("*** Check LOG_LEVEL=debug for full output ***\n")

    call |> reject(488)
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[LoggingDemo] Playback complete: #{file}")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[LoggingDemo] Call ended")
    {:noreply, call}
  end
end

# ==============================================================================
# Router - routes calls based on dialed number to appropriate error handler
# ==============================================================================
defmodule TestErrorRouter do
  use Parrot.Router

  # Route error test scenarios based on the dialed number
  invite "crash", CrashHandler
  invite "sdp_error", SdpErrorHandler
  invite "custom_error", CustomSdpErrorHandler
  invite "missing_file", MissingFileHandler
  invite "timeout", TimeoutHandler
  invite "recovery", GracefulRecoveryHandler
  invite "logging", LoggingDemoHandler

  # Default handler - shows graceful recovery patterns
  invite "*", GracefulRecoveryHandler
end

# ==============================================================================
# Custom Bridge.Handler wrapper that can inject SDP errors for testing
# ==============================================================================
defmodule TestErrorBridgeHandler do
  @moduledoc """
  Custom handler wrapper that can simulate SDP errors for testing.

  This intercepts handle_invite and can inject errors based on the dialed number.
  """

  @behaviour ParrotSip.Handler

  require Logger

  @impl true
  def transp_request(msg, args) do
    Parrot.Bridge.Handler.transp_request(msg, args)
  end

  @impl true
  def transaction(trans, sip_msg, args) do
    Parrot.Bridge.Handler.transaction(trans, sip_msg, args)
  end

  @impl true
  def transaction_stop(trans, trans_result, args) do
    Parrot.Bridge.Handler.transaction_stop(trans, trans_result, args)
  end

  @impl true
  def uas_request(uas, req_sip_msg, args) do
    Parrot.Bridge.Handler.uas_request(uas, req_sip_msg, args)
  end

  @impl true
  def uas_cancel(uas_id, args) do
    Parrot.Bridge.Handler.uas_cancel(uas_id, args)
  end

  @impl true
  def process_ack(sip_msg, args) do
    Parrot.Bridge.Handler.process_ack(sip_msg, args)
  end

  @impl true
  def handle_invite(uas, req_sip_msg, args) do
    # Check if the dialed number indicates we should force an SDP error
    to_user = extract_to_user(req_sip_msg)
    Logger.debug("[TestErrorBridgeHandler] Dialed number: #{to_user}")

    # Inject SDP error for "sdp_error" and "custom_error" test cases
    modified_args =
      case to_user do
        "sdp_error" ->
          IO.puts("\n*** Injecting SDP error (codec_mismatch) for testing ***\n")
          args
          |> Map.put(:force_sdp_error, true)
          |> Map.put(:sdp_error_reason, :codec_mismatch)

        "custom_error" ->
          IO.puts("\n*** Injecting SDP error (invalid_sdp) for testing ***\n")
          args
          |> Map.put(:force_sdp_error, true)
          |> Map.put(:sdp_error_reason, :invalid_sdp)

        _ ->
          args
      end

    # Delegate to the real Bridge.Handler with potentially modified args
    Parrot.Bridge.Handler.handle_invite(uas, req_sip_msg, modified_args)
  end

  @impl true
  def handle_bye(uas, req_sip_msg, args) do
    Parrot.Bridge.Handler.handle_bye(uas, req_sip_msg, args)
  end

  @impl true
  def handle_register(uas, req_sip_msg, args) do
    Parrot.Bridge.Handler.handle_register(uas, req_sip_msg, args)
  end

  @impl true
  def handle_options(uas, req_sip_msg, args) do
    Parrot.Bridge.Handler.handle_options(uas, req_sip_msg, args)
  end

  @impl true
  def handle_cancel(uas, req_sip_msg, args) do
    Parrot.Bridge.Handler.handle_cancel(uas, req_sip_msg, args)
  end

  # Extract the user part of the To URI
  defp extract_to_user(%{to: %{uri: %ParrotSip.Uri{user: user}}}) when is_binary(user), do: user
  defp extract_to_user(_), do: nil
end

# ==============================================================================
# Start the server
# ==============================================================================
IO.puts("""
================================================================================
Error Handling Test Server - Parrot DSL
================================================================================

Starting on port 5080...

Test error scenarios by calling:
  - sip:crash@127.0.0.1:5080        -> Handler exception -> 500 Internal Server Error
  - sip:sdp_error@127.0.0.1:5080    -> SDP codec mismatch -> 488 Not Acceptable Here
  - sip:custom_error@127.0.0.1:5080 -> SDP error with custom 406 response
  - sip:missing_file@127.0.0.1:5080 -> Answer + play missing file -> graceful handling
  - sip:timeout@127.0.0.1:5080      -> 2s delay before answer -> recovery demo
  - sip:recovery@127.0.0.1:5080     -> Graceful recovery patterns
  - sip:logging@127.0.0.1:5080      -> Logging patterns demo
  - sip:*@127.0.0.1:5080            -> Default graceful recovery handler

Error Response Codes:
  - 400 Bad Request        - Malformed SIP message
  - 406 Not Acceptable     - Custom error response
  - 408 Request Timeout    - Operation timed out
  - 480 Temporarily Unavailable
  - 486 Busy Here
  - 488 Not Acceptable Here - SDP/codec negotiation failed
  - 500 Internal Server Error - Handler crash
  - 503 Service Unavailable

Tips:
  - Use LOG_LEVEL=debug to see detailed error logs
  - Use SIP_TRACE=true to see wire-level SIP messages
  - Handler crashes result in 500 responses (production behavior)
  - SDP errors invoke handle_sdp_error/2 callback (FR-009, FR-012)

================================================================================
""")

# Use our custom handler wrapper that can inject SDP errors
handler = ParrotSip.Handler.new(TestErrorBridgeHandler, %{router: TestErrorRouter})

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
