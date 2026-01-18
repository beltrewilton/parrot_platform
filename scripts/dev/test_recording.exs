# Audio recording test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_recording.exs
#
# Demonstrates:
# - Basic recording: record(call, "/tmp/recording.wav")
# - Recording with options: record(call, path, max_duration: 30_000, beep: true)
# - Manual stop: stop_record(call)
# - handle_record_complete/3 callback for recording completion events
#
# Recording modes:
# - Timed recording: Auto-stops after max_duration
# - Manual recording: Use DTMF '#' to stop recording
#
# Recordings are stored in /tmp/parrot_recordings/

require Logger

# Ensure recordings directory exists
recordings_dir = "/tmp/parrot_recordings"
File.mkdir_p!(recordings_dir)

defmodule TestRecordingHandler do
  use Parrot.InviteHandler

  require Logger

  @recordings_dir "/tmp/parrot_recordings"

  @impl true
  def handle_invite(call) do
    Logger.info("[Recording] INVITE received from #{call.from}")
    Logger.info("[Recording] Answering call and starting recording...")

    # Generate unique filename with timestamp
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = Path.join(@recordings_dir, "recording_#{timestamp}.wav")

    Logger.info("[Recording] Recording to: #{filename}")
    Logger.info("[Recording] Press '#' to stop recording, or wait 30 seconds for auto-stop")

    call
    |> answer()
    |> assign(:recording_file, filename)
    |> assign(:recording_mode, :timed)
    # Start recording with 30 second max duration
    |> record(filename, max_duration: 30_000, beep: true)
    # Also collect DTMF to allow manual stop with '#'
    |> collect_dtmf(max: 1, timeout: 35_000, terminators: ["#"])
  end

  @impl true
  def handle_dtmf("#", call) do
    Logger.info("[Recording] *** '#' pressed - Stopping recording ***")
    IO.puts("\n*** '#' pressed - Stopping recording ***\n")

    call
    |> assign(:recording_mode, :manual_stop)
    |> stop_record()
  end

  def handle_dtmf(digit, call) when is_binary(digit) do
    Logger.info("[Recording] DTMF received: #{digit} (press '#' to stop recording)")
    IO.puts("\n*** DTMF: #{digit} (press '#' to stop) ***\n")

    # Continue collecting, waiting for '#'
    call |> collect_dtmf(max: 1, timeout: 30_000, terminators: ["#"])
  end

  def handle_dtmf(:timeout, call) do
    Logger.info("[Recording] DTMF collection timeout")
    {:noreply, call}
  end

  @impl true
  def handle_record_complete(filename, duration_ms, call) do
    duration_sec = duration_ms / 1000.0
    mode = call.assigns[:recording_mode] || :unknown

    Logger.info("[Recording] *** RECORDING COMPLETE ***")
    Logger.info("[Recording] File: #{filename}")
    Logger.info("[Recording] Duration: #{Float.round(duration_sec, 2)} seconds (#{duration_ms}ms)")
    Logger.info("[Recording] Mode: #{mode}")

    IO.puts("""

    ===============================================
    RECORDING COMPLETE
    ===============================================
    File:     #{filename}
    Duration: #{Float.round(duration_sec, 2)} seconds
    Mode:     #{mode}
    ===============================================

    """)

    # Check if file exists and get size
    case File.stat(filename) do
      {:ok, %{size: size}} ->
        Logger.info("[Recording] File size: #{size} bytes")
        IO.puts("File size: #{size} bytes\n")

      {:error, reason} ->
        Logger.warning("[Recording] Could not stat file: #{inspect(reason)}")
    end

    # Offer to record again
    new_timestamp = DateTime.utc_now() |> DateTime.to_unix()
    new_filename = Path.join(@recordings_dir, "recording_#{new_timestamp}.wav")

    Logger.info("[Recording] Press any digit to record again, or hang up to end")
    IO.puts("Press any digit to record again, or hang up to end\n")

    call
    |> assign(:recording_file, new_filename)
    |> assign(:recording_count, (call.assigns[:recording_count] || 0) + 1)
    |> collect_dtmf(max: 1, timeout: 30_000, terminators: [])
  end

  # When user presses a digit after recording complete, start a new recording
  @impl true
  def handle_play_complete(_file, %{assigns: %{start_new_recording: true}} = call) do
    new_filename = call.assigns[:recording_file]
    Logger.info("[Recording] Starting new recording: #{new_filename}")

    call
    |> assign(:start_new_recording, false)
    |> record(new_filename, max_duration: 30_000, beep: true)
    |> collect_dtmf(max: 1, timeout: 35_000, terminators: ["#"])
  end

  def handle_play_complete(_file, call) do
    {:noreply, call}
  end

  @impl true
  def handle_hangup(call) do
    recording_count = call.assigns[:recording_count] || 0
    Logger.info("[Recording] Call ended. Total recordings made: #{recording_count}")
    IO.puts("\nCall ended. Total recordings: #{recording_count}\n")
    {:noreply, call}
  end
