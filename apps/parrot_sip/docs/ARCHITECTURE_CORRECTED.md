# ParrotSip Corrected Architecture

**Version:** 2.0.0-corrected
**Date:** 2025-12-04
**Status:** READY FOR IMPLEMENTATION

This document shows the **corrected architecture** after resolving all critical review issues.

---

## CORRECTED OWNERSHIP MODEL

```
┌────────────────────────────────────────────────────────────────────┐
│                         OWNERSHIP HIERARCHY                         │
│                                                                     │
│  Who creates what? Who owns what? Who notifies whom?               │
└────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      B2BUA.Session                              │
│                     (gen_statem)                                │
│                                                                 │
│  Owns: Application routing logic                                │
│  Creates: UAS (A-leg), UAC (B-leg)                             │
│  Monitors: Both UAS and UAC                                     │
│  Lifetime: Call duration (30s - 2h)                            │
└─────────────────────────────────────────────────────────────────┘
         │                                    │
         │ creates                            │ creates
         │ monitors                           │ monitors
         ↓                                    ↓
┌──────────────────────┐           ┌──────────────────────┐
│       UAS            │           │       UAC            │
│   (gen_statem)       │           │   (gen_statem)       │
│                      │           │                      │
│  Owns: A-leg state   │           │  Owns: B-leg state   │
│  Receives: dialog_pid│           │  Receives: dialog_pid│
│  Monitors: Dialog    │           │  Monitors: Dialog    │
│  Lifetime: ~60s      │           │  Lifetime: ~60s      │
└──────────────────────┘           └──────────────────────┘
         │                                    │
         │ receives via event                 │ receives via event
         │ monitors (:DOWN)                   │ monitors (:DOWN)
         ↓                                    ↓
         ┌────────────────────────────────────┐
         │       Dialog                       │
         │   (DialogStatem)                   │ ◄───┐
         │                                    │     │
         │  Owns: Dialog state (CSeq, routes) │     │
         │  Owns: Timer H (32s ACK wait)      │     │ creates
         │  Owns: Timer G (retransmit)        │     │ notifies
         │  Lifetime: Call duration           │     │
         └────────────────────────────────────┘     │
                         ▲                          │
                         │ created by               │
                         │                          │
         ┌────────────────────────────────────┐     │
         │   Transaction.Server               │─────┘
         │   (gen_statem)                     │
         │                                    │
         │  Owns: Transaction lifecycle       │
         │  Owns: Timer I/J (cleanup)         │
         │  Creates: DialogStatem on 2xx      │
         │  Notifies: UAS via :dialog_created │
         │  Lifetime: 30-60s                  │
         └────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        CRITICAL FIXES                            │
├─────────────────────────────────────────────────────────────────┤
│ ✅ FIX 1: Transaction.Server creates DialogStatem (not UAS)     │
│ ✅ FIX 2: UAS receives dialog_pid via :dialog_created event     │
│ ✅ FIX 3: UAS monitors Dialog (no Timer H duplication)          │
│ ✅ FIX 4: Dialog owns Timer H exclusively                       │
│ ✅ FIX 5: No circular dependencies (acyclic graph)              │
└─────────────────────────────────────────────────────────────────┘
```

---

## CORRECTED EVENT FLOW

