# TransactionStatem RFC 3261 Behavior Catalog

This document catalogs all behaviors TransactionStatem should exhibit according to RFC 3261 Section 17. These behaviors form the specification for behavioral tests.

## Transaction Types (RFC 3261 Section 17)

| Type | Initial State | RFC Section |
|------|---------------|-------------|
| INVITE Client | `:calling` | 17.1.1 |
| INVITE Server | `:proceeding` (after auto-100) | 17.2.1 |
| Non-INVITE Client | `:trying` | 17.1.2 |
| Non-INVITE Server | `:trying` | 17.2.2 |

---

## INVITE Server Transaction Behaviors (RFC 3261 Section 17.2.1)

### IST-1: Auto-100 Trying on INVITE Receipt
**RFC Reference**: Section 17.2.1 - "When a server receives an INVITE request, it MUST send a 100 (Trying) response."
**Observable Behavior**: When an INVITE is received, a 100 Trying response is automatically sent.
**Test Method**: Verify handler receives/sends 100 Trying response.

### IST-2: Provisional Response Keeps Proceeding State
**RFC Reference**: Section 17.2.1 - "Any provisional response... leaves the transaction in the proceeding state."
**Observable Behavior**: After sending 1xx response, transaction accepts more provisionals or final.
**Test Method**: Send 180 Ringing, then 200 OK - both should succeed without error.

### IST-3: 2xx Response Terminates Immediately
**RFC Reference**: Section 17.2.1 - "If a 2xx response is passed to the transport, the transaction MUST transition to the terminated state."
**Observable Behavior**: Transaction terminates after 200 OK (process exits).
**Test Method**: Send 200 OK, verify process terminates with normal exit.

### IST-4: Non-2xx Final Response Starts Timer G and H
**RFC Reference**: Section 17.2.1 - Timer G (retransmit response) and H (timeout)
**Observable Behavior**: After 4xx-6xx response, response is retransmitted periodically until ACK or timeout.
**Test Method**: Send 404, verify response retransmission occurs (via handler/transport).

### IST-5: ACK Transitions to Confirmed, Cancels G/H, Starts I
**RFC Reference**: Section 17.2.1 - "When an ACK is received... the transaction MUST transition to the confirmed state."
**Observable Behavior**: ACK stops retransmissions, transaction enters linger period.
**Test Method**: After 404, send ACK, verify no more retransmissions occur.

### IST-6: Timer I Fires = Terminate
**RFC Reference**: Section 17.2.1 - Timer I is 5s for TCP, T4 (5s) for UDP.
**Observable Behavior**: Transaction terminates after Timer I in confirmed state.
**Test Method**: After ACK received, verify process eventually terminates.

### IST-7: Timer H Fires = Terminate (No ACK)
**RFC Reference**: Section 17.2.1 - Timer H is 64*T1 (32s default).
**Observable Behavior**: If no ACK received, transaction terminates with timeout.
**Test Method**: Send 404, don't send ACK, verify timeout callback/termination.

### IST-8: Request Retransmission in Proceeding Retransmits Last Response
**RFC Reference**: Section 17.2.1 - "If a request retransmission is received while in the proceeding state, the most recent provisional response... MUST be retransmitted."
**Observable Behavior**: Duplicate INVITE -> retransmit current response.
**Test Method**: Send INVITE, 180, INVITE again -> verify 180 sent again.

### IST-9: Request Retransmission in Completed Retransmits Final Response
**RFC Reference**: Section 17.2.1 - Similar retransmission behavior in completed.
**Observable Behavior**: Duplicate INVITE in completed -> retransmit final response.
**Test Method**: Send INVITE, 404, INVITE again -> verify 404 sent again.

### IST-10: CANCEL in Proceeding Sends 487
**RFC Reference**: Section 9.2 - "If the UAS has not issued a final response... it SHOULD generate a 487 (Request Terminated) response."
**Observable Behavior**: CANCEL causes 487 to be sent for the INVITE.
**Test Method**: INVITE, 180, CANCEL -> verify 487 sent.

---

## Non-INVITE Server Transaction Behaviors (RFC 3261 Section 17.2.2)

