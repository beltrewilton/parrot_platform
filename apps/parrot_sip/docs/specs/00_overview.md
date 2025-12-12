# ParrotSip Complete SIP Stack Architecture Specification

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-04

## 1. Introduction

### 1.1 Purpose

This specification defines the architecture for a **complete SIP implementation** in Elixir, including:
- Call handling (UAS/UAC/B2BUA)
- SIP authentication (digest auth per RFC 2617)
- Event subscriptions (SUBSCRIBE/NOTIFY per RFC 3265)
- Presence (per RFC 3856/3863)

### 1.2 Complete SIP Feature Scope

**IN SCOPE (v1.0):**
- ✅ User Agent Server (UAS) - Receive calls
- ✅ User Agent Client (UAC) - Make calls
- ✅ Back-to-Back User Agent (B2BUA) - Bridge calls
- ✅ SIP Authentication - Digest authentication (RFC 2617)
- ✅ SUBSCRIBE/NOTIFY - Event framework (RFC 3265)
- ✅ Presence - Presence state management (RFC 3856, 3863)
- ✅ Message Waiting Indication (MWI)
- ✅ Dialog Event Package
- ✅ Registration (REGISTER method)

**DEFERRED (v2.0+):**
- Media handling (RTP/RTCP) - Use external media server
- Codec negotiation helpers
- NAT traversal (STUN/TURN/ICE)
- Conference bridging (MCU functionality)
- SIP over WebSocket (transport layer)
- MESSAGE method (instant messaging)

---

## 2. Complete Architecture Overview

### 2.1 Four-Layer Design

```
┌──────────────────────────────────────────────────────────────┐
│  Layer 4: Application Modules                                 │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐ │
│  │ B2BUA.Session  │  │ Presence       │  │ MWI            │ │
│  │ (gen_statem)   │  │ (GenServer)    │  │ (GenServer)    │ │
│  │                │  │                │  │                │ │
│  │ - Coordinates  │  │ - Manages      │  │ - Voicemail    │ │
│  │   call legs    │  │   presence     │  │   notifications│ │
│  │ - Routing      │  │   state        │  │ - Uses         │ │
│  │ - Bridging     │  │ - Watchers     │  │   Subscription │ │
│  └────────────────┘  │ - Presentities │  └────────────────┘ │
│                      │ - Uses         │                      │
│                      │   Subscription │                      │
│                      └────────────────┘                      │
└──────────────────────────────────────────────────────────────┘
                              ↓ uses
┌──────────────────────────────────────────────────────────────┐
│  Layer 3: Entity Management                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ UAS          │  │ UAC          │  │ Subscription     │  │
│  │ (gen_statem) │  │ (gen_statem) │  │ (gen_statem)     │  │
│  │              │  │              │  │                  │  │
│  │ INVITE       │  │ INVITE       │  │ SUBSCRIBE/NOTIFY │  │
│  │ server       │  │ client       │  │ dialog           │  │
│  │              │  │              │  │                  │  │
│  │ States:      │  │ States:      │  │ States:          │  │
│  │  incoming    │  │  initiating  │  │  pending         │  │
│  │  trying      │  │  calling     │  │  active          │  │
│  │  ringing     │  │  ringing     │  │  terminated      │  │
│  │  answering   │  │  answered    │  │                  │  │
│  │  established │  │  established │  │                  │  │
│  │  terminating │  │  terminating │  │                  │  │
│  │  terminated  │  │  terminated  │  │                  │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Authentication (Middleware)                           │   │
│  │ - Digest challenge/response (RFC 2617)                │   │
│  │ - Credential validation                               │   │
│  │ - Used by: UAS, UAC, Subscription, Registrar         │   │
│  └──────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
                              ↓ uses
┌──────────────────────────────────────────────────────────────┐
│  Layer 2: Protocol (Existing - RFC 3261 Compliant)           │
│  ┌────────────────────────┐  ┌─────────────────────┐        │
│  │ DialogStatem           │  │ Transaction Layer   │        │
│  │ (gen_statem)           │  │                     │        │
│  │                        │  │ - Client            │        │
│  │ - Dialog states        │  │ - Server            │        │
│  │ - Sequence numbers     │  │ - Retransmissions   │        │
│  │ - Route sets           │  │ - Timers (A-K)      │        │
│  │ - In-dialog requests   │  │                     │        │
│  └────────────────────────┘  └─────────────────────┘        │
└──────────────────────────────────────────────────────────────┘
                              ↓ uses
┌──────────────────────────────────────────────────────────────┐
│  Layer 1: Transport (Existing)                                │
│  - UDP, TCP, TLS transports                                   │
│  - Message parsing/serialization                              │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 Module Relationships

```
Application Modules (Layer 4)
├─ B2BUA.Session
│  ├─ uses: UAS, UAC
│  └─ coordinates: call bridging, routing

