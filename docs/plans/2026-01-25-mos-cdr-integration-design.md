# MOS Scoring Integration with CDRs

**Date:** 2026-01-25
**Status:** Approved

## Overview

Integrate MOS (Mean Opinion Score) CallSummary data into CDRs while maintaining clean app boundaries between parrot_sip and parrot_media.

## Goals

- Include full MOS CallSummary in CDRs (min/max/avg MOS, packet stats, quality events)
- Maintain parrot_sip independence from parrot_media
- Handle missing MOS data gracefully
- Support JSON (full detail) and CSV (flattened) serialization

## Architecture

### Data Flow

```
Call terminates
      │
      ▼
DialogStatem.terminate/3
      │
      ▼
Calls mos_fetcher.(session_id)  ◄── injected by Parrot DSL layer
      │                              (wraps ParrotMedia.MOS.call_summary/1)
      ▼
Returns %{...} map or nil
      │
      ▼
CDR.Generator builds CDR with media_info.mos_summary
      │
      ▼
CDR dispatched to handlers
```

### App Boundaries

- **parrot_sip** - Defines CDR structs, generation, dispatch. No parrot_media dependency.
- **parrot_media** - Owns MOS calculation, CallSummary struct, Calculator GenServer.
- **parrot** (DSL) - Bridges both apps. Injects the MOS fetcher callback when creating dialogs.

### Key Principle

The MOS fetcher is a simple function `(session_id) -> map() | nil`. parrot_sip doesn't know or care where the data comes from - it just calls the function if one was provided.

## Struct Changes

### MediaInfo Struct

```elixir
defmodule ParrotSip.CDR.MediaInfo do
  @type t :: %__MODULE__{
    codec: String.t() | nil,
    codec_payload_type: non_neg_integer() | nil,
    mos_summary: mos_summary() | nil,  # Replaces mos_score
    packets_sent: non_neg_integer() | nil,
    packets_received: non_neg_integer() | nil,
    jitter_ms: float() | nil
  }

  @type mos_summary :: %{
    min_mos: float(),
    max_mos: float(),
    avg_mos: float(),
    total_packets: non_neg_integer(),
    total_lost: non_neg_integer(),
    overall_loss_percent: float(),
    intervals_calculated: non_neg_integer(),
    duration_ms: non_neg_integer(),
    status: :complete | :insufficient_data | :one_way_audio | :unavailable,
    quality_events: [quality_event()]
  }

  @type quality_event :: %{
    timestamp: DateTime.t(),
    mos_value: float(),
    threshold_name: atom(),
    direction: :rising | :falling
  }
end
```

The `mos_summary` is defined as a plain map type, not the actual `ParrotMedia.MOS.CallSummary` struct. This keeps parrot_sip independent.

## Callback Injection

### DialogStatem Data Struct

```elixir
defmodule Data do
  defstruct [
    # ... existing fields ...
    media_session_id: nil,      # Already exists
    mos_fetcher: nil            # NEW: fn(session_id) -> map() | nil
  ]
end
```

### Injection in Bridge.Handler

```elixir
def handle_request(%Message{method: "INVITE"} = request, state) do
  dialog_opts = [
    # ... existing opts ...
    mos_fetcher: &mos_fetcher/1
  ]

  DialogStatem.start_link(dialog_opts)
end

defp mos_fetcher(session_id) do
  case ParrotMedia.MOS.call_summary(session_id) do
    {:ok, %ParrotMedia.MOS.CallSummary{} = summary} ->
      CallSummary.to_map(summary)
    {:error, _} ->
      nil
  end
end
```

## CDR Generation

### In DialogStatem.terminate/3

```elixir
defp generate_and_dispatch_cdr(data, state, reason) do
  mos_summary = fetch_mos_summary(data)
  media_info = build_media_info(data, mos_summary)

  timing = %{
    invite_received_at: data.invite_received_at,
    answered_at: data.answered_at,
    ended_at: DateTime.utc_now()
  }

  cdr = Generator.generate(data.dialog, termination_cause, timing, media_info)
  # ... dispatch to handlers ...
end

defp fetch_mos_summary(%{mos_fetcher: nil}), do: nil
defp fetch_mos_summary(%{media_session_id: nil}), do: nil
defp fetch_mos_summary(%{mos_fetcher: fetcher, media_session_id: session_id}) do
  try do
    fetcher.(session_id)
  rescue
    _ -> nil  # Don't let MOS failures break CDR generation
  end
end

defp build_media_info(data, mos_summary) do
  %MediaInfo{
    codec: data.negotiated_codec,
    codec_payload_type: data.payload_type,
    mos_summary: mos_summary,
    packets_sent: get_in(mos_summary, [:total_packets]),
    packets_received: calculate_received(mos_summary),
    jitter_ms: extract_avg_jitter(mos_summary)
  }
end
```

## Serialization

### JSON (Full Nested Structure)

```elixir
defp serialize_mos_summary(nil), do: nil
defp serialize_mos_summary(summary) do
  %{
    "min_mos" => summary.min_mos,
    "max_mos" => summary.max_mos,
    "avg_mos" => summary.avg_mos,
    "total_packets" => summary.total_packets,
    "total_lost" => summary.total_lost,
    "overall_loss_percent" => summary.overall_loss_percent,
    "status" => to_string(summary.status),
    "quality_events" => Enum.map(summary.quality_events, &serialize_event/1)
  }
end
```

### CSV (Flattened Key Fields)

New columns:
- `mos_avg`
- `mos_min`
- `mos_max`
- `mos_status`
- `packet_loss_percent`

## Files to Modify

1. `apps/parrot_sip/lib/parrot_sip/cdr/media_info.ex` - Add mos_summary type, remove mos_score
2. `apps/parrot_sip/lib/parrot_sip/dialog_statem.ex` - Add mos_fetcher to Data, fetch in terminate
3. `apps/parrot_sip/lib/parrot_sip/cdr/serializer.ex` - JSON/CSV serialization for mos_summary
4. `apps/parrot/lib/parrot/bridge/handler.ex` - Inject mos_fetcher callback
5. `apps/parrot_media/lib/parrot_media/mos/call_summary.ex` - Add to_map/1 function

## Testing Strategy

### Unit Tests

- MediaInfo accepts full MOS summary map
- MediaInfo handles nil mos_summary gracefully
- Serializer produces correct JSON structure
- Serializer produces correct CSV columns

### Integration Tests

- CDR includes MOS summary when fetcher provided
- CDR has nil mos_summary when fetcher returns nil
- CDR generated even if mos_fetcher crashes
- End-to-end: call with MOS scoring produces CDR with quality data

### Key Principle

Tests inject simple mock functions rather than mocking parrot_media directly, keeping parrot_sip tests independent.

## Error Handling

- Missing MOS fetcher: `mos_summary: nil`
- Missing media session ID: `mos_summary: nil`
- MOS fetcher returns error: `mos_summary: nil`
- MOS fetcher crashes: `mos_summary: nil` (try/rescue protection)

CDR generation never fails due to MOS issues. A CDR with `mos_summary: nil` is always better than no CDR.
