# RFC 3261 Compliance Mapping

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-03

## 1. Overview

This document maps the UAS/UAC/B2BUA architecture to RFC 3261 requirements. It clarifies which RFC requirements are handled by existing layers vs. new entity/session layers.

### 1.1 Layered Compliance

```
┌─────────────────────────────────────────────┐
│ Layer 3: Session (B2BUA)                    │
│ Compliance: Application-level B2BUA logic   │
│ - Not RFC-defined                            │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│ Layer 2: Entity (UAS/UAC)                   │
│ Compliance: Application call control         │
│ - Uses Dialog layer for RFC compliance      │
│ - Adds application state & callbacks         │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│ Layer 1: Protocol (Dialog/Transaction)      │
│ Compliance: Full RFC 3261 §12, §17          │
│ - Dialog: §12 (EXISTING)                    │
│ - Transaction: §17 (EXISTING)                │
└─────────────────────────────────────────────┘
```

**Key Principle:** Protocol compliance is delegated to existing layers. Entity/Session layers provide application convenience.

---

## 2. RFC 3261 Section 17: Transactions

### 2.1 Compliance Status: ✅ COMPLETE (Existing)

**Implementation:** `ParrotSip.TransactionStatem`

All transaction requirements are handled by the existing transaction layer:

| RFC Section | Requirement | Status | Implementation |
|-------------|-------------|--------|----------------|
| §17.1.1 | INVITE Client Transaction | ✅ | TransactionStatem (client, INVITE) |
| §17.1.2 | Non-INVITE Client | ✅ | TransactionStatem (client, non-INVITE) |
| §17.2.1 | INVITE Server Transaction | ✅ | TransactionStatem (server, INVITE) |
| §17.2.2 | Non-INVITE Server | ✅ | TransactionStatem (server, non-INVITE) |
| §17.1.1.2 | Timer A (retransmit) | ✅ | TransactionStatem timers |
| §17.1.1.2 | Timer B (timeout) | ✅ | TransactionStatem timers |
| §17.2.1 | Timer G, H, I, J | ✅ | TransactionStatem timers |

**Entity Layer Responsibility:** NONE - Entities use Transaction layer, don't reimplement.

**Evidence:**
```elixir
# UAC sends INVITE via Transaction.Client
{:uac_id, trans} = Transaction.Client.request(invite_msg, callback)

# UAS receives transactions via Transaction.Server callbacks
def uas_request(uas, sip_msg, args)
```

---

## 3. RFC 3261 Section 12: Dialogs

### 3.1 Compliance Status: ✅ COMPLETE (Existing)

**Implementation:** `ParrotSip.DialogStatem`

All dialog requirements handled by existing dialog layer:

| RFC Section | Requirement | Status | Implementation |
|-------------|-------------|--------|----------------|
| §12.1 | Dialog Creation | ✅ | Dialog.create_from_invite/2 |
| §12.1.1 | UAS Dialog Creation | ✅ | DialogStatem (role: :uas) |
| §12.1.2 | UAC Dialog Creation | ✅ | DialogStatem (role: :uac) |
| §12.2 | Requests within Dialog | ✅ | Dialog.create_request/2 |
| §12.2.1.1 | Route Set | ✅ | Dialog.route_set field |
| §12.2.1.1 | Remote Target | ✅ | Dialog.remote_target field |
| §12.2.2 | CSeq Incrementing | ✅ | Dialog.local_seq management |
| §12.3 | Dialog Termination | ✅ | DialogStatem :terminated state |

**Entity Layer Responsibility:**
- Create DialogStatem process for each entity
- Delegate in-dialog requests to Dialog layer
- Monitor dialog lifecycle

**Evidence:**
```elixir
# UAS creates dialog in UAS role
{:ok, dialog_pid} = DialogStatem.start_link(invite, :uas)

# UAC creates dialog in UAC role
{:ok, dialog_pid} = DialogStatem.start_link(invite, :uac)

# Send BYE via dialog (proper CSeq, Route set)
Dialog.send_request(dialog_pid, :bye)
```

---

## 4. RFC 3261 Section 13: Initiating a Session

### 4.1 UAC Behavior (§13.1)

#### §13.1 - Generating INVITE Requests

