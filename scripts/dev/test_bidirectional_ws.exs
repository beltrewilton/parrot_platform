# Bidirectional WebSocket test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_bidirectional_ws.exs
#
# Demonstrates WebSocket bidirectional audio streaming for AI integration.
# Note: Actual WebSocket server not required - this shows the API usage pattern.

require Logger

defmodule TestBidirectionalWsHandler do
  @moduledoc """
  Handler demonstrating bidirectional WebSocket audio streaming.

  This handler shows how to:
  1. Connect to a WebSocket endpoint for real-time audio streaming
  2. Send configuration messages to the AI service
  3. Mute/unmute audio streams in either direction
  4. Send custom messages during the conversation
  5. Gracefully disconnect before ending the call
  """
  use Parrot.InviteHandler

  # Alias Call module for WebSocket operations not auto-imported by InviteHandler
  # We use Call.function() syntax for WebSocket-specific operations
  alias Parrot.Call

  require Logger

  # Mock WebSocket URL for demonstration
  @ws_url "wss://api.example.com/v1/realtime"

  @impl true
  def handle_invite(call) do
    Logger.info("[BidirectionalWS] INVITE received from #{call.from}")
    Logger.info("[BidirectionalWS] Answering call and connecting to WebSocket...")

    # Build the session configuration message
    session_config =
      Jason.encode!(%{
        type: "session.update",
        session: %{
          modalities: ["text", "audio"],
          voice: "alloy",
          input_audio_format: "pcm16",
          output_audio_format: "pcm16"
        }
      })

    call
    |> answer()
    |> assign(:ws_state, :connecting)
    |> Call.connect_bidirectional_ws(@ws_url,
      headers: [
        {"Authorization", "Bearer demo-token"},
        {"OpenAI-Beta", "realtime=v1"}
      ],
      callback_module: __MODULE__,
      callback_state: %{turn_count: 0},
      sample_rate: 24000,
      inbound_format: :pcm_16le,
      outbound_format: :pcm_16le
    )
    |> Call.send_ws_message(session_config)
    |> assign(:ws_state, :connected)
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[BidirectionalWS] Playback complete: #{file}")

    case call.assigns[:ws_state] do
      :connected ->
        # After welcome message, we're ready for conversation
        Logger.info("[BidirectionalWS] Ready for bidirectional audio")
        {:noreply, call}

      _ ->
        {:noreply, call}
    end
  end

  @impl true
  def handle_dtmf(digit, call) do
    Logger.info("[BidirectionalWS] DTMF received: #{inspect(digit)}")

    case digit do
      # Mute caller's audio to AI (caller can hear AI, AI cannot hear caller)
      "1" ->
        Logger.info("[BidirectionalWS] Muting outbound audio (caller -> AI)")

        call
        |> Call.mute_outbound()
        |> assign(:outbound_muted, true)

      # Unmute caller's audio to AI
      "2" ->
        Logger.info("[BidirectionalWS] Unmuting outbound audio (caller -> AI)")

        call
        |> Call.unmute_outbound()
        |> assign(:outbound_muted, false)

      # Mute AI's audio to caller (AI can hear caller, caller cannot hear AI)
      "3" ->
        Logger.info("[BidirectionalWS] Muting inbound audio (AI -> caller)")

        call
        |> Call.mute_inbound()
        |> assign(:inbound_muted, true)

      # Unmute AI's audio to caller
      "4" ->
        Logger.info("[BidirectionalWS] Unmuting inbound audio (AI -> caller)")

        call
        |> Call.unmute_inbound()
        |> assign(:inbound_muted, false)

      # Send a custom message to the AI service
      "5" ->
        Logger.info("[BidirectionalWS] Sending custom message to AI service")

        custom_message =
          Jason.encode!(%{
            type: "conversation.item.create",
            item: %{
              type: "message",
              role: "user",
              content: [%{type: "input_text", text: "Hello from DTMF!"}]
            }
          })

        call
        |> Call.send_ws_message(custom_message)

      # Request AI response
      "6" ->
        Logger.info("[BidirectionalWS] Requesting AI response")

        response_request =
          Jason.encode!(%{
            type: "response.create",
            response: %{
              modalities: ["audio", "text"]
            }
          })

        call
        |> Call.send_ws_message(response_request)

      # Disconnect from WebSocket
      "9" ->
        Logger.info("[BidirectionalWS] Disconnecting from WebSocket")

        call
        |> Call.disconnect_bidirectional_ws()
        |> assign(:ws_state, :disconnected)

      # End call
      "*" ->
        Logger.info("[BidirectionalWS] Ending call")

        call
        |> Call.disconnect_bidirectional_ws()
        |> hangup()

      _ ->
        Logger.info("[BidirectionalWS] Unknown DTMF: #{inspect(digit)}")
        {:noreply, call}
    end
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[BidirectionalWS] Call ended")
    Logger.info("[BidirectionalWS] Final state: #{inspect(call.assigns)}")

    # Note: The framework should auto-disconnect WebSocket on hangup,
    # but explicit disconnect is recommended before hangup for clean shutdown
    {:noreply, call}
  end
end

defmodule TestBidirectionalWsRouter do
  use Parrot.Router

  invite("*", TestBidirectionalWsHandler)
end

# Print usage information
IO.puts("""
Starting Bidirectional WebSocket DSL test server on port 5080...

This script demonstrates the WebSocket bidirectional audio API for AI integration.
Note: No actual WebSocket server is required - this shows the API usage pattern.

DTMF Commands:
  1 - Mute outbound audio (caller -> AI)
  2 - Unmute outbound audio (caller -> AI)
  3 - Mute inbound audio (AI -> caller)
  4 - Unmute inbound audio (AI -> caller)
  5 - Send custom text message to AI
  6 - Request AI response
  9 - Disconnect from WebSocket
  * - End call

WebSocket API Operations Demonstrated:
  - connect_bidirectional_ws/2, connect_bidirectional_ws/3
  - disconnect_bidirectional_ws/1
  - mute_inbound/1, unmute_inbound/1
  - mute_outbound/1, unmute_outbound/1
  - send_ws_message/2

""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestBidirectionalWsRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}")
    IO.puts("Call sip:test@127.0.0.1:#{port} to test bidirectional WebSocket audio")
    IO.puts("Press Ctrl+C to stop\n")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
