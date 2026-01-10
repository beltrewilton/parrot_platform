# Tasks: RFC 2833/4733 Telephone-Event Parser

**Input**: Design documents from `/specs/003-telephone-event-parser/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Included per TDD Policy in CLAUDE.md - tests written BEFORE implementation.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Umbrella app**: `apps/parrot_media/lib/parrot_media/` for source
- **Tests**: `apps/parrot_media/test/parrot_media/` for tests

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create element directory structure and base module skeleton

- [ ] T001 Create elements directory at `apps/parrot_media/lib/parrot_media/elements/`
- [ ] T002 Create test elements directory at `apps/parrot_media/test/parrot_media/elements/`
- [ ] T003 Create base module skeleton with `use Membrane.Filter` in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core element infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T004 Define input/output pads with RTP format acceptance in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T005 Define `payload_type` option with validation in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T006 Implement `handle_init/2` callback with state initialization in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T007 Implement `handle_stream_format/4` callback for pass-through in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T008 Implement digit mapping function (event_id 0-15 → "0"-"9", "*", "#", "A"-"D") in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: Foundation ready - element compiles, pads defined, basic callbacks in place

---

## Phase 3: User Story 1 - Detect Single DTMF Digit (Priority: P1) 🎯 MVP

**Goal**: Parse RFC 4733 payload, detect complete DTMF digit (end_bit=1), emit exactly one `{:dtmf, digit}` notification

**Independent Test**: Send a sequence of RTP packets representing a single DTMF digit and verify exactly one notification is emitted

### Tests for User Story 1

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [ ] T009 [P] [US1] Unit test for RFC 4733 payload parsing (4-byte structure) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T010 [P] [US1] Unit test for single digit detection with end_bit=1 in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T011 [P] [US1] Unit test for duplicate suppression (retransmitted end packets) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`

### Implementation for User Story 1

- [ ] T012 [US1] Implement RFC 4733 payload parsing with binary pattern match (`<<event_id::8, end_bit::1, _reserved::1, _volume::6, _duration::16>>`) in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T013 [US1] Implement `handle_buffer/4` callback with payload type filtering in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T014 [US1] Implement DTMF event tracking state (current_event, completed_events) in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T015 [US1] Implement `notify_parent: {:dtmf, digit}` action when end_bit=1 in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T016 [US1] Implement duplicate suppression using completed_events MapSet (limit 10) in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: Single digit detection works, notifications emitted, duplicates suppressed

---

## Phase 4: User Story 2 - Collect Multiple Digits in Sequence (Priority: P1)

**Goal**: Correctly reset state between events, detect sequential digits in order

**Independent Test**: Send RTP packet sequences for digits "1", "2", "3", "4" and verify four separate notifications in correct order

### Tests for User Story 2

- [ ] T017 [P] [US2] Unit test for sequential digit detection ("1234" → 4 notifications) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T018 [P] [US2] Unit test for state reset between events (different timestamp/event_id) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`

### Implementation for User Story 2

- [ ] T019 [US2] Implement event transition detection (new event_id or timestamp discontinuity) in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T020 [US2] Implement state reset logic when new event begins in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: Multi-digit sequences work, state correctly resets between events

---

## Phase 5: User Story 3 - Filter by Payload Type (Priority: P2)

**Goal**: Only parse packets matching configured payload_type, pass through all other packets unchanged

**Independent Test**: Send mix of audio (PT=0) and telephone-event (PT=101) packets, verify only PT=101 triggers DTMF detection

### Tests for User Story 3

- [ ] T021 [P] [US3] Unit test for payload type filtering (ignore non-matching PT) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T022 [P] [US3] Unit test for pass-through of non-telephone-event packets in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`

### Implementation for User Story 3

- [ ] T023 [US3] Implement payload type check in `handle_buffer/4` before parsing in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T024 [US3] Ensure all buffers pass through to output pad unchanged in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: Mixed traffic handled correctly, audio passes through, only telephone-events parsed

---

## Phase 6: User Story 4 - Support Special Keys (Priority: P2)