**RFC Requirement:**
> UAC creates INVITE with SDP offer, proper headers (From, To, Call-ID, CSeq, Via, Contact)

**Compliance:**
| Requirement | Layer | Implementation |
|-------------|-------|----------------|
| Build INVITE message | Entity (UAC) | UAC.start_link builds INVITE |
| Add SDP offer | Entity (UAC) | opts[:sdp] parameter |
| Generate Call-ID | Protocol (Dialog) | Dialog layer generates |
| Generate From tag | Protocol (Dialog) | Dialog layer generates |
| Add Via header | Protocol (Transaction) | Transaction.Client adds |
| Add Contact | Protocol (Dialog) | Dialog adds from config |

**Code Mapping:**
```elixir
# UAC builds INVITE
defmodule ParrotSip.UAC do
  def start_link(opts) do
    # Build INVITE message structure
    invite = build_invite(
      dest_uri: opts[:dest_uri],
      sdp: opts[:sdp],
      from_uri: opts[:from_uri],
      headers: opts[:headers]
    )

    # Dialog layer adds proper headers (Call-ID, From tag, Contact)
    {:ok, dialog} = DialogStatem.create_uac_dialog(invite)

    # Transaction layer adds Via, sends request
    {:uac_id, trans} = Transaction.Client.request(invite, callback)
  end
end
```

**Compliance: ✅** UAC delegates to existing layers.

#### §13.2 - Processing INVITE Response

**RFC Requirements:**

| Response Code | RFC Action | Entity Implementation |
|---------------|------------|----------------------|
| 100 Trying | Stop Timer A | Transaction layer handles |
| 1xx Provisional | Alert user | UAC notifies owner `{:uac_ringing, ...}` |
| 2xx Success | Send ACK, establish dialog | UAC sends ACK via Dialog layer |
| 3xx Redirect | Extract Contact, retry | UAC notifies owner `{:uac_rejected, 3xx, ...}` |
| 4xx-6xx Error | Send ACK (via transaction) | UAC sends ACK, notifies owner |

**Code Mapping:**
```elixir
# UAC state: :calling
def calling(:cast, {:tx_response, {180, response}}, data) do
  # Notify application
  notify(data.owner, {:uac_ringing, self(), 180, response})
  {:next_state, :ringing, data}
end

def calling(:cast, {:tx_response, {200, response}}, data) do
  # Send ACK via Dialog layer (RFC §13.2.2.4)
  Dialog.send_ack(data.dialog, response)
  notify(data.owner, {:uac_answered, self(), response.body})
  {:next_state, :established, data}
end
```

**Compliance: ✅** UAC delegates ACK generation to Dialog layer per RFC §13.2.2.4.

### 4.2 UAS Behavior (§13.2)

#### §13.2.1 - Processing INVITE

**RFC Requirements:**

| Requirement | Layer | Implementation |
|-------------|-------|----------------|
| Examine Request-URI | Application (Handler) | Handler.route_call/2 |
| Check To tag (new vs in-dialog) | Protocol (Transaction/Dialog) | TransactionStatem checks |
| Respond 100 Trying | Protocol (Transaction) | Transaction.Server auto-sends |
| Create dialog on 2xx | Protocol (Dialog) | DialogStatem created |
| Wait for ACK | Protocol + Entity | DialogStatem + UAS Timer H |

**Code Mapping:**
```elixir
# UAS receives INVITE
def start_link(opts) do
  invite = opts[:invite]

  # Dialog layer creates dialog in UAS role
  {:ok, dialog} = DialogStatem.create_uas_dialog(invite)

  # UAS provides application-level state machine
  # Transaction layer already sent 100 Trying
  data = %Data{
    dialog: dialog,
    invite: invite,
    owner: opts[:owner]
  }

  {:ok, :incoming, data}
end
```

**Compliance: ✅** UAS delegates to Dialog/Transaction layers.

#### §13.2.2 - UAS Generating Response

**RFC Requirements:**

| Response Type | RFC Requirement | Entity Implementation |
|---------------|-----------------|----------------------|
| 1xx Provisional | Copy Via, From, Call-ID, CSeq | Dialog.reply/2 handles |
| Add To tag | Generate tag on first response | DialogStatem adds tag |
| 2xx Success | Add Contact header | DialogStatem adds Contact |
| Retransmit 2xx | Retransmit if INVITE retransmitted | UAS + DialogStatem handle |