├─ Presence
│  ├─ uses: Subscription (for SUBSCRIBE/NOTIFY)
│  ├─ stores: presence state (ETS/DB)
│  └─ generates: PIDF+XML documents

└─ MWI (Message Waiting Indication)
   ├─ uses: Subscription
   └─ notifies: voicemail status

Entity Management (Layer 3)
├─ UAS (INVITE server)
├─ UAC (INVITE client)
├─ Subscription (SUBSCRIBE/NOTIFY)
└─ Authentication (middleware)
   ├─ used by: UAS, UAC, Subscription, Registrar
   └─ provides: digest auth helpers

Protocol Layer (Layer 2) - Existing
├─ DialogStatem
│  ├─ creates: itself via Dialog.Supervisor.start_child/1
│  ├─ registers: in Registry with deterministic dialog_id
│  └─ discovered by: Entity via Registry.lookup/2
└─ Transaction.{Client,Server}

Transport Layer (Layer 1) - Existing
```

### 2.3 Dialog Ownership Pattern (Critical Architecture Detail)

**Problem:** How does an Entity (UAS/UAC) find and own its Dialog process?

**Solution:** Dialog Self-Creation + Registry-Based Discovery

**Flow:**
1. **Dialog creates itself** when Transaction layer sends/receives 200 OK
   - Transaction calls `Dialog.Supervisor.start_child({:uas, resp, req})`
   - Dialog registers with deterministic ID: `"dialog:uas:#{call_id}:#{local_tag}:#{remote_tag}"`

2. **Entity discovers Dialog** via Registry lookup
   - Entity constructs same dialog_id from INVITE fields
   - Entity calls `Registry.lookup(ParrotSip.Registry, dialog_id)`
   - Always succeeds because Dialog creates itself first

3. **Entity registers as owner**
   - Entity calls `Dialog.set_owner(dialog_pid, dialog_id)`
   - Dialog monitors Entity via `Process.monitor(entity_pid)`
   - Dialog sends events to Entity: `{:dialog_event, :ack_received}`

**Why This Works:**
- ✅ No race conditions - Dialog exists before Entity needs it
- ✅ No message passing required for discovery - pure Registry lookup
- ✅ Deterministic IDs - both sides compute same value
- ✅ Already implemented in existing `dialog_statem.ex` code

**Code References:**
- Dialog self-creation: `apps/parrot_sip/lib/parrot_sip/dialog_statem.ex:792-799`
- Registry lookup: `apps/parrot_sip/lib/parrot_sip/dialog_statem.ex:286-297`
- set_owner/2: `apps/parrot_sip/lib/parrot_sip/dialog_statem.ex:501-510`
- Monitoring: `apps/parrot_sip/lib/parrot_sip/dialog_statem.ex:656-667`

---

## 3. Elixir/Erlang/OTP Best Practices

**All ParrotSip implementations MUST follow these principles:**

### 3.1 Pattern Matching Over Conditionals

```elixir
# Good
def handle_response(%{status_code: code} = resp) when code >= 200 and code < 300 do
  handle_success(resp)
end

def handle_response(%{status_code: code} = resp) when code >= 300 do
  handle_error(resp)
end

# Avoid
def handle_response(resp) do
  if resp.status_code >= 200 and resp.status_code < 300 do
    handle_success(resp)
  else
    handle_error(resp)
  end
end
```

### 3.2 Recursion Over Iteration

```elixir
# Good - tail-recursive
def notify_all([], _state), do: :ok
def notify_all([sub | rest], state) do
  Subscription.notify(sub, state)
  notify_all(rest, state)
end

# Avoid
def notify_all(subscriptions, state) do
  Enum.each(subscriptions, fn sub ->
    Subscription.notify(sub, state)
  end)
end
```

### 3.3 Immutable Data Structures

```elixir
# Good
data = %{data | state: :established, dialog: dialog_pid}

