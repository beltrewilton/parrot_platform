# Subagent Test Execution & Bug Reporting Workflow

This document defines how subagents execute tests and report bugs for the Parrot Platform.

## Overview

Subagents run tests in the background, analyze logs (not full context), and create structured bug reports in `bd`. This keeps orchestrator context low while enabling thorough testing.

---

## Iterative Test-Fix Cycle

Multiple orchestrators work through continuous cycles until all tests pass:

```
CYCLE N:
  Phase 1: DISCOVERY   - Run all tests, collect bugs (no fixing)
  Phase 2: DEDUPLICATE - Orchestrator groups bugs by root cause
  Phase 3: FIX         - Parallel fix unique bugs (new bugs logged, not fixed)
  Phase 4: VERIFY      - Merge fixes, re-run tests

  → If bugs remain, start CYCLE N+1
  → If all pass, DONE
```

### Phase 1: Discovery

Run ALL tests sequentially, create bugs, but DO NOT fix:

```bash
# Set orchestrator ID
export ORCHESTRATOR_ID="discovery-$(date +%s)"

# Run each test, collect results
for test in test_answer_play test_hangup_dsl test_reject_dsl test_dtmf_dsl test_sdp_negotiation; do
  ./scripts/dev/test_and_report.sh $test
done
```

Output collected:
```
TEST: test_answer_play | STATUS: FAIL | BUG: parrot_platform-aaa | SUMMARY: ...
TEST: test_hangup_dsl | STATUS: FAIL | BUG: parrot_platform-bbb | SUMMARY: ...
TEST: test_reject_dsl | STATUS: PASS | BUG: none | SUMMARY: ...
```

### Phase 2: Deduplicate

Orchestrator analyzes bugs and groups by root cause:

```bash
# List all open bugs from this cycle
bd list --label testing --status open

# Review each bug, identify duplicates
bd show parrot_platform-aaa
bd show parrot_platform-bbb

# If same root cause, mark duplicate:
bd duplicate parrot_platform-bbb --of parrot_platform-aaa
```

### Phase 3: Fix (Parallel)

Dispatch one agent per UNIQUE bug. If agent discovers NEW bugs during fix, log them but don't fix:

```
Agent 1: Fix parrot_platform-aaa
  → Creates worktree
  → Implements fix
  → Runs tests in worktree
  → Finds new bug! → Creates parrot_platform-ccc (for next cycle)
  → Commits fix for original bug
  → Reports back

Agent 2: Fix parrot_platform-ddd
  → (parallel work)
```

### Phase 4: Verify

After all fixes reviewed and merged:

```bash
# Merge all fix branches
git merge fix/parrot_platform-aaa
git merge fix/parrot_platform-ddd

# Re-run all tests
for test in test_answer_play test_hangup_dsl test_reject_dsl test_dtmf_dsl test_sdp_negotiation; do
  SKIP_LOCK=1 ./scripts/dev/test_and_report.sh $test
done
```

If bugs remain → start next cycle.
If all pass → done!

### Multi-Orchestrator Coordination

Multiple orchestrators can work different cycles or phases:

| Orchestrator | Task |
|--------------|------|
| Orch-1 | Phase 1: Discovery on scripts A-E |
| Orch-2 | Phase 3: Fixing bug X from previous cycle |
| Orch-3 | Phase 3: Fixing bug Y from previous cycle |
| Orch-4 | Phase 4: Verifying fixes from cycle N-1 |

Use bd labels to track:
- `cycle-1`, `cycle-2`, etc.
- `discovery`, `fixing`, `verifying`
- `fix-in-progress`, `fix-complete`

---

## Multi-Orchestrator Coordination

When multiple orchestrators run in parallel, they MUST coordinate to avoid:
1. **Port conflicts** - Only one test can use port 5080 at a time
2. **Duplicate work** - Don't work on the same test/bug simultaneously
3. **Race conditions** - Don't create duplicate bug reports

