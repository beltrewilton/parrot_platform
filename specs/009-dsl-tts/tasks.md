# Tasks: DSL Text-to-Speech Support

**Input**: Design documents from `/specs/009-dsl-tts/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Included per project TDD policy (CLAUDE.md requires tests before implementation)

**Organization**: Tasks grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, etc.)
- All paths relative to repository root

## Path Conventions

- **Source**: `apps/parrot/lib/parrot/tts/`
- **Tests**: `apps/parrot/test/parrot/tts/`
- **Existing DSL**: `apps/parrot/lib/parrot/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create TTS module structure and add dependencies

- [ ] T001 Create TTS directory structure: `apps/parrot/lib/parrot/tts/`, `apps/parrot/lib/parrot/tts/cache/`, `apps/parrot/lib/parrot/tts/providers/`
- [ ] T002 Create test directory structure: `apps/parrot/test/parrot/tts/`, `apps/parrot/test/parrot/tts/cache/`, `apps/parrot/test/parrot/tts/providers/`
- [ ] T003 [P] Add Req HTTP client dependency to `apps/parrot/mix.exs`
- [ ] T004 [P] Add Jason JSON library dependency if not present in `apps/parrot/mix.exs`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core behaviours and synthesizer that ALL user stories depend on

**CRITICAL**: No user story work can begin until this phase is complete

### Tests for Foundational

- [ ] T005 [P] Write Provider behaviour contract tests in `apps/parrot/test/parrot/tts/provider_test.exs`
- [ ] T006 [P] Write Cache behaviour contract tests in `apps/parrot/test/parrot/tts/cache_test.exs`
- [ ] T007 [P] Write Synthesizer unit tests in `apps/parrot/test/parrot/tts/synthesizer_test.exs`
- [ ] T008 [P] Write ETS cache backend tests in `apps/parrot/test/parrot/tts/cache/ets_test.exs`

### Implementation for Foundational

- [ ] T009 [P] Define Provider behaviour with callbacks in `apps/parrot/lib/parrot/tts/provider.ex`
- [ ] T010 [P] Define Cache behaviour with callbacks in `apps/parrot/lib/parrot/tts/cache.ex`
- [ ] T011 Implement ETS cache backend in `apps/parrot/lib/parrot/tts/cache/ets.ex` (depends on T010)
- [ ] T012 Implement Synthesizer GenServer in `apps/parrot/lib/parrot/tts/synthesizer.ex` (depends on T009, T010, T011)
- [ ] T013 Create mock provider for testing in `apps/parrot/test/support/mock_tts_provider.ex`

**Checkpoint**: Foundation ready - Provider/Cache behaviours defined, Synthesizer works with mock provider

---

## Phase 3: User Story 1 - Basic TTS Playback (Priority: P1) MVP

**Goal**: Developers can call `say("text")` and hear synthesized speech

**Independent Test**: Call `say("Hello, your balance is $50")` in a handler and hear audio

### Tests for User Story 1

- [ ] T014 [P] [US1] Write say/2,3 function tests in `apps/parrot/test/parrot/call_test.exs`
- [ ] T015 [P] [US1] Write ActionExecutor :say handling tests in `apps/parrot/test/parrot/bridge/action_executor_test.exs`
- [ ] T016 [P] [US1] Write OpenAI provider tests in `apps/parrot/test/parrot/tts/providers/openai_test.exs`

### Implementation for User Story 1

- [ ] T017 [P] [US1] Add `say/2` and `say/3` functions to `apps/parrot/lib/parrot/call.ex`
- [ ] T018 [US1] Add `:say` operation handling to `apps/parrot/lib/parrot/bridge/action_executor.ex` (depends on T017)
- [ ] T019 [US1] Implement OpenAI TTS provider in `apps/parrot/lib/parrot/tts/providers/openai.ex` (depends on T009)
- [ ] T020 [US1] Create basic profile config module in `apps/parrot/lib/parrot/tts/config.ex`
- [ ] T021 [US1] Wire ActionExecutor to Synthesizer for TTS playback (depends on T012, T018)

**Checkpoint**: `say("Hello")` works with OpenAI provider and plays audio to caller

---

## Phase 4: User Story 2 - TTS with DTMF Collection (Priority: P1)

**Goal**: Developers can call `say_prompt("text", max: 4)` for interactive TTS

**Independent Test**: Call `say_prompt("Enter PIN", max: 4)` and enter digits after TTS plays

### Tests for User Story 2

- [ ] T022 [P] [US2] Write say_prompt/3 function tests in `apps/parrot/test/parrot/call_test.exs`
- [ ] T023 [P] [US2] Write ActionExecutor :say_prompt handling tests in `apps/parrot/test/parrot/bridge/action_executor_test.exs`

### Implementation for User Story 2

