# CDR (Call Detail Record) callback test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_cdr_callbacks.exs
#
# Demonstrates CDR generation and handler callbacks for different call dispositions.
#
# This script shows how to:
# - Implement a custom CDR handler using the ParrotSip.CDR.Handler behaviour
# - Register CDR handlers to receive call records
# - Handle different call dispositions (answered, rejected, cancelled)
# - Access CDR fields: caller, callee, timestamps, duration, disposition
# - Export CDRs to JSON and CSV formats using ParrotSip.CDR.Serializer
#
# Testing Instructions:
# =====================
#
# Using pjsua (recommended):
#   pjsua --local-port=5090 --null-audio
#
#   Then in pjsua console:
#     m                                    # Make call
#     sip:answer@127.0.0.1:5080           # Call that will be answered
#     h                                    # Hang up after a few seconds
#
#     m
#     sip:reject@127.0.0.1:5080           # Call that will be rejected (486)
#
#     m
#     sip:forbidden@127.0.0.1:5080        # Call that will be rejected (403)
#
#     m
#     sip:answer@127.0.0.1:5080           # Make another call
#     # Press Ctrl+C in pjsua to cancel before answer completes
#
# Expected behavior:
#   - Each call completion generates a CDR
#   - Custom CDR handler logs detailed CDR information
#   - CDR includes caller, callee, timestamps, duration, disposition
#   - JSON and CSV export examples are shown

require Logger

# ==============================================================================
# Custom CDR Handler - Demonstrates the ParrotSip.CDR.Handler behaviour
# ==============================================================================
defmodule TestCDRHandler do
  @moduledoc """
  Custom CDR handler that demonstrates CDR processing capabilities.

  This handler:
  - Logs detailed CDR information when calls complete
  - Shows how to access all CDR fields
  - Demonstrates JSON and CSV export
  - Collects CDRs in an ETS table for later retrieval
  """

  @behaviour ParrotSip.CDR.Handler

  require Logger

  alias ParrotSip.CDR.Serializer

  @doc """
  Initialize the handler with an ETS table to store CDRs.
  """
  @impl true
  def init(_opts) do
    # Create an ETS table to store CDRs for demonstration
    table = :ets.new(:cdr_storage, [:set, :public, :named_table])
    {:ok, %{table: table, cdr_count: 0}}
  rescue
    ArgumentError ->
      # Table already exists (script rerun)
      {:ok, %{table: :cdr_storage, cdr_count: 0}}
  end

  @doc """
  Handle a CDR when a call completes.

  This callback demonstrates:
  - Accessing all CDR fields
  - Logging CDR details
  - JSON and CSV export
  - Storing CDRs for later retrieval
  """
  @impl true
  def handle_cdr(cdr, state) do
    count = state.cdr_count + 1

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("CDR ##{count} RECEIVED")
    IO.puts(String.duplicate("=", 80))

    # Display CDR core fields
    IO.puts("\n--- Call Identification ---")
    IO.puts("  CDR ID:          #{cdr.id}")
    IO.puts("  Call ID:         #{cdr.call_id}")
    IO.puts("  Correlation ID:  #{cdr.correlation_id}")
    IO.puts("  Dialog ID:       #{cdr.dialog_id}")

    # Display caller/callee information
    IO.puts("\n--- Parties ---")
    IO.puts("  Caller URI:      #{cdr.caller_uri}")
    IO.puts("  Caller Tag:      #{cdr.caller_tag}")
    display_name = cdr.caller_display_name || "(none)"
    IO.puts("  Caller Display:  #{display_name}")
    IO.puts("  Callee URI:      #{cdr.callee_uri}")
    IO.puts("  Callee Tag:      #{cdr.callee_tag || "(none)"}")
    callee_display = cdr.callee_display_name || "(none)"
    IO.puts("  Callee Display:  #{callee_display}")

    # Display call outcome
    IO.puts("\n--- Call Outcome ---")
    IO.puts("  Disposition:     #{cdr.disposition}")
    IO.puts("  Direction:       #{cdr.direction}")
    IO.puts("  Transport:       #{cdr.transport}")

    # Display termination cause
    if cdr.termination_cause do
      tc = cdr.termination_cause
      IO.puts("\n--- Termination Cause ---")
      IO.puts("  Party:           #{tc.party}")
      IO.puts("  SIP Code:        #{tc.sip_code}")
      IO.puts("  Reason:          #{tc.reason}")
      IO.puts("  Method:          #{tc.method}")
    end

    # Display timing information
    IO.puts("\n--- Timing ---")
    IO.puts("  INVITE Received: #{format_datetime(cdr.invite_received_at)}")
    IO.puts("  Answered At:     #{format_datetime(cdr.answered_at)}")
    IO.puts("  Ended At:        #{format_datetime(cdr.ended_at)}")
    IO.puts("  Ring Duration:   #{cdr.ring_duration_ms} ms")
    IO.puts("  Talk Duration:   #{cdr.talk_duration_ms} ms")

    # Calculate total duration
    total_ms = cdr.ring_duration_ms + cdr.talk_duration_ms
    IO.puts("  Total Duration:  #{total_ms} ms (#{Float.round(total_ms / 1000, 2)} seconds)")

    # Demonstrate JSON export
    IO.puts("\n--- JSON Export ---")

    case Serializer.to_json(cdr) do
      {:ok, json} ->
        # Pretty print the JSON
        case Jason.decode(json) do
          {:ok, decoded} ->
            pretty_json = Jason.encode!(decoded, pretty: true)
            IO.puts(pretty_json)

          _ ->
            IO.puts(json)
        end

      {:error, reason} ->
        IO.puts("  Error: #{inspect(reason)}")
    end

    # Demonstrate CSV export
    IO.puts("\n--- CSV Export ---")
    headers = Serializer.csv_headers()
    row = Serializer.to_csv_row(cdr)
    IO.puts("  Headers: #{Enum.join(headers, ",")}")
    IO.puts("  Row:     #{Enum.join(row, ",")}")

    IO.puts("\n" <> String.duplicate("=", 80))

    # Store CDR in ETS table
    :ets.insert(state.table, {cdr.id, cdr})

    # Log summary at info level
    Logger.info(
      "[TestCDRHandler] CDR generated: " <>
        "#{cdr.disposition} call from #{cdr.caller_uri} to #{cdr.callee_uri}, " <>
        "duration: #{cdr.talk_duration_ms}ms"
    )

    :ok
  end

  # Format DateTime for display
  defp format_datetime(nil), do: "(none)"
  defp format_datetime(dt), do: DateTime.to_string(dt)
