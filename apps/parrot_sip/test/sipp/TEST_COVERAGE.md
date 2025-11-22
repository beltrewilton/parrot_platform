# SIPp Test Coverage Status

## UAC Tests (ParrotSip sends → SIPp receives)

### ✅ Completed
- [x] INVITE - Basic outbound call
- [x] OPTIONS - Capability query
- [x] INVITE - Multiple sequential calls
- [x] re-INVITE - Hold (sendonly SDP)
- [x] BYE - Call termination
- [x] BYE - Multiple sequential calls
- [x] CANCEL - Cancel in-progress call
- [x] REGISTER - Client registration
- [x] REGISTER - Multiple sequential registrations

### 🚧 High Priority
- [ ] Provisional responses - 100/180/183 handling
- [ ] re-INVITE - Resume from hold
- [ ] re-INVITE - Codec change

### 📋 Medium Priority
- [ ] MESSAGE - Instant messaging
- [ ] SUBSCRIBE - Event subscription
- [ ] REFER - Call transfer initiation
- [ ] UPDATE - Session refresh
- [ ] Authentication - 401/407 challenge handling
- [ ] Redirects - 3xx response handling
- [ ] Error handling - 4xx/5xx/6xx

---

## UAS Tests (SIPp sends → ParrotSip receives)

### ✅ Completed
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

### 🚧 High Priority
- [x] REGISTER - Registration handling
- [x] REGISTER - Multiple registrations
- [x] BYE - Standalone termination test
- [ ] MESSAGE - Instant messaging
- [ ] SUBSCRIBE/NOTIFY - Event handling

### 📋 Medium Priority
- [ ] REFER - Call transfer handling
- [ ] UPDATE - Session refresh handling
- [ ] PRACK - Reliable provisional responses
- [ ] INFO - Mid-dialog information
- [ ] Authentication - Send 401/407 challenges
- [ ] Error responses - 4xx/5xx/6xx generation

---

## Implementation Order

1. **UAC re-INVITE** - Most critical missing feature
2. **UAC BYE** - Essential for call cleanup
3. **UAC CANCEL** - Important for user experience
4. **UAC REGISTER** - Core SIP functionality
5. **UAS REGISTER** - Registration server
6. **UAC Provisional Responses** - Real-world call handling
7. **UAS MESSAGE** - Messaging support
8. **Remaining items** - As needed
