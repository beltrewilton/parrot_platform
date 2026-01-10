# Feature Specification: CDR System

**Feature Branch**: `006-cdr-system`
**Created**: 2026-01-10
**Status**: Draft
**Input**: User description: "CDR system that can be used to get proper CDRs for calls"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Automatic CDR Generation (Priority: P1)

As a platform operator, I want call detail records to be automatically generated for every call so that I have complete records for billing, compliance, and analytics without manual intervention.

**Why this priority**: Automatic CDR generation is the core function - without it, no call records exist and all other features are impossible.

**Independent Test**: Can be fully tested by completing a call and verifying a CDR is generated with all mandatory fields populated correctly.

**Acceptance Scenarios**:

1. **Given** a completed inbound call, **When** the call ends normally, **Then** a CDR is created with caller/callee, timestamps, duration, and disposition
2. **Given** a completed outbound call, **When** the call ends normally, **Then** a CDR is created with origination and destination details
3. **Given** a failed call attempt, **When** the call is rejected or fails, **Then** a CDR is created with appropriate disposition code and failure reason
4. **Given** an answered call that is terminated early, **When** either party hangs up, **Then** the CDR reflects the actual talk time and termination cause

---

### User Story 2 - CDR Retrieval and Query (Priority: P2)

As a platform operator, I want to retrieve and query CDRs so that I can generate reports, investigate issues, and provide billing data to external systems.

**Why this priority**: CDRs are only useful if they can be retrieved and analyzed. This enables all downstream use cases (billing, reporting, troubleshooting).

**Independent Test**: Can be fully tested by generating several calls with different characteristics and querying CDRs by various criteria.

**Acceptance Scenarios**:

1. **Given** existing CDRs, **When** I query by date range, **Then** I receive all CDRs within that range
2. **Given** existing CDRs, **When** I query by caller or callee identifier, **Then** I receive matching CDRs
3. **Given** existing CDRs, **When** I query by call disposition, **Then** I receive CDRs matching that disposition
4. **Given** a specific call ID, **When** I request that CDR, **Then** I receive the complete record with all fields

---

### User Story 3 - CDR Export (Priority: P3)

As a platform operator, I want to export CDRs in standard formats so that I can integrate with external billing systems, analytics tools, and compliance archives.

**Why this priority**: Export enables integration with the broader telecom ecosystem but depends on CDR generation and retrieval being functional first.

**Independent Test**: Can be fully tested by generating CDRs and exporting them to verify correct format and completeness.

**Acceptance Scenarios**:

1. **Given** a set of CDRs, **When** I export to CSV format, **Then** I receive a properly formatted CSV file with all fields
2. **Given** a set of CDRs, **When** I export to JSON format, **Then** I receive valid JSON with all CDR data
3. **Given** a date range, **When** I request export for that range, **Then** only CDRs within that range are included

---

### User Story 4 - Custom CDR Handler (Priority: P4)

As a developer, I want to implement custom CDR handling logic so that I can store CDRs in my preferred backend, add custom fields, or integrate with my billing system in real-time.

**Why this priority**: Customization enables advanced use cases but requires the core CDR system to be stable first.

**Independent Test**: Can be fully tested by implementing a custom handler, completing calls, and verifying the handler receives correct CDR data.

**Acceptance Scenarios**:

1. **Given** a registered CDR handler, **When** a call completes, **Then** the handler receives the CDR data
2. **Given** a handler that adds custom fields, **When** a CDR is generated, **Then** the custom fields are included
3. **Given** a handler that fails, **When** a CDR is generated, **Then** the error is logged and other registered handlers continue to receive CDRs

---

### Edge Cases