**Code Mapping:**
```elixir
# UAS answers
def answer(uas, opts) do
  GenServer.call(uas, {:answer, opts[:sdp]})
end

def handle_call({:answer, sdp}, _from, state) do
  # Build 200 OK via Dialog layer (ensures proper headers)
  response = Dialog.build_response(state.dialog, 200, "OK", body: sdp)

  # Send via Transaction.Server
  Transaction.Server.response(response, state.uas_transaction)

  # Start Timer H (ACK wait) per RFC §13.3.1.4
  timer_h = Process.send_after(self(), :timer_h_fired, 32_000)

  {:reply, :ok, :answering, %{state | timer_h: timer_h}}
end
```

**Compliance: ✅** UAS uses Dialog layer for response generation per RFC §12.1.1.

---

## 5. RFC 3261 Section 15: Terminating a Session

### 5.1 BYE Request (§15.1)

**RFC Requirements:**

| Requirement | Layer | Implementation |
|-------------|-------|----------------|
| Send BYE within dialog | Protocol (Dialog) | Dialog.send_request(dialog, :bye) |
| Proper Route set | Protocol (Dialog) | Dialog.route_set used |
| Increment CSeq | Protocol (Dialog) | Dialog.local_seq incremented |
| Add Via, Contact | Protocol (Transaction) | Transaction.Client adds |

**Code Mapping:**
```elixir
# UAC sends BYE
def hangup(uac) do
  GenServer.call(uac, :hangup)
end

def handle_call(:hangup, _from, state) do
  # Dialog layer handles all RFC requirements
  :ok = Dialog.send_request(state.dialog, :bye)
  {:reply, :ok, :terminating, state}
end
```

**Compliance: ✅** Entities delegate to Dialog layer for BYE generation.

### 5.2 Receiving BYE (§15.1)

**RFC Requirements:**

| Requirement | Layer | Implementation |
|-------------|-------|----------------|
| Match to dialog | Protocol (Dialog) | DialogStatem matches Call-ID+tags |
| Send 200 OK | Protocol (Dialog) | Dialog.send_response/2 |
| Terminate dialog | Protocol (Dialog) | DialogStatem → :terminated |

**Code Mapping:**
```elixir
# UAS receives BYE
def handle_info({:dialog_event, {:bye_received, bye_msg}}, state) do
  # Dialog layer already matched to correct dialog
  # Dialog layer sends 200 OK automatically

  # UAS notifies application
  notify(state.owner, {:uas_bye, self(), bye_msg})
  {:next_state, :terminating, state}
end
```

**Compliance: ✅** DialogStatem handles BYE matching and response per §15.1.

---

## 6. RFC 3261 Section 14: Modifying an Existing Session

### 6.1 Re-INVITE (§14.1)

**RFC Requirements:**

| Requirement | Layer | Implementation |
|-------------|-------|----------------|
| Send re-INVITE in dialog | Protocol (Dialog) | Dialog.send_request(dialog, :invite, body) |
| Same Call-ID, From/To tags | Protocol (Dialog) | Dialog maintains dialog state |
| Increment CSeq | Protocol (Dialog) | Dialog increments local_seq |
| Handle SDP offer/answer | Application (Entity) | Entity passes SDP to/from handler |

**Code Mapping:**
```elixir
# UAC sends re-INVITE (hold)
def send_reinvite(uac, sdp) do
  GenServer.call(uac, {:reinvite, sdp})
end

def handle_call({:reinvite, sdp}, _from, state) do
  # Dialog layer handles all RFC requirements
  :ok = Dialog.send_request(state.dialog, :invite, body: sdp)
  {:reply, :ok, :established, state}
end

# UAS receives re-INVITE
def handle_info({:dialog_event, {:reinvite, invite}}, state) do
  # Notify application handler
  notify(state.owner, {:uas_reinvite, self(), invite})
  # Handler will call UAS.answer with new SDP
  {:next_state, :established, state}
end
```

**Compliance: ✅** Entities delegate to Dialog layer for re-INVITE generation per §14.1.

---

## 7. CANCEL Processing

### 7.1 UAC Sending CANCEL (§9.1)

**RFC Requirements:**

