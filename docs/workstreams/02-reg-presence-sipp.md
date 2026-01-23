# Workstream: Registration/Presence SIPp Scenarios

## Worktree Setup
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git worktree add ../parrot-reg-sipp 01-dsl-refactor -b workstream/reg-presence-sipp
cd ../parrot-reg-sipp
```

## When Complete
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git checkout 01-dsl-refactor
git merge workstream/reg-presence-sipp
git worktree remove ../parrot-reg-sipp
git branch -d workstream/reg-presence-sipp
```

## Context
Create automated SIPp scenarios for registration and presence testing.
Location: apps/parrot_sip/test/sipp/scenarios/

## Your Tasks (beads IDs)
- 8u6: Create SIPp scenario: Basic REGISTER / 200 OK (no auth)
- cio: Create SIPp scenario: REGISTER with expires=0 (unregister)
- uxd: Create SIPp scenario: Multiple contacts in single REGISTER
- lol: Create SIPp scenario: SUBSCRIBE/NOTIFY presence flow
- 2d7: Create SIPp scenario: PUBLISH presence update

## Beads Workflow
```bash
bd show 8u6           # View task details
bd update 8u6 --status in_progress
bd close 8u6 "Created uac_register_basic.xml with integration test"
bd sync
```

## Reference
- Existing scenarios: apps/parrot_sip/test/sipp/scenarios/
- SIPp test helper: apps/parrot_sip/test/support/sipp_helper.ex
- Run tests: `mix test --only sipp`

## File Naming Convention
- register/uac_register_basic.xml
- register/uac_register_unregister.xml
- register/uac_register_multi_contact.xml
- presence/uac_subscribe_notify.xml
- presence/uac_publish.xml

## Each Scenario Needs
1. XML scenario file
2. Elixir integration test in test/sipp/
3. Test handler if needed

## Subagent Usage
Use subagents for implementing each scenario (one per scenario).
Follow TDD: Write test first, then scenario.

## Before Merging
1. Run `mix test --only sipp` - all SIPp tests must pass
2. Run `mix test` - full suite must pass
3. `bd sync && git add .beads && git commit -m "Sync beads"`
