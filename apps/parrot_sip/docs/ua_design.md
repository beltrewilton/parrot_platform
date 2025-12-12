# ParrotSip UA Module Design

## Overview

The UA (User Agent) module provides a high-level API for building SIP applications - softphones, auto-attendants, and B2BUA softswitches. It sits on top of the Transaction layer (Client/Server) and provides a clean, callback-driven interface following Elixir community patterns.

## Design Principles

1. **Behaviour-driven** - Like Thousand Island, pass key references to every callback
2. **Minimal configuration** - Derive what we can, only require what's necessary
3. **OpenSIPS terminology** - Use "entity" for SIP dialogs, save "channel" for media layer
4. **Explicit actions** - Call functions like `UA.answer/3`, don't rely on return values for actions

## Core Concepts

### Entity

An entity represents one SIP dialog. Follows OpenSIPS terminology:

- **Server entity** - Created from received INVITE (UAS role)
- **Client entity** - Created by sending INVITE (UAC role)

```elixir
%ParrotSip.UA.Entity{
  id: "unique-id",
  type: :server | :client,
  state: :trying | :early | :confirmed | :terminated,
  remote_uri: "sip:bob@example.com",
  local_uri: "sip:alice@example.com",
  call_id: "sip-call-id@host",
  local_tag: "abc123",
  remote_tag: "xyz789"
}
```

### Session (Future)

For B2BUA, a session connects multiple entities. Not implemented in v1 - handler manages correlation in its own state.

## API

### Starting a UA

```elixir
{:ok, ua} = ParrotSip.UA.start_link(
  MyHandler,        # Handler module implementing UA.Handler behaviour
  init_arg,         # Passed to handler's init/1
  port: 5060,       # Bind port
  transport: :udp   # :udp | :tcp | :tls
)
```

The UA will:
- Start listening on the specified port/transport
- Derive From/Contact URIs from bind address
- Generate tags automatically

### Public Functions

```elixir
# Make outbound call - creates client entity
{:ok, entity} = ParrotSip.UA.dial(ua, "sip:bob@example.com",
  sdp: sdp_body,
  headers: %{"X-Custom" => "value"}
)

# Answer inbound call - for server entity
:ok = ParrotSip.UA.answer(ua, entity,
  sdp: sdp_body
)

# Send provisional response
:ok = ParrotSip.UA.ring(ua, entity)           # 180 Ringing
:ok = ParrotSip.UA.progress(ua, entity, 183)  # 183 Session Progress

# Reject inbound call
:ok = ParrotSip.UA.reject(ua, entity, 486, "Busy Here")

# End call (either direction)
:ok = ParrotSip.UA.hangup(ua, entity)

# Cancel outbound call before answer
:ok = ParrotSip.UA.cancel(ua, entity)

# Registration
{:ok, reg_id} = ParrotSip.UA.register(ua, "sip:registrar.example.com",
  expires: 3600,
  username: "alice",
  password: "secret"
)

:ok = ParrotSip.UA.unregister(ua, reg_id)
```

### Handler Behaviour

```elixir
defmodule MyHandler do
  use ParrotSip.UA.Handler

  # Required
  @impl true
  def init(init_arg) do
    {:ok, initial_state}
  end

  # Inbound call
  @impl true
  def handle_incoming(ua, invite, entity, state) do
    # Options:
    # - ParrotSip.UA.ring(ua, entity) then answer later
    # - ParrotSip.UA.answer(ua, entity, sdp: ...)
    # - ParrotSip.UA.reject(ua, entity, 486, "Busy")
    {:ok, new_state}
  end

  # Outbound call responses
  @impl true
  def handle_ringing(ua, response, entity, state) do
    {:ok, state}
  end

  @impl true
  def handle_answered(ua, response, entity, state) do
    # Call connected
    {:ok, state}
  end

  @impl true
  def handle_rejected(ua, response, entity, state) do
    # Call failed - 3xx, 4xx, 5xx, 6xx
    {:ok, state}
  end

  # Both directions
  @impl true
  def handle_hangup(ua, message, entity, state) do
    # Remote side hung up
    {:ok, state}
  end

  @impl true
  def handle_cancel(ua, entity, state) do
    # Call was cancelled before answer
    {:ok, state}
  end

  # Mid-call
  @impl true
  def handle_reinvite(ua, invite, entity, state) do
    # Re-INVITE for hold, codec change, etc.
    {:ok, state}
  end

  @impl true
  def handle_info(ua, info, entity, state) do
    # INFO request (DTMF, etc.)
    {:ok, state}
  end

  # Registration
  @impl true
  def handle_registered(ua, response, reg_id, state) do
    {:ok, state}
  end

  @impl true
  def handle_registration_failed(ua, response, reg_id, state) do
    {:ok, state}
  end

  # Errors
  @impl true
  def handle_timeout(ua, timeout_type, entity, state) do
    {:ok, state}
  end
end
```

