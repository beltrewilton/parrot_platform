defmodule ParrotMedia.MOS.Observer do
  @moduledoc """
  Membrane Filter element that collects RTP metrics for MOS calculation.

  The Observer is inserted into the media pipeline and performs two functions:
  1. Passes audio buffers through unchanged (zero latency requirement)
  2. Periodically sends metrics to the MOS Calculator

  ## Design Principles

  - **Zero Latency**: The Observer MUST NOT introduce any processing delay.
    Buffers are passed through directly without modification.
  - **Non-blocking**: Stats collection uses async casts to the Calculator.
  - **Fault Tolerant**: Missing Calculator is handled gracefully.

  ## Metrics Collection

  The Observer tracks:
  - Buffer count (proxy for packet count in simple mode)
  - Timestamps for timing calculations

  In the future, this can be extended to extract RTCP stats from the RTP bin
  via Membrane's notification system.

  ## Usage in Pipeline

      # In AlawPipeline or OpusPipeline
      child(:observer, %ParrotMedia.MOS.Observer{
        session_id: session_id,
        stats_interval_ms: 1000
      })

  The observer is typically placed after the RTP depayloader to observe
  decoded audio packets.

  ## Stats Interval

  By default, stats are collected every 1000ms. This can be configured
  to balance between measurement granularity and overhead.
  """

  use Membrane.Filter

  require Logger

  alias ParrotMedia.MOS.Calculator

  # ===========================================================================
  # Pad Definitions
  # ===========================================================================

  def_input_pad(:input,
    accepted_format: _any,
    flow_control: :auto
  )

  def_output_pad(:output,
    accepted_format: _any,
    flow_control: :auto
  )

  # ===========================================================================
  # Options
  # ===========================================================================

  def_options(
    session_id: [
      spec: String.t(),
      description: "Media session ID for Calculator lookup"
    ],
    stats_interval_ms: [
      spec: pos_integer(),
      default: 1000,
      description: "Interval in milliseconds between stats collection"
    ]
  )

  # ===========================================================================
  # Initialization
  # ===========================================================================

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      session_id: opts.session_id,
      stats_interval_ms: opts.stats_interval_ms,
      buffer_count: 0,
      stats_timer: nil,
      last_timestamp: nil
    }

    {[], state}
  end

  # ===========================================================================
  # Stream Format Handling
  # ===========================================================================

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    # Pass stream format through unchanged
    {[stream_format: {:output, stream_format}], state}
  end

  # ===========================================================================
  # Buffer Handling (Pass-through with Zero Latency)
  # ===========================================================================

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # CRITICAL: Pass buffer through UNCHANGED for zero latency
    # Only update our internal counters

    # Increment buffer count
    new_buffer_count = state.buffer_count + 1

    # Track timestamp if available
    new_last_timestamp =
      case buffer.pts do
        nil -> state.last_timestamp
        pts -> pts
      end

    new_state = %{
      state
      | buffer_count: new_buffer_count,
        last_timestamp: new_last_timestamp
    }

    # Pass buffer to output unchanged
    {[buffer: {:output, buffer}], new_state}
  end

  # ===========================================================================
  # Playing State (Timer Start)
  # ===========================================================================

  @impl true
  def handle_playing(_ctx, state) do
    # Start the stats collection timer when pipeline starts playing
    timer_ref = schedule_stats_collection(state.stats_interval_ms)

    {[], %{state | stats_timer: timer_ref}}
  end

  # ===========================================================================
  # Stats Collection
  # ===========================================================================

  @impl true
  def handle_info(:collect_stats, _ctx, state) do
    # Send current metrics to Calculator
    send_metrics_to_calculator(state)

    # Reset buffer count for next interval
    state = %{state | buffer_count: 0}

    # Reschedule stats collection
    timer_ref = schedule_stats_collection(state.stats_interval_ms)

    {[], %{state | stats_timer: timer_ref}}
  end

  def handle_info(_msg, _ctx, state) do
    # Ignore unknown messages
    {[], state}
  end

  # ===========================================================================
  # End of Stream
  # ===========================================================================

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    # Cancel stats timer if running
    state =
      if state.stats_timer do
        Process.cancel_timer(state.stats_timer)
        %{state | stats_timer: nil}
      else
        state
      end

    # Send final metrics before ending
    send_metrics_to_calculator(state)

    # Forward end of stream
    {[end_of_stream: :output], state}
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp schedule_stats_collection(interval_ms) do
    Process.send_after(self(), :collect_stats, interval_ms)
  end

  defp send_metrics_to_calculator(state) do
    # Build metrics map with packet counts from RTP stream observation
    # Jitter and delay are provided separately by RTCP.Receiver when RTCP reports arrive
    # The Calculator merges these metrics for MOS calculation
    metrics = %{
      packets_received: state.buffer_count,
      packets_expected: state.buffer_count,
      # Placeholder values - real values come from RTCP.Receiver via {:rtcp_metrics, _}
      jitter_ms: 0.0,
      delay_ms: 0.0
    }

    # Only send if we have data
    if state.buffer_count > 0 do
      # Try to send metrics to Calculator
      # Use Registry lookup to find Calculator for this session
      case Registry.lookup(ParrotMedia.MOS.Registry, state.session_id) do
        [{pid, _}] ->
          Calculator.add_metrics(pid, metrics)

        [] ->
          # Calculator not found - this is OK, might not be started yet
          Logger.debug(
            "[MOS.Observer] No Calculator found for session #{state.session_id}"
          )
      end
    end
  end
end
