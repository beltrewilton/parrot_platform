# SIPp Test Coverage Status

## UAC Tests (ParrotSip sends - SIPp receives)

### Completed
- [x] INVITE - Basic outbound call
- [x] OPTIONS - Capability query
- [x] INVITE - Multiple sequential calls
- [x] re-INVITE - Hold (sendonly SDP)
- [x] BYE - Call termination
- [x] BYE - Multiple sequential calls
- [x] CANCEL - Cancel in-progress call
- [x] REGISTER - Client registration
- [x] REGISTER - Multiple sequential registrations

### High Priority
- [ ] Provisional responses - 100/180/183 handling
- [ ] re-INVITE - Resume from hold
- [ ] re-INVITE - Codec change

### Medium Priority
- [ ] MESSAGE - Instant messaging
- [ ] SUBSCRIBE - Event subscription
- [ ] REFER - Call transfer initiation
- [ ] UPDATE - Session refresh
- [ ] Authentication - 401/407 challenge handling
- [ ] Redirects - 3xx response handling
- [ ] Error handling - 4xx/5xx/6xx

---

## UAS Tests (SIPp sends - ParrotSip receives)

### Completed
- [x] INVITE - Full call flow
- [x] OPTIONS - Capability query
- [x] CANCEL - Cancel before answer
- [x] re-INVITE - Hold
- [x] re-INVITE - Hold and resume
- [x] re-INVITE - Codec change
- [x] re-INVITE - Multiple in same dialog
- [x] re-INVITE - No SDP
- [x] re-INVITE - Timeout/retransmission
- [x] TCP transport
- [x] TLS transport
- [x] REGISTER - Registration handling
- [x] REGISTER - Multiple registrations
- [x] BYE - Standalone termination test

### High Priority
- [ ] MESSAGE - Instant messaging
- [ ] SUBSCRIBE/NOTIFY - Event handling

### Medium Priority
- [ ] REFER - Call transfer handling
- [ ] UPDATE - Session refresh handling
- [ ] PRACK - Reliable provisional responses
- [ ] Authentication - Send 401/407 challenges
- [ ] Error responses - 4xx/5xx/6xx generation

---

## DSL Feature Tests (SIPp sends - ParrotSip receives)

Tests for Parrot.InviteHandler DSL features. Located in `test/sipp/scenarios/dsl/`.

### Completed
- [x] INFO/DTMF - DTMF via SIP INFO method (RFC 6086)
  - Scenario: `uac_info_dtmf.xml`
  - Tests: Single call, multiple calls
- [x] Hold/Unhold - re-INVITE based hold and resume cycle
  - Scenario: `uac_hold_unhold.xml`
  - Tests: Single cycle, multiple cycles
- [x] Play with DTMF - IVR-style DTMF navigation
  - Scenario: `uac_play_dtmf.xml`
  - Tests: Single call

### B2BUA Features (Scenarios ready, tests pending implementation)
- [ ] Bridge - B2BUA bridge A-leg to B-leg
  - A-leg scenario: `uac_bridge.xml`
  - B-leg scenario: `uas_bridge_bleg.xml`
  - Requires B2BUA handler implementation
- [ ] Fork - Call forking to multiple destinations
  - Caller scenario: `uac_fork.xml`
  - Target scenario: `uas_fork_target.xml`
  - Requires fork handler implementation

---

## Implementation Order

1. **UAC re-INVITE** - Most critical missing feature
2. **UAC BYE** - Essential for call cleanup
3. **UAC CANCEL** - Important for user experience
4. **UAC REGISTER** - Core SIP functionality
5. **UAS REGISTER** - Registration server
6. **UAC Provisional Responses** - Real-world call handling
7. **UAS MESSAGE** - Messaging support
8. **B2BUA Bridge** - DSL bridge() function
9. **B2BUA Fork** - DSL fork() function
10. **Remaining items** - As needed

---

## DSL Test Handler

The DSL tests use `SippTest.DSLTestHandler` which implements `Parrot.InviteHandler` behaviour.
Location: `test/sipp/support/dsl_test_handler.ex`

Supported behaviors via assigns:
- `:answer` - Answer call with 200 OK
- `:reject` - Reject call (configurable status code)
- `:play_and_hangup` - Answer, play file, hangup
- `:bridge` - Answer and bridge to destination
- `:fork` - Answer and fork to multiple destinations
- `:dtmf_response` - Answer and handle DTMF events

## RFC References

- RFC 3261 - SIP: Session Initiation Protocol
- RFC 3264 - Offer/Answer Model with SDP (hold/resume)
- RFC 6086 - Session Initiation Protocol (SIP) INFO Method and Package (DTMF)
