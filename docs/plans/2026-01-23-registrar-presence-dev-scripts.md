# Registrar & Presence Dev Scripts Design

**Date:** 2026-01-23
**Status:** Approved

## Overview

Add development scripts for testing SIP registration and presence functionality using pjsua, following the existing `scripts/dev/` patterns. Use ETS for storage (simplest option).

## Scripts to Create

### 1. `scripts/dev/test_registrar.exs`

Standalone registration server demonstrating `Parrot.RegistrationHandler` behaviour.

**Features:**
- Digest authentication with hardcoded users (alice/secret123, bob/secret456)
- ETS-based binding storage
- Shows 401 challenge → credentials → 200 OK flow

### 2. `scripts/dev/test_registrar_presence.exs`

Registration + Presence integration server.

**Features:**
- Combines `Parrot.RegistrationHandler` + `Parrot.PresenceHandler`
- When user registers → presence becomes `:open` ("Available")
- When user unregisters/expires → presence becomes `:closed` ("Offline")
- Subscribers receive NOTIFY on presence changes

### 3. `scripts/dev/test_registrar_with_pjsua.sh`

Orchestration script for testing with full logging.

**Features:**
- Starts server with SIP_TRACE and LOG_LEVEL=debug
- Creates timestamped log directory
- Outputs pjsua commands with log file paths
- Full observability for troubleshooting

## Implementation Details

### Registration Handler

```elixir
defmodule DevRegistrar.Handler do
  use Parrot.RegistrationHandler

  @users %{
    "alice" => "secret123",
    "bob" => "secret456"
  }

  @impl true
  def get_password(username) do
    case Map.get(@users, username) do
      nil -> :error
      password -> {:ok, password}
    end
  end

  @impl true
  def authenticate(_credentials), do: :ok

  @impl true
  def store_binding(aor, contact, expires) do
    if expires > 0 do
      :ets.insert(:registrations, {aor, contact, expires, System.system_time(:second)})
    else
      :ets.delete_object(:registrations, {aor, contact, :_, :_})
    end
    :ok
  end

  @impl true
  def get_bindings(aor) do
    :ets.lookup(:registrations, aor)
    |> Enum.map(fn {_aor, contact, expires, registered_at} ->
      %{contact: contact, expires: expires, registered_at: registered_at}
    end)
  end

  @impl true
  def handle_registration_expired(aor, _contact) do
    IO.puts("[REGISTRAR] Registration expired: #{aor}")
    :ok
  end
end
```

### Presence Handler

```elixir
defmodule DevPresence.Handler do
  use Parrot.PresenceHandler

  @impl true
  def authorize_subscription(_watcher, _presentity), do: :allow

  @impl true
  def store_subscription(sub) do
    :ets.insert(:subscriptions, {sub.subscription_id, sub.watcher, sub.presentity, sub.dialog_id, sub.expires})
    :ok
  end

  @impl true
  def get_subscriptions(presentity) do
    :ets.match_object(:subscriptions, {:_, :_, presentity, :_, :_})
    |> Enum.map(fn {id, watcher, _presentity, dialog_id, _expires} ->
      %{subscription_id: id, watcher: watcher, dialog_id: dialog_id}
    end)
  end

  @impl true
  def get_presence(presentity) do
    case :ets.lookup(:presence_state, presentity) do
      [{_, status, note}] -> %{status: status, note: note}
      [] -> %{status: :closed, note: "Unknown"}
    end
  end

  @impl true
  def handle_publish(presentity, state) do
    :ets.insert(:presence_state, {presentity, state.status, state[:note] || ""})
    :ok
  end
end
```

### Integration Point

Registration handler triggers presence updates:

```elixir
def store_binding(aor, contact, expires) do
  # ... store binding ...
  if expires > 0 do
    Parrot.Presence.notify(aor, %{status: :open, note: "Available"})
  else
    Parrot.Presence.notify(aor, %{status: :closed, note: "Offline"})
  end
  :ok
end
```

### Router Configuration