## Use Cases

### Simple Softphone (UAC)

```elixir
defmodule MySoftphone do
  use ParrotSip.UA.Handler

  def init(_), do: {:ok, %{}}

  def handle_ringing(_ua, _response, entity, state) do
    IO.puts("Ringing #{entity.remote_uri}...")
    {:ok, state}
  end

  def handle_answered(_ua, _response, entity, state) do
    IO.puts("Connected to #{entity.remote_uri}")
    {:ok, state}
  end

  def handle_bye(_ua, _bye, _entity, state) do
    IO.puts("Call ended")
    {:ok, state}
  end
end

# Usage
{:ok, ua} = ParrotSip.UA.start_link(MySoftphone, nil, port: 5060)
{:ok, entity} = ParrotSip.UA.dial(ua, "sip:bob@example.com", sdp: my_sdp)
# ... later
ParrotSip.UA.hangup(ua, entity)
```

### Auto-Answer (UAS)

```elixir
defmodule AutoAnswer do
  use ParrotSip.UA.Handler

  def init(_), do: {:ok, %{}}

  def handle_invite(ua, invite, entity, state) do
    sdp = generate_answer_sdp(invite.body)
    ParrotSip.UA.answer(ua, entity, sdp: sdp)
    {:ok, state}
  end

  def handle_bye(_ua, _bye, _entity, state) do
    {:ok, state}
  end
end
```

### B2BUA Softswitch

```elixir
defmodule MySwitch do
  use ParrotSip.UA.Handler

  def init(_), do: {:ok, %{legs: %{}}}

  def handle_invite(ua, invite, leg_a, state) do
    # Route and create outbound leg
    dest = route(invite)
    {:ok, leg_b} = ParrotSip.UA.dial(ua, dest, sdp: invite.body)

    # Correlate legs
    legs = state.legs
      |> Map.put(leg_a.id, leg_b.id)
      |> Map.put(leg_b.id, leg_a.id)

    {:ok, %{state | legs: legs}}
  end

  def handle_ringing(ua, _response, leg_b, state) do
    leg_a_id = state.legs[leg_b.id]
    ParrotSip.UA.ring(ua, leg_a_id)
    {:ok, state}
  end

  def handle_answered(ua, response, leg_b, state) do
    leg_a_id = state.legs[leg_b.id]
    ParrotSip.UA.answer(ua, leg_a_id, sdp: response.body)
    {:ok, state}
  end

  def handle_bye(ua, _bye, entity, state) do
    case Map.get(state.legs, entity.id) do
      nil -> :ok
      other_id -> ParrotSip.UA.hangup(ua, other_id)
    end
    {:ok, state}
  end
end
```

## Implementation Notes

### Entity Lifecycle

1. **Client entity**: `dial/3` -> trying -> early (1xx) -> confirmed (2xx) -> terminated (BYE)
2. **Server entity**: INVITE received -> early (ring/progress) -> confirmed (answer) -> terminated (BYE)

### Internal State

The UA GenServer maintains:
- `entities` - Map of entity_id -> Entity struct
- `registrations` - Map of reg_id -> registration state
- `handler` - Handler module
- `handler_state` - State returned from handler callbacks
- `transport` - Transport configuration

### Transaction Layer Integration

- UA uses `ParrotSip.Transaction.Client` for outbound requests
- UA implements `ParrotSip.Handler` behaviour to receive inbound requests
- Transactions are abstracted away - handler only sees entity-level events

## Migration from Current UA

Current implementation has:
- `ParrotSip.UA.Config` struct - **Remove**, derive from bind address
- `ParrotSip.UA.Client` module - **Replace** with `UA.dial/3`, `UA.answer/3`, etc.
- `ParrotSip.UA.Behaviour` - **Refactor** callback signatures to include `ua` and `entity`
- No Entity struct - **Add** `ParrotSip.UA.Entity`

## Future Enhancements

- [ ] Session struct for B2BUA leg correlation (managed by UA, not handler)
- [ ] Subscription/NOTIFY support
- [ ] MESSAGE support
- [ ] Codec negotiation helpers
- [ ] Certificate configuration for TLS
- [ ] Outbound proxy support
- [ ] DNS SRV resolution
