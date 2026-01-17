# Subagent Test Execution Prompt

Use this prompt to kick off a Claude Code session for running DSL tests.

---

## Prompt for Task Tool (Orchestrator Use)

```
Run Parrot DSL tests and report results. Work autonomously - minimize questions.

**Workflow document:** scripts/dev/SUBAGENT_WORKFLOW.md (read first for full details)

**Your task:**
1. Run: ./scripts/dev/test_and_report.sh <script_name> [uri] [delay] [dtmf_cmds]
2. Parse the single-line output
3. If FAIL: Review the log file, add investigation notes to the bug
4. Return results in this format:

```
TEST: <name>
STATUS: PASS|FAIL
BUG: <id>|none
SUMMARY: <one-line description>
LAYER: dsl|sip|media|transport (if bug found)
```

**Scripts to test:** [specify which scripts]

**Bug triage:** Use error patterns from SUBAGENT_WORKFLOW.md to identify which layer (apps/parrot, apps/parrot_sip, apps/parrot_media, apps/parrot_transport) the bug belongs to.

Do NOT ask clarifying questions - investigate independently and report findings.
```

---

## Prompt for Standalone Session (Human Use)

Copy this to start a new Claude Code session:

```
I need you to run validation tests on the Parrot Platform DSL layer.

**Context:**
- This is an Elixir umbrella project implementing a SIP stack
- Test scripts are in scripts/dev/*.exs
- Each script tests a specific DSL feature (answer, play, DTMF, IVR, etc.)
- Tests use pjsua as the SIP client
- Multiple orchestrators may run in parallel - use locking

**Your workflow:**
1. Read scripts/dev/SUBAGENT_WORKFLOW.md for full instructions
2. Set your orchestrator ID: export ORCHESTRATOR_ID="agent-$(date +%s)"
3. Run tests using: ./scripts/dev/test_and_report.sh <script>
4. If STATUS: LOCKED, skip to next test (another orchestrator has it)
5. For failures: investigate logs, identify the layer (DSL/SIP/Media/Transport)
6. Create/update bug reports in bd with findings

**Scripts to test (in order):**
1. test_answer_play - Basic answer + playback
2. test_hangup_dsl - Hangup scenarios
3. test_reject_dsl - Call rejection
4. test_dtmf_dsl - DTMF collection
5. test_sdp_negotiation - SDP offer/answer

**Output format for each test:**
TEST: <name> | STATUS: PASS|FAIL|LOCKED | BUG: <id>|none | SUMMARY: <description>

Work autonomously. Only ask questions if you encounter infrastructure issues (pjsua not installed, port conflicts, etc.). For test failures, investigate and report - don't ask what to do.

Start with test_answer_play.
```

---

## Quick Reference: test_and_report.sh

**Simple tests (no DTMF):**
```bash
./scripts/dev/test_and_report.sh test_answer_play
./scripts/dev/test_and_report.sh test_hangup_dsl immediate 2
./scripts/dev/test_and_report.sh test_reject_dsl 486 2
./scripts/dev/test_and_report.sh test_sdp_negotiation test 3
```

**DTMF tests:**
```bash
./scripts/dev/test_and_report.sh test_dtmf_dsl test 2 "echo 1; echo 2; echo 3; echo #"
./scripts/dev/test_and_report.sh test_prompt_dsl test 3 "sleep 2; echo 1; echo 2; echo 3; echo #"
./scripts/dev/test_and_report.sh test_ivr_menu ivr 3 "echo 1; sleep 1; echo 1; sleep 1; echo 9"
```

**Error handling tests:**
```bash
./scripts/dev/test_and_report.sh test_error_handling crash 2
./scripts/dev/test_and_report.sh test_error_handling sdp_error 2
```

---

## Expected Subagent Behavior

1. **Autonomous execution** - Run tests without asking permission
2. **Investigate failures** - Read logs, identify root cause, determine layer
3. **Create structured bugs** - Use bd with proper labels and triage
4. **Minimal output** - Return single-line results per test
5. **No confirmation seeking** - Act, report, continue

---

## Orchestrator Tips

**Run tests sequentially** (port 5080 conflict):
```
for script in test_answer_play test_hangup_dsl test_reject_dsl; do
    dispatch subagent with: ./scripts/dev/test_and_report.sh $script
    wait for completion
done
```

**Collect results:**
```
Results:
TEST: test_answer_play | STATUS: PASS | BUG: none | SUMMARY: Clean run
TEST: test_hangup_dsl | STATUS: FAIL | BUG: parrot_platform-abc | SUMMARY: Errors: 2
TEST: test_reject_dsl | STATUS: PASS | BUG: none | SUMMARY: Clean run
```

**Follow-up on failures:**
- Dispatch investigation subagent with bug ID
- Or batch failures for human review
