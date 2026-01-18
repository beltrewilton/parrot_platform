# DSL Action Contracts: Bidirectional WebSocket

**Date**: 2026-01-10
**Feature**: 004-bidirectional-ws

This document defines the public API contracts for bidirectional WebSocket operations in the Parrot DSL.

## Actions in `Parrot.Call`

### connect_bidirectional_ws/2

Establishes a bidirectional WebSocket connection to a speech-to-speech AI service.

```elixir
@spec connect_bidirectional_ws(Call.t(), String.t()) :: Call.t()
@spec connect_bidirectional_ws(Call.t(), String.t(), keyword()) :: Call.t()

# Usage
call
|> connect_bidirectional_ws("wss://api.openai.com/v1/realtime")
|> connect_bidirectional_ws("wss://api.openai.com/v1/realtime",
     headers: [{"Authorization", "Bearer #{api_key}"}],
     callback: MyAIHandler,
     inbound_format: :pcm_16le,
     sample_rate: 24000
   )
```

**Options**:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:connection_id` | `String.t()` | auto-generated | Unique identifier for this connection |
| `:headers` | `[{String.t(), String.t()}]` | `[]` | HTTP headers for WebSocket handshake |
| `:callback` | `module()` | `nil` | Module implementing `WsBidirectionalConnector.Callback` |
| `:callback_state` | `term()` | `%{}` | Initial state for callback |
| `:inbound_format` | `atom()` | `:pcm_16le` | Audio format from WebSocket |
| `:outbound_format` | `atom()` | `:pcm_16le` | Audio format to WebSocket |
| `:sample_rate` | `pos_integer()` | `16000` | Sample rate in Hz |
| `:jitter_buffer_ms` | `pos_integer()` | `60` | Jitter buffer size |

**Errors**:
- `{:error, :already_connected}` - Call already has a bidirectional connection
- `{:error, :invalid_state}` - Call not in `:answered` state
- `{:error, :no_media_session}` - MediaSession not available
- `{:error, :connection_failed}` - WebSocket connection failed

---

### disconnect_bidirectional_ws/1

Disconnects the active bidirectional WebSocket connection.

```elixir
@spec disconnect_bidirectional_ws(Call.t()) :: Call.t()

# Usage
call |> disconnect_bidirectional_ws()
```

**Behavior**:
- Gracefully closes WebSocket connection
- Stops Source and Sink Membrane elements
- Restores original audio path
- No-op if no connection active

---

### mute_outbound/1

Mutes the outbound audio direction (caller → AI service).

```elixir
@spec mute_outbound(Call.t()) :: Call.t()

# Usage
call |> mute_outbound()
```

**Behavior**:
- Stops sending caller audio to WebSocket
- AI service stops receiving caller speech
- Does not affect inbound (AI → caller) audio
- Idempotent - safe to call multiple times

---

### unmute_outbound/1

Unmutes the outbound audio direction.

```elixir
@spec unmute_outbound(Call.t()) :: Call.t()

# Usage
call |> unmute_outbound()
```

**Behavior**:
- Resumes sending caller audio to WebSocket
- Idempotent - safe to call multiple times

---

### mute_inbound/1

Mutes the inbound audio direction (AI service → caller).

```elixir
@spec mute_inbound(Call.t()) :: Call.t()

# Usage
call |> mute_inbound()
```

**Behavior**:
- Stops playing AI audio to caller
- AI service continues receiving caller audio (unless outbound also muted)
- Does not affect outbound (caller → AI) audio
- Idempotent - safe to call multiple times

---

### unmute_inbound/1

Unmutes the inbound audio direction.

```elixir
@spec unmute_inbound(Call.t()) :: Call.t()

# Usage
call |> unmute_inbound()
```

**Behavior**:
- Resumes playing AI audio to caller
- Idempotent - safe to call multiple times

---

### send_ws_message/2

Sends a text or binary message to the connected WebSocket.

```elixir
@spec send_ws_message(Call.t(), String.t() | binary()) :: Call.t()