# Avoid (mutable operations)
# N/A in Elixir - language enforces this
```

### 3.4 Process-Per-Entity

```elixir
# Good - each call leg is a process
{:ok, uas_pid} = UAS.start_link(invite: invite, owner: self())

# Avoid - entities as data in single GenServer
# entities = Map.put(state.entities, id, %Entity{})
```

### 3.5 gen_statem for State Machines

```elixir
# Good
defmodule UAS do
  use :gen_statem

  def callback_mode, do: :state_functions

  def incoming({:call, from}, {:ring, opts}, data) do
    send_180_ringing(data)
    {:next_state, :ringing, data, [{:reply, from, :ok}]}
  end
end

# Avoid GenServer for complex state machines
```

### 3.6 Let-It-Crash Philosophy

```elixir
# Good - let invalid states crash
def established(:cast, {:answer, _sdp}, _data) do
  # This is invalid - crash with function_clause
  :error
end

# Avoid defensive programming
def established(:cast, {:answer, _sdp}, data) do
  Logger.warn("Cannot answer in established state")
  {:keep_state, data}
end
```

### 3.7 Supervision Trees

```elixir
# Good - supervised dynamic children
children = [
  {DynamicSupervisor, strategy: :one_for_one, name: UAS.Supervisor}
]

DynamicSupervisor.start_child(UAS.Supervisor, {UAS, opts})

# Avoid - unsupervised processes
spawn(fn -> UAS.run(opts) end)
```

### 3.8 Process Monitoring

```elixir
# Good - monitor dependencies
ref = Process.monitor(dialog_pid)
data = %{data | dialog: dialog_pid, dialog_ref: ref}

def handle_info({:DOWN, ref, :process, pid, reason}, state, data) do
  # Handle crash
end
```

### 3.9 Registry for Discovery

```elixir
# Good - deterministic IDs + Registry
dialog_id = build_dialog_id(:uas, call_id, local_tag, remote_tag)
{:ok, pid} = Registry.lookup(ParrotSip.Registry, dialog_id)

# Avoid - PID passing via messages
send(coordinator, {:dialog_created, dialog_pid})
```

### 3.10 Minimal Code

- No over-commenting (code should be self-documenting)
- No defensive nil checks (let it crash)
- No unnecessary abstractions
- Pattern matching makes logic clear

**Example of Clean Code:**
```elixir
def incoming({:call, from}, {:answer, sdp}, data) do
  response = build_200_ok(data.invite, sdp)
  Server.response(response, data.uas)
  dialog_id = build_dialog_id(data.invite)
  {:next_state, :answering, %{data | dialog_id: dialog_id}, [{:reply, from, :ok}]}
end
```

---

## 4. Feature Modules in Detail

### 3.1 Authentication Module

**Purpose:** SIP digest authentication per RFC 2617/3261 §22

**Architecture:** Middleware/Helper (not a process)

```elixir
defmodule ParrotSip.Auth do
  @moduledoc """
  SIP Digest Authentication (RFC 2617).

  Used by:
  - UAS/UAC for call authentication
  - Subscription for subscription authentication
  - Registrar for registration authentication
  """

  # Generate challenge
  def challenge(realm, opts \\ [])

  # Verify credentials
  def verify_credentials(authorization_header, credentials, method, uri)

  # Add auth header to request
  def add_authorization(request, username, password, challenge)
end
```

**Integration Points:**
```elixir
# In UAS - Challenge incoming call
def handle_invite(uas, invite, args) do
  case check_auth_required(invite) do
    :required ->
      challenge = Auth.challenge("example.com")
      send_401(challenge)

    :authenticated ->
      # Proceed with call
      create_uas_entity(invite)
  end
end

# In UAC - Respond to 401/407
def handle_401(uac, response) do
  authorization = Auth.add_authorization(
    uac.request,
    username,
    password,
    response.www_authenticate
  )
  retry_with_auth(authorization)
