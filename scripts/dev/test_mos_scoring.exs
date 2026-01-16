# MOS (Mean Opinion Score) quality monitoring test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_mos_scoring.exs
#
# This demonstrates:
# - Setting up MOS monitoring for incoming calls
# - Receiving real-time MOS score updates during the call
# - Logging quality metrics (packet loss, jitter, latency, MOS score)
# - Handling MOS threshold alerts when quality degrades/improves
# - Displaying final call quality summary after hangup

require Logger

# ===========================================================================
# MOS Quality Handler
#
# Implements the ParrotMedia.MOS.Handler behaviour to receive quality events.
# This handler logs all MOS events and tracks quality statistics.
# ===========================================================================
defmodule TestMOSQualityHandler do
  @behaviour ParrotMedia.MOS.Handler

  require Logger

  @impl true
  def init(opts) do
    Logger.info("[MOS-Handler] Initialized with opts: #{inspect(opts)}")

    state = %{
      session_id: opts[:session_id],
      scores: [],
      threshold_events: [],
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_mos_score(session_id, score, state) do
    # Log the MOS score with quality metrics
    Logger.info("""
    [MOS-Handler] Score Update for #{session_id}
      MOS Score: #{format_mos(score.value)} (#{score.quality_level})
      Packet Loss: #{format_percent(score.packet_loss_percent)}
      Jitter: #{format_ms(score.jitter_ms)}
      Delay: #{format_ms(score.delay_ms)}
      R-Factor: #{format_r_factor(score.r_factor)}
    """)

    # Print a visual quality indicator to console
    print_quality_bar(score.value, score.quality_level)

    # Track scores for summary
    new_state = Map.update!(state, :scores, &[score | &1])
    {:ok, new_state}
  end

  @impl true
  def handle_threshold_crossed(session_id, event, state) do
    direction_arrow = if event.direction == :falling, do: "v", else: "^"
    direction_text = if event.direction == :falling, do: "DEGRADED", else: "IMPROVED"

    Logger.warning("""
    [MOS-Handler] QUALITY ALERT for #{session_id}
      #{direction_arrow} Quality #{direction_text} - crossed #{event.threshold} threshold
      Current MOS: #{format_mos(event.mos)}
      Direction: #{event.direction}
      Timestamp: #{event.timestamp}
    """)

    # Print alert to console
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  QUALITY #{direction_text}! Crossed :#{event.threshold} threshold")
    IO.puts("  MOS: #{format_mos(event.mos)} - Direction: #{event.direction}")
    IO.puts(String.duplicate("=", 60) <> "\n")

    # Track threshold events
    new_state = Map.update!(state, :threshold_events, &[event | &1])
    {:ok, new_state}
  end

  @impl true
  def handle_call_summary(session_id, summary, state) do
    Logger.info("""
    [MOS-Handler] Call Quality Summary for #{session_id}
    #{String.duplicate("=", 50)}
      Status: #{summary.status}
      Duration: #{format_duration(summary.duration_ms)}

      MOS Statistics:
        Average: #{format_mos(summary.avg_mos)}
        Minimum: #{format_mos(summary.min_mos)}
        Maximum: #{format_mos(summary.max_mos)}

      Packet Statistics:
        Total Packets: #{summary.total_packets}
        Packets Lost: #{summary.total_lost}
        Loss Rate: #{format_percent(summary.overall_loss_percent)}

      Intervals Calculated: #{summary.intervals_calculated}
      Quality Events: #{length(summary.quality_events)}
    #{String.duplicate("=", 50)}
    """)

    # Print summary to console
    print_call_summary(summary)

    {:ok, state}
  end

  # ===========================================================================
  # Private Formatting Functions
  # ===========================================================================

  defp format_mos(nil), do: "N/A"
  defp format_mos(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp format_percent(nil), do: "N/A"
  defp format_percent(value), do: "#{:erlang.float_to_binary(value, decimals: 2)}%"

  defp format_ms(nil), do: "N/A"
  defp format_ms(value), do: "#{:erlang.float_to_binary(value, decimals: 1)} ms"

  defp format_r_factor(nil), do: "N/A"
  defp format_r_factor(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp format_duration(ms) when is_integer(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)
    "#{minutes}m #{remaining_seconds}s"
  end

  defp print_quality_bar(mos, quality_level) do
    # Create a visual quality bar (1.0 to 5.0 scale)
    bar_length = 40
    filled = round((mos - 1.0) / 4.0 * bar_length)
    empty = bar_length - filled

    quality_indicator =
      case quality_level do
        :excellent -> "[EXCELLENT]"
        :good -> "[GOOD]     "
        :fair -> "[FAIR]     "
        :poor -> "[POOR]     "
        _ -> "[...]      "
      end

    bar = String.duplicate("#", filled) <> String.duplicate("-", empty)
    IO.puts("  MOS: [#{bar}] #{format_mos(mos)} #{quality_indicator}")
  end

  defp print_call_summary(summary) do
    IO.puts("\n" <> String.duplicate("*", 60))
    IO.puts("*  CALL QUALITY SUMMARY")
    IO.puts(String.duplicate("*", 60))
    IO.puts("*")
    IO.puts("*  Session: #{summary.session_id}")
    IO.puts("*  Status: #{summary.status}")
    IO.puts("*  Duration: #{format_duration(summary.duration_ms)}")
    IO.puts("*")
    IO.puts("*  MOS Scores:")
    IO.puts("*    Average: #{format_mos(summary.avg_mos)}")
    IO.puts("*    Minimum: #{format_mos(summary.min_mos)}")
    IO.puts("*    Maximum: #{format_mos(summary.max_mos)}")
    IO.puts("*")
    IO.puts("*  Packets:")
    IO.puts("*    Total: #{summary.total_packets}")
    IO.puts("*    Lost: #{summary.total_lost} (#{format_percent(summary.overall_loss_percent)})")
    IO.puts("*")
    IO.puts("*  Quality Events: #{length(summary.quality_events)}")
    IO.puts("*")
    IO.puts(String.duplicate("*", 60) <> "\n")
  end
end

# ===========================================================================
# SIP Invite Handler
#
# Handles incoming SIP calls, answers them, registers for MOS monitoring,
# and plays audio to generate media traffic for quality analysis.
# ===========================================================================
defmodule TestMOSInviteHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[MOS-Test] INVITE received from #{call.from}")
    Logger.info("[MOS-Test] Setting up MOS monitoring...")

    # Answer the call first
    call = answer(call)

    # Register for MOS events using the handler behaviour
    # The session_id is typically the same as the call_id or dialog_id
    session_id = call.call_id
    Logger.info("[MOS-Test] Registering MOS handler for session: #{session_id}")

    # Register the MOS quality handler
    case ParrotMedia.MOS.register_handler(
           session_id,
           {TestMOSQualityHandler, %{session_id: session_id}}
         ) do
      :ok ->
        Logger.info("[MOS-Test] MOS handler registered successfully")

      {:error, :not_found} ->
        Logger.warning("[MOS-Test] MOS calculator not found - MOS may be disabled or media not started")
    end

    # Play audio to generate media traffic
    # This allows the MOS calculator to analyze the call quality
    Logger.info("[MOS-Test] Playing audio to generate media for quality analysis...")
    call |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(file, call) do
    Logger.info("[MOS-Test] Playback complete: #{file}")

    # Query and display current MOS score
    session_id = call.call_id

    case ParrotMedia.MOS.current_score(session_id) do
      {:ok, nil} ->
        Logger.info("[MOS-Test] No MOS score calculated yet (not enough samples)")

      {:ok, score} ->
        Logger.info(
          "[MOS-Test] Current MOS: #{score.value} (#{score.quality_level})"
        )

      {:error, :not_found} ->
        Logger.info("[MOS-Test] MOS calculator not active for this session")
    end

    # Continue playing to extend the call and allow more MOS calculations
    # Play the file again in a loop
    call |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[MOS-Test] Call ended - fetching final quality summary...")

    # Try to get the call summary before the calculator is cleaned up
    session_id = call.call_id

    case ParrotMedia.MOS.call_summary(session_id) do
      {:ok, summary} ->
        Logger.info("[MOS-Test] Final MOS average: #{summary.avg_mos}")

      {:error, :not_found} ->
        Logger.info("[MOS-Test] Summary not available (calculator already cleaned up)")
    end

    {:noreply, call}
  end
end

# ===========================================================================
# Router Configuration
# ===========================================================================
defmodule TestMOSRouter do
  use Parrot.Router

  invite("*", TestMOSInviteHandler)
end

# ===========================================================================
# Main Script Execution
# ===========================================================================
IO.puts("""

========================================
  MOS Quality Monitoring Test Server
========================================

This test demonstrates real-time call quality monitoring using
the MOS (Mean Opinion Score) system based on ITU-T G.107 E-model.

Quality Levels:
  Excellent : MOS >= 4.0 (toll quality)
  Good      : MOS >= 3.5 (acceptable)
  Fair      : MOS >= 3.0 (noticeable impairments)
  Poor      : MOS <  3.0 (significant problems)

MOS Configuration:
""")

# Display current MOS configuration
config = ParrotMedia.MOS.config()
IO.puts("  Enabled: #{config[:enabled]}")
IO.puts("  Interval: #{config[:interval_ms]} ms")
IO.puts("  Min packets per interval: #{config[:min_packets_per_interval]}")

IO.puts("\nConfigured Thresholds:")

for threshold <- ParrotMedia.MOS.thresholds() do
  IO.puts("  :#{threshold.name} - MOS #{threshold.value} (hysteresis: #{threshold.hysteresis})")
end

IO.puts("\n========================================\n")
IO.puts("Starting MOS test server on port 5080...")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestMOSRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}")
    IO.puts("Call sip:test@127.0.0.1:#{port} to start MOS monitoring")
    IO.puts("The call will play audio in a loop - hang up to see quality summary")
    IO.puts("\nPress Ctrl+C to stop\n")

    # Keep the script running
    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