| Requirement | Layer | Implementation |
|-------------|-------|----------------|
| Only before final response | Entity (UAC) | UAC validates state (:calling, :ringing) |
| CANCEL has same Request-URI, Call-ID, From, CSeq number | Protocol (Transaction) | Transaction.Client.cancel/1 |
| New Via branch | Protocol (Transaction) | Transaction.Client adds |

**Code Mapping:**
```elixir
# UAC cancels
def cancel(uac) do
  GenServer.call(uac, :cancel)
end

def calling(:call, :cancel, _from, state) do
  # Transaction layer generates proper CANCEL per RFC §9.1
  :ok = Transaction.Client.cancel(state.transaction)
  {:reply, :ok, :calling, state}
end

def ringing(:call, :cancel, _from, state) do
  :ok = Transaction.Client.cancel(state.transaction)
  {:reply, :ok, :ringing, state}
end

def established(:call, :cancel, _from, _state) do
  # Invalid state
  {:reply, {:error, :invalid_state}, :established, state}
end
```

**Compliance: ✅** UAC validates state, delegates to Transaction layer.

### 7.2 UAS Receiving CANCEL (§9.2)

**RFC Requirements:**

| Requirement | Layer | Implementation |
|-------------|-------|----------------|
| Match CANCEL to INVITE | Protocol (Transaction) | TransactionStatem matches branch |
| Send 200 OK to CANCEL | Protocol (Transaction) | Transaction.Server auto-responds |
| Send 487 to INVITE | Entity (UAS) | UAS sends 487 on notification |

**Code Mapping:**
```elixir
# UAS receives CANCEL notification from transaction layer
def handle_cast(:cancel_received, state) when state in [:incoming, :ringing] do
  # Transaction layer already sent 200 OK to CANCEL
  # UAS must send 487 to INVITE per RFC §9.2

  response = Dialog.build_response(state.dialog, 487, "Request Terminated")
  Transaction.Server.response(response, state.uas_transaction)

  notify(state.owner, {:uas_cancelled, self()})
  {:next_state, :terminated, state}
end
```

**Compliance: ✅** UAS coordinates with Transaction layer per §9.2.

---

## 8. ACK Handling

### 8.1 ACK for 2xx Response (§13.2.2.4)

**RFC Requirement:**
> ACK for 2xx is a new transaction, sent using the dialog route set.

**Compliance:**

| Aspect | Layer | Implementation |
|--------|-------|----------------|
| Generate ACK | Protocol (Dialog) | Dialog.send_ack/1 |
| Use dialog route set | Protocol (Dialog) | Dialog.route_set used |
| Same CSeq number | Protocol (Dialog) | Dialog maintains CSeq |

**Code Mapping:**
```elixir
# UAC receives 200 OK
def calling(:cast, {:tx_response, {200, response}}, data) do
  # ACK is sent via Dialog layer (not transaction)
  # Dialog uses route set per RFC §13.2.2.4
  :ok = Dialog.send_ack(data.dialog, response)

  {:next_state, :answered, data}
end
```

**Compliance: ✅** Dialog layer generates ACK per §13.2.2.4.

### 8.2 ACK for non-2xx Response (§17.1.1.3)

**RFC Requirement:**
> ACK for non-2xx is part of INVITE transaction.

**Compliance:**

| Aspect | Layer | Implementation |
|--------|-------|----------------|
| Generate ACK | Protocol (Transaction) | Transaction.Client auto-sends |
| Same Via branch | Protocol (Transaction) | Transaction uses same branch |

**Code Mapping:**
```elixir
# UAC receives 486 Busy
def calling(:cast, {:tx_response, {486, response}}, data) do
  # Transaction layer automatically sends ACK per RFC §17.1.1.3
  # No explicit action needed from UAC

  notify(data.owner, {:uac_rejected, self(), 486, response})
  {:next_state, :terminated, data}
end
```

**Compliance: ✅** Transaction layer handles per §17.1.1.3.

---

## 9. Compliance Summary

### 9.1 RFC Requirements Coverage

