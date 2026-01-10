# Feature Specification: RFC 2833/4733 Telephone-Event Parser

**Feature Branch**: `003-telephone-event-parser`
**Created**: 2026-01-09
**Status**: Draft
**Input**: User description: "Membrane Framework element for parsing RFC 2833/4733 DTMF telephone-events from RTP streams"

## Clarifications

### Session 2026-01-09

- Q: Should non-telephone-event packets pass through to downstream elements or be consumed? → A: Pass-through - forward all non-DTMF packets to output pad unchanged (filter element pattern)

## Overview

This specification defines a Membrane Framework element that parses DTMF (Dual-Tone Multi-Frequency) signals transmitted via RTP using the RFC 2833/RFC 4733 telephone-event format. This element enables VoIP applications to detect and respond to user key presses during calls, supporting interactive voice response (IVR) features like `collect_dtmf()` and `prompt()` operations.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Detect Single DTMF Digit (Priority: P1)

A VoIP application needs to detect when a caller presses a single digit on their phone keypad during a call. The system receives RTP packets containing telephone-event payloads and must correctly identify when a complete digit press has occurred.

**Why this priority**: This is the fundamental capability that all other DTMF features depend on. Without reliable single-digit detection, no IVR functionality is possible.

**Independent Test**: Can be fully tested by sending a sequence of RTP packets representing a single DTMF digit (start packets, intermediate packets, end packet) and verifying the correct digit notification is emitted exactly once.

**Acceptance Scenarios**:

1. **Given** the parser is receiving RTP packets, **When** a complete telephone-event sequence for digit "5" is received (multiple packets with end_bit=false followed by packets with end_bit=true), **Then** the parser emits exactly one `{:dtmf, "5"}` notification
2. **Given** the parser receives telephone-event packets, **When** the end_bit is set to true, **Then** the notification is emitted immediately upon processing that packet
3. **Given** the parser has emitted a digit notification, **When** duplicate end packets arrive (retransmissions), **Then** no additional notifications are emitted for the same event

---

### User Story 2 - Collect Multiple Digits in Sequence (Priority: P1)

A VoIP application prompts a caller to enter a multi-digit code (e.g., PIN, account number). The system must correctly detect each digit in sequence, even when digits are pressed in rapid succession.

**Why this priority**: Multi-digit collection is essential for real-world IVR applications. This validates the parser correctly resets state between events and handles sequential digit detection.

**Independent Test**: Can be tested by sending RTP packet sequences for digits "1", "2", "3", "4" in succession and verifying four separate notifications are emitted in the correct order.

**Acceptance Scenarios**:

1. **Given** a caller enters PIN "1234", **When** each digit's telephone-event sequence completes, **Then** the parser emits `{:dtmf, "1"}`, `{:dtmf, "2"}`, `{:dtmf, "3"}`, `{:dtmf, "4"}` in order
2. **Given** a pause between digit presses, **When** new telephone-event packets arrive with a different event_id, **Then** a new digit detection begins
3. **Given** digits are pressed with minimal gap, **When** the RTP timestamp changes indicate a new event, **Then** each digit is correctly distinguished

---

### User Story 3 - Filter by Payload Type (Priority: P2)

The Membrane pipeline receives mixed RTP traffic including audio and telephone-events. The parser must only process packets with the negotiated telephone-event payload type (typically 101) and pass through or ignore audio packets.

**Why this priority**: Real-world RTP streams contain multiple payload types. The parser must not misinterpret audio as DTMF or corrupt the audio stream.

**Independent Test**: Can be tested by sending a mix of audio packets (payload type 0 or 8) and telephone-event packets (payload type 101), verifying only telephone-event packets trigger DTMF detection.

**Acceptance Scenarios**:

1. **Given** the parser is configured with payload type 101, **When** RTP packets with payload type 0 (PCMU audio) arrive, **Then** no DTMF detection occurs and the packets pass through unchanged
2. **Given** the parser is configured with payload type 101, **When** RTP packets with payload type 101 arrive, **Then** the telephone-event payload is parsed for DTMF detection
3. **Given** the SDP negotiation specifies payload type 96 for telephone-event, **When** the parser is configured with payload type 96, **Then** it correctly processes type 96 packets as telephone-events

---

### User Story 4 - Support Special Keys (Priority: P2)