# Usage - send JSON control message
call |> send_ws_message(Jason.encode!(%{type: "response.create"}))

# Usage - send binary data
call |> send_ws_message(<<binary_data::binary>>)
```

**Behavior**:
- Sends message immediately if connected
- Queues message if temporarily disconnected
- Returns error if no bidirectional connection active

**Errors**:
- `{:error, :not_connected}` - No bidirectional connection active

---

## Callback Behaviour

### WsBidirectionalConnector.Callback

```elixir
defmodule ParrotMedia.WsBidirectionalConnector.Callback do
  @callback init(args :: term()) :: {:ok, state()} | {:error, reason :: term()}

  @callback handle_bidirectional_event(event :: bidirectional_event(), state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}
end
```

**Event Types**:

```elixir
# Connection established
{:bidirectional_event, connection_id, :connected}

# Connection lost (will retry)
{:bidirectional_event, connection_id, {:disconnected, reason}}

# Reconnection attempt
{:bidirectional_event, connection_id, {:reconnecting, attempt :: pos_integer()}}

# Permanent failure
{:bidirectional_event, connection_id, {:failed, reason}}

# Non-audio WebSocket message received
{:bidirectional_event, connection_id, {:ws_message, data :: binary() | String.t()}}

# Backpressure warning
{:bidirectional_event, connection_id, {:backpressure_warning, drops :: pos_integer()}}
```

**Example Implementation**:

```elixir
defmodule MyApp.OpenAIHandler do
  @behaviour ParrotMedia.WsBidirectionalConnector.Callback
  require Logger

  @impl true
  def init(%{call_id: call_id}) do
    {:ok, %{call_id: call_id, session_id: nil}}
  end

  @impl true
  def handle_bidirectional_event({:bidirectional_event, _conn_id, :connected}, state) do
    Logger.info("AI connected for call #{state.call_id}")
    {:ok, state}
  end

  @impl true
  def handle_bidirectional_event({:bidirectional_event, _conn_id, {:ws_message, data}}, state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "session.created", "session" => %{"id" => session_id}}} ->
        Logger.info("OpenAI session created: #{session_id}")
        {:ok, %{state | session_id: session_id}}

      {:ok, %{"type" => "response.audio.delta"}} ->
        # Audio is handled automatically by the Source element
        {:ok, state}

      {:ok, %{"type" => "error", "error" => error}} ->
        Logger.error("OpenAI error: #{inspect(error)}")
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_bidirectional_event({:bidirectional_event, _conn_id, {:failed, reason}}, state) do
    Logger.error("AI connection failed: #{inspect(reason)}")
    {:stop, :ai_failed, state}
  end

  @impl true
  def handle_bidirectional_event(_event, state) do
    {:ok, state}
  end
end
```

---

## Operation Execution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Code (Handler)                       │
│                                                                  │
│  def handle_request(call) do                                     │
│    call                                                          │
│    |> answer()                                                   │
│    |> connect_bidirectional_ws("wss://api.openai.com/...",      │
│         headers: [{"Authorization", "Bearer ..."}],              │
│         callback: MyApp.OpenAIHandler)                           │
│  end                                                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Parrot.Call.Server                          │
│                                                                  │
│  - Extracts operations from Call struct                          │
│  - Passes to ActionExecutor                                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Parrot.Bridge.ActionExecutor                   │
│                                                                  │
│  execute_connect_bidirectional_ws/4:                             │
│  1. Validate call state (:answered)                              │
│  2. Check no existing connection                                 │
│  3. Start WsBidirectionalConnector                               │
│  4. Link Sink/Source to MediaSession pipeline                    │
│  5. Store connection_pid in Call state                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              ParrotMedia.WsBidirectionalConnector                │
│                                                                  │
│  - Manages WebSocket lifecycle                                   │
│  - Routes audio between Membrane elements and WebSocket          │
│  - Handles reconnection                                          │
│  - Emits telemetry events                                        │
└─────────────────────────────────────────────────────────────────┘
```