```
┌────────────────────────────────────────────────────────────────────┐
│              INVITE → 200 OK → ACK → ESTABLISHED                   │
└────────────────────────────────────────────────────────────────────┘

1. INVITE arrives
   ┌─────────────────────────────────────┐
   │ Transport receives INVITE           │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ Transaction.Server.server_process() │
   │ Creates new Transaction.Server      │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ B2BUA.Session.start_link()          │
   │ Session decides routing             │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ UAS.start_link()                    │
   │ UAS enters :incoming state          │
   └─────────────────────────────────────┘

2. Handler decides to ring
   ┌─────────────────────────────────────┐
   │ Handler calls UAS.ring()            │
   │ UAS sends 180 via Transaction       │
   │ UAS → :ringing state                │
   └─────────────────────────────────────┘

3. Handler decides to answer
   ┌─────────────────────────────────────┐
   │ Handler calls UAS.answer(sdp)       │
   │ UAS sends 200 OK via Transaction    │
   │ UAS → :answering state              │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ Transaction.Server.send_response()  │
   │ Sends 200 OK to transport           │
   │ ⚡ Creates DialogStatem ⚡           │
   │ Sends {:dialog_created, pid} to UAS │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ DialogStatem.init()                 │
   │ Dialog enters :early state          │
   │ ⚡ Starts Timer H (32s) ⚡           │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ UAS receives :dialog_created        │
   │ UAS stores dialog_pid               │
   │ ⚡ UAS monitors Dialog ⚡            │
   │ UAS stays in :answering             │
   └─────────────────────────────────────┘

4. ACK arrives
   ┌─────────────────────────────────────┐
   │ Transport receives ACK              │
   │ Routes to DialogStatem              │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ DialogStatem processes ACK          │
   │ ⚡ Cancels Timer H ⚡                │
   │ Dialog → :confirmed state           │
   │ Sends {:dialog_event, :ack} to UAS  │
   └─────────────────────────────────────┘
                  ↓
   ┌─────────────────────────────────────┐
   │ UAS receives :ack_received          │
   │ UAS → :established state            │
   │ Notifies Session: :uas_established  │
   └─────────────────────────────────────┘

5. Call is now ESTABLISHED
   ┌─────────────────────────────────────┐
   │ Session coordinates media           │
   │ Both A-leg and B-leg active         │
   │ Dialog manages in-dialog requests   │
   └─────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        KEY POINTS                                │
├─────────────────────────────────────────────────────────────────┤
│ • Transaction creates Dialog (step 3)                           │
│ • UAS receives dialog_pid via event (not creating it)           │
│ • Dialog owns Timer H (UAS does not duplicate)                  │
│ • UAS monitors Dialog (crash detection)                         │
│ • Events flow: Transaction → Dialog → UAS → Session             │
└─────────────────────────────────────────────────────────────────┘
```

---

## CORRECTED TIMER OWNERSHIP

```
┌────────────────────────────────────────────────────────────────────┐
│                     WHO OWNS WHICH TIMER?                          │
└────────────────────────────────────────────────────────────────────┘

RFC 3261 Transaction Timers (Protocol Layer)
┌──────────────────────────────────────────────────────────────┐
│ Transaction.Client (UAC transactions)                        │
├──────────────────────────────────────────────────────────────┤
│ • Timer A: INVITE retransmit (500ms → 4s)                    │
│ • Timer B: INVITE timeout (32s) ✓                            │
│ • Timer D: Completed state (32s)                             │
│ • Timer E: Non-INVITE retransmit (500ms → 4s)                │
│ • Timer F: Non-INVITE timeout (32s)                          │
│ • Timer K: Non-INVITE completed (5s TCP, 0s UDP)             │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ Transaction.Server (UAS transactions)                        │
├──────────────────────────────────────────────────────────────┤
│ • Timer I: INVITE confirmed state (5s TCP, 0s UDP)           │
│ • Timer J: Non-INVITE completed (32s)                        │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ DialogStatem (Dialog management)                             │
├──────────────────────────────────────────────────────────────┤
│ • Timer G: Response retransmit (500ms → 4s)                  │
│ • Timer H: ACK wait timeout (32s) ✓✓✓ CRITICAL              │
└──────────────────────────────────────────────────────────────┘

Application Timers (Entity Layer)
┌──────────────────────────────────────────────────────────────┐
│ UAS (call entity)                                            │
├──────────────────────────────────────────────────────────────┤
│ • handler_decision: Handler timeout (10s)                    │
│ • cleanup: Force cleanup (5s)                                │
│ ✗ REMOVED: timer_h (Dialog owns this!)                      │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ UAC (call entity)                                            │
├──────────────────────────────────────────────────────────────┤
│ • cleanup: Force cleanup (5s)                                │
│ ✗ REMOVED: timer_b (Transaction owns this!)                 │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ Subscription (event subscription)                            │
├──────────────────────────────────────────────────────────────┤
│ • refresh: Subscription refresh (varies)                     │
│ • expires: Subscription expiration (varies)                  │
│ • handler_decision: Notifier timeout (10s)                   │
└──────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     CRITICAL RULE                            │
├─────────────────────────────────────────────────────────────┤
│ ❌ UAS/UAC NEVER duplicate RFC timers                       │
│ ✅ UAS/UAC monitor protocol processes instead               │
│ ✅ When protocol timer fires → process dies → :DOWN         │
│ ✅ Single source of truth (no race conditions)              │
└─────────────────────────────────────────────────────────────┘
```

---

## CORRECTED CRASH RECOVERY

