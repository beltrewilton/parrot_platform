# Orchestrator Startup Guide

Copy this prompt to start a new Claude Code session as an orchestrator for DSL testing.

---

## Prompt for New Orchestrator Session

```
You are an orchestrator for Parrot Platform DSL testing. Multiple orchestrators work in parallel.

**First, read these files:**
1. scripts/dev/SUBAGENT_WORKFLOW.md - Full workflow documentation
2. scripts/dev/SUBAGENT_PROMPT.md - Subagent dispatch templates

**Check current state:**
```bash
# See what's currently locked (being worked on)
./scripts/dev/orchestrator_lock.sh list

# See open bugs needing fixes
bd list --label testing --status open

# See bugs being fixed
bd search "fix-in-progress" --status open

# See recent test results
ls -lt logs/*.log | head -10
```

**Pick up available work based on current cycle phase:**

## If in DISCOVERY phase (finding bugs):
Run tests that aren't locked:
```bash
export ORCHESTRATOR_ID="orch-$(date +%s)"
# Check each test, run if available
for test in test_answer_play test_hangup_dsl test_reject_dsl test_dtmf_dsl test_sdp_negotiation; do
  ./scripts/dev/orchestrator_lock.sh check $test
  # If AVAILABLE, run it:
  # ./scripts/dev/test_and_report.sh $test
done
```

## If in FIX phase (fixing bugs):
1. Find an unfixed bug: `bd list --label testing --status open`
2. Check it's not being worked on: `bd show <bug-id>` (no "fix-in-progress" label)
3. Claim it: `bd update <bug-id> --add-label fix-in-progress --claim`
4. Dispatch implementer subagent with worktree instructions
5. After fix + reviews, remove label: `bd update <bug-id> --remove-label fix-in-progress`

## If in VERIFY phase (checking fixes):
1. List completed fixes: `bd search "fix-complete" --status open`
2. Merge fix branches and re-run tests
3. Close bugs that are fixed: `bd close <bug-id>`

**Coordination rules:**
- Always use locking for tests (automatic in test_and_report.sh)
- Always use worktrees for code changes
- Always use bd labels to communicate state
- If something is locked/claimed, move to next available work
- Log new bugs found during fixes (don't fix them - next cycle)

**Output format for reporting:**
```
ORCHESTRATOR: <your-id>
PHASE: discovery|fix|verify
WORK COMPLETED:
  - TEST: x | STATUS: y | BUG: z
  - TEST: x | STATUS: y | BUG: z
BUGS CREATED: [list]
BUGS FIXED: [list]
NEXT AVAILABLE WORK: [list]
```

Start by checking current state, then pick up available work.
```

---

## Quick Commands Reference

### Check State
```bash
# Current locks
./scripts/dev/orchestrator_lock.sh list

# Open bugs
bd list --label testing --status open --limit 20

# Bugs being fixed
bd search "fix-in-progress"

# Recent logs
ls -lt logs/*.log | head -5
```

### Discovery Phase
```bash
export ORCHESTRATOR_ID="orch-$(date +%s)"
./scripts/dev/test_and_report.sh test_answer_play
./scripts/dev/test_and_report.sh test_hangup_dsl
# etc.
```

### Fix Phase
```bash
# Claim a bug
bd update parrot_platform-xxx --add-label fix-in-progress --claim

# Create worktree
git worktree add ../parrot-fix-xxx -b fix/parrot_platform-xxx
cd ../parrot-fix-xxx

# After fix committed
bd update parrot_platform-xxx --remove-label fix-in-progress --add-label fix-complete
```

### Verify Phase
```bash
# Merge fixes
cd /Users/byoungdale/ElixirProjects/parrot_platform
git merge fix/parrot_platform-xxx

# Re-run tests
SKIP_LOCK=1 ./scripts/dev/test_and_report.sh test_answer_play

# If passes, close bug
bd close parrot_platform-xxx --reason "Fixed and verified"

# Cleanup worktree
git worktree remove ../parrot-fix-xxx
git branch -d fix/parrot_platform-xxx
```

---

## BD Label Conventions

| Label | Meaning |
|-------|---------|
| `testing` | Bug found during DSL testing |
| `cycle-N` | Which test cycle found this bug |
| `fix-in-progress` | An agent is actively fixing this |
| `fix-complete` | Fix committed, awaiting merge/verify |
| `dsl` / `sip` / `media` / `transport` | Which layer the bug is in |

---

## Cycle State Machine

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   ┌──────────┐    ┌───────────┐    ┌─────┐    ┌──────┐ │
│   │DISCOVERY │───▶│DEDUPLICATE│───▶│ FIX │───▶│VERIFY│ │
│   └──────────┘    └───────────┘    └─────┘    └──────┘ │
│        ▲                                          │     │
│        │          bugs remain                     │     │
│        └──────────────────────────────────────────┘     │
│                                                         │
│                    all pass ───▶ DONE                   │
└─────────────────────────────────────────────────────────┘
```

Multiple orchestrators can work different phases simultaneously:
- One orchestrator doing discovery on new tests
- Another fixing bugs from previous cycle
- Another verifying completed fixes