### Lock System

Use `orchestrator_lock.sh` to coordinate:

```bash
# Check if test is available
./scripts/dev/orchestrator_lock.sh check test_answer_play
# Output: AVAILABLE or LOCKED by <orchestrator>

# Acquire lock before running test
./scripts/dev/orchestrator_lock.sh acquire test_answer_play my-agent-id
# Output: ACQUIRED parrot_platform-xxx or LOCKED by <other>

# Release lock when done
./scripts/dev/orchestrator_lock.sh release test_answer_play my-agent-id
# Output: RELEASED parrot_platform-xxx

# List all current locks
./scripts/dev/orchestrator_lock.sh list
```

### Automatic Locking

`test_and_report.sh` handles locking automatically:
- Acquires lock before starting test
- Releases lock on exit (success, failure, or interrupt)
- Returns `STATUS: LOCKED` if another orchestrator holds the lock

```bash
# Automatic locking (default)
./scripts/dev/test_and_report.sh test_answer_play

# Skip locking (single orchestrator mode)
SKIP_LOCK=1 ./scripts/dev/test_and_report.sh test_answer_play

# Custom orchestrator ID
ORCHESTRATOR_ID=agent-123 ./scripts/dev/test_and_report.sh test_answer_play
```

### Orchestrator Protocol

1. **Before starting**: Set unique `ORCHESTRATOR_ID` (e.g., agent session ID)
2. **Before each test**: Check if locked, skip if so
3. **On LOCKED response**: Move to next available test
4. **On completion**: Lock auto-releases

---

## Git Worktree Isolation

**CRITICAL**: Implementation subagents MUST use git worktrees to avoid conflicts.

### Why Worktrees?

- Multiple subagents may fix bugs in parallel
- Working on the same branch causes merge conflicts
- Worktrees provide isolated working directories
- Each fix gets its own branch, merged after review

### Worktree Workflow

**1. Create worktree for bug fix:**
```bash
# From project root
git worktree add ../parrot-fix-<bug-id> -b fix/<bug-id>

# Example:
git worktree add ../parrot-fix-mec -b fix/parrot_platform-mec
```

**2. Work in the worktree:**
```bash
cd ../parrot-fix-<bug-id>
# Make changes, run tests, commit
```

**3. After review approval, merge back:**
```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
git merge fix/<bug-id>
git worktree remove ../parrot-fix-<bug-id>
git branch -d fix/<bug-id>
```

### Subagent Implementation Template

When dispatching an implementation subagent, include:

```
**Git Isolation (REQUIRED)**:
1. Create worktree: git worktree add ../parrot-fix-<bug-id> -b fix/<bug-id>
2. Work in: cd ../parrot-fix-<bug-id>
3. All changes in that directory
4. Commit to the fix branch
5. Do NOT merge - orchestrator handles merge after review
```

### Orchestrator Merge Protocol

After spec + code quality reviews pass:
1. Switch to main working directory
2. `git merge fix/<bug-id>`
3. Run tests to verify
4. `git worktree remove ../parrot-fix-<bug-id>`
5. `git branch -d fix/<bug-id>`

---

## Phase 1: Test Execution

### Step 1: Start Test Server

```bash
cd /Users/byoungdale/ElixirProjects/parrot_platform
./scripts/dev/run_test.sh <script_name>
```

**Output format (machine-readable):**
```
TEST_PID=12345
TEST_LOG=logs/<script_name>_YYYYMMDD_HHMMSS.log
```

**Capture these values for later use:**
```bash
OUTPUT=$(./scripts/dev/run_test.sh test_answer_play 2>&1)
TEST_PID=$(echo "$OUTPUT" | grep TEST_PID | cut -d= -f2)
TEST_LOG=$(echo "$OUTPUT" | grep TEST_LOG | cut -d= -f2)
```

### Step 2: Execute pjsua Client

