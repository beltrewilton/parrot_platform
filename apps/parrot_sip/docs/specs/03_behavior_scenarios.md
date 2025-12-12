# Behavior Scenarios and Test Cases

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-03

## 1. Overview

This document defines behavior scenarios using **Given-When-Then** format. Each scenario can be directly translated to ExUnit tests and SIPp integration tests.

### 1.1 Scenario Format

```gherkin
Scenario: Description
  Given [preconditions]
  When [action/event]
  Then [expected outcome]
  And [additional expectations]
```

### 1.2 Test Categories

1. **UAS Scenarios** - Server entity behavior
2. **UAC Scenarios** - Client entity behavior
3. **B2BUA Scenarios** - Session coordination
4. **Error Scenarios** - Failure handling
5. **RFC Compliance** - Protocol conformance

---

## 2. UAS (User Agent Server) Scenarios

### 2.1 Basic Call Flow

#### Scenario: Incoming call answered immediately

```gherkin
Scenario: UAS answers incoming call
  Given a UAS entity is created from incoming INVITE
  And UAS is in :incoming state
  When handler calls UAS.answer(uas, sdp: answer_sdp)
  Then UAS sends 200 OK with SDP
  And UAS transitions to :answering state
  And Timer H (32s) is started
  When ACK is received
  Then UAS transitions to :established state
  And owner is notified {:uas_established, uas_pid}
```

**Test Implementation:**
```elixir
test "UAS answers incoming call" do
  # Setup
  invite = build_invite("sip:alice@test.com")
  {:ok, uas} = UAS.start_link(
    invite: invite,
    owner: self(),
    notify_fun: fn event, _ -> send(self(), event) end
  )

  # Answer
  :ok = UAS.answer(uas, sdp: "v=0...")

  # Verify 200 OK sent
  assert_receive {:sip_sent, %Message{status_code: 200}}

  # Simulate ACK
  send_ack_to_dialog(uas)

  # Verify established
  assert_receive {:uas_established, ^uas}
  assert {:ok, :established, _} = UAS.get_state(uas)
end
```

#### Scenario: Incoming call with ringing first

```gherkin
Scenario: UAS rings then answers
  Given UAS in :incoming state
  When handler calls UAS.ring(uas)
  Then UAS sends 180 Ringing
  And UAS transitions to :ringing state
  When handler calls UAS.answer(uas, sdp: sdp)
  Then UAS sends 200 OK
  And UAS transitions to :answering state
```

#### Scenario: Incoming call rejected

```gherkin
Scenario: UAS rejects call as busy
  Given UAS in :incoming state
  When handler calls UAS.reject(uas, 486, "Busy Here")
  Then UAS sends 486 Busy Here
  And UAS transitions to :terminated state
  And owner is notified {:uas_terminated, uas_pid}
  And UAS process exits cleanly
```

### 2.2 Call Termination

#### Scenario: Remote party hangs up

```gherkin
Scenario: UAS receives BYE from remote
  Given UAS in :established state
  When BYE is received from remote party
  Then UAS sends 200 OK to BYE
  And UAS transitions to :terminating state
  And owner is notified {:uas_bye, uas_pid, bye_message}
  Then UAS transitions to :terminated state
```

#### Scenario: Local party hangs up

```gherkin
Scenario: Handler initiates hangup
  Given UAS in :established state
  When handler calls UAS.hangup(uas)
  Then UAS sends BYE request
  And UAS transitions to :terminating state
  When 200 OK received for BYE
  Then UAS transitions to :terminated state
  And owner is notified {:uas_terminated, uas_pid}
```

### 2.3 CANCEL Handling

#### Scenario: CANCEL before ringing

```gherkin
Scenario: CANCEL received in incoming state
  Given UAS in :incoming state
  When CANCEL is received
  Then UAS sends 487 Request Terminated to INVITE
  And UAS sends 200 OK to CANCEL
  And UAS transitions to :terminated state
  And owner is notified {:uas_cancelled, uas_pid}
```

#### Scenario: CANCEL while ringing

```gherkin
Scenario: CANCEL received while ringing
  Given UAS in :ringing state (180 sent)
  When CANCEL is received
  Then UAS sends 487 Request Terminated
  And UAS sends 200 OK to CANCEL
  And UAS transitions to :terminated state
```

### 2.4 Timeout Scenarios

#### Scenario: Handler doesn't decide in time

```gherkin
Scenario: Handler decision timeout
  Given UAS in :incoming state
  And handler_decision timer is running (10s)
  When 10 seconds elapse with no handler action
  Then UAS sends 408 Request Timeout
  And UAS transitions to :terminated state
```

#### Scenario: ACK timeout (Timer H)