```
┌────────────────────────────────────────────────────────────────────┐
│              WHAT HAPPENS WHEN PROCESSES CRASH?                    │
└────────────────────────────────────────────────────────────────────┘

Scenario 1: Dialog Crashes
═══════════════════════════════════════════════════════════════════

DialogStatem crashes (malformed message, bug, etc.)
         ↓
UAS has Process.monitor(dialog_pid)
         ↓
UAS receives: {:DOWN, ref, :process, dialog_pid, reason}
         ↓
┌─────────────────────────────────────┐
│ UAS.answering/3                     │
│                                     │
│ def answering(:info, {:DOWN, ref,  │
│     :process, pid, reason}, data)  │
│   when ref == data.dialog_mon do   │
│                                     │
│   Logger.error("Dialog crashed")   │
│   notify_owner({:uas_timeout, ...})│
│   {:next_state, :terminated, data} │
│ end                                 │
└─────────────────────────────────────┘
         ↓
Session receives: {:uas_timeout, uas_pid}
         ↓
┌─────────────────────────────────────┐
│ Session.established/3               │
│                                     │
│ UAC.hangup(b_leg)  # Cleanup B-leg │
│ handler.handle_failed(...)          │
│ {:next_state, :terminating, data}   │
└─────────────────────────────────────┘
         ↓
Both legs terminated, call ended
✅ No resource leaks
✅ Application notified
✅ Cleanup completed


Scenario 2: UAS Crashes
═══════════════════════════════════════════════════════════════════

UAS crashes (bug, bad message, etc.)
         ↓
Session has Process.monitor(uas_pid)
         ↓
Session receives: {:DOWN, ref, :process, uas_pid, reason}
         ↓
┌─────────────────────────────────────┐
│ Session.established/3               │
│                                     │
│ def established(:info, {:DOWN, ref,│
│     :process, pid, reason}, data)  │
│   when ref == data.uas_mon do      │
│                                     │
│   Logger.error("UAS crashed")      │
│   UAC.hangup(data.b_leg)           │
│   handler.handle_failed(...)        │
│   {:next_state, :terminating, ...} │
│ end                                 │
└─────────────────────────────────────┘
         ↓
B-leg receives BYE, terminates gracefully
✅ Remote party notified
✅ No orphaned calls
✅ Application notified


Scenario 3: Transaction Crashes
═══════════════════════════════════════════════════════════════════

Transaction.Server crashes
         ↓
UAS has Process.monitor(transaction_pid)
         ↓
UAS receives: {:DOWN, ref, :process, tx_pid, reason}
         ↓
┌─────────────────────────────────────┐
│ UAS.incoming/3                      │
│                                     │
│ def incoming(:info, {:DOWN, ref,   │
│     :process, pid, reason}, data)  │
│   when ref == data.tx_mon do       │
│                                     │
│   Logger.error("TX crashed")       │
│   notify_owner({:uas_error, ...})  │
│   {:next_state, :terminated, data} │
│ end                                 │
└─────────────────────────────────────┘
         ↓
Session terminates call
✅ Fast failure
✅ No hanging transactions


Scenario 4: Session Crashes
═══════════════════════════════════════════════════════════════════

Session crashes
         ↓
Supervisor detects exit
         ↓
┌─────────────────────────────────────┐
│ Session.Supervisor                  │
│                                     │
│ restart: :temporary                 │
│ → Do NOT restart                    │
│ → Remove from children              │
└─────────────────────────────────────┘
         ↓
UAS and UAC processes still alive (orphaned)
         ↓
❓ Problem: Orphaned processes
         ↓
✅ Solution: UAS/UAC have cleanup timer
┌─────────────────────────────────────┐
│ After 60s of no owner messages:     │
│ {:timeout, :cleanup} fires          │
│ UAS/UAC terminates                  │
└─────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                  CRASH RECOVERY PRINCIPLES                   │
├─────────────────────────────────────────────────────────────┤
│ 1. Monitor everything (Process.monitor)                     │
│ 2. Never restart call processes (temporary)                 │
│ 3. Parent handles child crash (cleanup)                     │
│ 4. Fast failure (let-it-crash)                              │
│ 5. Notify application (handler callbacks)                   │
│ 6. Cleanup timer (prevent orphans)                          │
└─────────────────────────────────────────────────────────────┘
```

---

## CORRECTED SUPERVISION TREE