**Goal**: Correctly map all 16 DTMF signals (0-9, *, #, A-D)

**Independent Test**: Send telephone-event sequences for each of the 16 event codes and verify correct character output

### Tests for User Story 4

- [ ] T025 [P] [US4] Unit test for digit mapping (event_id 0-9 → "0"-"9") in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T026 [P] [US4] Unit test for special key mapping (event_id 10 → "*", 11 → "#") in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T027 [P] [US4] Unit test for extended key mapping (event_id 12-15 → "A"-"D") in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`

### Implementation for User Story 4

- [ ] T028 [US4] Verify digit mapping covers all 16 event codes correctly in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T029 [US4] Implement handling for unknown event_id (16+) - ignore silently in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: All 16 DTMF signals correctly mapped and detected

---

## Phase 7: User Story 5 - Handle Long Key Presses (Priority: P3)

**Goal**: Track multi-packet events as single digit, emit one notification when released

**Independent Test**: Send 20+ packets for a single digit with incrementing duration and end_bit=false, then end packet, verify exactly one notification

### Tests for User Story 5

- [ ] T030 [P] [US5] Unit test for long press tracking (40+ intermediate packets → 1 notification) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T031 [P] [US5] Unit test for maximum duration handling (0xFFFF) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`

### Implementation for User Story 5

- [ ] T032 [US5] Verify current_event tracking handles long sequences without state corruption in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T033 [US5] Verify memory stability (no growth) during long key presses in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: Long key presses tracked correctly, memory stable

---

## Phase 8: User Story 6 - Recover from Packet Loss (Priority: P3)

**Goal**: Handle gaps gracefully, recover when new event begins

**Independent Test**: Send incomplete telephone-event sequence followed by new event, verify parser recovers and detects second event

### Tests for User Story 6

- [ ] T034 [P] [US6] Unit test for missing intermediate packets (end packet still works) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T035 [P] [US6] Unit test for lost end packets (new event resets state) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T036 [P] [US6] Unit test for lost first packet (tracking starts from first received) in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`

### Implementation for User Story 6

- [ ] T037 [US6] Verify state machine handles missing packets without crash in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T038 [US6] Verify new event always resets stale tracking state in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: Packet loss handled gracefully, parser recovers automatically

---

## Phase 9: Edge Cases & Error Handling

**Purpose**: Handle malformed payloads and configuration errors

### Tests for Edge Cases

- [ ] T039 [P] Unit test for malformed payload (wrong size) - logs warning, passes through in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`
- [ ] T040 [P] Unit test for missing payload_type config - raises ArgumentError in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs`

### Implementation for Edge Cases

- [ ] T041 Implement malformed payload handling (log warning, pass through) in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T042 Implement payload_type validation in `handle_init/2` in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`

**Checkpoint**: Error cases handled gracefully

---

## Phase 10: Integration & Polish

**Purpose**: Pipeline integration testing and documentation

- [ ] T043 [P] Create pipeline integration test in `apps/parrot_media/test/parrot_media/elements/telephone_event_parser_integration_test.exs`
- [ ] T044 [P] Add @moduledoc with RFC references and usage examples in `apps/parrot_media/lib/parrot_media/elements/telephone_event_parser.ex`
- [ ] T045 Run `mix format` on new files
- [ ] T046 Run `mix compile --warnings-as-errors` to verify no warnings
- [ ] T047 Run full test suite `mix test apps/parrot_media/test/parrot_media/elements/`
- [ ] T048 Validate quickstart.md examples work

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phases 3-8)**: All depend on Foundational phase completion
  - US1 and US2 are both P1 priority - can run in parallel
  - US3 and US4 are both P2 priority - can run in parallel after US1/US2
  - US5 and US6 are both P3 priority - can run in parallel after US3/US4
- **Edge Cases (Phase 9)**: Can run after Foundational, in parallel with user stories
- **Integration (Phase 10)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P1)**: Can start after Foundational (Phase 2) - Shares code with US1 but independently testable
- **User Story 3 (P2)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 4 (P2)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 5 (P3)**: Can start after Foundational (Phase 2) - Uses US1 tracking, but independently testable
- **User Story 6 (P3)**: Can start after Foundational (Phase 2) - Uses US1 tracking, but independently testable

### Within Each User Story

- Tests MUST be written and FAIL before implementation (TDD Policy)
- Implementation follows tests
- Story complete before checkpoint

### Parallel Opportunities

- All tests marked [P] within a story can run in parallel
- Different user stories can be worked on in parallel by different developers
- Edge case tests can run in parallel with user story tests

---

## Parallel Example: User Story 1 Tests

```bash
# Launch all tests for User Story 1 together:
Task: "Unit test for RFC 4733 payload parsing in telephone_event_parser_test.exs"
Task: "Unit test for single digit detection with end_bit=1 in telephone_event_parser_test.exs"
Task: "Unit test for duplicate suppression in telephone_event_parser_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1 (single digit detection)
4. **STOP and VALIDATE**: Test User Story 1 independently
5. Deploy/demo if ready - basic DTMF detection works

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 (single digit) → Test → MVP functional
3. Add User Story 2 (multi-digit) → Test → PIN entry works
4. Add User Story 3 (payload filtering) → Test → Mixed traffic works
5. Add User Story 4 (special keys) → Test → Full DTMF support
6. Add User Story 5 (long press) → Test → Robust detection
7. Add User Story 6 (packet loss) → Test → Production ready
8. Edge Cases + Integration → Test → Complete feature

### Single Developer Strategy

Work sequentially through phases in priority order (P1 → P2 → P3).
Each checkpoint validates a working increment.

---

## Summary

| Phase | Tasks | Focus |
|-------|-------|-------|
| Phase 1: Setup | T001-T003 (3) | Directory structure |
| Phase 2: Foundational | T004-T008 (5) | Core element skeleton |
| Phase 3: US1 - Single Digit | T009-T016 (8) | MVP - basic detection |
| Phase 4: US2 - Multi-Digit | T017-T020 (4) | Sequential digits |
| Phase 5: US3 - Payload Filter | T021-T024 (4) | Mixed traffic |
| Phase 6: US4 - Special Keys | T025-T029 (5) | Full DTMF |
| Phase 7: US5 - Long Press | T030-T033 (4) | Robust tracking |
| Phase 8: US6 - Packet Loss | T034-T038 (5) | Recovery |
| Phase 9: Edge Cases | T039-T042 (4) | Error handling |
| Phase 10: Integration | T043-T048 (6) | Polish |
| **Total** | **48 tasks** | |

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- TDD Policy: Verify tests fail before implementing
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