**Basic pattern (headless with piped commands):**
```bash
(sleep DELAY; echo "CMD1"; sleep DELAY; echo "CMD2"; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:TARGET@127.0.0.1:5080" 2>&1
```

**Common pjsua commands:**
| Command | Purpose |
|---------|---------|
| `h` | Hangup current call |
| `q` | Quit pjsua |
| `0-9` | Send DTMF digit |
| `*` | Send DTMF * |
| `#` | Send DTMF # |
| `m` | Make call (interactive only) |

### Step 3: Stop Test Server

```bash
./scripts/dev/stop_test.sh $TEST_PID $TEST_LOG
```

---

## Phase 2: Log Analysis

### Analyze with check_test.sh

```bash
./scripts/dev/check_test.sh $TEST_LOG --verbose
```

**Exit codes:**
- `0` - Clean (no errors)
- `1` - Errors found
- `2` - Log file not found

### Key Patterns to Grep

**Success indicators per script:**
| Script | Success Pattern |
|--------|-----------------|
| test_answer_play | `Playback complete` |
| test_dtmf_dsl | `DTMF COLLECTED:` |
| test_hangup_dsl | `Call ended` |
| test_reject_dsl | `Call rejected with` |
| test_ivr_menu | `Selected option:` |
| test_recording | `RECORDING COMPLETE` |
| test_cdr_callbacks | `CDR.*RECEIVED` |
| test_error_handling | `500\|488\|406` |

**Failure indicators (universal):**
```bash
grep -E "\[error\]|\[ERROR\]|exception|crash|exited with reason" $TEST_LOG
grep -E "5\d\d [A-Z]" $TEST_LOG  # Server errors
```

### Extract Error Context (Low-Context Approach)

**Get only error lines + context:**
```bash
# First 5 errors with 3 lines of context
grep -B3 -A3 -E "\[error\]|\[ERROR\]" $TEST_LOG | head -50

# Crash summary
grep -E "exited with reason|exception|GenServer.*stopped" $TEST_LOG | head -10

# Stack trace extraction
grep -A20 "** (RuntimeError)" $TEST_LOG | head -25
```

---

## Phase 3: Bug Reporting

### When to Create a Bug Report

1. `check_test.sh` returns exit code 1
2. Expected success pattern NOT found
3. Unexpected error patterns found
4. Server crash/exception detected

### Bug Report Template

```bash
bd create "[<script_name>] Brief description of failure" \
  --type bug \
  --priority 1 \
  --labels "008-dsl-sdp-negotiation,testing,<domain>" \
  --description "$(cat <<'EOF'
## Test Script
`scripts/dev/<script_name>.exs`

## Error
```
<paste relevant error lines here>
```

## To Reproduce
1. `./scripts/dev/run_test.sh <script_name>`
2. `(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"`
3. `./scripts/dev/stop_test.sh <PID>`

## Expected Behavior
<what should happen>

## Actual Behavior
<what happens instead>

## Log File
`<log_path>`

## Investigation Notes
- <finding 1>
- <finding 2>
EOF
)"
```

### Quick Bug Capture (Scripted)

```bash
# Create issue and get ID
ISSUE_ID=$(bd q "[test_answer_play] AlawPipeline crash" --type bug --priority 1)

# Add error details as comment
bd comments add $ISSUE_ID "$(grep -B3 -A10 "\[error\]" $TEST_LOG | head -50)"