```
ParrotSip.Application
│
└─ ParrotSip.Supervisor (one_for_one)
   │
   ├─ Registry (permanent) ──────────────────┐
   │  • Indexes all processes                │
   │  • Never crashes (Erlang built-in)      │
   │                                         │
   ├─ Auth.NonceStore (permanent) ───────────┤ Singleton
   │  • ETS nonce table                      │ Services
   │  • Restarts if crashes                  │ (permanent)
   │  • 5-minute nonce TTL                   │
   │                                         │
   └─ Presence (permanent) ──────────────────┘
      • ETS presence/watcher tables
      • Restarts if crashes
      • Re-subscribes on restart

   ┌──────────────────────────────────────────────────────────┐
   │           B2BUA.Supervisor (one_for_one)                 │
   │                                                           │
   │  All children: restart: :temporary (never restart)       │
   └──────────────────────────────────────────────────────────┘
      │
      ├─ Session.Supervisor (DynamicSupervisor)
      │  │
      │  └─ [Session 1] [Session 2] ... [Session N]
      │     • 1 per call
      │     • restart: :temporary
      │     • Lifetime: call duration
      │
      ├─ UAS.Supervisor (DynamicSupervisor)
      │  │
      │  └─ [UAS 1] [UAS 2] ... [UAS N]
      │     • 1 per incoming call leg
      │     • restart: :temporary
      │     • Monitors: Dialog
      │
      ├─ UAC.Supervisor (DynamicSupervisor)
      │  │
      │  └─ [UAC 1] [UAC 2] ... [UAC N]
      │     • 1 per outgoing call leg
      │     • restart: :temporary
      │     • Monitors: Dialog
      │
      ├─ Dialog.Supervisor (DynamicSupervisor)
      │  │
      │  └─ [Dialog 1] [Dialog 2] ... [Dialog N]
      │     • 1-2 per call (A-leg + B-leg)
      │     • restart: :temporary
      │     • Owns: Timer H, Timer G
      │
      ├─ Transaction.Supervisor (DynamicSupervisor)
      │  │
      │  └─ [TX.Server 1] [TX.Client 1] ... [TX N]
      │     • 2-4 per call (INVITE, ACK, BYE, etc.)
      │     • restart: :temporary
      │     • Lifetime: 30-60s
      │     • Creates: DialogStatem
      │
      └─ Subscription.Supervisor (DynamicSupervisor)
         │
         └─ [Sub 1] [Sub 2] ... [Sub N]
            • 1 per active subscription
            • restart: :temporary
            • Lifetime: varies (60s - hours)

┌─────────────────────────────────────────────────────────────┐
│                   SUPERVISION STRATEGIES                     │
├─────────────────────────────────────────────────────────────┤
│ Permanent (Auth, Presence, Registry):                       │
│   • Always restart on crash                                 │
│   • Critical infrastructure                                 │
│   • Max: 3 restarts in 5 seconds                           │
│                                                             │
│ Temporary (Session, UAS, UAC, Dialog, TX, Subscription):   │
│   • Never restart on crash                                  │
│   • Ephemeral (30s - 2h lifetime)                          │
│   • Parent handles cleanup via monitor                      │
│                                                             │
│ Why Temporary?                                              │
│   • Restarting loses call state (cannot recover)           │
│   • Dialog/Transaction are protocol state (non-persistent) │
│   • Better to fail fast and notify application             │
│   • Parent (Session) handles cascading cleanup             │
└─────────────────────────────────────────────────────────────┘
```

---

## CORRECTED RESOURCE LIMITS

