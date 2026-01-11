# Feature Specification: MOS Scoring

**Feature Branch**: `005-mos-scoring`
**Created**: 2026-01-10
**Status**: Draft
**Input**: User description: "MOS scoring with parrot_media along with a CDR system that can be used to get proper CDRs for calls"

## Clarifications

### Session 2026-01-10

- Q: Is CDR (Call Detail Record) functionality in scope for this feature? → A: CDR is out of scope - this feature focuses only on MOS scoring; CDR will be a separate feature
- Q: How should the system handle insufficient RTP packets for MOS calculation? → A: Distinguish cases - Low MOS (1.0-2.0) for missing packets during active call; `{:insufficient_data, reason}` for startup/short calls
- Q: How should MOS calculation integrate with the Membrane pipeline? → A: Observer + GenServer - Lightweight pipeline observer extracts RTP metadata, sends to dedicated MOS GenServer for async calculation (zero audio path latency)
- Q: Should MOS data persist beyond call lifetime? → A: Event-driven persistence - MOS data ephemeral in-memory, quality summary emitted as event for optional handler persistence
- Q: How should MOS scoring expose metrics for observability? → A: `:telemetry` events - Emit standard telemetry events for monitoring system integration

## Scope

### In Scope

- Real-time MOS score calculation based on RTP stream metrics
- Per-call quality summaries with min/max/average MOS
- Quality event callbacks and threshold alerting
- Integration with parrot_media MediaSession lifecycle

### Out of Scope

- CDR (Call Detail Record) system - will be addressed in a separate feature specification
- Audio-based MOS calculation (PESQ/POLQA) - using E-model network metrics only
- Historical MOS data storage or analytics dashboards

## Architecture

### Integration Pattern: Observer + GenServer

Following OTP best practices for separation of concerns and zero-latency audio path:

1. **RTP Metrics Observer** (Membrane Filter element)
   - Lightweight element inserted in RTP pipeline
   - Reads buffer metadata only (sequence numbers, timestamps) - zero-copy, no processing
   - Forwards metrics via message passing to MOS GenServer
   - Does NOT block or delay audio buffers

2. **MOS Calculator GenServer** (per MediaSession)
   - Receives metrics asynchronously from observer
   - Aggregates metrics over configurable intervals
   - Performs E-model (ITU-T G.107) calculation
   - Emits quality events to registered handlers
   - Maintains call quality summary state
   - Can crash independently without affecting audio flow

3. **Quality Event Handler** (behaviour)
   - Callback interface for quality event subscribers
   - Handlers registered per-session or globally
   - Isolated execution - handler errors don't affect other handlers

### Process Supervision

- MOS Calculator GenServer supervised under MediaSession supervisor
- One MOS Calculator per active MediaSession
- Lifecycle tied to MediaSession (starts/stops with media)

### Data Lifecycle

- **During call**: MOS scores and interval metrics held in GenServer state (ephemeral)
- **At call end**: Quality summary event emitted to all registered handlers
- **After call**: All in-memory MOS data discarded when GenServer terminates
- **Persistence**: Not built-in; handlers can implement persistence if needed (e.g., write to database, forward to CDR system)

### Observability

Telemetry events emitted for monitoring system integration:

- `[:parrot_media, :mos, :score]` - Emitted each calculation interval with MOS score and metrics
- `[:parrot_media, :mos, :threshold_crossed]` - Emitted when MOS crosses configured threshold
- `[:parrot_media, :mos, :call_summary]` - Emitted at call end with aggregate statistics

Event measurements include: `mos_score`, `packet_loss_percent`, `jitter_ms`, `interval_duration_ms`
Event metadata includes: `session_id`, `call_id`, `codec`, `direction`

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Real-Time Call Quality Monitoring (Priority: P1)

As a platform operator, I want to monitor call quality in real-time during active calls so that I can identify and respond to quality degradation before calls fail.

**Why this priority**: Real-time monitoring is the core value proposition - it enables proactive quality management and is the foundation for all other MOS-related features.

**Independent Test**: Can be fully tested by initiating a call with varying network conditions and observing MOS scores update in real-time. Delivers immediate visibility into call quality.

**Acceptance Scenarios**:

1. **Given** an active call with stable audio, **When** the system calculates MOS, **Then** the score reflects excellent quality (4.0-5.0 range)
2. **Given** an active call with packet loss, **When** the system calculates MOS, **Then** the score decreases proportionally to quality degradation
3. **Given** an active call with high jitter, **When** the system calculates MOS, **Then** the score reflects the impact on audio quality
4. **Given** an active call, **When** MOS drops below a configurable threshold, **Then** the system emits a quality alert event

---

### User Story 2 - Per-Call Quality Summary (Priority: P2)

As a platform operator, I want to receive a quality summary at the end of each call so that I can analyze call quality trends and identify problematic patterns.