- [ ] T024 [US2] Add `say_prompt/3` function to `apps/parrot/lib/parrot/call.ex`
- [ ] T025 [US2] Add `:say_prompt` operation handling to `apps/parrot/lib/parrot/bridge/action_executor.ex` (depends on T024)
- [ ] T026 [US2] Integrate say_prompt with existing DTMF collection in ActionExecutor (depends on T025)

**Checkpoint**: `say_prompt("Enter PIN", max: 4)` plays TTS then collects DTMF digits

---

## Phase 5: User Story 3 - Provider Profiles Configuration (Priority: P2)

**Goal**: Developers can configure named profiles and switch between providers

**Independent Test**: Configure standard/premium profiles, verify `say("text", profile: :premium)` uses correct provider

### Tests for User Story 3

- [ ] T027 [P] [US3] Write Config module tests in `apps/parrot/test/parrot/tts/config_test.exs`
- [ ] T028 [P] [US3] Write profile selection tests in `apps/parrot/test/parrot/tts/synthesizer_test.exs`

### Implementation for User Story 3

- [ ] T029 [US3] Extend Config module with full profile loading in `apps/parrot/lib/parrot/tts/config.ex`
- [ ] T030 [US3] Add environment variable credential resolution to Config
- [ ] T031 [US3] Update Synthesizer to use profile-based provider selection (depends on T029)
- [ ] T032 [P] [US3] Implement ElevenLabs provider in `apps/parrot/lib/parrot/tts/providers/elevenlabs.ex`
- [ ] T033 [P] [US3] Implement Google Cloud TTS provider in `apps/parrot/lib/parrot/tts/providers/google.ex`
- [ ] T034 [P] [US3] Implement Amazon Polly provider in `apps/parrot/lib/parrot/tts/providers/polly.ex`

**Checkpoint**: Multiple profiles configured, provider switching works via `profile:` option

---

## Phase 6: User Story 4 - TTS Caching (Priority: P2)

**Goal**: TTS audio is cached to reduce API calls and latency

**Independent Test**: Call `say("Welcome")` twice, verify second call uses cache (no API call)

### Tests for User Story 4

- [ ] T035 [P] [US4] Write cache key generation tests in `apps/parrot/test/parrot/tts/synthesizer_test.exs`
- [ ] T036 [P] [US4] Write Disk cache backend tests in `apps/parrot/test/parrot/tts/cache/disk_test.exs`
- [ ] T037 [P] [US4] Write cache hit/miss integration tests in `apps/parrot/test/parrot/tts/synthesizer_test.exs`

### Implementation for User Story 4

- [ ] T038 [US4] Implement deterministic cache key generation in Synthesizer (SHA256 of text + config)
- [ ] T039 [US4] Implement Disk cache backend in `apps/parrot/lib/parrot/tts/cache/disk.ex`
- [ ] T040 [US4] Add TTL expiration to Disk cache (depends on T039)
- [ ] T041 [US4] Add concurrent request deduplication to Synthesizer (first fetches, others wait)

**Checkpoint**: Repeated phrases use cached audio, disk cache persists across restarts

---

## Phase 7: User Story 5 - TTS Error Handling (Priority: P3)

**Goal**: TTS failures invoke handler callback instead of crashing

**Independent Test**: Configure invalid API key, verify `handle_tts_error/3` is invoked

### Tests for User Story 5

- [ ] T042 [P] [US5] Write handle_tts_error/3 callback tests in `apps/parrot/test/parrot/invite_handler_test.exs`
- [ ] T043 [P] [US5] Write error propagation tests in `apps/parrot/test/parrot/bridge/action_executor_test.exs`

### Implementation for User Story 5

- [ ] T044 [US5] Add `handle_tts_error/3` callback to InviteHandler behaviour in `apps/parrot/lib/parrot/invite_handler.ex`
- [ ] T045 [US5] Add default implementation that logs and continues
- [ ] T046 [US5] Wire ActionExecutor to invoke error callback on synthesis failure (depends on T044)

**Checkpoint**: TTS failures logged and call continues, custom handlers can override

---

## Phase 8: User Story 6 - Custom TTS Provider (Priority: P3)

**Goal**: Developers can implement custom providers using the behaviour

**Independent Test**: Implement mock provider, configure as profile, verify it's called

### Tests for User Story 6

- [ ] T047 [P] [US6] Write custom provider integration tests in `apps/parrot/test/parrot/tts/provider_test.exs`

### Implementation for User Story 6

- [ ] T048 [US6] Add provider documentation and example in `apps/parrot/lib/parrot/tts/provider.ex` moduledoc
- [ ] T049 [US6] Create example custom provider in `apps/parrot/lib/parrot/examples/custom_tts_provider.ex`
- [ ] T050 [US6] Verify config accepts custom provider modules

**Checkpoint**: Custom provider implementation works, documented in moduledoc

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Integration testing, documentation, examples

