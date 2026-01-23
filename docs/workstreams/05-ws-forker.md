# Workstream: WebSocket Audio Forker (US2-US5)

## Worktree Setup
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git worktree add ../parrot-ws-forker 01-dsl-refactor -b workstream/ws-forker
cd ../parrot-ws-forker
```

## When Complete
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git checkout 01-dsl-refactor
git merge workstream/ws-forker
git worktree remove ../parrot-ws-forker
git branch -d workstream/ws-forker
```

## Context
WebSocket audio forker for AI transcription services.
US1 (MVP) complete. Continue with resilience and advanced features.

## Your Tasks (beads IDs)
Epic: e9h - WebSocket Audio Forker

Remaining tasks:
- e9h.4: US2 - Multiple Concurrent Forks (P2)
- e9h.5: US3 - Resilient Connection Handling (P2)
- e9h.8: Phase 8 - Polish & Cross-Cutting (P2)
- e9h.6: US4 - Backpressure Handling (P3)
- e9h.7: US5 - Audio Format Configuration (P3)

## Beads Workflow
```bash
bd show e9h           # View epic and all tasks
bd show e9h.4         # View US2 details
bd update e9h.4 --status in_progress
bd close e9h.4 "Implemented concurrent forks with supervisor"
bd sync
```

## Architecture
- Module: apps/parrot_media/lib/parrot_media/ws_audio_forker/
- GenServer forking call audio to WebSocket endpoints

## Feature Details
**US2:** Fork same audio to multiple endpoints, independent connection management
**US3:** Reconnection on disconnect, configurable retry policy
**US4:** Handle slow consumers, buffer management
**US5:** Sample rate, channels, encoding options

## Subagent Usage
Use subagents for each user story (e9h.4, e9h.5, etc.)

## Before Merging
1. Run `mix test` - all tests must pass
2. `bd sync && git add .beads && git commit -m "Sync beads"`
