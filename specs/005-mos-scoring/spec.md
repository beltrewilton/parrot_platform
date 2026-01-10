# Feature Specification: MOS Scoring

**Feature Branch**: `005-mos-scoring`
**Created**: 2026-01-10
**Status**: Draft
**Input**: User description: "MOS scoring with parrot_media along with a CDR system that can be used to get proper CDRs for calls"

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

- What happens when a call has no RTP packets (silent call or media failure)?
- How does the system handle calls with only one-way audio?
- What happens when MOS calculation cannot complete due to insufficient samples?
- How are very short calls (< 1 second) handled?
- What happens during codec changes mid-call?

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