### NIST-1: Starts in Trying State
**RFC Reference**: Section 17.2.2 - "The transaction is in the trying state."
**Observable Behavior**: Transaction accepts responses (no auto-100).
**Test Method**: Send REGISTER, immediately send 200 OK - should succeed.

### NIST-2: Provisional Response Transitions to Proceeding
**RFC Reference**: Section 17.2.2 - "If a provisional response is passed to the transport while in the trying state, the transaction enters the proceeding state."
**Observable Behavior**: After 100, can still send more provisionals or final.
**Test Method**: Send REGISTER, 100, 200 OK - all should succeed.

### NIST-3: Final Response Transitions to Completed, Starts Timer J
**RFC Reference**: Section 17.2.2 - Timer J is 32s.
**Observable Behavior**: After final response, transaction lingers for retransmissions.
**Test Method**: Send REGISTER, 200 OK, verify transaction still alive for retransmissions.

### NIST-4: Timer J Fires = Terminate
**RFC Reference**: Section 17.2.2 - "Timer J fires, terminating the transaction."
**Observable Behavior**: Transaction terminates after Timer J.
**Test Method**: Verify process eventually terminates.

### NIST-5: Request Retransmission Retransmits Last Response
**RFC Reference**: Section 17.2.2 - "The server transaction MUST pass the response to the transport layer for retransmission."
**Observable Behavior**: Duplicate request -> retransmit last response.
**Test Method**: Send REGISTER, 100, REGISTER -> verify 100 sent again.

### NIST-6: CANCEL Does NOT Send 487
**RFC Reference**: Section 9.2 - CANCEL only applies to INVITE.
**Observable Behavior**: CANCEL on non-INVITE is ignored (no 487).
**Test Method**: REGISTER, CANCEL -> verify no 487, transaction unchanged.

---

## INVITE Client Transaction Behaviors (RFC 3261 Section 17.1.1)

### ICT-1: Starts in Calling State, Sends INVITE
**RFC Reference**: Section 17.1.1 - "The client transaction... MUST pass the request to the transport layer for transmission."
**Observable Behavior**: INVITE is sent immediately on transaction creation.
**Test Method**: Create transaction, verify INVITE sent via transport.

### ICT-2: Timer A for Retransmission (UDP)
**RFC Reference**: Section 17.1.1.2 - Timer A is T1 (500ms), exponential backoff.
**Observable Behavior**: INVITE retransmitted if no response.
**Test Method**: Create transaction, don't respond, verify retransmission.

### ICT-3: Timer B Timeout
**RFC Reference**: Section 17.1.1.2 - Timer B is 64*T1 (32s).
**Observable Behavior**: Callback receives `{:stop, :timeout}` after Timer B.
**Test Method**: Create transaction, don't respond, verify timeout callback.

### ICT-4: 1xx Response Transitions to Proceeding
**RFC Reference**: Section 17.1.1 - "A provisional response is passed to the TU, and the client transaction enters the proceeding state."
**Observable Behavior**: Callback receives response, can still receive more responses.
**Test Method**: Send 100, 180 responses, verify both delivered to callback.

### ICT-5: 2xx Response Terminates Transaction
**RFC Reference**: Section 17.1.1 - "The client transaction MUST transition to the terminated state."
**Observable Behavior**: Callback receives 200, transaction terminates.
**Test Method**: Send 200, verify callback and process termination.

### ICT-6: Non-2xx Final Response Transitions to Completed
**RFC Reference**: Section 17.1.1 - "The client transaction... enters the completed state."
**Observable Behavior**: Callback receives response, ACK is sent automatically.
**Test Method**: Send 404, verify callback, verify ACK sent.

### ICT-7: Cancel Sets Flag and Sends CANCEL Request
**RFC Reference**: Section 9.1 - "CANCEL request SHOULD be sent."
**Observable Behavior**: After cancel, CANCEL request is sent, transaction waits for response.
**Test Method**: Call `client_cancel/1`, verify CANCEL sent.

### ICT-8: Cancel Timeout (No Final Response)
**RFC Reference**: Section 9.1 - If no response to CANCEL, client handles timeout.
**Observable Behavior**: Callback receives `{:stop, :timeout}`.
**Test Method**: Cancel, don't respond, verify timeout callback.