Callers may press special keys including star (*), pound (#), and the extended A-D keys. The parser must correctly identify all 16 possible DTMF signals.

**Why this priority**: Star and pound are commonly used in IVR menus. A-D keys, while less common, are part of the DTMF specification and used in some specialized applications.

**Independent Test**: Can be tested by sending telephone-event sequences for each of the 16 possible event codes (0-15) and verifying correct character output.

**Acceptance Scenarios**:

1. **Given** telephone-event with event_id=10, **When** the event completes, **Then** the parser emits `{:dtmf, "*"}`
2. **Given** telephone-event with event_id=11, **When** the event completes, **Then** the parser emits `{:dtmf, "#"}`
3. **Given** telephone-event with event_id=12 through 15, **When** each event completes, **Then** the parser emits `{:dtmf, "A"}` through `{:dtmf, "D"}` respectively

---

### User Story 5 - Handle Long Key Presses (Priority: P3)

When a caller holds down a key for an extended period, many telephone-event packets are generated with increasing duration values. The parser must correctly track this as a single event and emit only one notification when the key is released.

**Why this priority**: Long key presses are normal user behavior and must not result in repeated digit detection.

**Independent Test**: Can be tested by sending 20+ packets for a single digit with incrementing duration and end_bit=false, followed by end packets, verifying only one notification is emitted.

**Acceptance Scenarios**:

1. **Given** a caller holds digit "7" for 2 seconds, **When** the parser receives 40+ intermediate packets, **Then** it tracks this as a single event
2. **Given** the long press completes with end_bit=true, **When** the end packet is processed, **Then** exactly one `{:dtmf, "7"}` notification is emitted
3. **Given** duration values exceed the maximum (65535), **When** packets with maximum duration arrive, **Then** the parser continues tracking without error

---

### User Story 6 - Recover from Packet Loss (Priority: P3)

In real network conditions, some RTP packets may be lost. The parser should handle gaps gracefully without crashing or producing incorrect results.

**Why this priority**: Network packet loss is inevitable in VoIP. The parser should be resilient, though some edge cases may result in missed or duplicated detections (acceptable trade-off).

**Independent Test**: Can be tested by sending an incomplete telephone-event sequence (missing end packets) followed by a new event, verifying the parser recovers and detects the second event.

**Acceptance Scenarios**:

1. **Given** a telephone-event sequence with missing intermediate packets, **When** the end packet arrives, **Then** the digit is still correctly detected
2. **Given** end packets are lost and never arrive, **When** a new event begins (different event_id), **Then** the parser resets state and tracks the new event
3. **Given** the first packet of an event is lost, **When** subsequent packets arrive, **Then** the parser begins tracking from the first received packet

---

### Edge Cases

- What happens when the parser receives a malformed telephone-event payload (wrong size)?
  - The parser logs a warning and discards the packet without crashing
- How does the system handle interleaved events from the same RTP source?
  - RFC 4733 does not support interleaved events; the parser tracks only the current event_id
- What happens if payload type is not configured?
  - The parser requires payload type configuration at initialization; missing configuration is a startup error
- How are event_id values outside 0-15 handled?
  - The parser ignores unknown event_id values (16+) as they represent non-DTMF events per RFC 4733

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST parse RFC 4733 telephone-event RTP payloads consisting of 4 bytes: event_id (8 bits), end_bit (1 bit), reserved (1 bit), volume (6 bits), and duration (16 bits)
- **FR-002**: System MUST filter RTP packets by a configurable payload type, processing only packets that match the telephone-event payload type
- **FR-003**: System MUST track digit state across multiple RTP packets using a combination of RTP timestamp and event_id to identify a single DTMF event
- **FR-004**: System MUST emit a `{:dtmf, digit}` notification exactly once per complete DTMF event, triggered when end_bit=true is received
- **FR-005**: System MUST suppress duplicate notifications from retransmitted end packets (same timestamp + event_id seen before)
- **FR-006**: System MUST map event_id values 0-9 to digit characters "0"-"9", value 10 to "*", value 11 to "#", and values 12-15 to "A"-"D"
- **FR-007**: System MUST reset event tracking state when a new event begins (different event_id or timestamp discontinuity)
- **FR-008**: System MUST pass through all RTP packets to the output pad unchanged, operating as a filter element that monitors traffic and emits side-effect notifications without transforming the data stream
- **FR-009**: System MUST handle malformed payloads (incorrect size) by logging a warning and discarding the packet
- **FR-010**: System MUST support the Membrane Framework element interface including proper pad definitions, callback implementations, and notification mechanisms

### Key Entities

- **Telephone-Event Payload**: 4-byte structure per RFC 4733 containing event identification, end marker, volume level, and cumulative duration
- **DTMF Event State**: Tracking structure holding current event_id, starting timestamp, and whether end has been processed, used to correlate multiple packets into a single digit detection
- **Digit Mapping**: Translation table from RFC 4733 event_id values (0-15) to human-readable digit characters ("0"-"9", "*", "#", "A"-"D")

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Parser correctly detects and reports 100% of well-formed DTMF digits in controlled testing (no packet loss)
- **SC-002**: Parser emits exactly one notification per digit press, with zero duplicate notifications from packet retransmissions
- **SC-003**: Parser processes 200 RTP packets per second without introducing latency or backpressure (typical VoIP call rate: 50 pps audio + occasional DTMF)
- **SC-004**: Parser correctly identifies all 16 DTMF signals (0-9, *, #, A-D) with no misidentification
- **SC-005**: Parser recovers from incomplete event sequences within one new event cycle (no permanent state corruption)
- **SC-006**: Parser handles 1000+ packets for a single long key press without memory growth or performance degradation

## Assumptions

- RTP packets arrive with correct RTP header structure (validated by upstream elements)
- Payload type for telephone-events is known at initialization time (from SDP negotiation)
- The Membrane Framework version supports filter elements with notification capabilities
- Upstream elements provide RTP buffers with accessible payload type and timestamp fields
- A single RTP stream contains at most one concurrent telephone-event (per RFC 4733)
- Volume values in telephone-event payloads are informational and not used for detection logic