**Why this priority**: Post-call summaries are essential for historical analysis and troubleshooting but depend on the real-time calculation infrastructure from P1.

**Independent Test**: Can be fully tested by completing a call and verifying the quality summary contains accurate MOS statistics. Delivers call quality analytics.

**Acceptance Scenarios**:

1. **Given** a completed call, **When** the call ends, **Then** the system provides minimum, maximum, and average MOS scores
2. **Given** a completed call with quality events, **When** the call ends, **Then** the summary includes timestamps of quality degradation periods
3. **Given** a call with no audio packets received, **When** the call ends, **Then** the summary indicates insufficient data for MOS calculation

---

### User Story 3 - Quality Event Callbacks (Priority: P3)

As a developer integrating with parrot_media, I want to receive callbacks when call quality changes significantly so that my application can respond to quality events.

**Why this priority**: Callbacks enable integration with external systems (alerting, dashboards, automation) and are valuable but not essential for basic MOS functionality.

**Independent Test**: Can be fully tested by registering a callback handler, simulating quality changes, and verifying callbacks are received with correct data.

**Acceptance Scenarios**:

1. **Given** a registered quality callback handler, **When** MOS crosses a threshold boundary, **Then** the handler receives an event with current MOS and threshold details
2. **Given** multiple registered handlers, **When** a quality event occurs, **Then** all handlers receive the event
3. **Given** a handler that raises an error, **When** a quality event occurs, **Then** other handlers still receive the event and the error is logged

---

### Edge Cases

- **No RTP packets during active call (media failure)**: System returns low MOS score (1.0-2.0) to reflect poor quality; quality alert event emitted
- **No RTP packets during startup**: System returns `{:insufficient_data, :awaiting_media}` until first packets arrive
- **One-way audio**: System calculates MOS for the active direction only; indicates bidirectional metrics unavailable in quality summary
- **Insufficient samples (< 10 packets in interval)**: During active call = low MOS; during startup = `{:insufficient_data, :insufficient_samples}`
- **Very short calls (< 1 second)**: System returns `{:insufficient_data, :call_too_short}` in quality summary; no interval MOS scores emitted
- **Codec changes mid-call**: MOS calculation continues; codec change noted in quality event timeline but doesn't reset metrics

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST calculate MOS scores based on RTP stream metrics (packet loss, jitter, latency)
- **FR-002**: System MUST use the E-model algorithm (ITU-T G.107) for MOS estimation from network metrics
- **FR-003**: System MUST calculate MOS at configurable intervals (default: every 5 seconds)
- **FR-004**: System MUST emit MOS score events that can be subscribed to by handlers
- **FR-005**: System MUST provide call quality summary when a media session ends
- **FR-006**: System MUST support configurable quality thresholds for alerting (default thresholds: excellent >= 4.0, good >= 3.5, fair >= 3.0, poor < 3.0)
- **FR-007**: System MUST track packet loss percentage per calculation interval
- **FR-008**: System MUST track jitter measurements per calculation interval
- **FR-009**: System MUST track round-trip delay when available
- **FR-010**: System MUST handle one-way audio streams and indicate when bidirectional metrics are unavailable
- **FR-011**: System MUST integrate with the existing MediaSession lifecycle in parrot_media
- **FR-012**: System MUST provide a behaviour/callback interface for quality event handlers

### Key Entities

- **MOS Score**: Represents a quality measurement at a point in time, including the numeric score (1.0-5.0), timestamp, and contributing metrics
- **Quality Interval**: A time window over which metrics are aggregated for MOS calculation, containing packet counts, loss statistics, and jitter measurements
- **Call Quality Summary**: End-of-call aggregate containing min/max/average MOS, total packets, quality event timeline, and call duration
- **Quality Threshold**: Configurable boundary that triggers events when MOS crosses it, with hysteresis to prevent flapping
- **Quality Event**: Notification emitted when quality changes significantly, containing event type, MOS value, threshold crossed, and timestamp

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: MOS scores are calculated and available within 100ms of the calculation interval completing
- **SC-002**: MOS calculation adds less than 1% CPU overhead to media session processing
- **SC-003**: Quality summaries are available within 500ms of call termination
- **SC-004**: System accurately detects 95% of quality degradation events (packet loss > 2%, jitter > 30ms)
- **SC-005**: Quality event callbacks are delivered within 50ms of threshold crossing
- **SC-006**: MOS scores correlate within 0.5 points of reference measurements under controlled test conditions

## Assumptions

- The E-model (ITU-T G.107) algorithm will be used as the primary MOS estimation method, as it can work with network metrics without requiring audio analysis
- RTCP statistics (when available) will be used to improve accuracy of delay and loss measurements
- The parrot_media RTP pipeline already provides access to packet timing and sequence number information needed for jitter/loss calculation
- Quality thresholds follow industry-standard MOS ranges: Excellent (4.0+), Good (3.5-4.0), Fair (3.0-3.5), Poor (<3.0)
