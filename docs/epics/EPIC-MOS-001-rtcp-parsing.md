# EPIC-MOS-001: RTCP Parsing for MOS Quality Metrics

## Overview

Implement RTCP (Real-time Transport Control Protocol) parsing to extract jitter, delay, and packet loss metrics from Receiver Reports (RR) and Sender Reports (SR). This enables realistic MOS scoring based on actual network conditions rather than placeholder values.

## Business Value

- Accurate MOS scores reflecting real call quality
- Ability to detect and alert on quality degradation
- Foundation for quality-based call routing decisions
- Compliance with VoIP quality monitoring standards

## Dependencies

- None (can start immediately)
- Parallel work possible with EPIC-MOS-002 (Sequence Number Tracking)

## Technical Background

### RTCP Packet Types (RFC 3550)

| Type | Name | Purpose |
|------|------|---------|
| 200 | SR (Sender Report) | Statistics from active senders |
| 201 | RR (Receiver Report) | Statistics from receivers |
| 202 | SDES | Source description items |
| 203 | BYE | End of participation |
| 204 | APP | Application-specific |

### Receiver Report Block Structure (RFC 3550 Section 6.4.2)

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 SSRC_1 (SSRC of first source)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| fraction lost |       cumulative number of packets lost       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           extended highest sequence number received           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      interarrival jitter                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         last SR (LSR)                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   delay since last SR (DLSR)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### Key Metrics to Extract

1. **Fraction Lost**: 8-bit fixed point, packets lost / packets expected since last RR
2. **Cumulative Lost**: 24-bit signed, total packets lost since session start
3. **Interarrival Jitter**: 32-bit, estimated variance of RTP packet interarrival time (in timestamp units)
4. **LSR + DLSR**: Used to calculate round-trip time

---

## Tasks

### Phase 1: RTCP Parser Module

#### Task 1.1: Create RTCP packet parser
**File**: `apps/parrot_media/lib/parrot_media/rtcp/parser.ex`
**Effort**: Medium
**Parallelizable**: Yes

Create a parser module for RTCP packets using binary pattern matching.

```elixir
defmodule ParrotMedia.RTCP.Parser do
  @moduledoc """
  Parses RTCP packets according to RFC 3550.
  """

  @type packet :: sr() | rr() | sdes() | bye() | app()

  @spec parse(binary()) :: {:ok, [packet()]} | {:error, term()}
  def parse(data)

  @spec parse_receiver_report(binary()) :: {:ok, rr()} | {:error, term()}
  def parse_receiver_report(data)

  @spec parse_sender_report(binary()) :: {:ok, sr()} | {:error, term()}
  def parse_sender_report(data)
end
```

**Acceptance Criteria**:
- [ ] Parse RTCP compound packets (multiple packets in one UDP datagram)
- [ ] Extract all RR block fields correctly
- [ ] Extract SR block fields (for NTP timestamp, packet counts)
- [ ] Handle malformed packets gracefully with `{:error, reason}`
- [ ] Unit tests with real RTCP packet captures

#### Task 1.2: Define RTCP struct types
**File**: `apps/parrot_media/lib/parrot_media/rtcp/packets.ex`
**Effort**: Small
**Parallelizable**: Yes

```elixir
defmodule ParrotMedia.RTCP.Packets do
  defmodule ReceiverReport do
    defstruct [:ssrc, :report_blocks]
  end

  defmodule ReportBlock do
    defstruct [
      :ssrc,              # Source being reported on
      :fraction_lost,     # 0-255 (divide by 256 for percentage)
      :cumulative_lost,   # Total packets lost (signed 24-bit)
      :highest_seq,       # Extended highest sequence number
      :jitter,            # Interarrival jitter (timestamp units)
      :lsr,               # Last SR timestamp (middle 32 bits of NTP)
      :dlsr               # Delay since last SR (1/65536 seconds)
    ]
  end

  defmodule SenderReport do
    defstruct [:ssrc, :ntp_timestamp, :rtp_timestamp, :packet_count, :octet_count, :report_blocks]
  end
end
```

**Acceptance Criteria**:
- [ ] All struct fields documented with types
- [ ] Helper functions to convert raw values (e.g., jitter timestamp units → ms)

#### Task 1.3: Unit tests for RTCP parser
**File**: `apps/parrot_media/test/parrot_media/rtcp/parser_test.exs`
**Effort**: Medium
**Parallelizable**: After 1.1

**Test Cases**:
- [ ] Parse valid RR with single report block
- [ ] Parse valid RR with multiple report blocks
- [ ] Parse valid SR with report blocks
- [ ] Parse compound RTCP packet (SR + SDES + RR)
- [ ] Handle truncated packets
- [ ] Handle invalid version field
- [ ] Handle zero-length packets
- [ ] Property-based tests for round-trip (if generating RTCP)

---

### Phase 2: RTCP Reception in Pipeline

#### Task 2.1: Create RTCP demuxer element
**File**: `apps/parrot_media/lib/parrot_media/rtcp/demuxer.ex`
**Effort**: Medium
**Parallelizable**: After Phase 1

RTP and RTCP can arrive on the same port (RFC 5761 multiplexing) or separate ports. Create a Membrane element to separate them.

```elixir
defmodule ParrotMedia.RTCP.Demuxer do
  use Membrane.Filter

  # RTP: payload type 0-127, 200+ are RTCP
  # RTCP: first byte has version=2 and PT 200-204

  def_output_pad :rtp, ...
  def_output_pad :rtcp, ...
end
```

