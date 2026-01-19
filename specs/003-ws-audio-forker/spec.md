# Feature Specification: WebSocket Audio Forker

**Feature Branch**: `003-ws-audio-forker`
**Created**: 2026-01-09
**Status**: Draft
**Input**: GenServer for forking call audio to WebSocket endpoints for real-time AI transcription services (Deepgram, AssemblyAI, OpenAI Realtime)

## Overview

The WebSocket Audio Forker enables real-time audio streaming from VoIP calls to external AI transcription and analysis services. This component acts as a bridge between the call's audio pipeline and WebSocket-based AI services, allowing developers to integrate live transcription, sentiment analysis, and other audio AI capabilities into their call handling workflows.

Key architectural decisions:
- Implemented as a GenServer (not Membrane element) for better failure isolation
- Receives audio via message passing from a Membrane Tee element
- WebSocket failures do not crash the call pipeline
- Supports multiple concurrent forks per call (e.g., transcription + recording simultaneously)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Stream Audio to Transcription Service (Priority: P1)

A developer wants to enable real-time transcription of a phone call by streaming audio to Deepgram or a similar service. They invoke `fork_ws_media()` in their call handler after answering, and the audio begins flowing to the transcription service. They receive transcription results back (outside this feature's scope) and can stop the stream at any time.

**Why this priority**: This is the primary use case - enabling AI-powered features during live calls. Without basic audio streaming, no other features work.

**Independent Test**: Can be fully tested by starting a call, invoking fork_ws_media with a Deepgram endpoint, verifying audio packets arrive at the WebSocket server, and invoking stop_fork_ws_media to cleanly terminate.

**Acceptance Scenarios**:

1. **Given** an active call with audio flowing, **When** developer calls `fork_ws_media(call, %{url: "wss://api.deepgram.com/v1/listen", auth: "Token xxx"})`, **Then** a WebSocket connection opens and audio packets begin streaming to the endpoint
2. **Given** an active audio fork, **When** developer calls `stop_fork_ws_media(call, fork_id)`, **Then** the WebSocket closes gracefully and audio is no longer sent to that endpoint
3. **Given** an active call, **When** developer starts multiple forks to different endpoints, **Then** each fork operates independently and audio flows to all configured endpoints simultaneously

---

### User Story 2 - Survive Transient Network Failures (Priority: P2)

A developer has a long-running call with transcription enabled. The network experiences brief connectivity issues to the transcription service. The forker should automatically attempt to reconnect without crashing the call or requiring developer intervention. The developer can configure retry behavior.

**Why this priority**: Production calls will inevitably encounter network issues. Without reconnection, every network blip would terminate transcription, degrading the user experience.

**Independent Test**: Can be tested by starting a fork, simulating WebSocket disconnection, observing automatic reconnection attempts, and verifying audio resumes once connection is restored.

**Acceptance Scenarios**:

1. **Given** an active audio fork, **When** the WebSocket connection drops unexpectedly, **Then** the forker attempts to reconnect using exponential backoff without affecting the main call
2. **Given** a fork in reconnecting state, **When** reconnection succeeds, **Then** audio streaming resumes automatically from the current point (no historical replay)
3. **Given** a fork that has failed reconnection for the configured maximum attempts, **When** the limit is reached, **Then** the forker enters a permanent failed state and notifies the call handler via a callback message

---

### User Story 3 - Handle Slow Consumers (Priority: P3)

The transcription service is experiencing high load and cannot accept audio packets as fast as they arrive. The forker should handle this gracefully by buffering packets up to a limit, then dropping oldest packets to maintain real-time alignment. The developer can configure buffer size and drop behavior.

**Why this priority**: Backpressure is inevitable in distributed systems. Without handling it, memory could grow unbounded or the call pipeline could stall.

**Independent Test**: Can be tested by starting a fork with a slow mock WebSocket server, sending audio at normal rate, and verifying that buffer limits are respected and oldest packets are dropped when full.

**Acceptance Scenarios**:

1. **Given** an audio fork with a slow WebSocket consumer, **When** audio arrives faster than it can be sent, **Then** packets are buffered up to the configured limit
2. **Given** a full buffer, **When** new audio arrives, **Then** the oldest packets are dropped and new packets are added
3. **Given** backpressure conditions, **When** the developer queries fork status, **Then** they can see metrics including buffer fill level and dropped packet count

---

### User Story 4 - Configure Audio Format (Priority: P4)

Different AI services expect different audio formats. A developer needs to specify whether to send PCM 16-bit, Opus, or other formats. The forker should either pass through the native pipeline format or perform necessary conversion.

**Why this priority**: Format flexibility enables integration with diverse AI services. However, basic PCM support covers most use cases, making this lower priority.

**Independent Test**: Can be tested by configuring a fork with specific format requirements and verifying the received audio matches the expected format specification.

**Acceptance Scenarios**:

1. **Given** a fork configured for PCM 16-bit format, **When** audio is received from the pipeline, **Then** it is sent as PCM 16-bit data to the WebSocket
2. **Given** a fork configured for Opus format, **When** audio is received, **Then** it is encoded as Opus before sending (if not already Opus)
3. **Given** format configuration, **When** audio parameters differ from requirements, **Then** the forker performs necessary sample rate conversion or encoding

---

### Edge Cases

- What happens when fork_ws_media is called on a call that hasn't answered yet?
  - The fork should queue and wait until audio is available, or return an error if the call is not in a state that will produce audio
- What happens when the WebSocket URL is invalid or unreachable on initial connection?
  - The fork should fail immediately with a clear error, not enter retry mode (distinguish initial failure from mid-stream failure)
- What happens when stop_fork_ws_media is called on an already-stopped fork?
  - Should be idempotent and return success (or :already_stopped status)
- What happens when the call ends while forks are active?
  - All forks should be cleanly terminated, sending any final close messages to the WebSocket
- What happens when authentication credentials are rejected by the WebSocket server?
  - Return authentication error immediately, do not retry (auth errors are not transient)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST allow starting an audio fork with a WebSocket URL and authentication headers
- **FR-002**: System MUST support multiple concurrent forks per call, each identified by a unique fork_id
- **FR-003**: System MUST receive audio buffers via messages from the Membrane pipeline Tee element
- **FR-004**: System MUST stream audio data to the configured WebSocket endpoint in real-time
- **FR-005**: System MUST support configurable audio formats (PCM 16-bit linear, Opus, G.711 A-law/u-law)
- **FR-006**: System MUST implement automatic reconnection on transient WebSocket failures with configurable retry limits
- **FR-007**: System MUST implement backpressure handling with configurable buffer size and drop policy
- **FR-008**: System MUST cleanly close WebSocket connections on stop_fork_ws_media()
- **FR-009**: System MUST NOT crash the call pipeline when WebSocket operations fail
- **FR-010**: System MUST provide status query capability including connection state, buffer metrics, and error counts
- **FR-011**: System MUST notify the call handler of significant events (connection established, connection failed, reconnecting, permanently failed)
- **FR-012**: System MUST support custom headers for WebSocket connection (for service-specific authentication)
- **FR-013**: System MUST support configurable audio sample rate specification for format negotiation

### Key Entities

- **Fork**: Represents a single audio streaming session to a WebSocket endpoint. Contains connection URL, authentication, format configuration, buffer state, and connection status.
- **ForkConfig**: Configuration for creating a fork including URL, headers, format, buffer limits, and retry policy.
- **AudioBuffer**: Bounded queue holding audio packets awaiting transmission. Tracks size, dropped count, and age of oldest packet.
- **ConnectionState**: State machine tracking WebSocket lifecycle: connecting, connected, reconnecting, failed, closed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Audio streaming to a WebSocket endpoint begins within 500ms of fork_ws_media() being called (connection time dependent on network latency to service)
- **SC-002**: System supports at least 4 concurrent forks per call without degradation
- **SC-003**: WebSocket failures result in zero call pipeline crashes (100% failure isolation)
- **SC-004**: Reconnection attempts succeed within 30 seconds for transient failures (when service recovers)
- **SC-005**: Buffer overflow scenarios drop packets gracefully with zero memory leaks
- **SC-006**: Clean shutdown completes within 2 seconds of stop_fork_ws_media()
- **SC-007**: 99% of audio packets arrive at the WebSocket endpoint within 100ms of being produced by the pipeline (under normal network conditions)
- **SC-008**: Developer can integrate audio forking into a call handler with fewer than 10 lines of code

## Assumptions

- The Membrane pipeline already supports Tee elements for splitting audio streams
- Audio arrives from the pipeline in a known format that can be determined at runtime
- WebSocket services use standard WSS (WebSocket Secure) protocol
- Authentication is handled via HTTP headers during WebSocket upgrade (standard for Deepgram, AssemblyAI, OpenAI)
- The call handler has access to the Call.Server process for invoking fork operations
- Audio sample rates are 8kHz, 16kHz, or 48kHz (standard telephony and AI service rates)
- The parrot_media app has access to appropriate encoding/decoding libraries for format conversion

## Out of Scope

- Receiving responses/transcriptions from the WebSocket service (this is a one-way audio fork)
- Recording audio to files (separate feature)
- Audio mixing or manipulation before forking
- WebSocket server implementation (only client functionality)
- Service-specific protocol handling beyond basic audio streaming (e.g., Deepgram-specific JSON messages)
- Billing or usage tracking for external AI services

## Dependencies

- Membrane Framework (existing in parrot_media)
- WebSocket client library (WebSockex or Mint.WebSocket - to be determined in planning)
- Audio codec libraries for format conversion (existing in parrot_media)
- Registry for fork process discovery (existing pattern in parrot)
