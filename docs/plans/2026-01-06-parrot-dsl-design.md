# Parrot DSL Design

**Date:** 2026-01-06
**Status:** Draft
**Goal:** Make building VoIP applications in Elixir as ergonomic as building web apps with Phoenix.

---

## Vision

Parrot should enable developers to build full-featured softswitches, PBXs, and VoIP applications using idiomatic Elixir patterns. The DSL should feel native to Elixir developers - pipeline operators, pattern matching, behaviours with sensible defaults.

---

## Router

Phoenix-style router with scopes, pipelines, and matching on SIP-specific criteria.

```elixir
defmodule MyApp.Router do
  use Parrot.Router

  # Pipelines for common processing
  pipeline :authenticated do
    plug :verify_registration
    plug :check_acl
  end

  pipeline :from_trunk do
    plug :validate_trunk_ip
    plug :apply_rate_limit
  end

  # Route by source IP (internal network)
  scope "/", from_ip: "192.168.1.0/24" do
    pipe_through :authenticated

    invite "1xxx", ExtensionsModule
    invite "9xxx", OutboundModule
    invite "*", DefaultModule
  end

  # Trunk traffic from carrier IPs
  scope "/", from_ip: ["10.0.0.1", "10.0.0.2"] do
    pipe_through :from_trunk

    invite "*", InboundTrunkModule
  end

  # Route by headers
  scope "/", header: {"X-Tenant", "acme"} do
    invite "*", AcmeTenantModule
  end

  # Route by From domain
  scope "/", from: "*@partner.com" do
    invite "*", PartnerModule
  end

  # Catch-all
  invite "*", RejectModule

  # Method handlers (not routed, just assigned)
  register MyRegistrationHandler
  presence MyPresenceHandler
end
```

### Scope Matching Options

- `from_ip: "192.168.1.0/24"` - CIDR notation
- `from_ip: ["10.0.0.1", "10.0.0.2"]` - List of IPs
- `from: "*@domain.com"` - From URI pattern
- `to: "1xxx"` - To URI pattern
- `header: {"X-Header", "value"}` - Header match
- Combine: `scope "/", from_ip: "10.0.0.0/8", header: {"X-Priority", "high"}`

---

## INVITE Handling - Pipeline Builder

Handlers use a pipeline builder pattern. Chain operations with `|>`, framework executes them.

```elixir
defmodule MyApp.ExtensionsModule do
  use Parrot.InviteHandler

  def handle_invite(%{to: "sip:" <> extension <> "@" <> _} = invite) do
    invite
    |> answer()
    |> assign(:extension, extension)
    |> play("welcome.wav")
  end

  # Pattern match on specific From
  def handle_invite(%{from: "sip:vip@" <> _} = invite) do
    invite
    |> answer()
    |> assign(:priority, :high)
    |> play("vip-welcome.wav")
  end
end
```

### Pipeline Operations

```elixir
# Signaling
call |> answer()
call |> answer(sdp_opts)
call |> reject(status_code)
call |> hangup()

# State
call |> assign(:key, value)

# Playback
call |> play("file.wav")
call |> play(["file1.wav", "file2.wav"])  # sequence
call |> play("music.wav", loop: true)

# Recording
call |> record("recording.wav")
call |> record("recording.wav", max_duration: 60_000, beep: true)
call |> stop_record()

# DTMF
call |> collect_dtmf(max: 4, timeout: 5_000)
call |> collect_dtmf(max: 16, terminators: ["#"])

# Play + Collect combo
call |> prompt("enter-pin.wav", collect: [max: 4, timeout: 10_000])

# Bridging
call |> bridge("sip:dest@somewhere")
call |> bridge("sip:dest@somewhere", timeout: 30_000, headers: %{})
call |> bridge("sip:dest@somewhere", handler: BLegHandler)

# Forking
call |> fork([
  {"sip:alice@device1", handler: Handler1},
  {"sip:alice@device2", handler: Handler2}
], strategy: :first_answer, timeout: 30_000)

# Conference
call |> join_conference("room-123")
call |> join_conference("room-123", muted: true)

# Media forking (external services)
call |> fork_media("wss://ai-service.com/stream", direction: :both)
call |> fork_media("rtp://recorder:5000", direction: :rx)

# Hold/Mute
call |> hold()
call |> resume()
call |> mute(:tx)
call |> mute(:rx)
call |> unmute(:tx)
```

---

## Callbacks

Framework defines callback functions. You pattern match on the data.

