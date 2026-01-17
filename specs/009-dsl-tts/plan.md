# Implementation Plan: DSL Text-to-Speech Support

**Branch**: `009-dsl-tts` | **Date**: 2026-01-17 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/009-dsl-tts/spec.md`

## Summary

Add text-to-speech capabilities to the Parrot DSL, enabling dynamic audio prompts without pre-recorded files. The implementation uses a provider-agnostic design with pluggable TTS providers (OpenAI, ElevenLabs, Google, Polly), async caching to minimize latency, and handler callbacks for error handling. New `say/2,3` and `say_prompt/3` functions mirror the existing `play/2,3` and `prompt/3` API.

## Technical Context

**Language/Version**: Elixir ~> 1.16 with OTP 26+
**Primary Dependencies**: Req (HTTP client), ExSDP, Membrane Framework (existing)
**Storage**: ETS (in-memory cache), Disk (persistent cache with TTL)
**Testing**: ExUnit with async: true where possible, SIPp for integration
**Target Platform**: Linux/macOS server, embedded in Parrot umbrella app
**Project Type**: Umbrella app - adding to `apps/parrot` (DSL layer)
**Performance Goals**: Cached TTS playback within 100ms (matching file playback)
**Constraints**: No streaming TTS (async fetch + cache), no SSML
**Scale/Scope**: Per-call TTS synthesis, cache shared across calls

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| TDD Policy | PASS | Tests written first for all new modules |
| No Shortcuts | PASS | Full provider implementations, not stubs |
| Media Handler Pattern | PASS | TTS uses message-passing via existing pipeline |
| RFC References | N/A | TTS is not SIP protocol work |
| Pattern Matching | PASS | Provider dispatch via pattern matching on atoms |

## Project Structure

### Documentation (this feature)

```text
specs/009-dsl-tts/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (Provider behaviour specs)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
apps/parrot/lib/parrot/
├── call.ex                    # Add say/2,3, say_prompt/3 functions
├── invite_handler.ex          # Add handle_tts_error/3 callback
├── bridge/
│   └── action_executor.ex     # Add :say operation handling
└── tts/                       # NEW: TTS subsystem
    ├── provider.ex            # Provider behaviour definition
    ├── cache.ex               # Cache behaviour definition
    ├── synthesizer.ex         # Coordination: cache + provider
    ├── config.ex              # Profile configuration loader
    ├── cache/
    │   ├── ets.ex             # ETS cache backend
    │   └── disk.ex            # Disk cache backend
    └── providers/
        ├── openai.ex          # OpenAI TTS provider
        ├── elevenlabs.ex      # ElevenLabs provider
        ├── google.ex          # Google Cloud TTS provider
        └── polly.ex           # Amazon Polly provider

apps/parrot/test/parrot/
└── tts/                       # NEW: TTS tests
    ├── provider_test.exs      # Behaviour contract tests
    ├── cache_test.exs         # Cache behaviour tests
    ├── synthesizer_test.exs   # Integration tests
    ├── config_test.exs        # Config loading tests
    ├── cache/
    │   ├── ets_test.exs
    │   └── disk_test.exs
    └── providers/
        ├── openai_test.exs
        ├── elevenlabs_test.exs
        ├── google_test.exs
        └── polly_test.exs
```

**Structure Decision**: Following existing Parrot umbrella structure. TTS is a subsystem within the `apps/parrot` DSL layer, similar to how `bridge/`, `router/`, and `call/` are organized. Tests mirror source structure.

## Complexity Tracking

No constitution violations requiring justification.

---

## Phase 0: Research

### Research Tasks

1. **Provider API Research** - Document API endpoints, auth methods, audio formats for each provider
2. **Cache Key Strategy** - Determine optimal hashing approach for text + config
3. **Audio Format Conversion** - Research format compatibility with existing Membrane pipelines
4. **HTTP Client Selection** - Confirm Req is appropriate for async TTS fetching

### Research Findings

See [research.md](./research.md) for detailed findings.

---

## Phase 1: Design

### Data Model

See [data-model.md](./data-model.md) for entity definitions.

### Contracts

See [contracts/](./contracts/) for behaviour specifications.

### Quickstart

See [quickstart.md](./quickstart.md) for usage examples.

---

## Implementation Phases

### Phase 1: Core Infrastructure (P1 Stories)
- Provider behaviour definition
- Cache behaviour definition
- Synthesizer coordination module
- ETS cache backend

### Phase 2: DSL Integration (P1 Stories)
- `say/2,3` functions in Call module
- `say_prompt/3` function
- ActionExecutor `:say` handling
- Integration with existing play infrastructure

### Phase 3: Provider Implementations (P2 Stories)
- OpenAI TTS provider
- ElevenLabs provider
- Google Cloud TTS provider
- Amazon Polly provider

### Phase 4: Configuration & Caching (P2 Stories)
- Profile configuration loader
- Disk cache backend
- Cache TTL handling

### Phase 5: Error Handling (P3 Stories)
- `handle_tts_error/3` callback in InviteHandler
- Default implementation
- Custom handler support

### Phase 6: Polish & Documentation
- Integration tests with SIPp
- Documentation updates
- Example handlers