end
```

**Credential Storage:**
- Library provides pure auth functions (challenge/verify)
- Applications provide credential lookup (callback, ETS, database, etc.)
- No database dependency in library

**Comparison to OpenSIPS:**
- OpenSIPS: `auth` module + `auth_db` module
- Our approach: Single `Auth` module with optional DB backend
- Similar API: challenge/verify pattern

---

### 3.2 Subscription Module

**Purpose:** SUBSCRIBE/NOTIFY event framework (RFC 3265)

**Architecture:** gen_statem (parallel to UAS/UAC)

```elixir
defmodule ParrotSip.Subscription do
  @moduledoc """
  SUBSCRIBE/NOTIFY subscription state machine (RFC 3265).

  Handles:
  - SUBSCRIBE requests (create subscription)
  - NOTIFY generation (send event notifications)
  - Subscription expiration
  - Subscription refresh

  Used by:
  - Presence module
  - MWI module
  - Dialog event package
  - Custom event packages
  """

  use :gen_statem

  @type state :: :pending | :active | :terminated

  # Server: Accept SUBSCRIBE
  def accept_subscription(subscription, opts)

  # Server: Send NOTIFY
  def notify(subscription, event_state, content_type, body)

  # Server: Terminate subscription
  def terminate_subscription(subscription)

  # Client: Create subscription
  def subscribe(event_package, resource_uri, opts)

  # Client: Refresh subscription
  def refresh(subscription, expires)

  # Client: Unsubscribe
  def unsubscribe(subscription)
end
```

**State Machine:**
```
Subscription Server (Notifier):
  :pending     → :active      (SUBSCRIBE accepted)
  :active      → :active      (SUBSCRIBE refresh)
  :active      → :terminated  (Expires or unsubscribe)

Subscription Client (Subscriber):
  :pending     → :active      (200 OK + NOTIFY received)
  :active      → :active      (NOTIFY received)
  :active      → :terminated  (Unsubscribe or timeout)
```

**Example Usage:**
```elixir
# Server side (Presence)
def handle_subscribe(presence, subscribe_msg) do
  # Create subscription
  {:ok, subscription} = Subscription.accept_subscription(
    event: "presence",
    resource: subscribe_msg.to.uri,
    subscriber: subscribe_msg.from.uri,
    expires: 3600
  )

  # Send initial NOTIFY
  state = get_presence_state(subscribe_msg.to.uri)
  Subscription.notify(subscription, state, "application/pidf+xml", pidf_body)
end

# When presence changes
def publish_presence_update(presentity_uri, new_state) do
  # Find all subscriptions for this presentity
  subscriptions = find_subscriptions(presentity_uri)

  # Send NOTIFY to all subscribers
  Enum.each(subscriptions, fn sub ->
    Subscription.notify(sub, new_state, "application/pidf+xml", build_pidf(new_state))
  end)
end
```

**Comparison to OpenSIPS:**
- OpenSIPS: `presence` module handles both SUBSCRIBE/NOTIFY and state
- Our approach: Separate Subscription (protocol) from Presence (application)
- More modular, easier to implement custom event packages

---

### 3.3 Presence Module

**Purpose:** SIP presence state management (RFC 3856, 3863)

**Architecture:** GenServer + ETS/DB backend

```elixir
defmodule ParrotSip.Presence do
  @moduledoc """
  Presence state management (RFC 3856, 3863).

  Manages:
  - Presentities (users who publish presence)
  - Watchers (users who subscribe to presence)
  - Presence state (available, busy, away, etc.)
  - PIDF document generation

  Uses Subscription module for SUBSCRIBE/NOTIFY.
  """

  use GenServer

  # Publish presence (from UA)
  def publish(presentity_uri, presence_state, opts \\ [])

  # Subscribe to presence (creates Subscription)
  def subscribe(watcher_uri, presentity_uri, opts \\ [])

  # Get current presence
  def get_presence(presentity_uri)

  # List watchers
  def list_watchers(presentity_uri)
end
```

**Data Model:**
```elixir
# Presentity (person publishing presence)
%Presentity{
  uri: "sip:alice@example.com",
  state: :open,  # :open, :closed
  status: "Available",
  note: "In a meeting",
  activities: [:meeting],
  updated_at: ~U[2025-12-04 10:00:00Z]
}

# Watcher (person subscribed to presence)
%Watcher{
  subscriber_uri: "sip:bob@example.com",
  presentity_uri: "sip:alice@example.com",
  subscription_id: "abc123",  # Links to Subscription process
  state: :active,
  expires: ~U[2025-12-04 11:00:00Z]
}
```

**PIDF Document Generation:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<presence xmlns="urn:ietf:params:xml:ns:pidf"
          entity="sip:alice@example.com">
  <tuple id="tuple-1">
    <status>
      <basic>open</basic>
    </status>
    <note>Available</note>
  </tuple>
</presence>
```