```elixir
defmodule MyApp.IVRHandler do
  use Parrot.InviteHandler

  def handle_invite(invite) do
    invite
    |> answer()
    |> assign(:menu, :main)
    |> play("welcome.wav")
  end

  # Playback complete
  def handle_play_complete("welcome.wav", call) do
    call |> prompt("main-menu.wav", collect: [max: 1, timeout: 10_000])
  end

  def handle_play_complete("goodbye.wav", call) do
    call |> hangup()
  end

  # DTMF received
  def handle_dtmf("1", %{assigns: %{menu: :main}} = call) do
    call |> assign(:menu, :sales) |> play("sales-menu.wav")
  end

  def handle_dtmf("2", %{assigns: %{menu: :main}} = call) do
    call |> assign(:menu, :support) |> bridge("sip:support@internal")
  end

  def handle_dtmf(:timeout, call) do
    call |> play("goodbye.wav")
  end

  # Bridge events
  def handle_bridge_complete(:answered, call) do
    Parrot.Presence.notify(call.assigns.extension, %{status: :busy})
    {:noreply, call}
  end

  def handle_bridge_complete({:failed, :busy}, call) do
    call |> play("user-busy.wav")
  end

  def handle_bridge_complete({:failed, :no_answer}, call) do
    call |> play("no-answer.wav")
  end

  # Recording complete
  def handle_record_complete(filename, duration, call) do
    {:noreply, call}
  end

  # Conference events
  def handle_conference_join(room, call) do
    {:noreply, call}
  end

  def handle_conference_leave(room, reason, call) do
    {:noreply, call}
  end

  # Call ended
  def handle_hangup(call) do
    Parrot.Presence.notify(call.assigns.extension, %{status: :available})
    {:noreply, call}
  end
end
```

### Available Callbacks

| Callback | When |
|----------|------|
| `handle_invite(invite)` | INVITE received |
| `handle_play_complete(filename, call)` | Playback finished |
| `handle_dtmf(digits_or_timeout, call)` | DTMF collected |
| `handle_prompt_complete(filename, digits, call)` | Play+collect finished |
| `handle_bridge_complete(result, call)` | Bridge answered/failed |
| `handle_fork_complete(result, call)` | Fork answered/failed |
| `handle_record_complete(filename, duration, call)` | Recording finished |
| `handle_conference_join(room, call)` | Joined conference |
| `handle_conference_leave(room, reason, call)` | Left conference |
| `handle_fork_media_connected(url, call)` | Media fork established |
| `handle_hangup(call)` | Call ended |

---

## B-Leg Control (Advanced)

For power users who need full control over the outbound leg:

```elixir
defmodule MyApp.BLegHandler do
  use Parrot.BLegHandler

  # Manipulate INVITE before sending
  def before_invite(invite, state) do
    invite
    |> put_header("X-Original-Caller", state.original_caller)
    |> put_header("X-Custom", "value")
    |> remove_header("X-Internal")
    |> modify_sdp(&add_custom_attribute/1)
  end

  # Handle provisional responses
  def handle_provisional(response, bleg) when response.status == 180 do
    {:ring, bleg}  # play ring-back to A-leg
  end

  def handle_provisional(response, bleg) when response.status == 183 do
    {:early_media, bleg}  # connect early media
  end

  # B-leg answered
  def handle_answer(response, bleg) do
    {:connect, bleg}
  end

  # B-leg rejected
  def handle_reject(response, bleg) do
    {:rejected, response.status, bleg}
  end

  # In-dialog events
  def handle_reinvite(reinvite, bleg) do
    {:passthrough, bleg}
  end

  def handle_bye(bye, bleg) do
    {:hangup, bleg}
  end
end
```

---

## Registration Handler

Framework handles SIP mechanics (challenge/response, expiry). You provide decisions and storage.

```elixir
defmodule MyApp.RegistrationHandler do
  use Parrot.RegistrationHandler

  # Authenticate credentials (framework handles 401 challenge dance)
  def authenticate(credentials) do
    case MyDB.check_password(credentials.username, credentials.password) do
      :ok -> :ok
      :error -> :error
    end
  end

  # Store binding (called after successful auth)
  def store_binding(aor, contact, expires) do
    MyDB.save_registration(aor, contact, expires)
    # Notify presence
    Parrot.Presence.notify(aor, %{status: :available})
    :ok
  end

  # Get current bindings (for 200 OK response)
  def get_bindings(aor) do
    MyDB.get_contacts(aor)
  end

  # Registration expired
  def handle_registration_expired(aor) do
    Parrot.Presence.notify(aor, %{status: :offline})
    :ok
  end
end
```

---

## Presence Handler

Framework handles SUBSCRIBE/NOTIFY/PUBLISH mechanics. You provide authorization and storage.

```elixir
defmodule MyApp.PresenceHandler do
  use Parrot.PresenceHandler

  # Authorize subscription request
  def authorize_subscription(watcher, presentity) do
    # :allow, :deny, or :pending (for approval flows)
    if MyDB.can_watch?(watcher, presentity), do: :allow, else: :deny
  end

  # Store subscription
  def store_subscription(subscription) do
    MyDB.save_subscription(subscription)
    :ok
  end

  # Get all watchers for a presentity
  def get_subscriptions(presentity) do
    MyDB.get_watchers(presentity)
  end

  # Get current presence state
  def get_presence(presentity) do
    case MyDB.get_user_state(presentity) do
      :available -> %{status: :open, note: "Available"}
      :busy -> %{status: :closed, note: "On a call"}
      :offline -> %{status: :closed, note: "Offline"}
    end
  end

  # User published their state
  def handle_publish(presentity, presence_state) do
    MyDB.set_user_state(presentity, presence_state)
    :ok
  end
end
```

