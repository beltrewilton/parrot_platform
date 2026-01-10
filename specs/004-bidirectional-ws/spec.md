# Feature Specification: Bidirectional WebSocket Audio Connection

**Feature Branch**: `004-bidirectional-ws`
**Created**: 2026-01-10
**Status**: Draft
**Input**: User description: "I want to add like we have fork_ws for forking audio, we need a connect_bidirectional_ws, for connecting a stream to websocket for bidirectional for speech to speech ai services."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Connect Call to Speech-to-Speech AI Service (Priority: P1)

A developer building an AI voice assistant application needs to connect an active phone call to a speech-to-speech AI service (like OpenAI Realtime API, ElevenLabs Conversational AI, or similar). The caller speaks, their audio is streamed to the AI service over WebSocket, and the AI's audio response is streamed back and played to the caller in real-time.

**Why this priority**: This is the core use case - enabling real-time conversational AI experiences over telephone calls. Without bidirectional audio streaming, speech-to-speech AI integration is not possible.

**Independent Test**: Can be fully tested by connecting a call to a mock WebSocket server that echoes audio back, verifying audio flows in both directions with acceptable latency.

**Acceptance Scenarios**:

1. **Given** an active call with media established, **When** the developer invokes `connect_bidirectional_ws` with a WebSocket URL and authentication headers, **Then** a bidirectional audio connection is established and caller audio flows to the WebSocket while WebSocket audio flows back to the caller.
2. **Given** a bidirectional connection is active, **When** the remote AI service sends audio data, **Then** the audio is played to the caller within the target latency window.
3. **Given** a bidirectional connection is active, **When** the caller speaks, **Then** their audio is streamed to the AI service in real-time.

---

### User Story 2 - Handle Connection Lifecycle Events (Priority: P2)

A developer needs visibility into the WebSocket connection state to handle errors gracefully, implement retry logic, and provide appropriate user feedback when connectivity issues occur.

**Why this priority**: Production applications must handle network failures, service outages, and reconnection scenarios gracefully to maintain acceptable user experience.

**Independent Test**: Can be tested by simulating connection drops and verifying callbacks are invoked with correct events.

**Acceptance Scenarios**:

1. **Given** a bidirectional connection attempt, **When** the WebSocket connects successfully, **Then** a `connected` event callback is invoked.
2. **Given** an active bidirectional connection, **When** the WebSocket disconnects unexpectedly, **Then** a `disconnected` event callback is invoked with the reason.
3. **Given** a disconnected bidirectional connection with auto-reconnect enabled, **When** reconnection is attempted, **Then** a `reconnecting` event callback is invoked with the attempt number.
4. **Given** reconnection attempts have exceeded the maximum limit, **When** the final attempt fails, **Then** a `failed` event callback is invoked and the connection stops retrying.

---

### User Story 3 - Control Audio Direction (Priority: P3)

A developer needs to control which audio directions are active during a bidirectional session - for example, to mute the outbound stream while the AI is speaking (to prevent echo/feedback) or to stop receiving AI audio during a transfer operation.

**Why this priority**: Advanced use cases require fine-grained control over audio flow to prevent echo, implement barge-in detection, or handle mid-call transfers cleanly.

**Independent Test**: Can be tested by toggling audio directions and verifying frames are only sent/received in the enabled direction(s).

**Acceptance Scenarios**:

1. **Given** an active bidirectional connection, **When** the developer invokes `mute_outbound`, **Then** caller audio stops being sent to the WebSocket while AI audio continues playing.
2. **Given** an active bidirectional connection, **When** the developer invokes `mute_inbound`, **Then** AI audio stops being played to the caller while caller audio continues streaming.
3. **Given** a muted direction, **When** the developer invokes the corresponding unmute operation, **Then** audio flow resumes in that direction.

---

### User Story 4 - Disconnect Bidirectional Connection (Priority: P4)

A developer needs to cleanly disconnect the bidirectional WebSocket connection when the AI interaction is complete, the call ends, or the application needs to switch to a different AI service.

**Why this priority**: Clean disconnection is essential for resource cleanup and proper session termination with AI services.

**Independent Test**: Can be tested by establishing a connection, disconnecting, and verifying WebSocket is closed and resources are released.

**Acceptance Scenarios**:

1. **Given** an active bidirectional connection, **When** the developer invokes `disconnect_bidirectional_ws`, **Then** the WebSocket is closed gracefully and the original audio path is restored.
2. **Given** a call ends while bidirectional connection is active, **When** the call termination is processed, **Then** the bidirectional connection is automatically cleaned up.

---

### Edge Cases

