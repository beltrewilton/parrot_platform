# B2BUA Call Bridging Design

**Date:** 2026-01-25
**Status:** Approved
**Epic:** parrot_platform-q90

## Overview

Implement full B2BUA (Back-to-Back User Agent) softswitch capabilities similar to FreeSWITCH/Asterisk. This enables call bridging, forking, transfers, hold/resume, and advanced call control.

## Goals

- Full softswitch capabilities (bridge, fork, transfer, hold/resume)
- High-level DSL for common cases
- Low-level leg control when needed
- Configurable media mode (proxy vs direct)
- All fork ring strategies (simultaneous, sequential, delayed)
- Handler controls all termination (no auto-cleanup)

## Architecture

### Core Abstractions

```
┌─────────────────────────────────────────────────────────────┐
│                      User Handler                            │
│  handle_invite/1, handle_leg_event/3, handle_play_complete/2│
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Parrot.Call DSL                          │
│  bridge/2, fork/2, hold/1, resume/1, transfer/3             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  ActionExecutor                              │
│  execute_bridge, execute_fork, execute_hold, etc.           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  B2BUA GenServer                             │
│  Manages session, legs, media bridging                      │
└─────────────────────────────────────────────────────────────┘
            │                               │
            ▼                               ▼
┌───────────────────┐           ┌───────────────────┐
│       Leg         │           │    MediaBridge    │
│  A-leg, B-leg...  │           │  RTP forwarding   │
└───────────────────┘           └───────────────────┘
```

### File Structure

```
apps/parrot/lib/parrot/
├── leg.ex                      # Leg struct and functions
├── bridge/
│   ├── b2bua.ex               # B2BUA GenServer
│   ├── media_bridge.ex        # Media bridging between legs
│   ├── ring_strategy.ex       # Fork ring strategies
│   └── action_executor.ex     # (existing - add B2BUA operations)
```

## Module Designs

### Leg (`apps/parrot/lib/parrot/leg.ex`)

Represents one side of a call:

```elixir
defmodule Parrot.Leg do
  defstruct [
    :id,           # Unique leg identifier (e.g., :a_leg, :b_leg, "custom-id")
    :direction,    # :inbound | :outbound
    :state,        # :init | :trying | :ringing | :answered | :held | :terminated
    :dialog_id,    # ParrotSip dialog reference
    :media_pid,    # MediaSession pid (when media: :proxy)
    :remote_uri,   # SIP URI of remote party
    :local_uri,    # SIP URI of local party
    :sdp,          # Negotiated SDP
    :created_at,   # Timestamp
    :answered_at,  # Timestamp (nil until answered)
    :metadata      # User-defined data
  ]

  @type leg_id :: atom() | String.t()
  @type state :: :init | :trying | :ringing | :answered | :held | :terminated
end
```

### B2BUA GenServer (`apps/parrot/lib/parrot/bridge/b2bua.ex`)

Manages the bridged session:

```elixir
defmodule Parrot.Bridge.B2BUA do
  use GenServer

  defstruct [
    :session_id,     # Unique bridge session identifier (spans multiple SIP Call-IDs)
    :handler,        # User's handler module
    :handler_state,  # Handler's state
    :legs,           # %{leg_id => Leg.t()}
    :media_mode,     # :proxy | :direct
    :ring_strategy,  # For fork: :simultaneous | :sequential | :delayed
    :active_bridge,  # {leg_id, leg_id} - currently connected legs
    :pending_legs,   # Legs still ringing (for fork)
    :created_at
  ]

  # Client API
  def start_link(opts)
  def set_a_leg(pid, leg)
  def originate(pid, destinations, opts \\ [])
  def connect(pid, leg_a, leg_b)
  def hold(pid, leg_id)
  def resume(pid, leg_id)
  def transfer(pid, leg_id, destination, opts \\ [])
  def hangup_leg(pid, leg_id)
  def hangup_all(pid)
end
```

### Ring Strategy (`apps/parrot/lib/parrot/bridge/ring_strategy.ex`)

Fork ring strategies:

```elixir
defmodule Parrot.Bridge.RingStrategy do
  @type strategy :: :simultaneous | :sequential | :delayed

  @type t :: %{
    type: strategy(),
    timeout: pos_integer(),
    delay: pos_integer() | nil,
    max_rings: pos_integer() | nil
  }

  def simultaneous(opts \\ [])  # Ring all at once, first answer wins
  def sequential(opts \\ [])    # Ring one at a time
  def delayed(opts \\ [])       # Start with first, add more after delay
end
```

### Media Bridge (`apps/parrot/lib/parrot/bridge/media_bridge.ex`)

Bridges RTP between legs in proxy mode:

```elixir
defmodule Parrot.Bridge.MediaBridge do
  use GenServer

  defstruct [
    :session_id,
    :leg_a,          # %{media_pid: pid, ssrc: integer}
    :leg_b,          # %{media_pid: pid, ssrc: integer}
    :active
  ]

  def start_link(opts)
  def connect(pid, leg_a_media, leg_b_media)
  def pause(pid, direction)   # :a_to_b | :b_to_a | :both
  def resume(pid, direction)
  def stop(pid)
end
```

## DSL Operations

