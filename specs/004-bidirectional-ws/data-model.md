# Data Model: Bidirectional WebSocket Audio Connection

**Date**: 2026-01-10
**Feature**: 004-bidirectional-ws

## Entities

### BidirectionalConfig

Configuration for establishing a bidirectional WebSocket connection.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `connection_id` | `String.t()` | Yes | - | Unique identifier for this connection |
| `url` | `String.t()` | Yes | - | WebSocket URL (must start with ws:// or wss://) |
| `headers` | `[{String.t(), String.t()}]` | No | `[]` | HTTP headers for authentication |
| `callback_module` | `module() \| nil` | No | `nil` | Module implementing `Callback` behaviour |
| `callback_state` | `term()` | No | `%{}` | Initial state for callback module |
| `inbound_format` | `:pcm_16le \| :pcmu \| :opus` | No | `:pcm_16le` | Audio format received from WebSocket |
| `outbound_format` | `:pcm_16le \| :pcmu \| :opus` | No | `:pcm_16le` | Audio format sent to WebSocket |
| `sample_rate` | `pos_integer()` | No | `16000` | Sample rate in Hz |
| `buffer_size` | `pos_integer()` | No | `100` | Max frames to buffer (1-500) |
| `jitter_buffer_ms` | `pos_integer()` | No | `60` | Jitter buffer size in milliseconds |
| `connect_timeout_ms` | `pos_integer()` | No | `5000` | Connection timeout |
| `max_retries` | `non_neg_integer()` | No | `5` | Max reconnection attempts |

**Validation Rules**:
- `connection_id` must be non-empty string
- `url` must start with `ws://` or `wss://`
- `buffer_size` must be 1-500
- `sample_rate` must be positive integer
- `jitter_buffer_ms` must be positive integer

### BidirectionalConnection (Runtime State)

Runtime state of an active bidirectional connection.

| Field | Type | Description |
|-------|------|-------------|
| `config` | `BidirectionalConfig.t()` | Connection configuration |
| `conn_pid` | `pid()` | Fresh WebSocket connection process |
| `source_pid` | `pid() \| nil` | Membrane Source element for inbound audio |
| `sink_pid` | `pid() \| nil` | Membrane Sink element for outbound audio |
| `connection_state` | `connection_state()` | Current connection state |
| `outbound_muted` | `boolean()` | Whether outbound (caller→AI) is muted |
| `inbound_muted` | `boolean()` | Whether inbound (AI→caller) is muted |
| `frames_sent` | `non_neg_integer()` | Total frames sent to WebSocket |
| `frames_received` | `non_neg_integer()` | Total frames received from WebSocket |
| `frames_dropped` | `non_neg_integer()` | Frames dropped due to backpressure |
| `reconnect_count` | `non_neg_integer()` | Number of reconnection attempts |
| `buffer` | `:queue.queue()` | Outbound frame buffer during disconnection |
| `buffer_size` | `non_neg_integer()` | Current buffer occupancy |
| `connected_at` | `DateTime.t() \| nil` | When connection was established |

**State Transitions**:
```
:connecting → :connected (on successful WebSocket handshake)
:connected → :disconnected (on WebSocket close/error)
:disconnected → :reconnecting (on automatic retry)
:reconnecting → :connected (on successful reconnection)
:reconnecting → :failed (on max retries exceeded)
:* → :stopped (on explicit disconnect)
```

### ConnectionState (Enum)

```elixir
@type connection_state ::
  :connecting     # Initial connection in progress
  | :connected    # WebSocket connected and streaming
  | :disconnected # Connection lost, will retry
  | :reconnecting # Retry attempt in progress
  | :failed       # Max retries exceeded, permanent failure
  | :stopped      # Explicitly disconnected
```

### CallbackEvent (Union Type)

Events delivered to the callback module.

```elixir
@type callback_event ::
  # Connection lifecycle
  {:bidirectional_event, connection_id, :connected}
  | {:bidirectional_event, connection_id, {:disconnected, reason}}
  | {:bidirectional_event, connection_id, {:reconnecting, attempt}}
  | {:bidirectional_event, connection_id, {:failed, reason}}

  # WebSocket messages (non-audio)
  | {:bidirectional_event, connection_id, {:ws_message, binary() | String.t()}}

  # Operational warnings
  | {:bidirectional_event, connection_id, {:backpressure_warning, drops}}
```

### TelemetryMetrics

Metrics emitted via `:telemetry`.

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:parrot_media, :bidirectional_ws, :connect, :start]` | - | `%{connection_id, url}` |
| `[:parrot_media, :bidirectional_ws, :connect, :stop]` | `duration_ms` | `%{connection_id, url, result}` |
| `[:parrot_media, :bidirectional_ws, :disconnect]` | - | `%{connection_id, reason}` |
| `[:parrot_media, :bidirectional_ws, :reconnect]` | `attempt` | `%{connection_id}` |
| `[:parrot_media, :bidirectional_ws, :audio, :stats]` | `frames_sent, frames_received, latency_ms, buffer_depth` | `%{connection_id}` |
| `[:parrot_media, :bidirectional_ws, :error]` | - | `%{connection_id, error, context}` |

## Relationships

```
┌─────────────────┐         ┌──────────────────────────┐
│ Parrot.Call     │────────▶│ WsBidirectionalConnector │
│                 │  1:0..1 │ (GenServer)              │
└─────────────────┘         └──────────────────────────┘
                                      │
                            ┌─────────┴─────────┐
                            │                   │
                            ▼                   ▼
               ┌────────────────────┐  ┌────────────────────┐
               │ WsBidirectionalSink│  │WsBidirectionalSource│
               │ (Membrane Sink)    │  │ (Membrane Source)   │
               │ Caller → WebSocket │  │ WebSocket → Caller  │
               └────────────────────┘  └─────────────────────┘
                            │                   │
                            └─────────┬─────────┘
                                      │
                                      ▼
                            ┌─────────────────┐
                            │ Fresh WebSocket │
                            │ Connection      │
                            └─────────────────┘
                                      │
                                      ▼
                            ┌─────────────────┐
                            │ AI Service      │
                            │ (External)      │
                            └─────────────────┘
```

## Registry Keys

| Registry | Key Pattern | Value |
|----------|-------------|-------|
| `ParrotMedia.BidirectionalRegistry` | `{:bidirectional, connection_id}` | `pid()` of WsBidirectionalConnector |

## Message Formats

### Outbound (to WebSocket)

Audio frames are sent as binary WebSocket messages:
```elixir
# PCM 16-bit little-endian
<<sample1::little-signed-16, sample2::little-signed-16, ...>>
```

### Inbound (from WebSocket)

Audio received as binary frames, forwarded to Source element:
```elixir
{:ws_audio, binary_data}
```

Control/text messages forwarded to callback:
```elixir
{:ws_message, json_string}
```

### Internal Messages

```elixir
# From DSL layer to Connector
{:mute, :outbound | :inbound}
{:unmute, :outbound | :inbound}
{:send_message, binary() | String.t()}
{:disconnect}

# From Connector to Source
{:ws_audio, binary_data}
{:connection_state, :connected | :disconnected}

# From Sink to Connector
{:audio_frame, binary_data}
```
