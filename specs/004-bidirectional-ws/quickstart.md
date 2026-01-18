# Quickstart: Bidirectional WebSocket Audio

**Feature**: 004-bidirectional-ws

This guide shows how to connect a phone call to a speech-to-speech AI service using the bidirectional WebSocket feature.

## Basic Usage

### 1. Connect a call to OpenAI Realtime API

```elixir
defmodule MyApp.AIAssistantHandler do
  use Parrot.InviteHandler

  @impl true
  def handle_request(call) do
    api_key = System.get_env("OPENAI_API_KEY")

    call
    |> answer()
    |> connect_bidirectional_ws("wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview",
         headers: [
           {"Authorization", "Bearer #{api_key}"},
           {"OpenAI-Beta", "realtime=v1"}
         ],
         callback_module: MyApp.OpenAICallback,
         sample_rate: 24000
       )
  end
end
```

### 2. Handle AI service events

```elixir
defmodule MyApp.OpenAICallback do
  @behaviour ParrotMedia.WsBidirectional.Callback
  require Logger

  @impl true
  def handle_event({:connected}, state) do
    Logger.info("Connected to OpenAI")
    {:ok, state}
  end

  @impl true
  def handle_event({:ws_message, data}, state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "error", "error" => error}} ->
        Logger.error("OpenAI error: #{inspect(error)}")
        {:ok, state}

      {:ok, event} ->
        Logger.debug("OpenAI event: #{event["type"]}")
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  @impl true
  def handle_event({:disconnected, reason}, state) do
    Logger.warning("OpenAI disconnected: #{inspect(reason)}")
    {:ok, state}
  end

  @impl true
  def handle_event({:reconnecting, attempt}, state) do
    Logger.info("Reconnecting to OpenAI (attempt #{attempt})")
    {:ok, state}
  end

  @impl true
  def handle_event({:failed, reason}, state) do
    Logger.error("OpenAI connection failed: #{inspect(reason)}")
    {:ok, state}
  end

  @impl true
  def handle_event(_event, state), do: {:ok, state}
end
```

## Advanced Usage

### Muting audio directions

```elixir
# Mute the caller's audio to AI (e.g., during AI response)
call |> mute_outbound()

# Unmute when AI is done speaking
call |> unmute_outbound()

# Mute AI audio to caller (e.g., during transfer)
call |> mute_inbound()
```

### Sending control messages to AI service

```elixir
# Send a JSON control message
call
|> send_ws_message(Jason.encode!(%{
     type: "response.create",
     response: %{
       modalities: ["text", "audio"],
       instructions: "You are a helpful assistant."
     }
   }))
```

### Disconnecting

```elixir
# Explicitly disconnect (also happens automatically on hangup)
call |> disconnect_bidirectional_ws()
```

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `headers` | HTTP headers for auth | `[]` |
| `callback_module` | Event handler module | `nil` |
| `callback_state` | Initial callback state | `%{}` |
| `inbound_format` | Audio format from AI (`:pcm_16le`, `:pcmu`, `:opus`) | `:pcm_16le` |
| `outbound_format` | Audio format to AI (`:pcm_16le`, `:pcmu`, `:opus`) | `:pcm_16le` |
| `sample_rate` | Sample rate in Hz | `16000` |
| `buffer_size` | Max frames to buffer during reconnection (1-500) | `100` |
| `jitter_buffer_ms` | Jitter buffer size in ms | `60` |
| `connect_timeout_ms` | WebSocket connection timeout in ms | `5000` |
| `max_retries` | Max reconnection attempts before failure | `5` |

## Supported AI Services

The bidirectional WebSocket feature works with any service that:
- Accepts WebSocket connections
- Sends/receives audio as binary frames
- Sends control messages as text/JSON frames

Tested with:
- OpenAI Realtime API
- ElevenLabs Conversational AI
- Custom WebSocket audio servers

## Error Handling

```elixir
def handle_event({:failed, reason}, state) do
  # Connection permanently failed - handle gracefully
  case reason do
    :max_retries_exceeded ->
      # Could fall back to TTS/STT or play error message
      Logger.error("AI service unavailable")

    {:auth_error, _} ->
      Logger.error("AI authentication failed")

    _ ->
      Logger.error("AI connection failed: #{inspect(reason)}")
  end

  {:ok, state}
end
```

## Testing

Use the mock WebSocket server for testing:

```elixir
# In test setup
{:ok, mock_server} = MockWsServer.start_link(port: 9999)

# In test
call
|> answer()
|> connect_bidirectional_ws("ws://localhost:9999/test",
     callback_module: TestCallback
   )

# Verify audio flows
MockWsServer.send_audio(mock_server, test_audio_data)
assert_receive {:audio_played, ^test_audio_data}
```
