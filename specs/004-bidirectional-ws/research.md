# Research: Bidirectional WebSocket Audio Connection

**Date**: 2026-01-10
**Feature**: 004-bidirectional-ws

## Research Questions

### R1: How to integrate inbound WebSocket audio into Membrane pipeline?

**Decision**: Create `WsBidirectionalSource` Membrane Source element

**Rationale**:
- The existing `WsForkSink` sends audio FROM pipeline TO WebSocket (one direction)
- For bidirectional, we need a Source that receives audio FROM WebSocket INTO pipeline
- Membrane's push-based Source pattern fits well - the WebSocket connection pushes buffers
- The Source receives messages from the `WsBidirectionalConnector` GenServer

**Alternatives considered**:
1. ~~Modify existing pipeline dynamically~~ - Too complex, requires runtime pipeline changes
2. ~~Use a separate process that writes to Membrane~~ - This IS the approach, via Source element
3. ~~Direct injection into existing RTP sink~~ - Breaks separation of concerns

**Implementation approach**:
```elixir
# WsBidirectionalSource receives audio via messages from WsBidirectionalConnector
def handle_info({:ws_audio, binary_data}, ctx, state) do
  buffer = %Buffer{payload: binary_data, pts: calculate_pts(state)}
  {[buffer: {:output, buffer}], update_pts(state)}
end
```

### R2: How to handle audio format conversion?

**Decision**: Support PCM 16-bit 16kHz as default, with optional codec conversion

**Rationale**:
- OpenAI Realtime API uses PCM 16-bit 24kHz
- ElevenLabs uses PCM 16-bit various sample rates
- Most AI services accept PCM 16-bit at 16kHz or 24kHz
- RTP typically uses PCMU (G.711) at 8kHz

**Alternatives considered**:
1. ~~Require all AI services to match RTP format~~ - Not practical, AI services have fixed formats
2. ~~Use FFmpeg subprocess for conversion~~ - Adds latency and complexity
3. **Use Membrane's built-in converters** - Native Elixir, low latency

**Implementation approach**:
- Config specifies `inbound_format` and `outbound_format`
- Use `Membrane.FFmpeg.SWResample.Converter` for sample rate conversion
- Use existing codec elements for G.711 <-> PCM conversion

### R3: How to manage the bidirectional connection lifecycle?

**Decision**: Create `WsBidirectionalConnector` GenServer similar to `WsAudioForker`

**Rationale**:
- `WsAudioForker` already handles WebSocket lifecycle well
- GenServer pattern works for managing connection state
- Can reuse `Fresh` library callbacks pattern
- Registry lookup enables finding connection by call_id

**Alternatives considered**:
1. ~~Extend WsAudioForker with bidirectional mode~~ - Would complicate existing working code
2. ~~Use gen_statem for complex state~~ - Overkill, connection states are simple
3. **New GenServer following WsAudioForker pattern** - Clean separation, proven pattern

**Key differences from WsAudioForker**:
- Tracks both inbound and outbound mute states
- Manages a Source element (not just Sink)
- Handles inbound audio buffering for jitter
- Emits metrics for both directions

### R4: How to implement mute/unmute for each direction?

**Decision**: Boolean flags in GenServer state with message-based control

**Rationale**:
- Muting outbound = stop forwarding audio from Sink to WebSocket
- Muting inbound = stop forwarding audio from WebSocket to Source
- Simple boolean flags, no complex state machine needed
- Messages from DSL layer toggle the flags

**Implementation approach**:
```elixir
# In WsBidirectionalConnector state
%{
  outbound_muted: false,
  inbound_muted: false,
  # ...
}

# Handle mute messages
def handle_cast({:mute, :outbound}, state), do: {:noreply, %{state | outbound_muted: true}}
def handle_cast({:mute, :inbound}, state), do: {:noreply, %{state | inbound_muted: true}}
```

### R5: How to integrate with the DSL layer (Parrot.Call)?

**Decision**: Add new operations to `Parrot.Call` and `ActionExecutor`

**Rationale**:
- Follows existing pattern for `fork_media`, `play`, etc.
- Operations are added to `__operations__` list in Call struct
- ActionExecutor processes them and sends messages to MediaSession

**New operations in Parrot.Call**:
- `connect_bidirectional_ws/2` - Establish connection
- `disconnect_bidirectional_ws/1` - Close connection
- `mute_outbound/1`, `unmute_outbound/1` - Control caller-to-AI audio
- `mute_inbound/1`, `unmute_inbound/1` - Control AI-to-caller audio
- `send_ws_message/2` - Send text/JSON to WebSocket

### R6: How to implement observability (telemetry)?

**Decision**: Use `:telemetry` library with structured events

**Rationale**:
- Standard Elixir/Erlang approach for metrics
- Integrates with common observability tools (Prometheus, DataDog)
- Already used in Membrane ecosystem

**Telemetry events**:
```elixir
# Connection lifecycle
[:parrot_media, :bidirectional_ws, :connect, :start]
[:parrot_media, :bidirectional_ws, :connect, :stop]
[:parrot_media, :bidirectional_ws, :disconnect]
[:parrot_media, :bidirectional_ws, :reconnect]

# Audio metrics (periodic, e.g., every 1 second)
[:parrot_media, :bidirectional_ws, :audio, :stats]
# Measurements: frames_sent, frames_received, latency_ms, buffer_depth

# Error events
[:parrot_media, :bidirectional_ws, :error]
```

### R7: How to handle jitter buffering for inbound audio?

**Decision**: Fixed-size circular buffer in WsBidirectionalSource

**Rationale**:
- Network jitter can cause uneven packet arrival
- Buffer smooths playback at cost of small latency increase
- 50-100ms buffer is typical for real-time audio

**Implementation approach**:
- Configurable buffer size (default: 3 frames at 20ms = 60ms)
- Ring buffer using Erlang's `:queue`
- Start playback only after buffer reaches minimum depth
- Drop oldest frames if buffer overflows

### R8: How to enforce single connection per call?

**Decision**: Track connection state in Call.Server, reject second connection attempt

**Rationale**:
- Clarification specified only one bidirectional connection per call
- Simpler than managing multiple connections
- Call.Server already manages call state

**Implementation approach**:
```elixir
# In Call.Server state
%{
  bidirectional_ws_pid: nil | pid(),
  # ...
}

# In ActionExecutor.execute_connect_bidirectional_ws
case call.__bidirectional_ws_pid__ do
  nil -> # OK, proceed with connection
  _pid -> {:error, :already_connected}
end
```

## Summary of Key Decisions

| Area | Decision |
|------|----------|
| Inbound audio | New Membrane Source element (`WsBidirectionalSource`) |
| Outbound audio | New Membrane Sink element (`WsBidirectionalSink`) |
| Connection management | New GenServer (`WsBidirectionalConnector`) |
| Audio format | PCM 16-bit default, configurable with Membrane converters |
| Mute control | Boolean flags with message-based control |
| DSL integration | New operations in `Parrot.Call` + `ActionExecutor` handlers |
| Observability | `:telemetry` library with structured events |
| Jitter buffer | Ring buffer in Source element (60ms default) |
| Single connection | Tracked in Call.Server, reject duplicates |

## Dependencies to Add

```elixir
# mix.exs for parrot_media
{:telemetry, "~> 1.2"}  # Already present in most Elixir projects
# Fresh and Membrane already dependencies
```

## Open Questions (Deferred to Implementation)

1. **Exact telemetry metric names** - Will finalize during implementation
2. **Jitter buffer tuning** - May need adjustment based on real-world testing
3. **Reconnection behavior during audio flow** - Need to handle gracefully
