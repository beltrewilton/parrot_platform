# Data Model: RFC 2833/4733 Telephone-Event Parser

**Branch**: `003-telephone-event-parser` | **Date**: 2026-01-09

## Entities

### 1. TelephoneEventPayload

RFC 4733 telephone-event payload structure (4 bytes).

| Field | Type | Bits | Description |
|-------|------|------|-------------|
| event_id | integer | 8 | Event code (0-15 for DTMF) |
| end_bit | boolean | 1 | true = final packet of event |
| reserved | integer | 1 | Always 0 (ignored) |
| volume | integer | 6 | Power level (0 to -63 dBm0) |
| duration | integer | 16 | Event duration in RTP timestamp units |

**Parsing (Elixir binary)**:
```elixir
<<event_id::8, end_bit::1, _reserved::1, _volume::6, _duration::16>>
```

### 2. DTMFEvent

Tracking state for a DTMF event in progress.

| Field | Type | Description |
|-------|------|-------------|
| timestamp | integer | RTP timestamp when event started |
| event_id | integer | Event code (0-15) |

**Identity**: `{timestamp, event_id}` tuple uniquely identifies an event.

### 3. DigitMapping

Translation from event codes to digit characters.

| event_id | digit |
|----------|-------|
| 0-9 | "0"-"9" |
| 10 | "*" |
| 11 | "#" |
| 12 | "A" |
| 13 | "B" |
| 14 | "C" |
| 15 | "D" |

**Implementation**: Pattern matching function or lookup map.

### 4. ParserState

Internal state of the Membrane filter element.

| Field | Type | Description |
|-------|------|-------------|
| payload_type | integer | Configured telephone-event payload type (e.g., 101) |
| current_event | nil \| {integer, integer} | Currently tracked `{timestamp, event_id}` |
| completed_events | MapSet.t({integer, integer}) | Recently completed events for dedup |

## State Transitions

```
┌─────────────┐
│    idle     │ (current_event = nil)
└──────┬──────┘
       │ receive telephone-event packet (matching PT)
       ▼
┌─────────────┐
│  tracking   │ (current_event = {ts, event_id})
└──────┬──────┘
       │
       ├── end_bit = 0 ──────────► stay in tracking
       │
       ├── end_bit = 1 (new) ────► emit {:dtmf, digit}
       │                            add to completed_events
       │                            → idle
       │
       ├── end_bit = 1 (dup) ────► skip (already in completed_events)
       │                            → idle
       │
       └── different event ──────► reset, start tracking new event
```

## Relationships

```
Pipeline
   │
   └── TelephoneEventParser (filter element)
           │
           ├── receives: Membrane.Buffer (RTP payload)
           │              └── metadata.rtp.payload_type
           │              └── metadata.rtp.timestamp
           │
           ├── parses: TelephoneEventPayload (4 bytes)
           │
           ├── tracks: DTMFEvent (in ParserState)
           │
           ├── emits: {:dtmf, digit} (notify_parent action)
           │
           └── outputs: Membrane.Buffer (unchanged pass-through)
```

## Validation Rules

1. **Payload size**: Must be exactly 4 bytes; log warning and skip if malformed
2. **Event code range**: 0-15 for DTMF; ignore 16+ (non-DTMF telephony events)
3. **Payload type match**: Only parse if `metadata.rtp.payload_type == configured_payload_type`
4. **Duplicate detection**: Skip if `{timestamp, event_id}` in completed_events

## Memory Bounds

- `completed_events` limited to 10 entries (sliding window)
- No unbounded accumulation for long key presses
- State is O(1) regardless of event duration
