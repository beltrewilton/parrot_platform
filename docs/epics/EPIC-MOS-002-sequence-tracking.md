# EPIC-MOS-002: RTP Sequence Number Tracking for Packet Loss Detection

## Overview

Implement RTP sequence number tracking in the MOS Observer to detect actual packet loss on inbound audio streams. This replaces the current placeholder (0% loss) with real measurements based on gaps in RTP sequence numbers.

## Business Value

- Accurate packet loss metrics for MOS calculation
- Early detection of network issues
- Enables quality alerts based on actual loss thresholds
- Foundation for packet loss concealment decisions

## Dependencies

- None (can start immediately)
- Parallel work possible with EPIC-MOS-001 (RTCP Parsing)
- Complements RTCP metrics (RTCP provides loss from remote's perspective)

## Technical Background

### RTP Header Structure (RFC 3550)

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|V=2|P|X|  CC   |M|     PT      |       sequence number         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           timestamp                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             SSRC                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### Sequence Number Behavior

- 16-bit unsigned integer (0-65535)
- Increments by 1 for each RTP packet
- Wraps around from 65535 to 0
- Initial value is random (RFC 3550 Section 5.1)
- Gaps indicate packet loss
- Duplicates possible (network retransmission)
- Out-of-order delivery possible

### Packet Loss Calculation

```
expected = (highest_seq - first_seq + 1) + cycles * 65536
received = actual packet count
lost = expected - received
loss_percent = (lost / expected) * 100
```

### Extended Sequence Number

To handle wraparound, use 32-bit extended sequence number:
```
extended_seq = (cycles << 16) | seq
```

---

## Tasks

### Phase 1: Sequence Tracker Module

#### Task 1.1: Create RTP sequence tracker
**File**: `apps/parrot_media/lib/parrot_media/rtp/sequence_tracker.ex`
**Effort**: Medium
**Parallelizable**: Yes

```elixir
defmodule ParrotMedia.RTP.SequenceTracker do
  @moduledoc """
  Tracks RTP sequence numbers to detect packet loss, duplicates,
  and out-of-order delivery.
  """

  defstruct [
    :ssrc,
    :first_seq,
    :highest_seq,
    :cycles,           # Wraparound count
    :received,         # Total packets received
    :expected_prior,   # Expected at last interval
    :received_prior,   # Received at last interval
    :out_of_order,     # Out-of-order count
    :duplicates,       # Duplicate count
    :late_threshold    # Max reorder window (default 100)
  ]

  @spec new() :: t()
  @spec update(t(), non_neg_integer()) :: t()
  @spec packet_loss(t()) :: {lost :: integer(), expected :: integer()}
  @spec interval_loss(t()) :: {lost :: integer(), expected :: integer(), updated :: t()}
  @spec loss_percent(t()) :: float()
end
```

**Acceptance Criteria**:
- [ ] Track first and highest sequence numbers
- [ ] Detect and count wraparound (cycles)
- [ ] Calculate cumulative packet loss
- [ ] Calculate interval-based loss (since last query)
- [ ] Detect duplicates (same seq seen twice)
- [ ] Detect out-of-order (seq < highest but within window)
- [ ] Handle initial random sequence number

#### Task 1.2: Handle sequence wraparound
**File**: Same as 1.1
**Effort**: Small
**Parallelizable**: Part of 1.1

RFC 3550 specifies handling wraparound:
- When seq < highest_seq by more than 0x8000, assume wraparound
- Increment cycle counter

```elixir
defp detect_wraparound(seq, highest_seq, cycles) when seq < highest_seq do
  # Check if this is wraparound (seq near 0, highest near 65535)
  if highest_seq - seq > 0x8000 do
    {seq, cycles + 1}
  else
    # Out of order or duplicate
    {highest_seq, cycles}
  end
end
```

**Acceptance Criteria**:
- [ ] Wraparound detected at 65535 → 0 transition
- [ ] Multiple wraparounds handled correctly
- [ ] Extended sequence number calculated correctly

#### Task 1.3: Unit tests for sequence tracker
**File**: `apps/parrot_media/test/parrot_media/rtp/sequence_tracker_test.exs`
**Effort**: Medium
**Parallelizable**: After 1.1

**Test Cases**:
- [ ] Sequential packets (no loss)
- [ ] Single packet gap (1 lost)
- [ ] Multiple packet gaps
- [ ] Burst loss (consecutive packets lost)
- [ ] Wraparound from 65535 to 0
- [ ] Wraparound with loss
- [ ] Out-of-order delivery (late packets)
- [ ] Duplicate packets
- [ ] Interval loss calculation
- [ ] Property-based: random sequence with known gaps

---

### Phase 2: Observer Integration

#### Task 2.1: Extract sequence number in Observer
**File**: `apps/parrot_media/lib/parrot_media/mos/observer.ex`
**Effort**: Medium
**Parallelizable**: After Phase 1

Modify Observer to extract RTP sequence number from buffers and feed to SequenceTracker.

```elixir
defmodule ParrotMedia.MOS.Observer do
  # Add to state
  defstruct [
    # ... existing fields
    :sequence_tracker
  ]

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # Extract seq from buffer metadata (set by RTP depayloader)
    seq = get_rtp_sequence(buffer)

    # Update tracker
    tracker = SequenceTracker.update(state.sequence_tracker, seq)

    # ... rest of existing logic
    {[buffer: {:output, buffer}], %{state | sequence_tracker: tracker}}
  end
end
```

**Acceptance Criteria**:
- [ ] Sequence number extracted from buffer metadata
- [ ] SequenceTracker updated for each buffer
- [ ] No additional latency introduced

#### Task 2.2: Report loss metrics to Calculator
**File**: `apps/parrot_media/lib/parrot_media/mos/observer.ex`
**Effort**: Small
**Parallelizable**: After 2.1

Include packet loss in metrics sent to Calculator.

```elixir
defp build_metrics(state) do
  {lost, expected, tracker} = SequenceTracker.interval_loss(state.sequence_tracker)

  %{
    packets_received: state.buffer_count,
    packets_expected: expected,
    packets_lost: lost,
    packet_loss_percent: if(expected > 0, do: lost / expected * 100, else: 0.0),
    jitter_ms: state.jitter_ms,
    delay_ms: state.delay_ms,
    out_of_order: tracker.out_of_order,
    duplicates: tracker.duplicates
  }
end
```

**Acceptance Criteria**:
- [ ] Interval-based loss reported (not cumulative)
- [ ] Loss percentage calculated correctly
- [ ] Tracker state updated after interval

#### Task 2.3: Verify RTP metadata availability
**File**: Investigation task
**Effort**: Small
**Parallelizable**: Yes

Verify that Membrane's RTP depayloader exposes sequence number in buffer metadata.

**Acceptance Criteria**:
- [ ] Document where seq is available (buffer.metadata.rtp.sequence_number?)
- [ ] If not available, identify how to extract from raw RTP
- [ ] Update Observer to access correct field

---

### Phase 3: Jitter Calculation (Bonus)

#### Task 3.1: Implement RFC 3550 jitter calculation
**File**: `apps/parrot_media/lib/parrot_media/rtp/jitter_calculator.ex`
**Effort**: Medium
**Parallelizable**: Yes

RFC 3550 Section 6.4.1 defines interarrival jitter:

```
D(i,j) = (Rj - Ri) - (Sj - Si)
J(i) = J(i-1) + (|D(i-1,i)| - J(i-1)) / 16
```

Where:
- R = receive timestamp (local clock)
- S = RTP timestamp (sender's clock)
- J = estimated jitter (exponential average)

```elixir
defmodule ParrotMedia.RTP.JitterCalculator do
  defstruct [
    :last_rtp_ts,
    :last_arrival_ts,
    :jitter           # In timestamp units
  ]

  @spec update(t(), rtp_timestamp :: integer(), arrival_time :: integer()) :: t()
  @spec jitter_ms(t(), clock_rate :: integer()) :: float()
end
```

**Acceptance Criteria**:
- [ ] Implements RFC 3550 jitter formula exactly
- [ ] Converts timestamp units to milliseconds
- [ ] Handles first packet (no prior reference)
- [ ] Handles clock rate differences (8000Hz, 48000Hz)

#### Task 3.2: Integrate jitter into Observer
**File**: `apps/parrot_media/lib/parrot_media/mos/observer.ex`
**Effort**: Small
**Parallelizable**: After 3.1

**Acceptance Criteria**:
- [ ] JitterCalculator updated for each buffer
- [ ] Jitter included in metrics (replacing placeholder)
- [ ] Clock rate from codec used for conversion

---

### Phase 4: Testing

#### Task 4.1: Integration test with packet loss
**File**: `apps/parrot_media/test/parrot_media/mos/packet_loss_test.exs`
**Effort**: Medium
**Parallelizable**: After Phase 2

**Test Scenarios**:
- [ ] Normal call (expect ~0% loss)
- [ ] Simulated 1% loss (drop every 100th packet)
- [ ] Simulated 5% loss
- [ ] Burst loss (drop 10 consecutive)
- [ ] Verify MOS degrades appropriately with loss

#### Task 4.2: SIPp scenario with packet loss
**File**: `apps/parrot_sip/test/sipp/scenarios/mos/uac_with_loss.xml`
**Effort**: Small
**Parallelizable**: Yes

Create SIPp scenario that can simulate packet loss for testing.

Note: SIPp has limited RTP loss simulation. May need to use network tools (tc/netem) or custom RTP sender.

**Acceptance Criteria**:
- [ ] Document how to simulate loss in test environment
- [ ] Verify MOS reports expected loss percentage

#### Task 4.3: Property-based testing
**File**: `apps/parrot_media/test/parrot_media/rtp/sequence_tracker_property_test.exs`
**Effort**: Medium
**Parallelizable**: After Phase 1

Use StreamData to generate random packet sequences with known loss patterns.

```elixir
property "correctly counts lost packets" do
  check all seq_list <- list_of(integer(0..65535)),
            # Remove some to simulate loss
            lost_indices <- list_of(integer(0..length(seq_list)-1)) do
    # ... verify tracker reports correct loss count
  end
end
```

**Acceptance Criteria**:
- [ ] Verify loss count matches actual dropped packets
- [ ] Verify wraparound handled in all cases
- [ ] Verify no false positives (legitimate reordering)

---

## Definition of Done

- [ ] All tasks completed and reviewed
- [ ] Packet loss detected from sequence gaps
- [ ] MOS scores degrade appropriately with loss
- [ ] Jitter calculated per RFC 3550 (if Phase 3 included)
- [ ] Integration tests pass
- [ ] Documentation updated

## Estimated Effort

| Phase | Tasks | Parallelizable |
|-------|-------|----------------|
| Phase 1 | 3 | Mostly (1.2 part of 1.1) |
| Phase 2 | 3 | Sequential |
| Phase 3 | 2 | Yes (bonus) |
| Phase 4 | 3 | Yes |

**Total**: ~11 tasks (9 core + 2 bonus), moderate complexity

## Interaction with EPIC-MOS-001

These two epics provide complementary packet loss metrics:

| Source | What it measures | Perspective |
|--------|------------------|-------------|
| **EPIC-MOS-002** (Sequence Tracking) | Gaps in received RTP | Local (inbound quality) |
| **EPIC-MOS-001** (RTCP RR) | Remote's reported loss | Remote (outbound quality) |

Both should be implemented for complete bidirectional quality monitoring.

## References

- RFC 3550: RTP Protocol (Section 6.4.1 for jitter, Appendix A.1 for loss)
- RFC 3551: RTP Audio/Video Profile
- ITU-T G.107: E-Model (packet loss impact on MOS)