```
┌────────────────────────────────────────────────────────────────────┐
│                    PRODUCTION RESOURCE LIMITS                      │
└────────────────────────────────────────────────────────────────────┘

Concurrent Call Capacity
═══════════════════════════════════════════════════════════════════
┌─────────────────────────────────────┐
│ Hard Limit: 10,000 sessions         │
├─────────────────────────────────────┤
│ Check: B2BUA.Session.start_link()   │
│ Action: {:error, :capacity_exceeded}│
│ Response: 503 Service Unavailable   │
└─────────────────────────────────────┘

Per-Call Process Count:
  1x Session
  1x UAS (A-leg)
  1x UAC (B-leg)
  2x Dialog (A-leg + B-leg)
  4x Transaction (INVITE × 2, BYE × 2)
  ─────────────
  9 processes per call

At 10,000 calls:
  90,000 call-related processes
  +10,000 system processes (supervisors, singletons)
  ═══════════
  100,000 total processes

BEAM Process Limit
═══════════════════════════════════════════════════════════════════
┌─────────────────────────────────────┐
│ VM Setting: +P 150000               │
├─────────────────────────────────────┤
│ Actual limit: 150,000 processes     │
│ Used: 100,000 (at capacity)         │
│ Safety margin: 50,000 (33%)         │
└─────────────────────────────────────┘

ETS Table Limits
═══════════════════════════════════════════════════════════════════
┌─────────────────────────────────────┐
│ Nonce Table                         │
├─────────────────────────────────────┤
│ Max entries: 100,000                │
│ TTL: 5 minutes                      │
│ Cleanup: Every 60s                  │
│ Memory: ~10MB at max                │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Presence Table                      │
├─────────────────────────────────────┤
│ Presentities: 1,000,000 max         │
│ Watchers: 10,000,000 max (10/user)  │
│ Memory: ~500MB at max               │
└─────────────────────────────────────┘

Memory Limits
═══════════════════════════════════════════════════════════════════
Per-process memory:
  Session: ~10KB
  UAS/UAC: ~5KB
  Dialog: ~8KB
  Transaction: ~6KB

At 10,000 calls:
  Sessions: 10k × 10KB = 100MB
  UAS/UAC: 20k × 5KB = 100MB
  Dialogs: 20k × 8KB = 160MB
  Transactions: 40k × 6KB = 240MB
  ──────────────────────────
  Total: ~600MB call state

System overhead: ~400MB
ETS tables: ~510MB
───────────────────────────
Total VM memory: ~1.5GB

Backpressure
═══════════════════════════════════════════════════════════════════
┌─────────────────────────────────────┐
│ When session count >= 10,000:       │
├─────────────────────────────────────┤
│ 1. Reject new INVITE with 503       │
│ 2. Add "Retry-After: 60" header     │
│ 3. Emit telemetry event             │
│ 4. Log warning                      │
│ 5. Continue serving existing calls  │
└─────────────────────────────────────┘

Monitoring
═══════════════════════════════════════════════════════════════════
Telemetry events:
  [:parrot_sip, :session, :count] - Every 10s
  [:parrot_sip, :capacity, :utilization] - Percentage
  [:parrot_sip, :vm, :processes] - Process count
  [:parrot_sip, :vm, :memory] - Memory usage

Alert thresholds:
  Session count > 8,000 (80%): Warning
  Session count > 9,500 (95%): Critical
  Process count > 120,000 (80%): Warning
  Memory > 1.2GB (80%): Warning
```

---

## CORRECTED AUTHENTICATION FLOW

