# Implementation Plan: Bidirectional WebSocket Audio Connection

**Branch**: `004-bidirectional-ws` | **Date**: 2026-01-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-bidirectional-ws/spec.md`

## Summary

Add bidirectional WebSocket audio streaming capability to enable real-time speech-to-speech AI integration. This extends the existing unidirectional `WsAudioForker` pattern (which only sends audio to WebSocket) with a new `WsBidirectionalConnector` that supports both sending caller audio to AI services and receiving AI-generated audio back to play to the caller.

## Technical Context

**Language/Version**: Elixir ~> 1.16 with OTP 26+
**Primary Dependencies**: Fresh (WebSocket client), Membrane Framework (media pipelines), Telemetry (observability)
**Storage**: N/A (in-memory process state, Registry for lookups)
**Testing**: ExUnit with SIPp integration tests, mock WebSocket servers
**Target Platform**: Linux server / macOS development
**Project Type**: Umbrella application (apps/parrot, apps/parrot_media, apps/parrot_sip, apps/parrot_transport)
**Performance Goals**: <500ms audio round-trip latency, 100 concurrent connections per instance
**Constraints**: Single bidirectional connection per call, full telemetry required
**Scale/Scope**: Production VoIP platform supporting concurrent AI-assisted calls

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Based on CLAUDE.md project principles:

| Principle | Status | Notes |
|-----------|--------|-------|
| TDD Policy | PASS | Tests will be written before implementation |
| No Shortcuts | PASS | Full implementation following WsAudioForker patterns |
| Media Handler Pattern | PASS | Message-passing design, no function calls for media control |
| State Machines | PASS | Will use GenServer (no complex state transitions needed) |
| NO SIP dependencies in parrot_media | PASS | Feature is in parrot_media, independent of SIP |
| Membrane Framework patterns | PASS | Will create WsBidirectionalSource element for inbound audio |
| Production-Grade Engineering | PASS | Clean APIs, proper abstractions, follows existing patterns |

## Project Structure

### Documentation (this feature)

```text
specs/004-bidirectional-ws/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   └── dsl-actions.md   # DSL action specifications
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
apps/parrot_media/lib/parrot_media/
├── ws_bidirectional_connector.ex          # Main GenServer (like WsAudioForker)
├── ws_bidirectional_connector/
│   ├── config.ex                          # Configuration struct with validation
│   ├── connection.ex                      # Fresh WebSocket handler
│   └── callback.ex                        # Callback behaviour for events
├── ws_bidirectional_source.ex             # Membrane Source for inbound audio
└── ws_bidirectional_sink.ex               # Membrane Sink for outbound audio

apps/parrot_media/test/parrot_media/
├── ws_bidirectional_connector_test.exs    # Unit tests
├── ws_bidirectional_connector/
│   ├── config_test.exs                    # Config validation tests
│   └── callback_test.exs                  # Callback behaviour tests
└── ws_bidirectional_integration_test.exs  # Integration with mock WS server

apps/parrot/lib/parrot/
├── call.ex                                # Add connect_bidirectional_ws/2 action
└── bridge/
    └── action_executor.ex                 # Add execute_connect_bidirectional_ws/4
```

**Structure Decision**: Follows existing umbrella structure. New bidirectional WebSocket components go in `parrot_media` (media layer, no SIP dependencies). DSL integration goes in `parrot` app via Call and ActionExecutor.