**Storage:**
- In-memory GenServer state for active presence
- ETS for fast lookups
- Applications can persist to database if needed (via callbacks)
- No database dependency in library

**Comparison to Platforms:**
- **OpenSIPS:** `presence` module with mandatory DB backend
- **FreeSWITCH:** Built into mod_sofia, in-memory
- **Our approach:** GenServer + ETS (in-memory), apps handle persistence if needed

---

### 3.4 Message Waiting Indication (MWI)

**Purpose:** Voicemail notification (RFC 3842)

**Architecture:** Uses Subscription module

```elixir
defmodule ParrotSip.MWI do
  @moduledoc """
  Message Waiting Indication (RFC 3842).

  Notifies users of voicemail messages.
  Uses Subscription module with event package "message-summary".
  """

  # Subscribe to MWI
  def subscribe(mailbox_uri, subscriber_uri)

  # Update MWI (from voicemail system)
  def update(mailbox_uri, new_messages, old_messages)
end
```

**NOTIFY Body Example:**
```
Messages-Waiting: yes
Message-Account: sip:alice@example.com
Voice-Message: 2/5 (0/0)
```

---

## 4. Revised Scope

### 4.1 v1.0 Scope (Complete SIP Implementation)

| Feature | Status | Module | RFC |
|---------|--------|--------|-----|
| User Agent Client (UAC) | ✅ Core | ParrotSip.UAC | RFC 3261 |
| User Agent Server (UAS) | ✅ Core | ParrotSip.UAS | RFC 3261 |
| B2BUA | ✅ Core | ParrotSip.B2BUA.Session | - |
| **SIP Authentication** | ✅ **In Scope** | ParrotSip.Auth | RFC 2617 |
| **SUBSCRIBE/NOTIFY** | ✅ **In Scope** | ParrotSip.Subscription | RFC 3265 |
| **Presence** | ✅ **In Scope** | ParrotSip.Presence | RFC 3856 |
| **MWI** | ✅ **In Scope** | ParrotSip.MWI | RFC 3842 |
| Dialog Event Package | ✅ In Scope | Uses Subscription | RFC 4235 |
| Registration | ✅ In Scope | ParrotSip.Registrar | RFC 3261 |

### 4.2 Deferred to v2.0+

- Media handling (RTP/RTCP) - Complex, use external media server
- Codec negotiation - Application concern
- NAT traversal - Requires STUN/TURN integration
- Conference (MCU) - Separate concern
- SIP over WebSocket - Transport layer update
- MESSAGE method - Simple to add later

---

## 5. Implementation Priorities

**Phase 1: Core (Weeks 1-4)**
1. UAS entity + tests
2. UAC entity + tests
3. B2BUA.Session + tests

**Phase 2: Authentication (Week 5)**
4. Auth module (digest challenge/response)
5. Integration with UAS/UAC
6. ~~Database backend for credentials~~ (application concern, not library)

**Phase 3: Event Framework (Weeks 6-7)**
7. Subscription entity
8. SUBSCRIBE/NOTIFY state machine
9. Event package framework

**Phase 4: Presence (Week 8)**
10. Presence module
11. PIDF document generation
12. Watcher/presentity management
13. ~~Database backend~~ (application concern, not library)

**Phase 5: Additional Features (Week 9)**
14. MWI module
15. Dialog event package
16. Registrar module

**Phase 6: Production (Week 10+)**
17. Performance testing
18. Documentation
19. Example applications

---

## 6. Platform Comparison Summary

| Feature | OpenSIPS | FreeSWITCH | ParrotSip |
|---------|----------|------------|-----------|
| Architecture | Modular (C) | Monolithic core | Layered OTP |
| Auth | auth + auth_db | Built-in | Auth module |
| Presence | presence module | mod_sofia | Presence module |
| SUBSCRIBE | presence handles | mod_sofia | Subscription entity |
| Storage | Database | In-memory | In-memory (ETS/GenServer) |
| Concurrency | Process pool | Threading | OTP processes |
| Distribution | Shared memory | Single node | Erlang cluster |

---

**Next Steps:**
1. Review updated scope
2. Add specs for Auth, Subscription, Presence modules
3. Update state machine docs for Subscription
4. Update test plan for new modules

---

**Review Status:**
- [ ] Architecture approved
- [ ] Scope confirmed
- [ ] Priorities agreed
- [ ] Approved by: _____________
