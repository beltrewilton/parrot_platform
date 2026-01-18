# Test playing multiple audio files and looping with Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_multi_play.exs
#
# This script demonstrates:
# - Playing a sequence of multiple files: play(call, ["file1.wav", "file2.wav", "file3.wav"])
# - Using handle_play_complete/2 callback to track each file completion
# - Testing looping playback with play(call, "file.wav", loop: true)
# - Chaining multiple play operations
#
# NOTE: Since only parrot-welcome.wav is available, we use it multiple times
# to demonstrate the multi-file and looping patterns. In production, you would
# use different audio files (e.g., welcome.wav, menu.wav, goodbye.wav).

require Logger

defmodule TestMultiPlayHandler do
  use Parrot.InviteHandler

  require Logger

  # Audio file - in production, use different files for each purpose
  @welcome_audio "priv/audio/parrot-welcome.wav"

  @impl true
  def handle_invite(call) do
    Logger.info("[MultiPlay] INVITE received from #{call.from}")
    Logger.info("[MultiPlay] Demonstrating multi-file playback...")

    # Initialize a counter to track which playback mode we're in
    call
    |> answer()
    |> assign(:play_mode, :sequence)
    |> assign(:sequence_count, 0)
    # Play a sequence of files - the same file 3 times to simulate multiple files
    # In production: play(call, ["welcome.wav", "menu.wav", "options.wav"])
    |> play([@welcome_audio, @welcome_audio, @welcome_audio])
  end

  @impl true
  def handle_play_complete(file, %{assigns: %{play_mode: :sequence, sequence_count: count}} = call) do
    new_count = count + 1
    Logger.info("[MultiPlay] Sequence playback #{new_count}/3 complete: #{file}")

    if new_count >= 3 do
      # Sequence complete, switch to chained play demonstration
      Logger.info("[MultiPlay] Sequence complete! Starting chained play demo...")

      call
      |> assign(:play_mode, :chain)
      |> assign(:chain_count, 0)
      # Chain multiple play operations - each returns immediately, executes in order
      |> play(@welcome_audio)
    else
      call |> assign(:sequence_count, new_count)
    end
  end

  def handle_play_complete(file, %{assigns: %{play_mode: :chain, chain_count: count}} = call) do
    new_count = count + 1
    Logger.info("[MultiPlay] Chained play #{new_count}/2 complete: #{file}")

    if new_count >= 2 do
      # Chained plays complete, demonstrate looping
      Logger.info("[MultiPlay] Chained plays complete! Starting loop demo (5 seconds)...")

      call
      |> assign(:play_mode, :loop)
      |> assign(:loop_start_time, System.monotonic_time(:millisecond))
      # Play in loop mode - will repeat until stopped
      |> play(@welcome_audio, loop: true)
    else
      # Queue another chained play
      call
      |> assign(:chain_count, new_count)
      |> play(@welcome_audio)
    end
  end

  def handle_play_complete(file, %{assigns: %{play_mode: :loop, loop_start_time: start_time}} = call) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("[MultiPlay] Loop iteration complete: #{file} (elapsed: #{elapsed}ms)")

    # Let the loop run for about 5 seconds then hang up
    if elapsed > 5_000 do
      Logger.info("[MultiPlay] Loop demo complete after #{elapsed}ms, hanging up...")
      call |> hangup()
    else
      # Loop mode continues automatically via the loop: true option
      # This callback is informational; looping is handled by the media layer
      {:noreply, call |> assign(:loop_iterations, (call.assigns[:loop_iterations] || 0) + 1)}
    end
  end

  def handle_play_complete(file, call) do
    # Fallback for any other playback completion
    Logger.info("[MultiPlay] Playback complete: #{file}")
    {:noreply, call}
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[MultiPlay] Call ended")
    Logger.info("[MultiPlay] Summary:")
    Logger.info("[MultiPlay]   - Sequence play: 3 files played in order")
    Logger.info("[MultiPlay]   - Chained play: 2 operations queued and executed")
    Logger.info("[MultiPlay]   - Loop play: Ran for ~5 seconds")
    {:noreply, call}
  end
end

defmodule TestMultiPlayRouter do
  use Parrot.Router

  invite("*", TestMultiPlayHandler)
end

IO.puts("""
Starting multi-play DSL test server on port 5080...

This test demonstrates three playback patterns:
1. SEQUENCE: play(call, ["file1.wav", "file2.wav", "file3.wav"])
   - Plays files in order, one handle_play_complete per file

2. CHAINED: Multiple play() calls piped together
   - call |> play("a.wav") |> play("b.wav")
   - Operations execute in order

3. LOOP: play(call, "file.wav", loop: true)
   - Repeats until explicitly stopped
   - Demo runs for 5 seconds then hangs up

""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestMultiPlayRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}")
    IO.puts("Call sip:test@127.0.0.1:#{port} to test multi-file playback")
    IO.puts("Press Ctrl+C to stop\n")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