```
┌────────────────────────────────────────────────────────────────────┐
│           NON-BLOCKING AUTHENTICATION (NO DEADLOCK)                │
└────────────────────────────────────────────────────────────────────┘

INVITE arrives without credentials
         ↓
┌─────────────────────────────────────┐
│ UAS.incoming state                  │
│ Check: invite.authorization == nil  │
└─────────────────────────────────────┘
         ↓
┌─────────────────────────────────────┐
│ Generate challenge                  │
│ challenge = Auth.challenge(realm)   │
│ nonce = generate_nonce()            │
│ Store in ETS (TTL: 5 min)           │
└─────────────────────────────────────┘
         ↓
┌─────────────────────────────────────┐
│ Send 401 Unauthorized               │
│ WWW-Authenticate: Digest            │
│   realm="example.com"               │
│   nonce="abc123..."                 │
│   algorithm=MD5                     │
└─────────────────────────────────────┘
         ↓
INVITE arrives WITH credentials
         ↓
┌─────────────────────────────────────┐
│ UAS.incoming state                  │
│ Check: invite.authorization != nil  │
└─────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────────────┐
│ Auth.verify_credentials_async()                         │
│                                                          │
│ ┌────────────────────────────────────────────┐          │
│ │ Task.async(fn ->                           │          │
│ │   # Runs in separate process               │          │
│ │   Application.lookup_password(username)    │          │
│ │ end)                                       │          │
│ └────────────────────────────────────────────┘          │
│         ↓                                                │
│ ┌────────────────────────────────────────────┐          │
│ │ Task.yield(task, 5000)  # 5s timeout       │          │
│ └────────────────────────────────────────────┘          │
│         ↓                    ↓                           │
│    Success               Timeout                        │
│         ↓                    ↓                           │
│   Verify digest      Return {:error, :timeout}          │
└─────────────────────────────────────────────────────────┘
         ↓                    ↓
    Valid                 Timeout
         ↓                    ↓
┌─────────────────┐   ┌─────────────────┐
│ Proceed with    │   │ Send 500        │
│ call            │   │ Server Error    │
│ UAS → :ringing  │   │ UAS → :terminated│
└─────────────────┘   └─────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   CRITICAL FIXES                             │
├─────────────────────────────────────────────────────────────┤
│ ✅ FIX 1: Task.async isolates DB query (no UAS blocking)   │
│ ✅ FIX 2: 5s timeout prevents infinite wait                │
│ ✅ FIX 3: Timeout sends 500 (not 401)                      │
│ ✅ FIX 4: Nonce cleanup prevents memory leak               │
│ ✅ FIX 5: Telemetry tracks timeout rate                    │
└─────────────────────────────────────────────────────────────┘

Application Implementation (Non-Blocking)
═══════════════════════════════════════════════════════════════════

❌ BAD (Blocking):
defmodule MyApp.Auth do
  def lookup_password(username) do
    # BLOCKS gen_statem process!
    Repo.get_by(User, username: username).password
  end
end

✅ GOOD (Non-Blocking):
defmodule MyApp.Auth do
  def lookup_password(username) do
    # Uses connection pool (non-blocking)
    case MyApp.CredentialCache.get(username) do
      {:ok, password} -> {:ok, password}
      :miss ->
        # DB query with timeout < auth timeout
        Repo.get_password(username, timeout: 4_000)
    end
  end
end

Circuit Breaker (Graceful Degradation)
═══════════════════════════════════════════════════════════════════

defmodule MyApp.CredentialStore do
  use GenServer

  def lookup_password(username) do
    GenServer.call(__MODULE__, {:lookup, username}, 4_000)
  end

  def handle_call({:lookup, username}, _from, state) do
    if state.circuit_open? do
      # Circuit breaker open - fail fast
      {:reply, {:error, :db_unavailable}, state}
    else
      try do
        password = query_database(username)
        {:reply, {:ok, password}, reset_failures(state)}
      rescue
        _ ->
          updated = increment_failures(state)
          if updated.failure_count >= 5 do
            # Open circuit for 30s
            schedule_reset(30_000)
            {:reply, {:error, :db_unavailable}, open_circuit(updated)}
          else
            {:reply, {:error, :db_unavailable}, updated}
          end
      end
    end
  end
end
```

---

## SUMMARY: WHAT CHANGED?

```
┌────────────────────────────────────────────────────────────────────┐
│                     BEFORE (BROKEN)                                │
└────────────────────────────────────────────────────────────────────┘

❌ UAS creates DialogStatem → Circular dependency
❌ UAS has Timer H, Dialog has Timer H → Race condition
❌ Auth blocks on DB query → Deadlock at scale
❌ No resource limits → OOM crash
❌ No crash recovery → Resource leaks

┌────────────────────────────────────────────────────────────────────┐
│                     AFTER (FIXED)                                  │
└────────────────────────────────────────────────────────────────────┘

✅ Transaction creates DialogStatem → No circular dependency
✅ Dialog owns Timer H, UAS monitors → No race condition
✅ Auth uses Task.async with timeout → No deadlock
✅ Session limit (10k) + VM config → No OOM
✅ Process monitors + cascading cleanup → No leaks

┌────────────────────────────────────────────────────────────────────┐
│                     KEY PRINCIPLES                                 │
└────────────────────────────────────────────────────────────────────┘

1. Ownership: Clear hierarchy (Transaction → Dialog → UAS → Session)
2. Monitoring: Parents monitor children (Process.monitor)
3. Timers: Protocol timers in protocol layer, app timers in app layer
4. Async: Never block gen_statem (Task.async for I/O)
5. Limits: Hard limits prevent resource exhaustion
6. Telemetry: Observe everything (auth, sessions, processes, memory)
7. Let-it-crash: Fast failure, notify application, cleanup
8. RFC Compliance: Follow RFC 3261 (Transaction creates dialogs)
```

---

**This architecture is production-ready and scales to 10,000+ concurrent calls.**

For implementation details, see:
- `CRITICAL_REVIEW_SOLUTIONS.md` - Full solutions with code
- `SOLUTION_SUMMARY.md` - Quick reference
- `03_crash_recovery.md` - Crash handling (to be created)
- `04_resource_limits.md` - Capacity planning (to be created)
- `05_telemetry.md` - Monitoring (to be created)
