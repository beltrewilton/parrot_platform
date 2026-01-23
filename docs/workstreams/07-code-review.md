# Workstream: Code Review Technical Debt

## Worktree Setup
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git worktree add ../parrot-code-review 01-dsl-refactor -b workstream/code-review
cd ../parrot-code-review
```

## When Complete
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git checkout 01-dsl-refactor
git merge workstream/code-review
git worktree remove ../parrot-code-review
git branch -d workstream/code-review
```

## Context
Address code review findings from previous sessions.
These are independent fixes that improve code quality.

## Your Tasks (beads IDs)

### P1 (Higher Priority)
- rxd: Test Suite Process.sleep Timing Issues
- r1b: Silent Exception Swallowing in MOS Calculator
- mnl: TTS Synthesizer Process Safety

### P2 (Standard)
- cwh: Callback Exception Masking in ExpiryManager
- yo0: Missing @tag :slow on Integration Tests
- bsq: Tests Using :sys.get_state for Internal State
- mza: Duplicate MOS Configuration
- 5zf: GitHub Dependency Should Use Hex.pm
- 0rl: Missing @moduledoc on Key Supervisor Modules
- rlg: Error Handling in Media Handler Callbacks
- 3sa: GenServer.cast for State Changes Needing Acknowledgment

## Beads Workflow
```bash
bd show rxd           # View task details
bd update rxd --status in_progress
bd close rxd "Fixed timing issues with receive patterns"
bd sync
```

## Approach
1. Read the task description for context
2. Find the affected code
3. Write a test that exposes the issue (if applicable)
4. Fix the issue
5. Verify tests pass
6. Commit with task ID reference

## Commit Format
```
[<task-id>] Fix: <brief description>
```

## Subagent Usage
Can dispatch subagents for independent fixes in parallel.
Each fix is isolated - no dependencies between them.

## Before Merging
1. Run `mix test` - all tests must pass
2. Run `mix format --check-formatted`
3. Each fix in separate commit
4. `bd sync && git add .beads && git commit -m "Sync beads"`
