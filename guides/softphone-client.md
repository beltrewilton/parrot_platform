# Softphone Client Guide

## Overview

The Parrot SoftphoneClient allows you to build SIP softphone applications that can:

- **Register** with external SIP servers (with Digest authentication support)
- **Publish presence** state and receive updates from subscribed contacts
- **Subscribe to presence** of other users
- **Make and receive calls** with full call control

## Architecture

```
Parrot.SoftphoneClient (GenServer)
├── Registration (gen_statem)
│   ├── States: unregistered, registering, awaiting_auth, registered, unregistering, failed
│   └── Handles 401/407 auth challenges automatically
├── PresenceSubscription (gen_statem, one per presentity)
│   ├── States: idle, subscribing, active, refreshing, unsubscribing, terminated
│   └── Parses PIDF+XML to extract status
├── PresencePublisher (GenServer)
│   ├── Generates PIDF+XML for publishing
│   └── Handles SIP-ETag for conditional updates
└── Call tracking
    └── Manages incoming/outgoing call state
```

## Quick Start

### 1. Define a Handler

```elixir
defmodule MyApp.PhoneHandler do
  use Parrot.SoftphoneHandler

  @impl true
  def init(opts) do
    config = %{
      username: opts[:username],
      domain: opts[:domain],
      auth_password: opts[:password],
      auto_register: true
    }
    {:ok, config, %{events: []}}
  end

  @impl true
  def handle_registered(info, state) do
    Logger.info("Registered! Expires in #{info.expires} seconds")
    {:ok, state}
  end

  @impl true
  def handle_presence_update(presentity, presence, state) do
    Logger.info("#{presentity} is now #{presence.status}")
    {:ok, state}
  end

  @impl true
  def handle_incoming_call(call_info, state) do
    Logger.info("Incoming call from #{call_info.from}")
    # Options: {:answer, [], state}, {:ring, state}, {:reject, 486, state}
    {:ring, state}
  end

  @impl true
  def handle_call_answered(call_id, state) do
    Logger.info("Call #{call_id} answered")
    {:ok, state}
  end

  @impl true
  def handle_call_ended(call_id, reason, state) do
    Logger.info("Call #{call_id} ended: #{reason}")
    {:ok, state}
  end
end
```

### 2. Start the Client

```elixir
{:ok, phone} = Parrot.SoftphoneClient.start_link(
  handler: MyApp.PhoneHandler,
  handler_opts: %{
    username: "alice",
    domain: "pbx.example.com",
    password: System.get_env("SIP_PASSWORD")
  }
)
```

### 3. Register and Use

```elixir
# Register with the SIP server
:ok = Parrot.SoftphoneClient.register(phone)

# Check registration status
{:ok, :registered} = Parrot.SoftphoneClient.registration_status(phone)

# Subscribe to a colleague's presence
:ok = Parrot.SoftphoneClient.subscribe(phone, "sip:bob@example.com")

# Publish your own presence
:ok = Parrot.SoftphoneClient.publish_presence(phone, %{status: :open, note: "Available"})

# Make a call
{:ok, call_id} = Parrot.SoftphoneClient.dial(phone, "sip:+15551234567@pbx.example.com")

# Hang up
:ok = Parrot.SoftphoneClient.hangup(phone, call_id)
```

## Configuration Options

The handler's `init/1` callback returns a config map. These are the available options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `username` | string | **required** | SIP username |
| `domain` | string | **required** | SIP domain |
| `display_name` | string | `nil` | Display name for From header |
| `auth_username` | string | `username` | Auth username (if different) |
| `auth_password` | string | `nil` | Digest auth password |
| `registrar` | string | `"sip:{domain}"` | Registrar URI |
| `register_expires` | integer | `3600` | Registration expiry (seconds) |
| `auto_register` | boolean | `true` | Register automatically on start |
| `transport` | atom | `:udp` | Transport: `:udp`, `:tcp`, `:tls`, `:ws` |
| `local_ip` | string | `nil` | Local IP to bind (auto-detect) |
| `local_port` | integer | `0` | Local port (0 = ephemeral) |
| `outbound_proxy` | string | `nil` | Outbound proxy URI |
| `supported_codecs` | list | `[:pcma, :opus]` | Supported audio codecs |

## Callbacks Reference

### Registration Callbacks

#### `handle_registered/2`

Called when registration succeeds.

```elixir
@callback handle_registered(info :: map(), state) :: {:ok, state}
```

**Info map contains:**
- `:expires` - Registration expiry in seconds

#### `handle_registration_failed/2`

Called when registration fails.

```elixir
@callback handle_registration_failed(reason :: term(), state) :: {:ok, state} | {:retry, delay_ms, state}
```

Returning `{:retry, delay_ms, state}` schedules a retry.

#### `handle_unregistered/1`

Called when unregistration completes.