- [ ] T051 [P] Create TTS integration test with SIPp in `apps/parrot_sip/test/sipp/tts_test.exs`
- [ ] T052 [P] Add TTS example handler in `apps/parrot/lib/parrot/examples/tts_demo.ex`
- [ ] T053 [P] Update CLAUDE.md with TTS subsystem documentation
- [ ] T054 Run full test suite and verify all tests pass
- [ ] T055 Validate quickstart.md examples work as documented

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - start immediately
- **Foundational (Phase 2)**: Depends on Setup - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational
- **User Story 2 (Phase 4)**: Depends on Foundational, can parallel with US1
- **User Story 3 (Phase 5)**: Depends on Foundational, can parallel with US1/US2
- **User Story 4 (Phase 6)**: Depends on Foundational, can parallel with US1/US2/US3
- **User Story 5 (Phase 7)**: Depends on US1 (needs say/2 to exist)
- **User Story 6 (Phase 8)**: Depends on Foundational only
- **Polish (Phase 9)**: Depends on all user stories complete

### User Story Dependencies

| Story | Depends On | Can Parallel With |
|-------|------------|-------------------|
| US1 (Basic TTS) | Foundational | - |
| US2 (TTS+DTMF) | Foundational | US1, US3, US4, US6 |
| US3 (Profiles) | Foundational | US1, US2, US4, US6 |
| US4 (Caching) | Foundational | US1, US2, US3, US6 |
| US5 (Errors) | US1 | US6 |
| US6 (Custom) | Foundational | US1, US2, US3, US4, US5 |

### Parallel Opportunities per Phase

**Foundational (8 parallel tasks)**:
- T005, T006, T007, T008 (all tests)
- T009, T010 (both behaviours)

**US1 (3 parallel tasks)**:
- T014, T015, T016 (all tests)

**US3 (5 parallel tasks)**:
- T027, T028 (tests)
- T032, T033, T034 (providers)

**US4 (3 parallel tasks)**:
- T035, T036, T037 (all tests)

---

## Parallel Example: Foundational Phase

```bash
# Launch all Foundational tests in parallel:
Task: "Write Provider behaviour contract tests in apps/parrot/test/parrot/tts/provider_test.exs"
Task: "Write Cache behaviour contract tests in apps/parrot/test/parrot/tts/cache_test.exs"
Task: "Write Synthesizer unit tests in apps/parrot/test/parrot/tts/synthesizer_test.exs"
Task: "Write ETS cache backend tests in apps/parrot/test/parrot/tts/cache/ets_test.exs"

# Launch both behaviours in parallel:
Task: "Define Provider behaviour with callbacks in apps/parrot/lib/parrot/tts/provider.ex"
Task: "Define Cache behaviour with callbacks in apps/parrot/lib/parrot/tts/cache.ex"
```

## Parallel Example: Provider Implementations (US3)

```bash
# All 4 providers can be implemented in parallel:
Task: "Implement OpenAI TTS provider in apps/parrot/lib/parrot/tts/providers/openai.ex"
Task: "Implement ElevenLabs provider in apps/parrot/lib/parrot/tts/providers/elevenlabs.ex"
Task: "Implement Google Cloud TTS provider in apps/parrot/lib/parrot/tts/providers/google.ex"
Task: "Implement Amazon Polly provider in apps/parrot/lib/parrot/tts/providers/polly.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (4 tasks)
2. Complete Phase 2: Foundational (9 tasks)
3. Complete Phase 3: User Story 1 (8 tasks)
4. **STOP and VALIDATE**: Test `say("Hello")` with OpenAI
5. Deploy/demo if ready - basic TTS works!

### Incremental Delivery

1. Setup + Foundational (13 tasks) → Foundation ready
2. Add US1 (8 tasks) → MVP: `say/2,3` works
3. Add US2 (5 tasks) → `say_prompt/3` works
4. Add US3 (8 tasks) → Multiple providers, profiles
5. Add US4 (7 tasks) → Caching reduces latency/cost
6. Add US5 (5 tasks) → Production-ready error handling
7. Add US6 (4 tasks) → Extensibility for custom providers
8. Polish (5 tasks) → Documentation, examples

---

## Summary

- **Total Tasks**: 55
- **Setup**: 4 tasks
- **Foundational**: 9 tasks
- **US1 (Basic TTS)**: 8 tasks
- **US2 (TTS+DTMF)**: 5 tasks
- **US3 (Profiles)**: 8 tasks
- **US4 (Caching)**: 7 tasks
- **US5 (Errors)**: 5 tasks
- **US6 (Custom)**: 4 tasks
- **Polish**: 5 tasks

**Parallel Opportunities**: 23 tasks marked [P]

**MVP Scope**: Setup + Foundational + US1 = 21 tasks