- Multi-leg calls (transfers, conferences): Each leg generates a separate CDR; all legs share a correlation ID for reconstruction
- Abandoned calls (ring-no-answer, immediate cancels): CDR generated for every INVITE with appropriate disposition (no-answer, cancelled)
- Handler failures: Library logs error and continues (fire-and-forget); handlers responsible for their own retry/persistence guarantees
- Midnight boundary: CDRs use actual timestamps; date aggregation is handler responsibility
- System restart: In-progress dialogs terminate normally (timeout or BYE); CDR generated on termination per standard DialogStatem lifecycle

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST generate a CDR for every INVITE transaction, regardless of outcome (answered, failed, cancelled, or abandoned)
- **FR-002**: System MUST capture call start time (invite received), answer time (if answered), and end time
- **FR-003**: System MUST calculate and store call duration (ring time and talk time separately)
- **FR-004**: System MUST record caller identifier (From URI, caller ID)
- **FR-005**: System MUST record callee identifier (To URI, dialed number)
- **FR-006**: System MUST record call disposition (answered, busy, no-answer, failed, cancelled)
- **FR-007**: System MUST record termination cause (who hung up, SIP response code)
- **FR-008**: System MUST assign a unique identifier to each CDR
- **FR-009**: System MUST link CDRs to SIP Call-ID for correlation with protocol traces
- **FR-010**: System MUST provide a behaviour/callback interface for custom CDR handlers
- **FR-011**: CDR struct MUST include unique ID field to enable handler-implemented retrieval
- **FR-012**: CDR struct MUST include indexed fields (timestamps, caller, callee, disposition) to enable handler-implemented queries
- **FR-013**: Library MUST provide CDR serialization helpers for CSV and JSON formats (export implementation is handler responsibility)
- **FR-014**: System MUST handle CDR generation and handler delivery failures gracefully (log and continue) without affecting call processing
- **FR-015**: System MUST record media information when available (codec, MOS score if 005-mos-scoring is implemented)
- **FR-016**: System MUST assign a correlation ID to link CDRs from multi-leg calls (transfers, conferences)

### Key Entities

- **Call Detail Record (CDR)**: The primary entity representing a single call, containing all call metadata, timing, participants, and outcome information
- **Call Disposition**: Enumeration of possible call outcomes (answered, busy, no-answer, failed, cancelled, transferred)
- **Termination Cause**: Information about why and how a call ended, including SIP response codes and terminating party
- **CDR Handler**: A behaviour that users implement for CDR storage, transformation, and forwarding; the library delivers CDR structs to handlers but does not persist them
- **CDR Query**: Parameters for searching CDRs including date ranges, participant filters, and disposition filters
- **Correlation ID**: Unique identifier linking related CDRs from multi-leg calls (transfers, conferences); all legs of a logical call share the same correlation ID while having distinct CDR IDs

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: CDRs are generated within 1 second of call termination
- **SC-002**: 100% of completed calls have corresponding CDRs (no data loss)
- **SC-003**: CDR serialization to JSON/CSV completes within 1ms per record
- **SC-004**: Reference handler implementation (if provided) demonstrates query patterns for typical use cases
- **SC-005**: Custom CDR handlers receive events within 100ms of CDR generation
- **SC-006**: CDR generation adds less than 10ms latency to call termination processing

## Clarifications

### Session 2026-01-10

- Q: How should multi-leg calls (transfers, conferences) be represented in the CDR system? → A: Separate CDR per leg with correlation ID linking related legs
- Q: What is the primary interface for CDR retrieval and queries? → A: Elixir API only (module functions); library provides CDR generation and handler callbacks, users implement storage
- Q: When should a CDR be generated for unanswered calls? → A: Generate CDR for every INVITE, regardless of outcome (including immediate cancels)
- Q: What should happen when a CDR handler fails to process a CDR? → A: Log error and drop (fire-and-forget); handlers own their reliability
- Q: Where should CDR generation be triggered in the Parrot architecture? → A: DialogStatem termination (captures all calls regardless of upper layer)

## Assumptions

- The CDR system is a library providing CDR generation and a handler behaviour; storage is the responsibility of user-implemented handlers (no built-in storage)
- SIP Call-ID will be used as the primary correlation key between CDRs and SIP transactions
- Time synchronization (NTP) is assumed for accurate timestamps
- CDR retention policy and archival is the responsibility of the CDR handler implementation
- Multi-leg calls (transfers, conferences) generate separate CDRs linked by a shared correlation ID
- CDR generation hooks into DialogStatem termination to capture all calls regardless of upper-layer abstraction