---

## Non-INVITE Client Transaction Behaviors (RFC 3261 Section 17.1.2)

### NICT-1: Starts in Trying State, Sends Request
**RFC Reference**: Section 17.1.2 - "The client transaction... MUST pass the request to the transport layer for transmission."
**Observable Behavior**: Request sent immediately.
**Test Method**: Create transaction, verify request sent.

### NICT-2: Timer E for Retransmission (UDP)
**RFC Reference**: Section 17.1.2.2 - Timer E like Timer A.
**Observable Behavior**: Request retransmitted if no response.
**Test Method**: Don't respond, verify retransmission.

### NICT-3: Timer F Timeout
**RFC Reference**: Section 17.1.2.2 - Timer F is 64*T1 (32s).
**Observable Behavior**: Callback receives `{:stop, :timeout}`.
**Test Method**: Don't respond, verify timeout callback.

### NICT-4: Final Response Transitions to Completed
**RFC Reference**: Section 17.1.2 - "A final response... moves the transaction to the completed state."
**Observable Behavior**: Callback receives response.
**Test Method**: Send 200, verify callback.

### NICT-5: Timer K Lingers in Completed
**RFC Reference**: Section 17.1.2.2 - Timer K is T4 (5s) for UDP, 0 for TCP.
**Observable Behavior**: Transaction lingers, then terminates.
**Test Method**: Verify process eventually terminates.

---

## Owner Monitoring Behaviors

### OWN-1: Server Owner Death Sends Auto-Response
**RFC Reference**: Implementation-specific reliability.
**Observable Behavior**: If owner dies before final, auto-response (e.g., 503) is sent.
**Test Method**: Set owner, kill owner, verify response sent.

### OWN-2: Server Owner Death After Final = No Action
**Observable Behavior**: If final already sent, owner death has no effect.
**Test Method**: Send 200, set owner, kill owner, verify no additional response.

### OWN-3: Client Owner Death Cancels Transaction
**Observable Behavior**: If owner dies, transaction is cancelled.
**Test Method**: Set owner, kill owner, verify cancelled.

---

## API Behaviors

### API-1: `server_cancel/1` Returns 481 for Non-Existent Transaction
**Observable Behavior**: Returns `{:reply, %Message{status_code: 481}}`.
**Test Method**: Call with non-existent branch, verify 481.

### API-2: `server_cancel/1` Returns 200 for Existing Transaction
**Observable Behavior**: Returns `{:reply, %Message{status_code: 200}}`.
**Test Method**: Create INVITE transaction, call server_cancel, verify 200.

### API-3: `count/0` Returns Active Transaction Count
**Observable Behavior**: Returns number of registered transactions.
**Test Method**: Create transactions, verify count increases.

### API-4: `server_process/2` Routes to Existing Transaction
**Observable Behavior**: Retransmissions go to same transaction.
**Test Method**: Process same request twice, verify single transaction.

### API-5: `server_process/2` Creates New Transaction for New Request
**Observable Behavior**: New requests create new transactions.
**Test Method**: Verify count increases.

---

## Testing Strategy

### What We DON'T Test (Implementation Details)
- Internal state structure (`:sys.get_state`)
- Timer references
- Internal flags (cancelled, owner_mon, etc.)
- State machine state names directly

### What We DO Test (Observable Behaviors)
1. **Responses sent** - Via mock transport or handler
2. **Callbacks invoked** - Via test process message receiving
3. **Process lifecycle** - `Process.monitor/1` + `assert_receive {:DOWN, ...}`
4. **Retransmission timing** - Wait and verify retransmission occurs
5. **Timeout behavior** - Use short test timeouts and verify callbacks
6. **Message routing** - Verify messages reach correct transactions

### Public API Additions Needed
To test behaviors without `:sys.get_state`, we need:

1. **`get_state/1`** - Returns current state name (`:trying`, `:proceeding`, etc.)
   - This is a legitimate public API for debugging/monitoring
   - Tests use it to verify state transitions occurred

2. **Consider**: Response capture via handler/transport mock instead of internal inspection
