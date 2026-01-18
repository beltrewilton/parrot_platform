# TTS Testing Strategy

## Overview

This document describes the testing approach for the TTS feature and clearly identifies what is and isn't validated by tests.

## Test Layers

### 1. Unit Tests (Mocked) - IMPLEMENTED

| Test File | What It Tests | Mocking Approach |
|-----------|--------------|------------------|
| `provider_test.exs` | Provider behaviour contract | Inline mock modules with `@behaviour` |
| `cache_test.exs` | Cache behaviour contract | Inline mock modules with `@behaviour` |
| `synthesizer_test.exs` | Synthesizer GenServer orchestration | Agent-based mock provider and cache |
| `action_executor_test.exs` | ActionExecutor :say routing | Agent-based mock synthesizer |

**What these validate:**
- Return type contracts are correct
- Error handling paths work
- GenServer state management
- Operation routing logic

**What these do NOT validate:**
- Real API calls work
- Real audio is generated
- Audio is playable

### 2. Integration Tests (Real Components) - IMPLEMENTED

| Test File | What It Tests |
|-----------|--------------|
| `cache/ets_test.exs` | Real ETS cache operations |
| `providers/openai_test.exs` | OpenAI validation logic, request building |

**OpenAI Provider Testing:**
- Uses `Req` library with test plug injection
- Tests validation (api_key, voice, model)
- Tests HTTP request building
- Does NOT make real API calls in CI

### 3. Integration Tests (External APIs) - NOT IMPLEMENTED

Need tests that:
- Call real OpenAI API with test key
- Verify returned audio is valid
- Tagged `@tag :external_api` for optional execution

### 4. End-to-End Tests - NOT IMPLEMENTED

Need tests that:
- Make SIPp call to Parrot server
- Trigger TTS via `say()` operation
- Verify audio is played to caller
- Verify call quality metrics

## Test Execution

```bash
# Run all TTS unit tests (fast, no external deps)
mix test apps/parrot/test/parrot/tts/

# Run with external API tests (requires OPENAI_API_KEY)
OPENAI_API_KEY=sk-xxx mix test apps/parrot/test/parrot/tts/ --include external_api

# Run E2E tests with SIPp (requires SIPp installed)
mix test --only sipp
```

## Known Gaps

1. **No real API integration tests** - We don't test actual OpenAI API
2. **No audio validation** - No verification audio binary is valid MP3/WAV
3. **No E2E media playback** - No verification audio plays via Membrane
4. **No format conversion testing** - No MP3→PCM conversion tests
5. **No performance testing** - No cache hit/miss benchmarks

## Issue Tracking

- `parrot_platform-o5o`: TTS integration testing gaps

## Recommendation

Before production use:
1. Add at least one real API smoke test
2. Add SIPp E2E test for TTS playback
3. Add audio header validation
