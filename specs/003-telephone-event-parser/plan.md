# Implementation Plan: RFC 2833/4733 Telephone-Event Parser

**Branch**: `003-telephone-event-parser` | **Date**: 2026-01-09 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-telephone-event-parser/spec.md`

## Summary

Implement a Membrane Framework filter element that parses RFC 2833/RFC 4733 telephone-event payloads from RTP streams to detect DTMF digits. The element monitors incoming RTP traffic, parses 4-byte telephone-event payloads, tracks multi-packet events using timestamp + event_id correlation, and emits `{:dtmf, digit}` notifications when complete digits are detected (end_bit=true). All RTP packets pass through unchanged (filter pattern).

## Technical Context

**Language/Version**: Elixir ~> 1.16 with OTP 26+
**Primary Dependencies**: membrane_core ~> 1.0, membrane_rtp_plugin ~> 0.31.0, membrane_rtp_format ~> 0.11.0
**Storage**: N/A (stateless filter with transient event tracking state)
**Testing**: ExUnit with `async: true` for unit tests, `async: false` for pipeline integration tests
**Target Platform**: Linux/macOS server (same as parrot_media)
**Project Type**: Umbrella app - element lives in `apps/parrot_media`
**Performance Goals**: 200 RTP packets/second without backpressure (typical VoIP call rate)
**Constraints**: Must not introduce latency; memory-stable for long key presses (1000+ packets)
**Scale/Scope**: Single RTP stream per element instance; concurrent calls handled by separate pipelines

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution is a template (not yet filled in). Applying principles from CLAUDE.md:

| Principle | Status | Notes |
|-----------|--------|-------|
| TDD Policy | ✅ PASS | Tests will be written before implementation |
| No Shortcuts | ✅ PASS | Full RFC 4733 compliance planned |
| Media Handler Pattern | ✅ PASS | Uses Membrane notification pattern, not direct function calls |
| Pattern Matching | ✅ PASS | Will use pattern matching for payload parsing |
| No SIP Dependencies | ✅ PASS | Element lives in parrot_media, no SIP imports |
| Membrane Framework Patterns | ✅ PASS | Using `Membrane.Filter` with proper pad definitions |

## Project Structure

### Documentation (this feature)

```text
specs/003-telephone-event-parser/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (Membrane element API)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
apps/parrot_media/
├── lib/parrot_media/
│   └── elements/
│       └── telephone_event_parser.ex    # New Membrane Filter element
└── test/parrot_media/
    └── elements/
        ├── telephone_event_parser_test.exs           # Unit tests
        └── telephone_event_parser_integration_test.exs  # Pipeline tests
```

**Structure Decision**: The element follows existing parrot_media patterns (see `audio_chunker.ex`, `rtp_packet.ex`). Located under `elements/` subdirectory to organize Membrane elements separately from other modules.

## Complexity Tracking

> No constitution violations requiring justification. Implementation is a single focused module.
