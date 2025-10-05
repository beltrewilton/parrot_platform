# SiPP Integration Test Findings

## Summary

SiPP integration testing has uncovered several bugs in the ParrotSip/ParrotTransport integration. This document summarizes the findings, fixes applied, and remaining work.

## Issues Found and Fixed

### 1. ✅ SiPP Timeout Configuration (FIXED)

**Problem**: SiPP test runner wasn't passing timeout parameter to SiPP itself, only using it for Elixir Task.yield timeout. This caused:
- SiPP to hang indefinitely
- Tests to timeout at Task.yield level
- No proper error messages from SiPP

**Root Cause**:
- `SippRunner.run_scenario/1` accepted `timeout` parameter but only used it for `Task.yield`
- SiPP needs its own `-timeout` argument in seconds

**Fix Applied**:
1. Added SiPP `-timeout` argument: `div(timeout * 80, 100_000)` seconds (80% of Task timeout, min 10s)
2. Added `-timeout_error` flag so SiPP fails on timeout
3. Increased test timeouts to account for scenario pauses (scenarios have 5-second pauses)

**Files Changed**:
- `test/sipp/support/sipp_runner.ex`: Added timeout arguments to SiPP command
- `test/sipp/test_basic.exs`: Increased timeouts from 5s/15s to 15s/60s

**Commit**: `0d0e46b` - "Fix SiPP test runner timeout handling"

---

## Outstanding Bugs

### 2. ❌ BYE Response Not Received (BUG)

**Symptom**:
```
Messages  Retrans   Timeout   Unexpected-Msg
BYE ---------->         10        81        9
200 <----------         1         0         0         0
```

**What's Happening**:
- SiPP sends 10 BYE requests
- Only 1 receives 200 OK response
- 9 calls timeout waiting for BYE response
- SiPP retransmits BYE 81 times total

**Error Message**:
```
Dead call 10-30790@127.0.0.1 (aborted at index 7), received
'SIP/2.0 200 OK
Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bK-30790-10-6
From: sipp <sip:sipp@127.0.0.1:5060>;tag=10
To: sut <sip:service@127.0.0.1:57625>
Call-ID: 10-30790@127.0.0.1
CSeq: 2 BYE'
```

**Analysis**:
The 200 OK response IS being sent (we can see it in the error), but SiPP is receiving it on a "dead call". This suggests:

1. **Response routing issue**: The 200 OK may be sent to the wrong address/port
2. **Via header issue**: The Via header branch may not match what SiPP expects
3. **Timing issue**: Response arrives after SiPP has given up on the transaction

**Next Steps**:
- [ ] Add SiPP trace logging (`-trace_msg`) to see exact messages
- [ ] Check Via header in BYE response
- [ ] Verify response is sent to correct source address
- [ ] Check if response uses proper transaction matching

### 3. ❌ CANCEL Returns 481 (BUG)

**Symptom**:
```
Aborting call on unexpected message for Call-Id '1-31735@127.0.0.1':
while expecting '200' (index 5), received
'SIP/2.0 481 Call/Transaction Does Not Exist
...
CSeq: 1 CANCEL'
```

**What's Happening**:
1. SiPP sends INVITE
2. Receives 100 Trying
3. Receives 180 Ringing
4. Sends CANCEL
5. Receives **481** instead of 200 OK
6. Test fails

**Analysis**:
The ParrotSip stack is responding with "481 Call/Transaction Does Not Exist" to CANCEL requests. This means:

1. **Transaction not found**: The CANCEL transaction lookup is failing
2. **Branch parameter issue**: CANCEL must use same branch as INVITE per RFC 3261
3. **Handler not implemented**: CANCEL handling may not be wired up properly in TestHandler

**RFC 3261 Requirements**:
- CANCEL must have same Call-ID, To, From, and initial Via branch as INVITE
- UAS must respond 200 OK to CANCEL (even if transaction doesn't exist)
- Then send 487 Request Terminated to INVITE

**Next Steps**:
- [ ] Check if CANCEL uses correct branch parameter
- [ ] Verify transaction layer handles CANCEL correctly
- [ ] Check TestHandler CANCEL implementation
- [ ] Add unit test for CANCEL handling

---

## Test Infrastructure Improvements

### Testing Architecture

Created comprehensive SiPP testing infrastructure:

1. **SippRunner** (`test/sipp/support/sipp_runner.ex`):
   - Elixir wrapper for SiPP execution
   - Handles all transport types (UDP, TCP, TLS, WebSocket)
   - Proper timeout and error handling
   - Returns `:ok` or `{:error, reason}` tuples

2. **TestHandler** (`test/sipp/support/test_handler.ex`):
   - Configurable ParrotSip.Handler implementation
   - Auto-response configuration per method
   - Statistics tracking
   - Background process for state management

3. **SipStackHelper** (`test/sipp/support/sip_stack_helper.ex`):
   - Wires ParrotTransport + ParrotSip together
   - Manages listener lifecycle
   - Handles transport registration
   - Supports UDP, TCP, TLS, WebSocket

4. **Basic Call Flow Test** (`apps/parrot_sip/test/parrot_sip/basic_call_flow_test.exs`):
   - Unit test that verifies INVITE→200 OK→ACK→BYE flow at SIP layer
   - Bypasses transport layer to isolate SIP logic
   - **This test PASSES** - proves SIP layer works correctly in isolation

### SiPP Exit Codes

SiPP returns specific exit codes:
- `0`: All calls successful
- `1`: At least one call failed
- `97`: Exit on internal command
- `99`: Normal exit without calls processed
- `253`: RTP validation failure
- `255` (-1): Fatal error
- `254` (-2): Fatal error binding socket

Our test runner properly catches and reports these.

---

## Test Results Summary

### ✅ Passing Tests
- `test_scenarios.exs` - Original working tests using old API (3/3 passing)
- `apps/parrot_sip/test/parrot_sip/basic_call_flow_test.exs` - Unit test (1/1 passing)

### ❌ Failing Tests
- `test_basic.exs` - BYE response issue (0/3 passing)
- `test_cancel.exs` - CANCEL returns 481 (0/2 passing)
- `test_cancel_simple.exs` - XML variable error (0/1 passing)
- `test_transports.exs` - Port binding issues (0/3 passing)

---

## Recommendations

### Immediate Actions

1. **Fix BYE Response Routing**:
   - Enable SiPP message tracing: `SippRunner.run_scenario(trace_msg: true)`
   - Compare working vs. broken BYE responses
   - Check Via header and source address handling

2. **Fix CANCEL Handling**:
   - Verify CANCEL transaction matching in ParrotSip.TransactionStatem
   - Ensure CANCEL uses same branch as INVITE
   - Add proper CANCEL response (200 OK + 487 to INVITE)

3. **Address Test Infrastructure**:
   - Fix TCP/TLS port binding conflicts between tests
   - Fix CANCEL simple test XML variable issue
   - Add more logging/tracing options to tests

### Future Enhancements

1. **Add More Scenarios**:
   - Re-INVITE
   - Early media (183 Session Progress)
   - Authentication (401/407)
   - Redirects (3xx)
   - Stress/load testing

2. **CI/CD Integration**:
   - Add SiPP tests to continuous integration
   - Run on PR validation
   - Generate coverage reports

3. **Documentation**:
   - Document SiPP scenario format
   - Add troubleshooting guide
   - Create developer guide for adding new scenarios