```elixir
defmodule DevRegistrarPresence.Router do
  use Parrot.Router

  register DevRegistrar.Handler
  presence DevPresence.Handler
end
```

### ETS Tables

```elixir
:ets.new(:registrations, [:named_table, :set, :public])
:ets.new(:subscriptions, [:named_table, :bag, :public])  # bag allows multiple watchers
:ets.new(:presence_state, [:named_table, :set, :public])
```

## Testing with pjsua

### Server Startup

```bash
# With orchestration script (recommended)
./scripts/dev/test_registrar_with_pjsua.sh

# Or direct
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_registrar_presence.exs
```

### Registration Test (Terminal 2 - Alice)

```bash
pjsua --null-audio --no-tcp --local-port=5090 \
  --log-file=/tmp/pjsua_alice.log --log-level=5 \
  --id="sip:alice@127.0.0.1" \
  --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="alice" --password="secret123"
```

### Presence Test (Terminal 3 - Bob)

```bash
pjsua --null-audio --no-tcp --local-port=5091 \
  --log-file=/tmp/pjsua_bob.log --log-level=5 \
  --id="sip:bob@127.0.0.1" \
  --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="bob" --password="secret456"
```

**In Bob's pjsua console:**
```
>>> +b sip:alice@127.0.0.1   # Add alice as buddy
>>> s                         # Subscribe to alice's presence
# Bob receives NOTIFY with alice's status
```

**In Alice's pjsua console:**
```
>>> ru                        # Alice unregisters
# Bob receives NOTIFY showing alice offline
```

### Log Files for Troubleshooting

- Server: `$LOG_DIR/server.log` - SIP traces, state machine logs
- Alice: `$LOG_DIR/pjsua_alice.log` - Client SIP messages
- Bob: `$LOG_DIR/pjsua_bob.log` - Client SIP messages, presence NOTIFYs

## Documentation Updates

1. **`docs/pjsua-testing.md`** - Add registration/presence testing section
2. **`scripts/dev/TESTING_GUIDE.md`** - Add registrar workflow and log analysis patterns
3. **`Parrot.Examples.Registrar`** - Document the existing example

## SIPp Scenarios to Add

Located in `apps/parrot_sip/test/sipp/scenarios/`:

### Registration Scenarios
- `register/uac_register_basic.xml` - Basic REGISTER / 200 OK (no auth)
- `register/uac_register_unregister.xml` - REGISTER with expires=0
- `register/uac_register_multi_contact.xml` - Multiple contacts in single REGISTER

### Presence Scenarios
- `presence/uac_subscribe_notify.xml` - SUBSCRIBE/NOTIFY flow
- `presence/uac_publish.xml` - PUBLISH presence update

## Bug Tracking Workflow

**IMPORTANT:** During verification and testing, if any bugs are discovered:

1. **DO NOT attempt to fix bugs inline** - this risks losing track of issues
2. **Create a beads task immediately:** `bd create "Bug: <description>" -t bug -l "bug,registration" -d "<details>"`
3. **Add as blocker if needed:** `bd dep add <verification-task> <bug-task>`
4. **Continue testing** other aspects if possible
5. **Nothing should be lost** - all issues go into beads for tracking

This ensures:
- Full visibility of all discovered issues
- Proper prioritization and scheduling
- No context lost when switching between tasks
- Clear audit trail of what was found and when

## Task Summary

1. Create `scripts/dev/test_registrar.exs`
2. Create `scripts/dev/test_registrar_presence.exs`
3. Create `scripts/dev/test_registrar_with_pjsua.sh`
4. Update `docs/pjsua-testing.md`
5. Update `scripts/dev/TESTING_GUIDE.md`
6. Document `Parrot.Examples.Registrar`
7. Test registration flow with pjsua
8. Test presence flow with pjsua
9. Create SIPp: Basic REGISTER (no auth)
10. Create SIPp: REGISTER unregister (expires=0)
11. Create SIPp: Multiple contacts
12. Create SIPp: SUBSCRIBE/NOTIFY
13. Create SIPp: PUBLISH
14. Test expiry timer → presence integration