- What happens when the WebSocket server sends non-audio data (JSON control messages)? The system must forward these to a callback handler for processing.
- What happens when audio format conversion is needed between the call and the AI service? The system must support configurable audio encoding/decoding.
- What happens when the WebSocket buffer fills up due to slow network? The system must apply backpressure or drop frames appropriately without crashing.
- What happens when the caller hangs up while the AI is mid-sentence? The system must terminate cleanly without orphaned processes.
- What happens when the initial WebSocket connection fails? The system must invoke error callbacks and allow retry configuration.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a DSL action `connect_bidirectional_ws/2` that establishes a bidirectional WebSocket audio connection with URL and options.
- **FR-002**: System MUST stream caller audio to the connected WebSocket endpoint in real-time.
- **FR-003**: System MUST receive audio from the WebSocket endpoint and play it to the caller in real-time.
- **FR-004**: System MUST support configurable audio encoding for outbound streams (e.g., PCM 16-bit, PCMU, Opus).
- **FR-005**: System MUST support configurable audio decoding for inbound streams (e.g., PCM 16-bit, PCMU, Opus).
- **FR-006**: System MUST provide a `disconnect_bidirectional_ws/1` action to terminate the bidirectional connection.
- **FR-007**: System MUST invoke callback functions for connection lifecycle events (connected, disconnected, reconnecting, failed).
- **FR-008**: System MUST forward non-audio WebSocket messages (text/JSON) to a callback handler.
- **FR-009**: System MUST support custom HTTP headers for WebSocket authentication (API keys, bearer tokens).
- **FR-010**: System MUST handle WebSocket reconnection with configurable retry policy (max attempts, backoff strategy).
- **FR-011**: System MUST provide `mute_outbound/1` and `unmute_outbound/1` actions to control caller-to-AI audio flow.
- **FR-012**: System MUST provide `mute_inbound/1` and `unmute_inbound/1` actions to control AI-to-caller audio flow.
- **FR-013**: System MUST clean up bidirectional connection automatically when the call ends.
- **FR-014**: System MUST support sending text/JSON messages to the WebSocket via a `send_ws_message/2` action.
- **FR-015**: System MUST buffer inbound audio appropriately to handle network jitter without audible artifacts.
- **FR-016**: System MUST enforce a maximum of one bidirectional WebSocket connection per call; attempting to establish a second connection while one is active MUST return an error.
- **FR-017**: System MUST emit structured logs for connection lifecycle events (connect, disconnect, reconnect, errors) with correlation IDs for tracing.
- **FR-018**: System MUST expose metrics for frames sent/received counts, audio latency, buffer depth, and connection duration.
- **FR-019**: System MUST support distributed tracing by propagating trace context through WebSocket connections.

### Key Entities

- **BidirectionalConnection**: Represents an active bidirectional WebSocket session, including connection state, audio encoding settings, mute states, and callback configuration.
- **ConnectionConfig**: Configuration for establishing a bidirectional connection, including URL, headers, audio format, retry policy, and callback module.
- **AudioStream**: The bidirectional audio path between the call and the WebSocket, supporting independent control of each direction.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Audio round-trip latency from caller speech to AI response playback is under 500ms (excluding AI processing time).
- **SC-002**: System supports 100 concurrent bidirectional connections per instance without degradation.
- **SC-003**: Connection establishment completes within 2 seconds for available WebSocket endpoints.
- **SC-004**: Audio quality is preserved with no more than 1% frame loss under normal network conditions.
- **SC-005**: Reconnection after network disruption succeeds within 5 seconds when the endpoint is available.
- **SC-006**: Developers can integrate a new AI service in under 30 minutes using the callback API.
- **SC-007**: System handles graceful shutdown of all connections within 1 second when the application stops.

## Clarifications

### Session 2026-01-10

- Q: Should a single call support multiple concurrent bidirectional WebSocket connections? → A: No, only one bidirectional connection per call at a time (simpler, covers primary use case)
- Q: What level of observability should bidirectional connections provide? → A: Full telemetry - Logs, metrics (frames sent/received, latency, buffer depth), and distributed tracing

## Assumptions

- The AI service WebSocket endpoint follows a message-based protocol where audio is sent as binary frames and control messages as text/JSON frames.
- The caller's audio is already available in a Membrane pipeline that can be tapped via a Tee element (following the existing fork_ws pattern).
- The default audio format is PCM 16-bit 16kHz mono, which is common for speech-to-speech AI services, but other formats are configurable.
- The Fresh WebSocket library (already used by WsAudioForker) will be used for WebSocket connections.
- The existing Registry pattern (`ParrotMedia.WsForkerRegistry`) can be extended or a new registry created for bidirectional connections.
