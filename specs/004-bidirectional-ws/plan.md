# Implementation Plan: Bidirectional WebSocket Audio Connection

**Branch**: `004-bidirectional-ws` | **Date**: 2026-01-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-bidirectional-ws/spec.md`

## Summary

Add bidirectional WebSocket audio streaming to enable real-time speech-to-speech AI integrations. Callers can speak to AI services (OpenAI Realtime, ElevenLabs) via WebSocket while hearing AI responses in real-time. Extends the existing unidirectional `WsAudioForker` pattern with a new `WsBidirectionalConnector` GenServer, Membrane Source/Sink elements, and DSL operations.

## Technical Context

**Language/Version**: Elixir ~> 1.16, OTP 26+
**Primary Dependencies**: Membrane Framework, Fresh (WebSocket), ExSDP, Telemetry
**Storage**: N/A (in-memory process state, Registry for lookups)
**Testing**: ExUnit, SIPp integration tests, StreamData property tests
**Target Platform**: Linux server (Nerves-compatible)
**Project Type**: Umbrella application (4 apps: parrot, parrot_sip, parrot_media, parrot_transport)
**Performance Goals**: <500ms audio round-trip latency (excluding AI processing), 100 concurrent connections/instance
**Constraints**: <200ms pipeline latency, message-passing for media control, TDD-first
**Scale/Scope**: Extends parrot_media (new modules) + parrot DSL (new operations)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution is templated and not yet customized. Applying CLAUDE.md rules as effective constitution:

| Principle | Status | Notes |
|-----------|--------|-------|
| TDD Policy | PASS | Tests will be written before implementation |
| No Shortcuts | PASS | Full implementation, no TODOs in production code |
| Media Handler Pattern | PASS | Message-passing for media control (not function calls) |
| State Machines | N/A | GenServer sufficient, no complex state machine needed |
| RFC References | N/A | No SIP protocol changes, media-layer only |
| Single-line Commits | PASS | Will follow |
| Production-Grade | PASS | Clean APIs, proper abstractions planned |
| No SIP in parrot_media | PASS | New modules have no SIP dependencies |

**Gate Result**: PASS - All applicable principles satisfied.

## Project Structure

### Documentation (this feature)

```text
specs/004-bidirectional-ws/
├── plan.md              # This file
├── research.md          # Phase 0 output (complete)
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
apps/parrot_media/lib/parrot_media/
├── ws_bidirectional/
│   ├── connector.ex           # GenServer managing WebSocket + bidirectional state
│   ├── config.ex              # Configuration struct (similar to WsAudioForker.Config)
│   ├── connection.ex          # Fresh WebSocket callbacks
│   ├── source.ex              # Membrane Source element (WS → pipeline)
│   ├── sink.ex                # Membrane Sink element (pipeline → WS)
│   └── telemetry.ex           # Telemetry event definitions and helpers
├── ws_bidirectional.ex        # Public API module

apps/parrot_media/test/parrot_media/
├── ws_bidirectional/
│   ├── connector_test.exs
│   ├── config_test.exs
│   ├── source_test.exs
│   └── sink_test.exs
├── ws_bidirectional_test.exs  # Integration tests

apps/parrot/lib/parrot/
├── call.ex                    # Add new operations (connect_bidirectional_ws, etc.)
├── bridge/
│   └── action_executor.ex     # Add handlers for new operations

apps/parrot/test/parrot/
├── call_bidirectional_ws_test.exs
```

**Structure Decision**: Follows existing `ws_audio_forker/` pattern in parrot_media. New modules in dedicated subdirectory. DSL changes in existing files.

## Complexity Tracking

> No violations requiring justification. Design follows existing patterns.

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| Separate from WsAudioForker | New module hierarchy | Bidirectional adds significant complexity; cleaner separation |
| GenServer over gen_statem | GenServer | Connection states are simple (connected/disconnected), no complex transitions |
| Single connection per call | Enforced | Per clarification; simplifies state management |

## Phase 0 Completion

Research completed in `research.md`. Key decisions:

1. **Inbound audio**: New Membrane Source element (`WsBidirectionalSource`)
2. **Outbound audio**: New Membrane Sink element (`WsBidirectionalSink`)
3. **Connection management**: New GenServer (`WsBidirectionalConnector`)
4. **Audio format**: PCM 16-bit default, Membrane converters for transcoding
5. **Mute control**: Boolean flags with message-based control
6. **DSL integration**: New operations in `Parrot.Call` + `ActionExecutor` handlers
7. **Observability**: `:telemetry` library with structured events
8. **Jitter buffer**: Ring buffer in Source element (60ms default)

## Phase 1 Artifacts

See:
- `data-model.md` - Entity definitions and state
- `contracts/` - API contracts (Elixir behaviour specifications)
- `quickstart.md` - Integration guide for developers

## Implementation Phases (for /speckit.tasks)

### Phase 1: Core Infrastructure
- WsBidirectionalConnector GenServer
- WsBidirectionalConfig struct
- Fresh Connection callbacks
- Registry integration

### Phase 2: Membrane Elements
- WsBidirectionalSource (inbound audio)
- WsBidirectionalSink (outbound audio)
- Jitter buffer implementation
- Audio format configuration

### Phase 3: DSL Integration
- Parrot.Call operations
- ActionExecutor handlers
- MediaSession integration

### Phase 4: Observability & Polish
- Telemetry events
- Structured logging
- Metrics collection
- Documentation

### Phase 5: Testing & Validation
- Unit tests for all modules
- Integration tests with mock WebSocket server
- Performance validation against success criteria