# Link to related feature work
bd dep add $ISSUE_ID parrot_platform-clx -t blocks
```

### Label Guidelines

**Required labels:**
- Feature branch: `008-dsl-sdp-negotiation`, `007-dsl-dtmf-collect`, etc.
- Domain: `media`, `sip`, `dsl`, `transport`, `handler`
- Activity: `testing`, `implementation`

**Priority mapping:**
- P0: Crash/security issue blocking all work
- P1: Blocking current feature development
- P2: Important but not blocking
- P3: Nice to have
- P4: Low priority

---

## Test Script Reference

### Scripts That Don't Require DTMF

| Script | URI Pattern | pjsua Command |
|--------|-------------|---------------|
| test_answer_play | `sip:test@...` | `(sleep 3; echo "h"; echo "q")` |
| test_hangup_dsl | `sip:immediate@...` | `(sleep 2; echo "q")` |
| test_hangup_dsl | `sip:delayed@...` | `(sleep 5; echo "q")` |
| test_reject_dsl | `sip:486@...` | `(sleep 2; echo "q")` |
| test_sdp_negotiation | `sip:test@...` | `(sleep 3; echo "h"; echo "q")` |
| test_cdr_callbacks | `sip:answer@...` | `(sleep 3; echo "h"; echo "q")` |
| test_error_handling | `sip:crash@...` | `(sleep 2; echo "q")` |

### Scripts That Require DTMF

| Script | URI Pattern | pjsua Command |
|--------|-------------|---------------|
| test_dtmf_dsl | `sip:test@...` | `(sleep 2; echo "#"; echo "1"; echo "2"; echo "3"; echo "#"; sleep 2; echo "h"; echo "q")` |
| test_prompt_dsl | `sip:test@...` | `(sleep 3; echo "1"; echo "2"; echo "3"; echo "#"; sleep 2; echo "h"; echo "q")` |
| test_ivr_menu | `sip:ivr@...` | `(sleep 3; echo "1"; sleep 2; echo "1"; sleep 2; echo "9"; sleep 2; echo "h"; echo "q")` |
| test_recording | `sip:test@...` | `(sleep 3; echo "#"; sleep 2; echo "h"; echo "q")` |

---

## Complete Subagent Test Execution Script

```bash
#!/bin/bash
# test_and_report.sh - Run test, analyze, report bugs if found

SCRIPT_NAME="$1"
SIP_URI="${2:-test}"
PJSUA_COMMANDS="${3:-sleep 3; echo h; echo q}"

# Start test
OUTPUT=$(./scripts/dev/run_test.sh $SCRIPT_NAME 2>&1)
TEST_PID=$(echo "$OUTPUT" | grep TEST_PID | cut -d= -f2)
TEST_LOG=$(echo "$OUTPUT" | grep TEST_LOG | cut -d= -f2)

if [ -z "$TEST_PID" ]; then
    echo "ERROR: Failed to start test server"
    echo "$OUTPUT"
    exit 1
fi

echo "Server started: PID=$TEST_PID LOG=$TEST_LOG"

# Wait for server initialization
sleep 2

# Run pjsua
echo "Running pjsua client..."
eval "($PJSUA_COMMANDS)" | pjsua --null-audio --no-tcp --local-port=5100 \
    "sip:$SIP_URI@127.0.0.1:5080" 2>&1 | tee /tmp/pjsua_output.log

# Stop server
./scripts/dev/stop_test.sh $TEST_PID $TEST_LOG

# Analyze
echo "Analyzing log..."
./scripts/dev/check_test.sh $TEST_LOG --verbose
CHECK_RESULT=$?

if [ $CHECK_RESULT -ne 0 ]; then
    echo "ERRORS DETECTED - Creating bug report..."

    # Extract error summary
    ERROR_SUMMARY=$(grep -B2 -A5 "\[error\]\|\[ERROR\]" $TEST_LOG | head -30)

    # Create bug report
    ISSUE_ID=$(bd q "[$SCRIPT_NAME] Test failure - errors detected" --type bug --priority 2)

    # Add details
    bd comments add $ISSUE_ID "Log file: $TEST_LOG

Error summary:
\`\`\`
$ERROR_SUMMARY
\`\`\`"

    echo "Bug created: $ISSUE_ID"
    exit 1
fi

echo "Test passed successfully"
exit 0
```

---

## Orchestrator Integration

### Running Multiple Tests in Parallel

The orchestrator should dispatch subagents sequentially (port conflicts) but can run analysis in parallel:

