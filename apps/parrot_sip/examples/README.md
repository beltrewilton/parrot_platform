## ParrotSip Usage Examples

This directory contains real-world examples of how to use ParrotSip's UAS/UAC entities.

### Examples

#### 1. SimplePhone - Basic SIP Phone

**File:** `simple_phone.ex`

A basic SIP phone that can:
- Make outbound calls (UAC)
- Receive incoming calls (UAS)
- Auto-answer incoming calls
- Hangup calls
- List active calls

**Usage:**

```elixir
# Start the phone
{:ok, phone} = ParrotSip.Examples.SimplePhone.start_link(
  local_uri: "sip:alice@example.com"
)

# Make an outbound call
{:ok, call_id} = ParrotSip.Examples.SimplePhone.dial(
  phone,
  "sip:bob@example.com",
  sdp: build_my_sdp()
)

# Incoming calls are auto-answered after 2 seconds

# List active calls
calls = ParrotSip.Examples.SimplePhone.list_calls(phone)
# => [%{call_id: "call-123", type: :outgoing, state: :established, remote_uri: "sip:bob@example.com"}]

# Hangup a call
:ok = ParrotSip.Examples.SimplePhone.hangup(phone, call_id)
```

**Key Concepts Demonstrated:**
- Creating UAS for incoming calls
- Creating UAC for outgoing calls
- Handling entity events (:uas_established, :uac_answered, etc.)
- Managing multiple concurrent calls
- Dialog discovery (handled automatically by UAS/UAC)

---

#### 2. SimpleB2BUA - Call Routing/Bridging

**File:** `simple_b2bua.ex`

A Back-to-Back User Agent that:
- Accepts incoming calls (A-leg UAS)
- Routes calls based on routing table
- Creates outbound calls (B-leg UAC)
- Bridges two legs together
- Forwards SDP between legs
- Handles hangup from either side

**Usage:**

```elixir
# Start B2BUA with routing table
{:ok, b2bua} = ParrotSip.Examples.SimpleB2BUA.start_link(
  routing_table: %{
    "sip:bob@example.com" => "sip:bob@internal.example.com:5061",
    "sip:alice@example.com" => "sip:alice@internal.example.com:5062"
  }
)

# Incoming calls are automatically:
# 1. Accepted (UAS created)
# 2. Routed based on table
# 3. Forwarded (UAC created)
# 4. Bridged together

# List active sessions
sessions = ParrotSip.Examples.SimpleB2BUA.list_sessions(b2bua)
# => [%{session_id: "call-123", state: :established, a_leg_uri: "...", b_leg_uri: "..."}]

# Hangup a session (both legs)
:ok = ParrotSip.Examples.SimpleB2BUA.hangup_session(b2bua, session_id)
```

**Key Concepts Demonstrated:**
- Coordinating UAS and UAC in same process
- SDP manipulation (A→B and B→A)
- Event forwarding between legs
- Handling rejection/timeout/cancel from either side
- Session state management

---

### Architecture Pattern

Both examples follow this pattern:

```elixir
defmodule MyApp do
  use GenServer

  # Tracks active UAS/UAC processes
  defstruct active_calls: %{}

  # Handler for incoming INVITEs
  @impl Handler
  def handle_invite(uas, invite, args) do
    # Create UAS entity
    {:ok, uas_pid} = UAS.Supervisor.start_child(
      invite: invite,
      owner: self(),
      notify_fun: &handle_uas_event/2,
      uas: uas
    )

    # Store and manage
    # ...
  end

  # Handle UAS events
  defp handle_uas_event({:uas_established, uas}, owner) do
    send(owner, {:call_active, uas})
  end

  # Make outbound call
  def dial(dest_uri, sdp) do
    {:ok, uac} = UAC.Supervisor.start_child(
      dest_uri: dest_uri,
      sdp: sdp,
      owner: self(),
      notify_fun: &handle_uac_event/2
    )
  end

  # Handle UAC events
  defp handle_uac_event({:uac_established, uac}, owner) do
    send(owner, {:call_active, uac})
  end
end
```

---

### Running the Examples

1. **Start ParrotSip application:**

```elixir
{:ok, _} = Application.ensure_all_started(:parrot_sip)
```

2. **Run SimplePhone:**

```elixir
{:ok, phone} = ParrotSip.Examples.SimplePhone.start_link(local_uri: "sip:test@localhost")

# In another terminal, use SIPp to call it:
# sipp -sf test/sipp/scenarios/uas_basic_call.xml 127.0.0.1:5060
```

3. **Run SimpleB2BUA:**

```elixir
{:ok, b2bua} = ParrotSip.Examples.SimpleB2BUA.start_link(
  routing_table: %{"sip:bob@example.com" => "sip:bob@localhost:5061"}
)

# SIPp as caller:
# sipp -sf test/sipp/scenarios/uas_basic_call.xml 127.0.0.1:5060 -s bob@example.com

# SIPp as callee:
# sipp -sn uas -p 5061
```

---

### Entity Lifecycle

**UAS (Incoming Call):**
```
incoming → ringing → answering → established → terminating → terminated
```

**UAC (Outgoing Call):**
```
initiating → calling → ringing → answered → established → terminating → terminated
```

**Events you'll receive:**
- UAS: `:uas_created`, `:uas_ringing`, `:uas_answered`, `:uas_established`, `:uas_bye`, `:uas_terminated`
- UAC: `:uac_created`, `:uac_ringing`, `:uac_answered`, `:uac_established`, `:uac_bye`, `:uac_terminated`

---

### Next Steps

- **Implement B2BUA.Session:** Full-featured session manager (specs/01_state_machines.md §4)
- **Add Authentication:** Integrate Auth module (specs/02_api_contracts.md §6)
- **Add Presence:** Subscribe/Notify for presence (specs/02_api_contracts.md §7-9)
- **Media Proxy:** Handle RTP forwarding between legs
- **Call Recording:** Monitor established calls and record media
- **IVR:** Interactive Voice Response with DTMF handling

---

### Testing

**Unit Tests:**
```bash
mix test test/parrot_sip/uas_entity_test.exs
mix test test/parrot_sip/uac_entity_test.exs
```

**SIPp Tests:**
```bash
# Terminal 1: Start your app
iex -S mix

# Terminal 2: Run SIPp
sipp -sf test/sipp/scenarios/uas_basic_call.xml 127.0.0.1:5060 -m 1
```

---

### Key Takeaways

1. **Process-per-entity:** Each call leg is its own supervised process
2. **Event-driven:** React to entity events, don't poll
3. **Dialog ownership:** Handled automatically via Registry (specs/03_dialog_ownership.md)
4. **Clean separation:** UAS = incoming, UAC = outgoing, your app = coordination
5. **OTP patterns:** Supervision, monitoring, let-it-crash all work correctly

**The examples show that using ParrotSip's entities is straightforward - create entities, handle events, coordinate logic in your GenServer.**