```elixir
# Simple bridge - connects to single destination
call |> bridge("sip:agent@pbx.local", timeout: 30_000, media: :proxy)

# Fork - multiple destinations with ring strategy
call |> fork(["sip:a@x", "sip:b@x"], strategy: :simultaneous)
call |> fork(["sip:a@x", "sip:b@x"], strategy: :sequential, timeout: 15_000)
call |> fork(["sip:a@x", "sip:b@x"], strategy: :delayed, delay: 5_000)

# Explicit leg control
call |> originate("sip:dest@x", as: :b_leg)
call |> connect_legs(:a_leg, :b_leg)

# Hold/resume
call |> hold(:b_leg)
call |> resume(:b_leg)

# Transfer
call |> transfer(:b_leg, "sip:new@x")                    # Blind
call |> transfer(:b_leg, "sip:new@x", type: :attended)   # Attended

# Hangup specific leg
call |> hangup_leg(:b_leg)
```

## Handler Callback

Unified `handle_leg_event/3` with pattern matching:

```elixir
defmodule MyHandler do
  use Parrot.InviteHandler

  def handle_invite(call) do
    call |> answer() |> bridge("sip:agent@pbx.local")
  end

  def handle_leg_event(call, leg_id, :ringing) do
    Logger.info("#{leg_id} is ringing")
    {:ok, call}
  end

  def handle_leg_event(call, leg_id, {:answered, _sdp}) do
    Logger.info("#{leg_id} answered")
    {:ok, call}
  end

  def handle_leg_event(call, leg_id, {:failed, reason}) do
    Logger.warn("#{leg_id} failed: #{inspect(reason)}")
    {:ok, call |> play("unavailable.wav") |> hangup()}
  end

  def handle_leg_event(call, leg_id, :bye) do
    Logger.info("#{leg_id} hung up")
    {:ok, call |> hangup()}
  end

  def handle_leg_event(call, _leg_id, {:refer_requested, to_uri}) do
    Logger.info("Transfer requested to #{to_uri}")
    {:ok, call}
  end

  def handle_leg_event(call, _leg_id, _event) do
    {:ok, call}
  end
end
```

### Leg Events

| Event | Description |
|-------|-------------|
| `:trying` | Outbound INVITE sent |
| `:ringing` | Received 180 Ringing |
| `{:early_media, sdp}` | Received 183 with SDP |
| `{:answered, sdp}` | Received 200 OK |
| `{:failed, reason}` | Leg failed |
| `:bye` | Remote party sent BYE |
| `:cancelled` | Leg cancelled (another answered) |
| `:held` | Leg placed on hold |
| `:resumed` | Leg resumed |
| `{:refer_requested, uri}` | Remote sent REFER |
| `{:transfer_complete, leg_id}` | Transfer succeeded |
| `{:transfer_failed, reason}` | Transfer failed |

### Return Values

| Return | Effect |
|--------|--------|
| `{:ok, call}` | Continue |
| `{:bridge, leg_id, call}` | Connect this leg to A-leg |
| `{:reject_refer, reason, call}` | Reject REFER request |

## Media Modes

### Proxy Mode (default)

```
Caller <──RTP──> Parrot <──RTP──> Destination
```

- Full control: recording, transcoding, injection
- Higher latency
- Required for mid-call features

### Direct Mode

```
Caller <────────RTP────────> Destination
        (SIP through Parrot)
```

- Lower latency
- No mid-call media manipulation
- SDP rewriting for direct path

## Error Handling

Handler controls all termination. When a leg fails or ends:

1. B2BUA notifies handler via `handle_leg_event/3`
2. Handler decides what to do with remaining legs
3. No automatic cleanup - explicit `hangup()` or `hangup_leg()` required

## Transcoding

Not in initial scope. Current approach:
- Negotiate common codec between legs
- Fail bridge if no common codec

Building blocks exist in parrot_media (G711, Opus, FFmpeg resampler) for future transcoding epic.

## Testing Strategy

### Unit Tests

- `Leg` struct and state transitions
- `RingStrategy` configuration
- `MediaBridge` connect/pause/resume

### Integration Tests

- Bridge lifecycle: originate → ringing → answered → connected → bye
- Fork scenarios: all ring strategies
- Hold/resume flow
- Transfer flows (blind, attended)
- Error cases: timeout, rejection, network failure

### SIPp Scenarios

| Scenario | Description |
|----------|-------------|
| `b2bua/uac_bridge_basic.xml` | Simple bridge, B-leg answers |
| `b2bua/uac_bridge_reject.xml` | B-leg rejects |
| `b2bua/uac_fork_simultaneous.xml` | Fork, first answer wins |
| `b2bua/uac_hold_resume.xml` | Hold/resume mid-call |
| `b2bua/uac_blind_transfer.xml` | REFER transfer |
| `b2bua/uas_refer_inbound.xml` | Handle incoming REFER |

## Implementation Tasks

1. **Leg module** - Struct, state transitions, helpers
2. **RingStrategy module** - Strategy configs
3. **B2BUA GenServer** - Core session management
4. **MediaBridge** - RTP forwarding between legs
5. **DSL operations** - bridge, fork, hold, resume, transfer in Call.ex
6. **ActionExecutor integration** - Wire up operations
7. **Handler callback** - handle_leg_event/3 in InviteHandler
8. **MediaSession extensions** - set_rtp_forward, pause_forward, resume_forward
9. **Unit tests** - All modules
10. **Integration tests** - Full flows
11. **SIPp scenarios** - End-to-end testing

## RFC References

- RFC 3261 Section 16 - B2BUA patterns
- RFC 5765 - B2BUA requirements
- RFC 3891 - REFER with Replaces (attended transfer)
- RFC 3515 - REFER method
- RFC 3264 - SDP offer/answer for hold (a=sendonly/recvonly)