| RFC Section | Requirement | Compliance | Implementation Layer |
|-------------|-------------|-----------|---------------------|
| §17 | Transactions | ✅ Complete | TransactionStatem (existing) |
| §12 | Dialogs | ✅ Complete | DialogStatem (existing) |
| §13.1 | UAC INVITE | ✅ Complete | UAC + Dialog + Transaction |
| §13.2 | UAS INVITE | ✅ Complete | UAS + Dialog + Transaction |
| §15 | BYE | ✅ Complete | Entity + Dialog |
| §14 | Re-INVITE | ✅ Complete | Entity + Dialog |
| §9 | CANCEL | ✅ Complete | Entity + Transaction |
| §13.2.2.4 | ACK for 2xx | ✅ Complete | Dialog |
| §17.1.1.3 | ACK for non-2xx | ✅ Complete | Transaction |

### 9.2 Compliance Verification

**Test Methodology:**
1. Run existing SIPp scenarios against Entity layer
2. Verify protocol behavior via Wireshark captures
3. Compare headers, sequences to RFC examples

**Existing Tests (Transaction/Dialog):**
- Transaction layer: `test/parrot_sip/uac_test.exs`, `uas_test.exs`
- Dialog layer: `test/parrot_sip/dialog_test.exs`
- SIPp scenarios: `test/sipp/basic_test.exs`

**New Tests (Entity/Session):**
- Entity tests will verify delegation to lower layers
- No new protocol behavior (all RFC compliance in existing layers)

---

## 10. Non-Compliant by Design

The following RFC 3261 features are intentionally NOT implemented:

### 10.1 Registration (§10)

**Status:** NOT IMPLEMENTED in Entity/Session layer

**Rationale:**
- Registration is endpoint behavior, not call handling
- B2BUA softswitches typically don't register
- If needed, implement separate Registration module

### 10.2 Proxy Behavior (§16)

**Status:** NOT APPLICABLE

**Rationale:**
- B2BUA is back-to-back user agent, not proxy
- Different forwarding semantics
- Record-Route not used in B2BUA

### 10.3 Authentication (§22)

**Status:** Delegated to lower layers

**Rationale:**
- Transaction layer can handle auth challenges
- Application provides credentials via handler
- Not specific to entity lifecycle

---

## 11. RFC Compliance Testing

### 11.1 Test Plan

For each RFC requirement:
1. Identify which layer implements it
2. Verify existing tests cover it (Transaction/Dialog)
3. Add entity-level tests that verify proper delegation

### 11.2 Example: Verify BYE Compliance

```elixir
test "UAS sends BYE with proper headers (RFC §15.1)" do
  # Setup established call
  {:ok, uas} = UAS.start_link(invite: invite, ...)
  UAS.answer(uas, sdp: sdp)
  simulate_ack(uas)

  # Capture outgoing BYE
  capture_sip_message(fn ->
    UAS.hangup(uas)
  end)

  # Verify BYE message
  assert bye.method == :bye
  assert bye.call_id == invite.call_id  # RFC §15.1
  assert bye.from.tag == invite.to.tag  # Dialog tag
  assert bye.to.tag == invite.from.tag  # Dialog tag
  assert bye.cseq.number > invite.cseq.number  # Incremented CSeq

  # Verify route set used (if present)
  if invite.record_route do
    assert bye.route == reverse(invite.record_route)
  end
end
```

### 11.3 SIPp Conformance Tests

Run standard SIPp scenarios:
- `uac_pcap_play.xml` - Play back RFC example traces
- `uac_3pcc.xml` - Third-party call control
- `branchc.xml` - Branch parameter validation

---

## 12. Deviations and Extensions

### 12.1 Intentional Deviations

**None.** All RFC requirements are met via layering.

### 12.2 Extensions Beyond RFC

**Application-Level Features:**
- B2BUA Session coordination (not in RFC)
- Forking support (1 UAS → N UAC)
- Handler callbacks for routing
- SDP modification hooks

These are application features built ON TOP of RFC-compliant layers.

---

## 13. References

**Primary:**
- [RFC 3261] SIP: Session Initiation Protocol

**Related:**
- [RFC 3262] Reliability of Provisional Responses (PRACK)
- [RFC 3263] Locating SIP Servers (DNS SRV)
- [RFC 3264] SDP Offer/Answer Model
- [RFC 3265] SIP-Specific Event Notification (SUBSCRIBE/NOTIFY)

---

**Review Status:**
- [ ] RFC compliance verified
- [ ] Test plan approved
- [ ] Wireshark captures reviewed
- [ ] Approved by: _____________