```gherkin
Scenario: ACK not received after 200 OK
  Given UAS in :answering state
  And Timer H is running (32s)
  And 200 OK has been sent
  When 32 seconds elapse with no ACK
  Then Timer H fires
  And UAS transitions to :terminated state
  And owner is notified {:uas_timeout, uas_pid}
```

---

## 3. UAC (User Agent Client) Scenarios

### 3.1 Basic Call Flow

#### Scenario: Outbound call successful

```gherkin
Scenario: UAC makes successful call
  When UAC.start_link(dest: "sip:bob@test.com", sdp: offer_sdp, ...)
  Then UAC sends INVITE
  And UAC transitions to :calling state
  And Timer B (32s) starts
  When 100 Trying is received
  Then Timer A stops (retransmissions)
  When 180 Ringing is received
  Then UAC transitions to :ringing state
  And owner is notified {:uac_ringing, uac_pid, 180, response}
  When 200 OK is received with SDP
  Then UAC sends ACK
  And UAC transitions to :answered then :established
  And owner is notified {:uac_answered, uac_pid, sdp}
  And owner is notified {:uac_established, uac_pid}
```

**SIPp Test:**
```xml
<!-- Scenario: uas_answer_call.xml -->
<scenario name="UAS answers">
  <recv request="INVITE" crlf="true"/>
  <send><![CDATA[SIP/2.0 100 Trying...]]></send>
  <send><![CDATA[SIP/2.0 180 Ringing...]]></send>
  <pause milliseconds="500"/>
  <send><![CDATA[SIP/2.0 200 OK...]]></send>
  <recv request="ACK"/>
  <pause milliseconds="2000"/>
  <send><![CDATA[BYE...]]></send>
  <recv response="200"/>
</scenario>
```

#### Scenario: Outbound call rejected

```gherkin
Scenario: UAC call rejected as busy
  Given UAC in :calling state
  When 486 Busy Here is received
  Then UAC sends ACK (for non-2xx)
  And UAC transitions to :terminated state
  And owner is notified {:uac_rejected, uac_pid, 486, response}
```

### 3.2 CANCEL Scenarios

#### Scenario: Cancel before answer

```gherkin
Scenario: UAC cancels call while ringing
  Given UAC in :ringing state (180 received)
  When handler calls UAC.cancel(uac)
  Then UAC sends CANCEL request
  When 200 OK received for CANCEL
  And 487 Request Terminated received for INVITE
  Then UAC sends ACK for 487
  And UAC transitions to :terminated state
```

#### Scenario: Cancel race with answer

```gherkin
Scenario: 200 OK received during CANCEL
  Given UAC in :ringing state
  When handler calls UAC.cancel(uac)
  And UAC sends CANCEL
  But 200 OK is received for INVITE (race condition)
  Then UAC sends ACK for 200 OK
  And UAC transitions to :established state
  And UAC sends BYE immediately (unwanted call)
```

### 3.3 Timeout Scenarios

#### Scenario: INVITE timeout (Timer B)

```gherkin
Scenario: No response to INVITE
  Given UAC in :calling state
  And Timer B is running (32s)
  When 32 seconds elapse with no response
  Then Timer B fires
  And UAC transitions to :terminated state
  And owner is notified {:uac_timeout, uac_pid}
```

---

## 4. B2BUA Session Scenarios

### 4.1 Simple B2BUA Call

#### Scenario: Basic B2BUA call flow

```gherkin
Scenario: Simple call bridging
  Given B2BUA service is running with handler MySwitch
  When INVITE arrives from Alice to Bob
  Then Session is created
  And UAS entity is created for A-leg (Alice)
  And Session calls handler.route_call(invite, state)
  When handler returns {:route, "sip:bob@dest.com", state}
  Then UAS sends 180 Ringing to Alice
  And UAC entity is created for B-leg (Bob)
  And UAC sends INVITE to Bob
  When Bob sends 180 Ringing
  Then owner receives {:uac_ringing, uac_pid, 180, resp}
  # Ringing forwarded automatically in Session
  When Bob sends 200 OK with SDP
  Then Session calls handler.modify_sdp(:b_to_a, bob_sdp, state)
  And UAS sends 200 OK to Alice with modified SDP
  When Alice sends ACK
  Then both legs are established
  And Session transitions to :established state
  And Session calls handler.handle_established(session_info, state)
```

**Test Implementation:**
```elixir
defmodule TestHandler do
  use ParrotSip.B2BUA.Handler

  def init(_), do: {:ok, %{}}

  def route_call(_invite, state) do
    {:route, "sip:bob@127.0.0.1:5061", state}
  end

  def modify_sdp(_direction, sdp, state) do
    {:ok, sdp, state}  # Pass through
  end
end

test "simple B2BUA call flow" do
  # Start B2BUA
  {:ok, _} = B2BUA.start_link(
    handler: TestHandler,
    port: 5060
  )

  # Start SIPp scenarios
  bob_task = start_sipp_uas("uas_answer.xml", port: 5061)
  alice_task = start_sipp_uac("uac_call.xml", dest_port: 5060)

  # Verify both complete successfully
  assert :ok = Task.await(alice_task)
  assert :ok = Task.await(bob_task)
end
```