end

# ==============================================================================
# Handler for calls that will be answered
# ==============================================================================
defmodule AnswerHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[AnswerHandler] INVITE received from #{call.from}")
    IO.puts("\n*** Answering call - CDR will show disposition: answered ***\n")

    call
    |> answer()
    |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(_file, call) do
    Logger.info("[AnswerHandler] Playback complete, hanging up")
    call |> hangup()
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[AnswerHandler] Call ended - CDR will be generated")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler for calls that will be rejected with 486 Busy Here
# ==============================================================================
defmodule RejectHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[RejectHandler] INVITE received from #{call.from}")
    IO.puts("\n*** Rejecting call with 486 - CDR will show disposition: busy ***\n")

    call |> reject(486)
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[RejectHandler] Call rejected - CDR will be generated")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler for calls that will be rejected with 403 Forbidden
# ==============================================================================
defmodule ForbiddenHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[ForbiddenHandler] INVITE received from #{call.from}")
    IO.puts("\n*** Rejecting call with 403 - CDR will show disposition: forbidden ***\n")

    call |> reject(403)
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[ForbiddenHandler] Call rejected - CDR will be generated")
    {:noreply, call}
  end
end

# ==============================================================================
# Handler for calls that will timeout (no answer)
# ==============================================================================
defmodule NoAnswerHandler do
  use Parrot.InviteHandler

  require Logger

  @impl true
  def handle_invite(call) do
    Logger.info("[NoAnswerHandler] INVITE received from #{call.from}")
    IO.puts("\n*** Not answering - caller can cancel for cancelled disposition ***\n")

    # Don't answer - just return the call
    # The caller can cancel, or the call will eventually timeout
    {:noreply, call}
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[NoAnswerHandler] Call ended without answer - CDR will be generated")
    {:noreply, call}
  end
end

# ==============================================================================
# Router - routes calls to appropriate handlers based on dialed number
# ==============================================================================
defmodule TestCDRRouter do
  use Parrot.Router

  # Route based on the dialed number
  invite "answer", AnswerHandler
  invite "reject", RejectHandler
  invite "forbidden", ForbiddenHandler
  invite "noanswer", NoAnswerHandler

  # Default handler
  invite "*", AnswerHandler
end

# ==============================================================================
# Start the server
# ==============================================================================
IO.puts("""

================================================================================
CDR (Call Detail Record) Callback Test
================================================================================

This script demonstrates CDR generation for different call dispositions.

Test scenarios by calling:
  - sip:answer@127.0.0.1:5080    -> Answered call (hang up to see CDR)
  - sip:reject@127.0.0.1:5080    -> Rejected (486 Busy Here)
  - sip:forbidden@127.0.0.1:5080 -> Rejected (403 Forbidden)
  - sip:noanswer@127.0.0.1:5080  -> Not answered (cancel to see cancelled CDR)
  - sip:*@127.0.0.1:5080         -> Default (answered)

Each call completion will display a detailed CDR with:
  - Call identification (CDR ID, Call ID, Dialog ID)
  - Caller/Callee information (URIs, tags, display names)
  - Call outcome (disposition, direction, transport)
  - Termination cause (party, SIP code, reason, method)
  - Timing (invite received, answered, ended, durations)
  - JSON export
  - CSV export

Starting server...
""")

# Register our custom CDR handler BEFORE starting the stack
:ok = ParrotSip.CDR.register_handler(TestCDRHandler, [])
IO.puts("Registered TestCDRHandler for CDR callbacks")

# Also register the built-in logging handler to show both working
:ok = ParrotSip.CDR.register_handler(
  ParrotSip.CDR.Handlers.LoggingHandler,
  level: :info, metadata: [:call_id, :disposition, :direction]
)
IO.puts("Registered LoggingHandler for CDR logging")

# Show registered handlers
handlers = ParrotSip.CDR.list_handlers()
IO.puts("\nRegistered CDR handlers:")

for {module, _state} <- handlers do
  IO.puts("  - #{inspect(module)}")
end

IO.puts("")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestCDRRouter})

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
