# Workstream: DTMF Feature Implementation

## Worktree Setup
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git worktree add ../parrot-dtmf 01-dsl-refactor -b workstream/dtmf-feature
cd ../parrot-dtmf
```

## When Complete
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git checkout 01-dsl-refactor
git merge workstream/dtmf-feature
git worktree remove ../parrot-dtmf
git branch -d workstream/dtmf-feature
```

## Context
Implement RFC 4733 telephone-event parsing for DTMF detection.
- Spec: specs/003-telephone-event-parser/spec.md
- Plan: specs/003-telephone-event-parser/plan.md

## Your Tasks (beads IDs)
Epic: d0r - DTMF Feature Integration

Sub-tasks (work in order):
- prw.10.9-prw.10.20: TelephoneEventParser element (TDD tasks)
- d0r.1: Wire TelephoneEventParser into AlawPipeline
- d0r.2: Wire TelephoneEventParser into OpusPipeline
- d0r.3: Forward DTMF notifications from pipeline to MediaSession
- d0r.4: Create SIPp scenario uac_rtp_dtmf.xml
- d0r.5: Create Elixir test handler for DTMF collection
- d0r.6: Create SIPp DTMF integration test

## Beads Workflow
```bash
bd show d0r           # View epic and children
bd show prw.10        # View TelephoneEventParser tasks
bd update d0r.1 --status in_progress
bd close d0r.1 "Wired parser into AlawPipeline with tests"
bd sync
```

## Architecture
- TelephoneEventParser: Membrane filter element
- Location: apps/parrot_media/lib/parrot_media/elements/
- Passes all buffers through, emits {:dtmf, digit} notifications
- Pipelines wire parser after RTP depayloader

## TDD Required
Follow red-green-refactor for each prw.10.x task.

## Subagent Usage
Use subagents for:
- TelephoneEventParser implementation (prw.10.* tasks)
- Pipeline integration (d0r.1, d0r.2)
- SIPp scenario creation (d0r.4-d0r.6)

Each subagent should follow TDD strictly.

## Before Merging
1. Run `mix test` - all tests must pass
2. Run `mix test --only sipp` - SIPp tests must pass
3. RFC 4733 compliance verified
4. `bd sync && git add .beads && git commit -m "Sync beads"`