**Acceptance Criteria**:
- [ ] Correctly identify RTP vs RTCP packets
- [ ] Forward RTP packets unchanged to :rtp pad
- [ ] Forward RTCP packets to :rtcp pad
- [ ] Handle edge cases (ambiguous packets)

#### Task 2.2: Create RTCP sink element
**File**: `apps/parrot_media/lib/parrot_media/rtcp/sink.ex`
**Effort**: Medium
**Parallelizable**: After 2.1

Membrane sink that receives RTCP packets, parses them, and forwards metrics to the MOS Calculator.

```elixir
defmodule ParrotMedia.RTCP.Sink do
  use Membrane.Sink

  def_options [
    mos_calculator: [spec: pid(), description: "MOS Calculator to send metrics to"]
  ]

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case Parser.parse(buffer.payload) do
      {:ok, packets} ->
        Enum.each(packets, &process_rtcp_packet(&1, state))
        {[], state}
      {:error, _} ->
        {[], state}
    end
  end
end
```

**Acceptance Criteria**:
- [ ] Parse incoming RTCP packets
- [ ] Extract jitter from RR blocks
- [ ] Calculate RTT from LSR/DLSR
- [ ] Send metrics to MOS Calculator via `add_rtcp_metrics/2`

#### Task 2.3: Integrate RTCP into pipelines
**Files**:
- `apps/parrot_media/lib/parrot_media/alaw_pipeline.ex`
- `apps/parrot_media/lib/parrot_media/opus_pipeline.ex`
**Effort**: Medium
**Parallelizable**: After 2.1, 2.2

Add RTCP demuxing and sink to receive pipelines.

**Acceptance Criteria**:
- [ ] RTCP packets are captured from UDP socket
- [ ] RTCP sink receives parsed packets
- [ ] Metrics flow to MOS Calculator
- [ ] No impact on RTP latency

---

### Phase 3: MOS Calculator Integration

#### Task 3.1: Add RTCP metrics API to Calculator
**File**: `apps/parrot_media/lib/parrot_media/mos/calculator.ex`
**Effort**: Small
**Parallelizable**: After Phase 1

```elixir
@spec add_rtcp_metrics(pid(), map()) :: :ok
def add_rtcp_metrics(pid, %{
  jitter_ms: jitter,
  rtt_ms: rtt,
  fraction_lost: loss,
  direction: direction
}) do
  GenServer.cast(pid, {:add_rtcp_metrics, metrics})
end
```

**Acceptance Criteria**:
- [ ] New API function for RTCP-sourced metrics
- [ ] Metrics merged with Observer metrics in Interval
- [ ] Direction-aware (inbound RR = outbound quality)

#### Task 3.2: Update Interval to use RTCP metrics
**File**: `apps/parrot_media/lib/parrot_media/mos/interval.ex`
**Effort**: Small
**Parallelizable**: After 3.1

Replace placeholder jitter/delay with RTCP-sourced values.

**Acceptance Criteria**:
- [ ] Jitter from RTCP RR used in E-Model calculation
- [ ] RTT from LSR/DLSR used for delay
- [ ] Graceful fallback if no RTCP received

#### Task 3.3: Add bidirectional MOS tracking
**File**: `apps/parrot_media/lib/parrot_media/mos/calculator.ex`
**Effort**: Medium
**Parallelizable**: After 3.1

Track separate MOS for inbound and outbound streams.

```elixir
%{
  inbound: %{mos: 4.2, jitter: 5.0, loss: 0.1},   # From Observer
  outbound: %{mos: 3.8, jitter: 12.0, loss: 1.2}  # From remote's RR
}
```

**Acceptance Criteria**:
- [ ] Separate MOS scores for each direction
- [ ] Handler callbacks include direction
- [ ] Call summary includes both directions

---

### Phase 4: Testing

#### Task 4.1: Integration test with SIPp RTCP
**File**: `apps/parrot_media/test/parrot_media/mos/rtcp_integration_test.exs`
**Effort**: Medium
**Parallelizable**: After Phase 3

**Test Scenarios**:
- [ ] SIPp sends RTP+RTCP, verify metrics extracted
- [ ] Verify jitter values match SIPp's actual jitter
- [ ] Verify RTT calculation is reasonable
- [ ] Test with packet loss simulation

#### Task 4.2: Create RTCP test fixtures
**File**: `apps/parrot_media/test/fixtures/rtcp/`
**Effort**: Small
**Parallelizable**: Yes

Capture real RTCP packets for unit tests:
- [ ] `rr_single_block.bin` - Simple RR
- [ ] `rr_multi_block.bin` - RR with multiple sources
- [ ] `sr_with_rr.bin` - SR containing RR blocks
- [ ] `compound.bin` - SR + SDES + RR compound packet

---

## Definition of Done

- [ ] All tasks completed and reviewed
- [ ] MOS scores reflect actual jitter/delay from RTCP
- [ ] Bidirectional quality tracking works
- [ ] Integration tests pass with SIPp
- [ ] Documentation updated

## Estimated Effort

| Phase | Tasks | Parallelizable |
|-------|-------|----------------|
| Phase 1 | 3 | Yes (1.1, 1.2 parallel) |
| Phase 2 | 3 | Sequential |
| Phase 3 | 3 | Mostly parallel |
| Phase 4 | 2 | Yes |

**Total**: ~11 tasks, moderate complexity

## References

- RFC 3550: RTP/RTCP Protocol
- RFC 5761: Multiplexing RTP and RTCP
- ITU-T G.107: E-Model for MOS calculation
