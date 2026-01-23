# Workstream: WebSocket Bidirectional Audio (US2-US4)

## Worktree Setup
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git worktree add ../parrot-ws-bidir 01-dsl-refactor -b workstream/ws-bidirectional
cd ../parrot-ws-bidir
```

## When Complete
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git checkout 01-dsl-refactor
git merge workstream/ws-bidirectional
git worktree remove ../parrot-ws-bidir
git branch -d workstream/ws-bidirectional
```

## Context
Bidirectional WebSocket audio for speech-to-speech AI integrations.
US1 (MVP) is complete. Continue with lifecycle and control features.
- Spec: specs/004-bidirectional-ws/spec.md
- Plan: specs/004-bidirectional-ws/plan.md

## Your Tasks (beads IDs)
Epic: 9cr - Bidirectional WebSocket Audio Connection

Remaining phases:
- 9cr.4: Phase 4: US2 - Handle Connection Lifecycle Events (P2)
- 9cr.5: Phase 5: US3 - Control Audio Direction (P3)
- 9cr.6: Phase 6: US4 - Disconnect Bidirectional Connection (P4)
- 9cr.7: Phase 7: Observability and Polish (P4)

## Beads Workflow
```bash
bd show 9cr           # View epic and all phases
bd show 9cr.4         # View Phase 4 details
bd update 9cr.4 --status in_progress
bd close 9cr.4 "Implemented lifecycle callbacks with tests"
bd sync
```

## Architecture
- Module: apps/parrot_media/lib/parrot_media/ws_bidirectional/
- DSL operations: apps/parrot/lib/parrot/call.ex
- Follows WsAudioForker patterns

## Feature Details
**US2 Callbacks:** on_connect, on_disconnect, on_reconnect, on_fail
**US3 Audio Control:** mute_inbound/unmute_inbound, mute_outbound/unmute_outbound
**US4 Clean Disconnect:** disconnect_bidirectional/1, resource cleanup

## Subagent Usage
Use subagents for each phase (9cr.4, 9cr.5, etc.)
Each subagent follows TDD and implements one user story.

## Before Merging
1. Run `mix test` - all tests must pass
2. <500ms latency target verified
3. `bd sync && git add .beads && git commit -m "Sync beads"`
