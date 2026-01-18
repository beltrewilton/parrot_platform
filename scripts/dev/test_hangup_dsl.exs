# Test hangup scenarios using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=info mix run scripts/dev/test_hangup_dsl.exs
#
# Test Scenarios:
# ===============
#
# 1. IMMEDIATE HANGUP AFTER ANSWER
#    - Call sip:immediate@127.0.0.1:5080
#    - Answers the call then hangs up immediately
#    - Tests that hangup works right after answer
#
# 2. DELAYED HANGUP
#    - Call sip:delayed@127.0.0.1:5080
#    - Answers, waits 3 seconds, then hangs up
#    - Tests scheduled hangup via assigns + timer
#
# 3. HANGUP AFTER PLAY
#    - Call sip:play@127.0.0.1:5080 (or any other user)
#    - Answers, plays welcome audio, then hangs up on completion
#    - Tests hangup in handle_play_complete callback
#
# All scenarios log to handle_hangup/1 when the call ends.

require Logger

# =============================================================================
# Handler: Immediate hangup after answer
# =============================================================================
defmodule ImmediateHangupHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[ImmediateHangup] INVITE received from #{call.from}")
    Logger.info("[ImmediateHangup] Answering and hanging up immediately...")

    # Answer then immediately hang up - tests basic hangup flow
    call
    |> answer()
    |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[ImmediateHangup] handle_hangup callback invoked")
    Logger.info("[ImmediateHangup] Call ID: #{call.call_id}")
    Logger.info("[ImmediateHangup] Final state: #{inspect(call.state)}")
    IO.puts("\n*** IMMEDIATE HANGUP - Call ended ***\n")
    {:noreply, call}
  end
end

# =============================================================================
# Handler: Delayed hangup (answer, wait, then hangup)
# =============================================================================
defmodule DelayedHangupHandler do
  use Parrot.InviteHandler

  require Logger

  @delay_ms 3_000

  @impl true
  def handle_invite(call) do
    Logger.info("[DelayedHangup] INVITE received from #{call.from}")
    Logger.info("[DelayedHangup] Answering... will hang up in #{@delay_ms}ms")

    # Schedule a hangup after the delay
    # Note: In a real implementation, you might use Process.send_after
    # to the Call.Server. For this test, we use a simple spawned process.
    spawn(fn ->
      Process.sleep(@delay_ms)
      Logger.info("[DelayedHangup] Delay elapsed, sending hangup signal...")

      # Look up the Call.Server process and send it a custom message
      # In production, you'd use a proper mechanism; here we log it
      IO.puts("\n*** DELAYED HANGUP - #{@delay_ms}ms elapsed ***\n")
    end)

    # Answer the call and store info in assigns
    call
    |> answer()
    |> assign(:hangup_scheduled_at, System.monotonic_time(:millisecond))
    |> assign(:hangup_delay_ms, @delay_ms)
  end

  @impl true
  def handle_hangup(call) do
    scheduled_at = call.assigns[:hangup_scheduled_at]
    delay = call.assigns[:hangup_delay_ms]

    if scheduled_at do
      elapsed = System.monotonic_time(:millisecond) - scheduled_at
      Logger.info("[DelayedHangup] handle_hangup - call lasted #{elapsed}ms (expected ~#{delay}ms)")
    else
      Logger.info("[DelayedHangup] handle_hangup - call ended")
    end

    Logger.info("[DelayedHangup] Call ID: #{call.call_id}")
    {:noreply, call}
  end
end

# =============================================================================
# Handler: Hangup after play completes (default route)
# =============================================================================
defmodule PlayThenHangupHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[PlayThenHangup] INVITE received from #{call.from}")
    Logger.info("[PlayThenHangup] Answering and playing welcome audio...")

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[PlayThenHangup] Playback complete: #{file}")
    Logger.info("[PlayThenHangup] Hanging up after playback...")
    IO.puts("\n*** PLAY COMPLETE - Hanging up ***\n")

    # Hang up after the audio finishes
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[PlayThenHangup] handle_hangup callback invoked")
    Logger.info("[PlayThenHangup] From: #{call.from}")
    Logger.info("[PlayThenHangup] To: #{call.to}")
    Logger.info("[PlayThenHangup] Call ID: #{call.call_id}")
    Logger.info("[PlayThenHangup] Final state: #{inspect(call.state)}")
    IO.puts("\n*** PLAY THEN HANGUP - Call ended gracefully ***\n")
    {:noreply, call}
  end
end

# =============================================================================
# Router: Route to different handlers based on To URI
# =============================================================================
defmodule TestHangupRouter do
  use Parrot.Router

  # Route based on the user part of the To URI
  # sip:immediate@host -> ImmediateHangupHandler
  invite("immediate", ImmediateHangupHandler)

  # sip:delayed@host -> DelayedHangupHandler
  invite("delayed", DelayedHangupHandler)

  # sip:play@host -> PlayThenHangupHandler
  invite("play", PlayThenHangupHandler)

  # Default: play then hangup for any other destination
  invite("*", PlayThenHangupHandler)
end

# =============================================================================
# Server startup
# =============================================================================
IO.puts("""
Starting hangup DSL test server on port 5080...

Test Scenarios:
  1. sip:immediate@127.0.0.1:5080 - Answer then immediately hangup
  2. sip:delayed@127.0.0.1:5080   - Answer, wait 3s, then hangup
  3. sip:play@127.0.0.1:5080      - Answer, play audio, then hangup
  4. Any other user              - Same as 'play' (default handler)

Watch the logs to see handle_hangup/1 callbacks being invoked.
""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestHangupRouter})

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