```
# Sequential execution (one at a time due to port 5080)
for script in test_answer_play test_dtmf_dsl test_hangup_dsl; do
    Subagent: Run test $script
    Wait for completion
done

# Parallel analysis (no port conflicts)
Subagents: Analyze all log files in parallel
```

### Minimal Context for Orchestrator

Subagents should return only:
1. Test name
2. Pass/Fail status
3. Bug ID (if created)
4. One-line error summary (if failed)

Example return format:
```
TEST: test_answer_play
STATUS: FAIL
BUG: parrot_platform-xyz
SUMMARY: AlawPipeline crashed with Membrane.UnknownChildError
```

---

## Bug Triage: Which Layer to Fix

When a bug is discovered, subagents must identify **which app** the fix belongs to:

### Layer Identification Guide

| Error Pattern | Layer | App | Example |
|---------------|-------|-----|---------|
| `[Bridge.Handler]`, `[Router]`, `InviteHandler` | DSL | `apps/parrot` | Handler callback errors, routing issues |
| `[TransactionStatem]`, `[DialogStatem]`, RFC 3261 | SIP Protocol | `apps/parrot_sip` | Transaction timeouts, dialog state errors |
| `[MediaSession]`, `[Pipeline]`, Membrane errors | Media | `apps/parrot_media` | Codec errors, pipeline crashes, RTP issues |
| `[UdpListener]`, `[TcpListener]`, socket errors | Transport | `apps/parrot_transport` | Connection failures, framing errors |

### Error Pattern Recognition

**DSL Layer (`apps/parrot`):**
```
[Bridge.Handler] Received INVITE
[Router.Dispatcher] No route found
[ActionExecutor] Executing play action
handle_invite/1 raised exception
```

**SIP Protocol Layer (`apps/parrot_sip`):**
```
[TransactionStatem] Timer B fired
[DialogStatem] Invalid state transition
[UA] Failed to send response
RFC 3261 Section X.Y violation
```

**Media Layer (`apps/parrot_media`):**
```
[MediaSession] Failed to start pipeline
[AlawPipeline] Membrane.UnknownChildError
[SwitchableFileSource] File not found
codec negotiation failed
```

**Transport Layer (`apps/parrot_transport`):**
```
[UdpListener] Failed to bind
[TcpListener] Connection refused
[Framing] Invalid Content-Length
```

### Bug Report Labels by Layer

| Layer | Labels |
|-------|--------|
| DSL | `dsl`, `handler`, `router`, `bridge` |
| SIP | `sip`, `transaction`, `dialog`, `rfc3261` |
| Media | `media`, `pipeline`, `codec`, `rtp` |
| Transport | `transport`, `udp`, `tcp`, `socket` |

### Example Triage

**Scenario:** test_answer_play.exs crashes with `Membrane.UnknownChildError`

1. Error contains `Membrane` and `Pipeline` → **Media Layer**
2. App: `apps/parrot_media`
3. Labels: `media,pipeline,008-dsl-sdp-negotiation`
4. Bug title: `[parrot_media] AlawPipeline crash in test_answer_play`

**Scenario:** Call connects but no audio plays

1. Check logs for layer indicators
2. If `[ActionExecutor] play action` succeeded but `[MediaSession]` shows no activity → **Media Layer**
3. If `[ActionExecutor]` never received play command → **DSL Layer**

---

## Note on Test Coverage Scope

These DSL test scripts cover **high-level Parrot DSL features**:
- Handler callbacks (answer, play, hangup, reject, DTMF)
- Router pattern matching
- Media operations (play, record, prompt)
- CDR generation
- Error handling

**Low-level SIP protocol testing** (retransmissions, re-INVITEs, B2BUA, etc.) is handled by:
- SIPp integration tests in `test/sipp/`
- Unit tests in `apps/parrot_sip/test/`

When DSL tests fail, the root cause may be in any layer. Use the triage guide above.
