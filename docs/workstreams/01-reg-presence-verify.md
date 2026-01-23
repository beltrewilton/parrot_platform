# Workstream: Registration/Presence Verification & Documentation

## Worktree Setup
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git worktree add ../parrot-reg-verify 01-dsl-refactor -b workstream/reg-presence-verify
cd ../parrot-reg-verify
```

## When Complete
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git checkout 01-dsl-refactor
git merge workstream/reg-presence-verify
git worktree remove ../parrot-reg-verify
git branch -d workstream/reg-presence-verify
```

## Context
The registration and presence DSL implementation is complete. Dev scripts exist at:
- scripts/dev/test_registrar.exs - Standalone registration server
- scripts/dev/test_registrar_presence.exs - Registration + presence integration
- scripts/dev/test_registrar_with_pjsua.sh - Orchestration with logging

## Your Tasks (beads IDs)
- u7l: Verify registration flow with pjsua (in_progress)
- slo: Verify presence flow with pjsua
- 1uo: Update docs/pjsua-testing.md with registration/presence section
- 5k8: Update scripts/dev/TESTING_GUIDE.md with registrar workflow
- wnx: Document Parrot.Examples.Registrar usage
- hit: Test expiry timer → presence integration

## Beads Workflow
```bash
# View task details
bd show u7l

# When starting a task
bd update u7l --status in_progress

# When done
bd close u7l "Verified registration flow - all tests pass"

# If you find a bug - DO NOT FIX INLINE
bd create "Bug: <description>" -t bug -l "bug,registration" -d "<details>"

# Sync beads state
bd sync
```

## Verification Steps
1. Run `./scripts/dev/test_registrar_with_pjsua.sh`
2. In terminal 2: Register Alice with pjsua (see script output for command)
3. Verify 401 challenge → credentials → 200 OK flow
4. Test unregister with `ru` command
5. For presence: Register Bob, subscribe to Alice with `+b` then `s`
6. Verify NOTIFY received when Alice's status changes

## Subagent Usage
You are the orchestrator. Use subagents for:
- Documentation writing (one subagent per doc file)
- Testing verification (capture logs, analyze results)

Keep yourself as coordinator - don't do all work in subagents.

## Before Merging
1. Run `mix test` - all tests must pass
2. Run `mix format --check-formatted`
3. Commit all changes with descriptive messages
4. `bd sync && git add .beads && git commit -m "Sync beads"`