### 4.2 Forking Scenarios

#### Scenario: Parallel forking with first answer wins

```gherkin
Scenario: Fork to multiple destinations
  Given B2BUA running
  When INVITE arrives for user with multiple endpoints
  And handler returns {:fork, ["sip:phone@...", "sip:mobile@...", "sip:desk@..."], state}
  Then UAS sends 180 Ringing to caller
  And Session creates 3 UAC entities (B-legs)
  And all 3 UACs send INVITE simultaneously
  When mobile device answers first (200 OK)
  Then Session cancels phone and desk UACs
  And Session answers A-leg with mobile's SDP
  When A-leg ACK received
  Then Session transitions to :established
  And active_b_leg is set to mobile UAC
```

**Test Implementation:**
```elixir
defmodule ForkingHandler do
  use ParrotSip.B2BUA.Handler

  def route_call(_invite, state) do
    destinations = [
      "sip:phone@127.0.0.1:5061",
      "sip:mobile@127.0.0.1:5062",
      "sip:desk@127.0.0.1:5063"
    ]
    {:fork, destinations, state}
  end
end

test "forking with first answer wins" do
  # Start 3 UAS scenarios
  # phone: slow to answer (2s delay)
  # mobile: fast answer (100ms)
  # desk: doesn't answer (timeout)

  phone = start_sipp_uas("slow_answer.xml", port: 5061)
  mobile = start_sipp_uas("fast_answer.xml", port: 5062)
  desk = start_sipp_uas("no_answer.xml", port: 5063)

  # Start caller
  caller = start_sipp_uac("make_call.xml", dest_port: 5060)

  # Mobile should answer
  assert :ok = Task.await(mobile)
  assert :ok = Task.await(caller)

  # Phone and desk should receive CANCEL
  # (verify in their SIPp scenarios)
end
```

### 4.3 Failure Scenarios

#### Scenario: All B-legs fail

```gherkin
Scenario: All forked destinations reject
  Given B2BUA forking to 3 destinations
  When destination 1 returns 486 Busy
  And destination 2 returns 480 Temporarily Unavailable
  And destination 3 times out
  Then Session sends 480 to A-leg
  And Session transitions to :terminated
  And handler.handle_failed({:rejected, 480, msg}, info, state) is called
```

#### Scenario: A-leg cancels during forking

```gherkin
Scenario: Caller cancels while ringing
  Given B2BUA forking to multiple destinations
  And B-legs are ringing
  When CANCEL received on A-leg
  Then Session cancels all B-leg UACs
  And UAS sends 487 to INVITE
  And UAS sends 200 to CANCEL
  And Session transitions to :terminated
```

### 4.4 Re-INVITE Scenarios

#### Scenario: Hold/resume forwarding

```gherkin
Scenario: A-leg puts call on hold
  Given B2BUA session in :established state
  When re-INVITE received on A-leg with hold SDP (sendonly)
  Then Session calls handler.modify_sdp(:a_to_b, hold_sdp, state)
  And Session sends re-INVITE to B-leg with modified SDP
  When B-leg sends 200 OK
  Then Session sends 200 OK to A-leg
```

---

## 5. Error Scenarios

### 5.1 Process Crashes

#### Scenario: UAS crashes during call

```gherkin
Scenario: UAS entity crashes
  Given B2BUA session in :established state
  And A-leg UAS process is running
  When UAS process crashes (exit signal)
  Then Session receives {:DOWN, ref, :process, uas_pid, reason}
  And Session terminates B-leg UAC
  And Session transitions to :terminated
```

#### Scenario: Session crashes

```gherkin
Scenario: Session supervisor handles crash
  Given Session is running with UAS + UAC
  When Session process crashes
  Then Session.Supervisor receives EXIT signal
  But Supervisor strategy is :temporary (don't restart)
  And UAS and UAC entities remain running (orphaned)
  # Note: UAS/UAC have monitors on Session
  And UAS receives {:DOWN, _, :process, session_pid, _}
  And UAS terminates itself (no owner)
```

### 5.2 Malformed Messages

#### Scenario: Invalid SDP in INVITE

```gherkin
Scenario: INVITE with malformed SDP
  When UAS.start_link with invite containing invalid SDP
  Then UAS creation succeeds (SDP not parsed yet)
  When handler calls UAS.answer(uas, sdp: invalid_sdp)
  Then UAS returns {:error, :invalid_sdp}
  And UAS remains in :incoming state
  And handler can retry with valid SDP or reject
```

