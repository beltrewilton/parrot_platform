# Research: RFC 2833/4733 Telephone-Event Parser

**Branch**: `003-telephone-event-parser` | **Date**: 2026-01-09

## Research Questions

1. RFC 4733 telephone-event payload format
2. Membrane Framework notification patterns for filter elements
3. RTP buffer structure in existing parrot_media codebase

---

## 1. RFC 4733 Payload Format

### Decision
Use the standard RFC 4733 4-byte payload structure with binary pattern matching.

### Rationale
RFC 4733 is the current standard (obsoletes RFC 2833) and defines a simple, fixed 4-byte format that maps directly to Elixir binary pattern matching.

### Payload Structure

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     event     |E|R| volume    |          duration             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| Field | Bits | Position | Description |
|-------|------|----------|-------------|
| event | 8 | 0-7 | Event code (0-15 for DTMF) |
| E (end) | 1 | 8 | 1 = final packet of event |
| R (reserved) | 1 | 9 | Must be 0, ignored on receive |
| volume | 6 | 10-15 | Power level (0 to -63 dBm0) |
| duration | 16 | 16-31 | Event duration in timestamp units |

### DTMF Event Codes

| Digit | Code |
|-------|------|
| 0-9 | 0-9 |
| * | 10 |
| # | 11 |
| A | 12 |
| B | 13 |
| C | 14 |
| D | 15 |

### Elixir Pattern Match

```elixir
<<event::8, end_bit::1, _reserved::1, _volume::6, _duration::16>> = payload
```

### Long Events (Segmentation)

When duration exceeds 0xFFFF (65535):
- Sender transmits packet with max duration, E bit = 0
- New segment starts with updated RTP timestamp
- Process repeats until event completes
- Only final segment has E bit = 1

**For this implementation**: We only trigger on E bit = 1, so segmentation is transparent - we simply wait for the final packet.

### Sources
- [RFC 4733: RTP Payload for DTMF Digits, Telephony Tones, and Telephony Signals](https://www.rfc-editor.org/rfc/rfc4733.html)
- [DTMF and RFC 2833 / 4733 | Andrew J Prokop](https://andrewjprokop.wordpress.com/2013/09/27/dtmf-and-rfc-2833-4733/)

---

## 2. Membrane Framework Notifications

### Decision
Use `notify_parent` action to emit `{:dtmf, digit}` notifications to the parent pipeline.

### Rationale
This is the standard Membrane pattern for elements to communicate events to their parent. The parent pipeline can handle these notifications and route them to the appropriate handler (e.g., Call.Server).

### Implementation Pattern

```elixir
# In handle_buffer callback, when DTMF detected:
{[notify_parent: {:dtmf, digit}, buffer: {:output, buffer}], state}
```

### Key Callbacks

| Callback | Purpose |
|----------|---------|
| `handle_init/2` | Initialize state with payload_type config |
| `handle_stream_format/4` | Pass through stream format unchanged |
| `handle_buffer/4` | Parse telephone-events, emit notifications, pass buffers |

### Sources
- [Membrane Core v1.2.6 Documentation](https://hexdocs.pm/membrane_core/readme.html)
- [Membrane.Element.Base](https://hexdocs.pm/membrane_core/Membrane.Element.Base.html)

---

## 3. Existing RTP Buffer Patterns in parrot_media

### Decision
Use the existing `ParrotMedia.RtpPacket` module for RTP header parsing, access payload_type from decoded packet.

### Rationale
The project already has RTP packet parsing in `rtp_packet.ex`. We can leverage this or use Membrane's RTP format structs directly.

### Existing Pattern (rtp_packet.ex)

```elixir
def decode(<<
      v::2, p::1, x::1, cc::4,
      m::1, pt::7,
      seq::16, ts::32, ssrc::32,
      rest::binary
    >>) do
  # Returns %RtpPacket{payload_type: pt, timestamp: ts, ...}
end
```

### Integration Options

1. **Use Membrane RTP Plugin**: If using `membrane_rtp_plugin`, buffers already have RTP metadata in `buffer.metadata`
2. **Use ParrotMedia.RtpPacket**: Decode raw binary if needed
3. **Direct pattern match**: For simple payload_type check

### Recommended Approach
Receive Membrane buffers with RTP format, access `buffer.metadata[:rtp]` for payload_type and timestamp. This integrates cleanly with existing Membrane pipelines.

---

## 4. Event Tracking State Machine

### Decision
Track current event using `{timestamp, event_id}` tuple to detect duplicates and correlate multi-packet events.

### Rationale
- RTP timestamp identifies the start of an event
- event_id identifies which digit
- Together they uniquely identify a single DTMF press
- Storing the combination prevents duplicate notifications on retransmitted end packets

### State Structure

```elixir
%{
  payload_type: integer(),           # Configured telephone-event PT
  current_event: nil | {timestamp, event_id},  # Currently tracked event
  completed_events: MapSet.t()       # Recently completed {timestamp, event_id} pairs
}
```

### State Transitions

```
No Event → Receiving Event (first packet with matching PT)
Receiving Event → Receiving Event (same timestamp + event_id, end_bit = 0)
Receiving Event → Completed (end_bit = 1) → emit notification → No Event
Receiving Event → New Event (different timestamp or event_id) → reset → Receiving Event
```

### Duplicate Suppression
Store completed events in a bounded set. When end_bit = 1:
1. Check if `{timestamp, event_id}` in completed_events
2. If yes: skip (duplicate retransmission)
3. If no: emit notification, add to completed_events

### Completed Events Cleanup
Option 1: Keep last N events (e.g., 10)
Option 2: Clear on timestamp discontinuity (new call)

**Recommendation**: Keep last 10 events. Simple, bounded memory, covers retransmission window.

---

## Alternatives Considered

### Alternative 1: Emit on First Packet Instead of End
- **Rejected**: Would miss long-pressed digits, risk duplicate events from retransmissions

### Alternative 2: Use GenServer Instead of Membrane Element
- **Rejected**: Would not integrate with Membrane pipeline flow control; breaks pass-through pattern

### Alternative 3: Transform Buffers Instead of Pass-Through
- **Rejected**: Unnecessary complexity; other pipeline elements need the original buffers unchanged