end

# Handler for testing manual stop recording (no auto-duration limit)
defmodule TestManualRecordingHandler do
  use Parrot.InviteHandler

  require Logger

  @recordings_dir "/tmp/parrot_recordings"

  @impl true
  def handle_invite(call) do
    Logger.info("[ManualRecord] INVITE received from #{call.from}")
    Logger.info("[ManualRecord] Manual recording mode - no time limit")

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = Path.join(@recordings_dir, "manual_recording_#{timestamp}.wav")

    Logger.info("[ManualRecord] Recording to: #{filename}")
    Logger.info("[ManualRecord] Press '#' to stop recording")

    call
    |> answer()
    |> assign(:recording_file, filename)
    |> assign(:recording_mode, :manual)
    # Start recording without max_duration - records until manually stopped
    |> record(filename, beep: true)
    |> collect_dtmf(max: 1, timeout: 300_000, terminators: ["#"])
  end

  @impl true
  def handle_dtmf("#", call) do
    Logger.info("[ManualRecord] *** '#' pressed - Stopping recording ***")
    call |> stop_record()
  end

  def handle_dtmf(_digit, call) do
    # Continue collecting, waiting for '#'
    call |> collect_dtmf(max: 1, timeout: 300_000, terminators: ["#"])
  end

  @impl true
  def handle_record_complete(filename, duration_ms, call) do
    duration_sec = duration_ms / 1000.0
    Logger.info("[ManualRecord] Recording complete: #{filename} (#{Float.round(duration_sec, 2)}s)")

    IO.puts("""

    *** MANUAL RECORDING COMPLETE ***
    File: #{filename}
    Duration: #{Float.round(duration_sec, 2)} seconds
    """)

    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[ManualRecord] Call ended")
    {:noreply, call}
  end
end

# Router that handles both modes based on dialed number
defmodule TestRecordingRouter do
  use Parrot.Router

  # Dial 1 for timed recording (30 second max)
  invite("1*", TestRecordingHandler)

  # Dial 2 for manual recording (no time limit)
  invite("2*", TestManualRecordingHandler)

  # Default to timed recording
  invite("*", TestRecordingHandler)
end

# Start the server
IO.puts("""
Starting Recording DSL test server on port 5080...

Recordings will be saved to: #{recordings_dir}

Modes:
  - Default/Dial 1: Timed recording (30 second max, press '#' to stop early)
  - Dial 2: Manual recording (no time limit, must press '#' to stop)

Examples:
  sip:test@127.0.0.1:5080     -> Timed recording
  sip:1@127.0.0.1:5080        -> Timed recording
  sip:2@127.0.0.1:5080        -> Manual recording

""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestRecordingRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Recording server listening on port #{port}")
    IO.puts("Call sip:test@127.0.0.1:#{port} to start recording")
    IO.puts("Press Ctrl+C to stop\n")

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