```elixir
@callback handle_unregistered(state) :: {:ok, state}
```

### Presence Callbacks

#### `handle_presence_update/3`

Called when a subscribed presentity's status changes.

```elixir
@callback handle_presence_update(presentity :: String.t(), presence :: map(), state) ::
            {:ok, state}
```

**Presence map contains:**
- `:status` - `:open` or `:closed`
- `:note` - Optional status note

#### `handle_subscription_terminated/3`

Called when a subscription ends (timeout, rejection, etc).

```elixir
@callback handle_subscription_terminated(presentity :: String.t(), reason :: term(), state) ::
            {:ok, state}
```

#### `handle_publish_success/1`

Called when presence publication succeeds.

```elixir
@callback handle_publish_success(state) :: {:ok, state}
```

#### `handle_publish_failed/2`

Called when presence publication fails.

```elixir
@callback handle_publish_failed(reason :: term(), state) :: {:ok, state}
```

### Call Callbacks

#### `handle_incoming_call/2`

Called for incoming calls. Must return an action.

```elixir
@callback handle_incoming_call(call_info :: map(), state) ::
            {:answer, opts :: keyword(), state}
            | {:ring, state}
            | {:reject, status_code :: integer(), state}
```

**Call info contains:**
- `:from` - Caller URI
- `:to` - Called URI
- `:call_id` - Call identifier

#### `handle_ringing/2`

Called when remote party is ringing (180 received).

```elixir
@callback handle_ringing(call_id :: String.t(), state) :: {:ok, state}
```

#### `handle_call_answered/2`

Called when call is answered (outbound or inbound).

```elixir
@callback handle_call_answered(call_id :: String.t(), state) :: {:ok, state}
```

#### `handle_call_rejected/3`

Called when call is rejected by remote party.

```elixir
@callback handle_call_rejected(call_id :: String.t(), reason :: term(), state) :: {:ok, state}
```

#### `handle_call_ended/3`

Called when call ends.

```elixir
@callback handle_call_ended(call_id :: String.t(), reason :: term(), state) :: {:ok, state}
```

## API Reference

### Registration

```elixir
# Start registration
:ok = SoftphoneClient.register(phone)

# Check status
{:ok, status} = SoftphoneClient.registration_status(phone)
# status is :unregistered, :registering, :registered, or :unregistering

# Unregister
:ok = SoftphoneClient.unregister(phone)
```

### Presence Subscription

```elixir
# Subscribe to someone's presence
:ok = SoftphoneClient.subscribe(phone, "sip:bob@example.com")

# Unsubscribe
:ok = SoftphoneClient.unsubscribe(phone, "sip:bob@example.com")
```

### Presence Publishing

```elixir
# Publish available
:ok = SoftphoneClient.publish_presence(phone, %{status: :open, note: "At my desk"})

# Publish away
:ok = SoftphoneClient.publish_presence(phone, %{status: :closed, note: "In a meeting"})
```

### Call Control

```elixir
# Make a call
{:ok, call_id} = SoftphoneClient.dial(phone, "sip:bob@example.com")

# Answer incoming call
:ok = SoftphoneClient.answer(phone, call_id)

# Reject incoming call
:ok = SoftphoneClient.reject(phone, call_id, 486)  # 486 = Busy Here

# Hang up
:ok = SoftphoneClient.hangup(phone, call_id)

# Hold
:ok = SoftphoneClient.hold(phone, call_id)

# Resume
:ok = SoftphoneClient.resume(phone, call_id)

# Send DTMF
:ok = SoftphoneClient.send_dtmf(phone, call_id, "1234#")
```

## RFC Compliance

The SoftphoneClient implements these RFCs:

- **RFC 3261** - SIP: Session Initiation Protocol (REGISTER, INVITE)
- **RFC 2617** - HTTP Digest Authentication
- **RFC 3265** - SIP-Specific Event Notification (SUBSCRIBE/NOTIFY)
- **RFC 3856** - Presence Event Package for SIP
- **RFC 3903** - SIP Extension for Event State Publication (PUBLISH)
- **RFC 3863** - Presence Information Data Format (PIDF+XML)

## Example: Complete Softphone Application

See `apps/parrot/lib/parrot/examples/softphone_example.ex` for a complete, runnable example showing all features.

## Troubleshooting

### Registration fails with 401/407

Ensure your `auth_password` is correct. The client automatically handles digest authentication challenges.

### Presence subscription not receiving updates

1. Check that the presentity URI is correct
2. Verify the remote server supports presence (RFC 3856)
3. Check `handle_subscription_terminated/3` for rejection reasons

### Calls not connecting

1. Verify SDP negotiation is working (check codec compatibility)
2. Ensure NAT traversal is handled (use `local_ip` if behind NAT)
3. Check firewall allows UDP on the SIP and RTP ports
