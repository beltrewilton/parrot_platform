# Parrot Platform - Development Testing Guide

This guide documents how to run and test the development scripts in `scripts/dev/`. Intended for subagents and developers working on the Parrot Platform.

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [Test Execution Workflow](#test-execution-workflow)
3. [pjsua Commands](#pjsua-commands)
4. [Log Analysis Patterns](#log-analysis-patterns)
5. [Bug Reporting](#bug-reporting)
6. [Fix and Retest Workflow](#fix-and-retest-workflow)
7. [Script-Specific Test Patterns](#script-specific-test-patterns)

---

## Quick Reference

### Start a Test Server

```bash
# Basic command pattern
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/<script_name>.exs

# Minimal logging (recommended for most tests)
LOG_LEVEL=info mix run scripts/dev/<script_name>.exs

# Full debug mode (when investigating issues)
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/<script_name>.exs
```

### Stop a Test Server

- **Ctrl+C** in the terminal running the server
- All servers run with `Process.sleep(:infinity)` and listen on **port 5080**

### Make a Test Call (pjsua)

```bash
# Basic call with immediate hangup
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"

# Call to specific user/extension
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:1234@127.0.0.1:5080"
```

### Log File Locations

- Server logs: stdout (redirected from terminal)
- SIP traces: enabled with `SIP_TRACE=true` environment variable
- Recordings: `/tmp/parrot_recordings/`

### Key Log Patterns to Watch

| Script | Success Pattern | Failure Pattern |
|--------|-----------------|-----------------|
| test_answer_play | `[AnswerPlay] Playback complete` | `Failed to start server` |
| test_dtmf_dsl | `DTMF COLLECTED:` | `DTMF timeout` (expected) |
| test_hangup_dsl | `handle_hangup callback invoked` | `Failed to start server` |
| test_recording | `RECORDING COMPLETE` | `Could not stat file` |

---

## Test Execution Workflow

### Category 1: Simple Tests (No DTMF Required)

These scripts test basic SIP call handling without needing DTMF input.

**Scripts:**
- `test_answer_play.exs` - Basic answer and play
- `test_hangup_dsl.exs` - Hangup scenarios
- `test_reject_dsl.exs` - Call rejection codes
- `test_multi_play.exs` - Multiple file playback
- `test_sdp_negotiation.exs` - SDP offer/answer
- `test_cdr_callbacks.exs` - CDR generation
- `test_mos_scoring.exs` - Quality monitoring

**Workflow:**

```bash
# Terminal 1: Start the server
LOG_LEVEL=info mix run scripts/dev/test_answer_play.exs

# Terminal 2: Make test call
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

### Category 2: DTMF Tests

These scripts require DTMF digit input during the call.

**Scripts:**
- `test_dtmf_dsl.exs` - DTMF collection
- `test_prompt_dsl.exs` - Prompt + DTMF collection
- `test_ivr_menu.exs` - Full IVR menu system
- `test_recording.exs` - Recording with # to stop
- `test_bidirectional_ws.exs` - WebSocket with DTMF controls

**Workflow:**

```bash
# Terminal 1: Start the server
LOG_LEVEL=info mix run scripts/dev/test_dtmf_dsl.exs

# Terminal 2: Make call and send DTMF
(sleep 2; echo "#"; echo "1"; echo "2"; echo "3"; sleep 2; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**DTMF Characters:**
- `0-9` - Numeric digits
- `*` - Star key
- `#` - Pound/hash key (often terminator)

### Category 3: Unit-Style Tests (No pjsua Required)

These scripts test internal APIs without SIP calls.

**Scripts:**
- `test_media_handler.exs` - MediaHandler message patterns

**Workflow:**

```bash
# Just run the script directly
LOG_LEVEL=debug mix run scripts/dev/test_media_handler.exs

# Expected output includes multiple "[VerboseMediaHandler]" log entries
```

### Category 4: Router Pattern Tests

Test pattern matching without DTMF.

**Scripts:**
- `test_router_patterns.exs` - Pattern matching rules

**Workflow:**

```bash
# Terminal 1: Start the server
LOG_LEVEL=info mix run scripts/dev/test_router_patterns.exs

# Terminal 2: Test different patterns
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:1234@127.0.0.1:5080"   # ExtensionHandler
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:911@127.0.0.1:5080"    # EmergencyHandler
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:9123456@127.0.0.1:5080" # OutboundHandler
```

### Category 5: Error Handling Tests

Test error scenarios and recovery.

**Scripts:**
- `test_error_handling.exs` - Various error scenarios

**Workflow:**

```bash
# Terminal 1: Start the server
LOG_LEVEL=info mix run scripts/dev/test_error_handling.exs

# Terminal 2: Test error scenarios
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:crash@127.0.0.1:5080"      # 500 error
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:sdp_error@127.0.0.1:5080"  # 488 error
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:timeout@127.0.0.1:5080"    # Slow operation
```

### Category 6: Registration and Presence Tests

Test SIP REGISTER with digest authentication and presence subscriptions.

**Scripts:**
- `test_registrar.exs` - Basic registration with digest auth
- `test_registrar_presence.exs` - Registration + presence integration
- `test_registrar_with_pjsua.sh` - Orchestration script with logging

**Test Users:**
| Username | Password |
|----------|----------|
| alice | secret123 |
| bob | secret456 |

**Workflow (using orchestration script):**

```bash
# Terminal 1: Start server with logging
./scripts/dev/test_registrar_with_pjsua.sh

# Terminal 2: Register Alice (follow printed commands)
pjsua --null-audio --no-tcp --local-port=5090 \
  --log-file=<LOG_DIR>/pjsua_alice.log --log-level=5 \
  --id="sip:alice@127.0.0.1" --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="alice" --password="secret123"

# Terminal 3: Register Bob (for presence testing)
pjsua --null-audio --no-tcp --local-port=5091 \
  --log-file=<LOG_DIR>/pjsua_bob.log --log-level=5 \
  --id="sip:bob@127.0.0.1" --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="bob" --password="secret456"
```

**Expected Registration Flow:**
1. pjsua sends REGISTER (no credentials)
2. Server responds 401 Unauthorized with WWW-Authenticate
3. pjsua sends REGISTER with Authorization header
4. Server responds 200 OK

**pjsua Registration Commands:**
- `ru` - Unregister (expires=0)
- `rr` - Re-register
- `Lr` - Show registration status

**Presence Testing (in Bob's console):**
```
>>> +b sip:alice@127.0.0.1    # Add Alice as buddy
>>> s                          # Subscribe to presence
# Alice unregisters: ru
# Bob receives NOTIFY: Alice offline
# Alice re-registers: rr
# Bob receives NOTIFY: Alice available
```

**Success Verification:**
```bash
# Check server logs for registration success
grep -E "(401|200 OK|REGISTER)" server.log

# Check for presence NOTIFY
grep -E "(SUBSCRIBE|NOTIFY|presence)" server.log
```

---

## pjsua Commands

### Basic Call Commands

```bash
# Make a call (minimal)
pjsua --null-audio "sip:test@127.0.0.1:5080"

# Make a call with no TCP (UDP only, like our server)
pjsua --null-audio --no-tcp "sip:test@127.0.0.1:5080"

# Make a call with specific local port (avoid conflicts)
pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

### Automated Call Sequences

```bash
# Call and hangup after 2 seconds
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"

# Call, wait 5 seconds, hangup
(sleep 5; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"

# Call with DTMF input (digits 1, 2, 3 then hangup)
(sleep 2; echo "#"; echo "1"; echo "2"; echo "3"; sleep 1; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

### Interactive pjsua Session

```bash
# Start interactive session
pjsua --null-audio --no-tcp --local-port=5100

# Commands inside pjsua:
# m              - Make a call (prompts for URI)
# h              - Hangup current call
# #              - Send DTMF # (pound)
# 1-9, 0, *      - Send DTMF digits
# q              - Quit pjsua
```

### Sending DTMF in Automated Scripts

```bash
# Send single DTMF digit
echo "#" | pjsua ...

# Send multiple DTMF digits with delays
(sleep 2; echo "1"; sleep 0.5; echo "2"; sleep 0.5; echo "3"; echo "#"; sleep 1; echo "h"; echo "q") | pjsua ...

# Send DTMF sequence for IVR menu navigation
# Main menu -> Account (1) -> Balance (1) -> Return to main (9)
(sleep 3; echo "1"; sleep 2; echo "1"; sleep 2; echo "9"; sleep 2; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:ivr@127.0.0.1:5080"
```

### Capturing pjsua Output

```bash
# Save output to file
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 \
  "sip:test@127.0.0.1:5080" 2>&1 | tee /tmp/pjsua_output.log

# Check call established
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 \
  "sip:test@127.0.0.1:5080" 2>&1 | grep -i "confirmed"
```

---

## Log Analysis Patterns

### Success Patterns by Script

**test_answer_play.exs**
```
grep -E "\[AnswerPlay\] (INVITE received|Playback complete|Call ended)" server.log
# Expected: All three messages in sequence
```

**test_dtmf_dsl.exs**
```
grep -E "(DTMF COLLECTED|DTMF TIMEOUT|\*\*\* DTMF)" server.log
# Expected: "DTMF COLLECTED: <digits>" when digits sent
```

**test_hangup_dsl.exs**
```
grep -E "handle_hangup callback invoked|Call ended" server.log
# Expected: handle_hangup callback for each scenario
```

**test_ivr_menu.exs**
```
grep -E "\[IVR\] (Main menu:|Account menu:|Selected)" server.log
# Expected: Menu navigation messages based on DTMF input
```

**test_recording.exs**
```
grep -E "(RECORDING COMPLETE|Recording to:|File size:)" server.log
# Expected: Recording complete message with filename and size
```

**test_cdr_callbacks.exs**
```
grep -E "(CDR #\d+ RECEIVED|disposition:|talk_duration_ms)" server.log
# Expected: CDR details after call completes
```

**test_sdp_negotiation.exs**
```
grep -E "\[SDP-Test\] (INVITE received|SDP negotiation|MEDIA SESSION INFO)" server.log
# Expected: SDP negotiation flow messages
```

**test_error_handling.exs**
```
grep -E "(500|488|CrashHandler|SdpErrorHandler)" server.log
# Expected: Error responses based on test scenario
```

**test_media_handler.exs**
```
grep -E "\[VerboseMediaHandler\] (INIT|HANDLE_)" output.log
# Expected: All handler callbacks logged
```

### Failure Patterns

```bash
# General server startup failure
grep -i "Failed to start server" server.log

# Process crashes
grep -i "exited with reason" server.log

# SIP errors
grep -E "(4\d\d|5\d\d) [A-Z]" server.log  # 4xx and 5xx responses

# Media errors
grep -i "(media.*error|pipeline.*failed|codec.*mismatch)" server.log
```

### Maximum Lines to Read

Keep context small when analyzing logs:

```bash
# Last 50 lines of relevant output
grep -E "<pattern>" server.log | tail -50

# First occurrence with context
grep -m 1 -A 5 "<pattern>" server.log

# Count occurrences
grep -c "<pattern>" server.log
```

---

## Bug Reporting

### When to File a Bug

File a bug when:

1. **Server fails to start** - `Failed to start server` message
2. **Expected callback not invoked** - Missing `handle_hangup`, `handle_play_complete`, etc.
3. **Wrong SIP response code** - Expected 200, got 500
4. **Media not playing** - No playback complete callback
5. **DTMF not collected** - Continuous timeouts despite sending digits
6. **CDR not generated** - No CDR callback after call completion
7. **Crash in handler** - Unexpected process termination

### Filing a Bug with bd (beads)

Use the `bd` command-line tool for bug tracking:

**Create a bug with details:**
```bash
bd create --title="[test_answer_play] AlawPipeline crashes on play" --type=bug --priority=2

# Then add detailed description
bd edit <id> description
# Paste the following into the editor:
# - Steps to reproduce
# - Expected vs actual behavior
# - Relevant log excerpt
```

**Quick capture (for fast bug logging):**
```bash
bd q "[test_answer_play] AlawPipeline crashes on play" --type=bug
```

**Viewing bugs:**
```bash
bd list --type=bug --status=open   # All open bugs
bd show <id>                       # Bug details
```

### Bug Description Template

When editing a bug description with `bd edit <id> description`, include:

```
Script: test_<name>.exs

Steps to Reproduce:
1. Start server: LOG_LEVEL=info mix run scripts/dev/test_<name>.exs
2. Make call: (sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
3. Observe: [what happened]

Expected Behavior:
[What should happen]

Actual Behavior:
[What actually happened]

Relevant Logs:
[paste relevant log lines here]

Environment:
- Elixir: [version]
- OTP: [version]
- pjsua: [version]
```

---

## Fix and Retest Workflow

### Pick Up a Bug to Fix

1. **Find available bugs:**
   ```bash
   bd ready                           # Show bugs ready to work on
   bd list --type=bug --status=open   # All open bugs
   ```

2. **View bug details:**
   ```bash
   bd show <id>                       # Full bug details and description
   ```

3. **Claim the bug:**
   ```bash
   bd update <id> --status=in_progress
   ```

### Fix the Bug

1. **Read the reproduction steps** (from `bd show <id>`)
2. **Run the test to confirm the bug**
3. **Make code changes**
4. **Test your fix:**
   ```bash
   # Run the specific test script
   LOG_LEVEL=debug mix run scripts/dev/test_<name>.exs

   # In another terminal, reproduce the scenario
   (sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
   ```

### Verify the Fix

1. **Run full test suite:**
   ```bash
   mix test
   mix test --only sipp  # SIPp integration tests
   ```

2. **Run the specific dev script:**
   ```bash
   LOG_LEVEL=info mix run scripts/dev/test_<name>.exs
   # Make test call and verify expected behavior
   ```

3. **Check for regressions:**
   ```bash
   # Run related scripts
   LOG_LEVEL=info mix run scripts/dev/test_hangup_dsl.exs
   # ... test ...
   ```

### Mark as Fixed

Close the bug with a resolution:

```bash
bd close <id> --reason="Fixed by increasing timeout in AlawPipeline"
```

Or if more context is needed before closing:

```bash
# Add a comment first
bd comment <id> "Fixed by increasing buffer timeout from 100ms to 500ms"

# Then close
bd close <id> --reason="Buffer timeout fix"
```

---

## Script-Specific Test Patterns

### test_answer_play.exs

**Purpose:** Basic call answer and audio playback

**Dial:** `sip:test@127.0.0.1:5080`

**pjsua command:**
```bash
(sleep 3; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "\[AnswerPlay\] (Playback complete|Call ended)" server.log
```

**Common failures:**
- Missing audio file `priv/audio/parrot-welcome.wav`
- Port 5080 already in use

---

### test_dtmf_dsl.exs

**Purpose:** DTMF digit collection

**Dial:** `sip:test@127.0.0.1:5080`

**pjsua command (with DTMF):**
```bash
(sleep 2; echo "1"; echo "2"; echo "3"; echo "#"; sleep 1; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep "DTMF COLLECTED:" server.log
```

**Common failures:**
- DTMF not being sent (RFC 2833 issues)
- Timeout before digits received

---

### test_prompt_dsl.exs

**Purpose:** Combined prompt (play + collect DTMF)

**Dial:** `sip:test@127.0.0.1:5080`

**pjsua command:**
```bash
(sleep 4; echo "1"; echo "2"; echo "#"; sleep 1; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "(Playback complete.*starting DTMF|DTMF COLLECTED)" server.log
```

**Common failures:**
- DTMF collection not starting after playback

---

### test_hangup_dsl.exs

**Purpose:** Test various hangup scenarios

**Dial patterns:**
- `sip:immediate@127.0.0.1:5080` - Immediate hangup after answer
- `sip:delayed@127.0.0.1:5080` - Delayed hangup (3 seconds)
- `sip:play@127.0.0.1:5080` - Hangup after playback

**pjsua commands:**
```bash
# Immediate hangup
(sleep 1; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:immediate@127.0.0.1:5080"

# Play then hangup
(sleep 4; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:play@127.0.0.1:5080"
```

**Success grep:**
```bash
grep "handle_hangup callback invoked" server.log
```

**Common failures:**
- BYE not being sent properly
- Dialog state issues

---

### test_reject_dsl.exs

**Purpose:** Test call rejection with various SIP codes

**Dial patterns:**
- `sip:486@127.0.0.1:5080` - 486 Busy Here
- `sip:603@127.0.0.1:5080` - 603 Decline
- `sip:480@127.0.0.1:5080` - 480 Temporarily Unavailable
- `sip:403@127.0.0.1:5080` - 403 Forbidden

**pjsua command:**
```bash
(sleep 2; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:486@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "Rejecting with (486|603|480|403)" server.log
```

**Common failures:**
- Wrong response code returned
- Call answered instead of rejected

---

### test_multi_play.exs

**Purpose:** Multiple file playback and looping

**Dial:** `sip:test@127.0.0.1:5080`

**pjsua command:**
```bash
(sleep 15; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "(Sequence playback|Chained play|Loop iteration)" server.log
```

**Common failures:**
- Files not playing in sequence
- Loop not terminating

---

### test_ivr_menu.exs

**Purpose:** Full IVR menu system with navigation

**Dial:** `sip:ivr@127.0.0.1:5080`

**pjsua commands:**
```bash
# Navigate: Main -> Account (1) -> Balance (1) -> Return (9)
(sleep 3; echo "1"; sleep 2; echo "1"; sleep 2; echo "9"; sleep 2; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:ivr@127.0.0.1:5080"

# Test invalid input handling (press 7 three times)
(sleep 3; echo "7"; sleep 2; echo "7"; sleep 2; echo "7"; sleep 2; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:ivr@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "\[IVR\] (Main menu:|Account menu:|Selected)" server.log
```

**Common failures:**
- Menu state not tracking correctly
- Max retries not enforced

---

### test_recording.exs

**Purpose:** Audio recording with manual stop

**Dial patterns:**
- `sip:test@127.0.0.1:5080` or `sip:1@...` - Timed recording (30s max)
- `sip:2@127.0.0.1:5080` - Manual recording (no limit)

**pjsua command:**
```bash
# Record for a few seconds, then stop with #
(sleep 3; echo "#"; sleep 1; echo "h"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "(RECORDING COMPLETE|File:|Duration:)" server.log
```

**Verify recording:**
```bash
ls -la /tmp/parrot_recordings/
```

**Common failures:**
- Recording file not created
- Recording not stopping on #

---

### test_sdp_negotiation.exs

**Purpose:** SDP offer/answer negotiation

**Dial:** `sip:test@127.0.0.1:5080`

**pjsua command:**
```bash
(sleep 3; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "\[SDP-Test\] (MEDIA SESSION INFO|State:|Codec)" server.log
```

**Common failures:**
- Codec mismatch (488 response)
- Media session not created

---

### test_cdr_callbacks.exs

**Purpose:** CDR generation for different call dispositions

**Dial patterns:**
- `sip:answer@127.0.0.1:5080` - Answered call
- `sip:reject@127.0.0.1:5080` - Rejected (486)
- `sip:forbidden@127.0.0.1:5080` - Rejected (403)

**pjsua command:**
```bash
(sleep 3; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:answer@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "CDR #\d+ RECEIVED" server.log
grep -E "Disposition:" server.log
```

**Common failures:**
- CDR handler not registered
- Missing fields in CDR

---

### test_error_handling.exs

**Purpose:** Error scenarios and recovery

**Dial patterns:**
- `sip:crash@127.0.0.1:5080` - Handler crash (500 error)
- `sip:sdp_error@127.0.0.1:5080` - SDP error (488 error)
- `sip:missing_file@127.0.0.1:5080` - Missing audio file
- `sip:timeout@127.0.0.1:5080` - Slow operation (2s delay)
- `sip:recovery@127.0.0.1:5080` - Graceful recovery demo

**pjsua command:**
```bash
(sleep 2; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:crash@127.0.0.1:5080"
```

**Success grep:**
```bash
# For crash scenario
grep -E "(500|CrashHandler.*crash)" server.log

# For SDP error
grep -E "(488|handle_sdp_error)" server.log
```

**Common failures:**
- Crash not returning 500
- SDP error not invoking callback

---

### test_media_handler.exs

**Purpose:** Unit test for MediaHandler message patterns (no pjsua needed)

**Run command:**
```bash
LOG_LEVEL=debug mix run scripts/dev/test_media_handler.exs
```

**Success grep:**
```bash
grep -E "\[VerboseMediaHandler\] (INIT|HANDLE_INFO.*play_files)" output.log
```

**Key output to verify:**
- `INIT called` - Handler initialization
- `HANDLE_STREAM_START called` - Stream ready (NO auto-play)
- `HANDLE_INFO received {:play_files, files, opts}` - Play message received
- `Actions returned: [{:play_sequence, ...}]` - Correct action returned

**Common failures:**
- Auto-play happening in handle_stream_start (anti-pattern)
- Wrong action type returned

---

### test_mos_scoring.exs

**Purpose:** MOS quality monitoring (requires actual media flow)

**Dial:** `sip:test@127.0.0.1:5080`

**pjsua command:**
```bash
# Let the call run for quality analysis
(sleep 10; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "(MOS Score:|CALL QUALITY SUMMARY)" server.log
```

**Common failures:**
- MOS calculator not found (media not started)
- Not enough samples for MOS calculation

---

### test_router_patterns.exs

**Purpose:** Test router pattern matching rules

**Dial patterns:**
- `sip:1234@127.0.0.1:5080` - ExtensionHandler (1xxx pattern)
- `sip:9123456@127.0.0.1:5080` - OutboundHandler (9~ pattern)
- `sip:911@127.0.0.1:5080` - EmergencyHandler (exact match)
- `sip:0@127.0.0.1:5080` - OperatorHandler (exact match)
- `sip:hello@127.0.0.1:5080` - DefaultHandler (catch-all)

**pjsua commands:**
```bash
# Test extension pattern
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:1234@127.0.0.1:5080"

# Test outbound pattern
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:9123456@127.0.0.1:5080"

# Test emergency
(sleep 2; echo "h"; echo "q") | pjsua --null-audio --no-tcp --local-port=5100 "sip:911@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "\[(Extension|Outbound|Emergency|Operator|Default)Handler\] MATCHED" server.log
```

**Common failures:**
- Wrong handler matched
- Pattern precedence incorrect

---

### test_bidirectional_ws.exs

**Purpose:** WebSocket bidirectional audio API demo (no actual WS server required)

**Dial:** `sip:test@127.0.0.1:5080`

**DTMF controls:**
- `1` - Mute outbound (caller -> AI)
- `2` - Unmute outbound
- `3` - Mute inbound (AI -> caller)
- `4` - Unmute inbound
- `5` - Send custom message
- `6` - Request AI response
- `9` - Disconnect WebSocket
- `*` - End call

**pjsua command:**
```bash
# Test mute/unmute
(sleep 3; echo "1"; sleep 1; echo "2"; sleep 1; echo "*"; echo "q") | \
  pjsua --null-audio --no-tcp --local-port=5100 "sip:test@127.0.0.1:5080"
```

**Success grep:**
```bash
grep -E "(Muting|Unmuting|connect_bidirectional_ws)" server.log
```

**Common failures:**
- WebSocket API functions not defined
- Mute state not tracked

---

### test_registrar.exs

**Purpose:** Basic SIP registration with digest authentication

**pjsua command:**
```bash
pjsua --null-audio --no-tcp --local-port=5090 \
  --id="sip:alice@127.0.0.1" --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="alice" --password="secret123"
```

**Success grep:**
```bash
grep -E "\[DevRegistrar\] (Storing binding|Looking up password)" server.log
```

**Common failures:**
- Wrong password results in 403 Forbidden
- Unknown user results in 403 Forbidden

---

### test_registrar_presence.exs

**Purpose:** Registration with presence state integration

**pjsua commands:**
```bash
# Terminal 2 - Alice
pjsua --null-audio --no-tcp --local-port=5090 \
  --id="sip:alice@127.0.0.1" --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="alice" --password="secret123"

# Terminal 3 - Bob
pjsua --null-audio --no-tcp --local-port=5091 \
  --id="sip:bob@127.0.0.1" --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="bob" --password="secret456"
```

**Presence testing (in Bob's console):**
```
>>> +b sip:alice@127.0.0.1
>>> s
# Wait for NOTIFY
# In Alice: ru (unregister)
# Bob receives NOTIFY: offline
# In Alice: rr (re-register)
# Bob receives NOTIFY: available
```

**Success grep:**
```bash
grep -E "(Notifying presence|SUBSCRIBE|NOTIFY)" server.log
```

**Common failures:**
- Presence not updating on registration change
- NOTIFY not delivered to subscribers

---

### test_registrar_with_pjsua.sh

**Purpose:** Orchestration script for full registrar testing with logging

**Usage:**
```bash
./scripts/dev/test_registrar_with_pjsua.sh [port]
```

**Features:**
- Creates timestamped log directory in `logs/`
- Starts server with `SIP_TRACE=true LOG_LEVEL=debug`
- Outputs exact pjsua commands with log file paths
- Handles Ctrl+C gracefully

**Log locations:**
- Server: `logs/registrar_TIMESTAMP/server.log`
- Alice: `logs/registrar_TIMESTAMP/pjsua_alice.log`
- Bob: `logs/registrar_TIMESTAMP/pjsua_bob.log`

**Success verification:**
```bash
# Check server started
grep "Server listening on port" logs/registrar_*/server.log

# Check registration flow
grep -E "(401|200 OK|REGISTER)" logs/registrar_*/server.log
```

---

## Troubleshooting

### Port Already in Use

```bash
# Find process using port 5080
lsof -i :5080

# Kill it
kill -9 <PID>
```

### pjsua Not Sending Audio

```bash
# Use --null-audio flag (doesn't require actual audio device)
pjsua --null-audio ...
```

### DTMF Not Working

Ensure pjsua is using RFC 2833 for DTMF (default in most cases). If DTMF still fails:

```bash
# Try with explicit codec configuration
pjsua --null-audio --add-codec pcmu --add-codec pcma ...
```

### Server Hangs on Startup

Check for compilation errors:

```bash
mix compile --warnings-as-errors
```

### No Output from Server

Increase log level:

```bash
LOG_LEVEL=debug mix run scripts/dev/test_<name>.exs
```