### Triggering Presence Updates

Call `Parrot.Presence.notify/2` from anywhere - it's async, fire-and-forget:

```elixir
# In a call handler
def handle_bridge_complete(:answered, call) do
  Parrot.Presence.notify(call.assigns.extension, %{status: :busy})
  {:noreply, call}
end

def handle_hangup(call) do
  Parrot.Presence.notify(call.assigns.extension, %{status: :available})
  {:noreply, call}
end

# In registration handler
def store_binding(aor, contact, expires) do
  Parrot.Presence.notify(aor, %{status: :available})
  :ok
end
```

---

## State Management

Per-call state lives on `call.assigns`. Global state is your responsibility (ETS, GenServer, database).

```elixir
def handle_invite(invite) do
  invite
  |> answer()
  |> assign(:menu, :main)
  |> assign(:retries, 0)
  |> assign(:caller_info, lookup_caller(invite.from))
  |> play("welcome.wav")
end

def handle_dtmf(:timeout, call) do
  if call.assigns.retries < 3 do
    call
    |> assign(:retries, call.assigns.retries + 1)
    |> play("please-try-again.wav")
  else
    call |> play("goodbye.wav") |> hangup()
  end
end
```

---

## Error Handling

Framework provides sensible defaults. Override only what you care about.

```elixir
defmodule MyApp.Handler do
  use Parrot.InviteHandler

  # Only override specific cases
  def handle_bridge_complete({:failed, :busy}, call) do
    call |> play("busy-try-later.wav") |> hangup()
  end

  # Everything else uses framework defaults:
  # - :no_answer → play tone, hangup
  # - :rejected → play tone, hangup
  # - :timeout → play tone, hangup
  # - network error → log, hangup
end
```

---

## Application Startup

Explicit in `application.ex` - no magic.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your app's storage, etc.
      MyApp.Database,

      # Parrot SIP stack
      {Parrot,
        router: MyApp.Router,
        transports: [
          {:udp, port: 5060},
          {:tcp, port: 5060},
          {:tls, port: 5061, certfile: "cert.pem", keyfile: "key.pem"}
        ]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

---

## Supervision / Fault Tolerance

Simple, predictable behavior when handlers crash:

```
Handler crash → Call process dies → Media cleaned up → BYE sent → Log error
```

- Caller hears disconnect
- Crash logged with stacktrace
- No weird half-recovered state
- Fix the bug, move on

---

## Testing

Three levels of testing:

### 1. Unit Tests - Fast, Isolated

```elixir
defmodule MyApp.IVRHandlerTest do
  use ExUnit.Case

  test "routes to sales on digit 1" do
    call = Parrot.Test.call_fixture(assigns: %{menu: :main})

    result = MyApp.IVRHandler.handle_dtmf("1", call)

    assert {:play, "sales-menu.wav", updated_call} = result
    assert updated_call.assigns.menu == :sales
  end
end
```

### 2. Simulated Flow Tests

```elixir
defmodule MyApp.IVRFlowTest do
  use ExUnit.Case

  test "complete IVR flow to sales" do
    {:ok, call} = Parrot.Test.simulate_call(
      handler: MyApp.IVRHandler,
      to: "sip:100@local"
    )

    assert_played(call, "welcome.wav")

    simulate_dtmf(call, "1")
    assert_played(call, "sales-menu.wav")

    simulate_dtmf(call, "1")
    assert_bridged(call, ~r/sales/)
  end
end
```

### 3. SIPp Integration Tests

```elixir
defmodule MyApp.SIPpTest do
  use ExUnit.Case

  @tag :sipp
  test "real call with DTMF" do
    start_parrot(router: MyApp.Router)

    {:ok, result} = Sipp.run_scenario("test/sipp/scenarios/ivr_sales.xml")

    assert result.calls_completed == 1
    assert result.failed == 0
  end
end
```

---

## Summary

| Concept | Pattern |
|---------|---------|
| Routing | Phoenix-style router with scopes, pipelines, SIP-specific matching |
| Call handling | Pipeline builder with `\|>` |
| Async events | Defined callbacks (`handle_play_complete`, etc.) |
| Registration | Framework handles SIP, you provide auth/storage callbacks |
| Presence | Framework handles SIP, you provide authorization/storage |
| Bridging | Simple by default, full B-leg control available |
| State | `call.assigns` for per-call, user manages global |
| Errors | Sensible defaults, selective override |
| Startup | Explicit in application.ex |
| Crashes | Call dies, cleanup, BYE sent |
| Testing | Unit + simulated + SIPp |