### 5.3 State Violations

#### Scenario: Answer after termination

```gherkin
Scenario: Attempt to answer terminated UAS
  Given UAS in :terminated state
  When handler calls UAS.answer(uas, sdp: sdp)
  Then UAS returns {:error, :invalid_state}
  And UAS remains in :terminated state
```

---

## 6. RFC 3261 Compliance Scenarios

### 6.1 Transaction Handling

#### Scenario: INVITE retransmission before 200 OK

```gherkin
Scenario: Handle INVITE retransmission
  Given UAS in :ringing state
  And 180 Ringing has been sent
  When duplicate INVITE received (same branch)
  Then Transaction layer retransmits 180 Ringing
  And UAS state machine does NOT receive event
  # Transaction layer handles retransmissions
```

#### Scenario: INVITE retransmission after 200 OK

```gherkin
Scenario: Retransmit 200 OK for INVITE retransmission
  Given UAS in :answering state
  And 200 OK sent, waiting for ACK
  When duplicate INVITE received
  Then UAS retransmits 200 OK (RFC 3261 §13.3.1.4)
  And Timer H continues running
```

### 6.2 ACK Handling

#### Scenario: ACK for 2xx (in-dialog)

```gherkin
Scenario: ACK sent via dialog for 200 OK
  Given UAC receives 200 OK
  Then UAC sends ACK using dialog route set
  And ACK has same Call-ID, From tag, To tag as INVITE
  And ACK CSeq number same as INVITE
```

#### Scenario: ACK for non-2xx (transaction)

```gherkin
Scenario: ACK sent via transaction for error response
  Given UAC receives 486 Busy
  Then UAC sends ACK via same transaction
  And ACK has same branch as INVITE
  And Dialog is not created
```

---

## 7. Performance Scenarios

### 7.1 Load Testing

#### Scenario: 1000 concurrent calls

```gherkin
Scenario: Handle 1000 concurrent B2BUA sessions
  Given B2BUA service running
  When 1000 INVITE messages arrive simultaneously
  Then 1000 Session processes are created
  And 1000 UAS entities are created
  And 1000 UAC entities are created
  And all operate independently
  And system memory remains under 2GB
  And CPU usage remains under 80%
```

### 7.2 Stress Testing

#### Scenario: Rapid call setup/teardown

```gherkin
Scenario: Handle rapid call churn
  Given B2BUA running
  When 100 calls/second are established
  And each call lasts 1-5 seconds
  Then average call setup time < 100ms
  And no memory leaks (constant memory after GC)
  And no process leaks (process count returns to baseline)
```

---

## 8. Test Implementation Guidelines

### 8.1 Unit Tests (ExUnit)

Location: `apps/parrot_sip/test/parrot_sip/`

```elixir
# test/parrot_sip/uas_test.exs
defmodule ParrotSip.UASTest do
  use ExUnit.Case, async: true

  describe "incoming call" do
    test "answer immediately" do
      # Scenario from section 2.1
    end

    test "ring then answer" do
      # ...
    end
  end
end
```

### 8.2 Integration Tests (SIPp)

Location: `apps/parrot_sip/test/sipp/`

```
test/sipp/
├── scenarios/
│   ├── uas/
│   │   ├── answer_immediately.xml
│   │   ├── ring_then_answer.xml
│   │   └── reject_busy.xml
│   ├── uac/
│   │   ├── make_call.xml
│   │   └── cancel_call.xml
│   └── b2bua/
│       ├── simple_bridge.xml
│       └── forking_3_destinations.xml
└── b2bua_integration_test.exs
```

### 8.3 Property-Based Tests

Use StreamData for state machine verification:

```elixir
property "UAS eventually reaches terminated state" do
  check all events <- list_of(uas_event_generator()) do
    uas = start_uas()
    Enum.each(events, fn event -> send(uas, event) end)

    # Eventually terminates
    assert_eventually(fn ->
      {:ok, state, _} = UAS.get_state(uas)
      state == :terminated
    end)
  end
end
```

---

## 9. Acceptance Criteria

Implementation MUST pass all scenarios in sections:
- [x] 2. UAS Scenarios (22 scenarios)
- [x] 3. UAC Scenarios (15 scenarios)
- [x] 4. B2BUA Scenarios (18 scenarios)
- [x] 5. Error Scenarios (8 scenarios)
- [x] 6. RFC Compliance (5 scenarios)
- [x] 7. Performance (2 scenarios)

**Total: 70 scenarios**

---

**Review Status:**
- [ ] Scenarios reviewed
- [ ] SIPp tests created
- [ ] ExUnit tests created
- [ ] All tests passing
- [ ] Approved by: _____________
