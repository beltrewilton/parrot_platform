# Quickstart: TTS in Parrot DSL

**Feature**: 009-dsl-tts

## Configuration

Add TTS configuration to your `config/config.exs`:

```elixir
config :parrot, :tts,
  default_profile: :standard,

  profiles: [
    standard: [
      provider: :openai,
      voice: "alloy",
      model: "tts-1"
    ],
    premium: [
      provider: :elevenlabs,
      voice: "rachel",
      model: "eleven_multilingual_v2"
    ]
  ],

  credentials: [
    openai: [api_key: {:system, "OPENAI_API_KEY"}],
    elevenlabs: [api_key: {:system, "ELEVENLABS_API_KEY"}]
  ],

  cache: [
    backend: Parrot.TTS.Cache.ETS,
    max_entries: 10_000
  ]
```

## Basic Usage

### Simple TTS Playback

```elixir
defmodule MyApp.BalanceHandler do
  use Parrot.InviteHandler

  def handle_invite(call) do
    balance = get_user_balance(call.from)

    call
    |> answer()
    |> say("Hello! Your current balance is $#{balance}.")
    |> hangup()
  end
end
```

### TTS with Profile Selection

```elixir
def handle_invite(call) do
  call
  |> answer()
  |> say("Welcome to premium support.", profile: :premium)
end
```

### TTS Prompt with DTMF Collection

```elixir
def handle_invite(call) do
  call
  |> answer()
  |> say_prompt("Please enter your 4-digit PIN.", max: 4, timeout: 10_000)
end

def handle_dtmf(digits, call) do
  if verify_pin(digits) do
    call |> say("PIN verified. How can I help you?")
  else
    call |> say("Invalid PIN. Goodbye.") |> hangup()
  end
end
```

### Mixed File and TTS Playback

```elixir
def handle_invite(call) do
  user_name = lookup_user_name(call.from)

  call
  |> answer()
  |> play("priv/audio/welcome-music.wav")
  |> say("Hello #{user_name}, welcome back!")
  |> play("priv/audio/menu-options.wav")
end
```

## Error Handling

### Default Behavior

By default, TTS errors are logged and the call continues:

```elixir
# Default implementation (you don't need to write this)
def handle_tts_error(text, error, call) do
  Logger.warning("TTS failed: #{inspect(error)}")
  {:noreply, call}  # Continue without playing audio
end
```

### Custom Error Handler

Override to implement fallback behavior:

```elixir
defmodule MyApp.RobustHandler do
  use Parrot.InviteHandler

  def handle_tts_error(_text, _error, call) do
    # Play fallback audio file
    call |> play("priv/audio/sorry-technical-difficulties.wav")
  end
end
```

### Retry with Different Provider

```elixir
def handle_tts_error(text, _error, %{assigns: %{tts_retry: true}} = call) do
  # Already retried, give up
  call |> play("priv/audio/sorry.wav")
end

def handle_tts_error(text, _error, call) do
  # Retry with backup provider
  call
  |> assign(:tts_retry, true)
  |> say(text, profile: :backup)
end
```

## Testing

### Unit Test with Mock Provider

```elixir
defmodule MyApp.TTSTest do
  use ExUnit.Case

  test "say/2 adds operation to call" do
    call = Parrot.Call.new()
    result = call |> Parrot.Call.say("Hello")

    operations = Parrot.Call.get_operations(result)
    assert {:say, "Hello", []} in operations
  end
end
```

### Integration Test

```elixir
defmodule MyApp.TTSIntegrationTest do
  use ExUnit.Case

  @tag :integration
  test "TTS plays audio to caller" do
    # Use SIPp or pjsua to make call
    # Verify audio is heard
  end
end
```

## Caching Behavior

- First call synthesizes and caches audio
- Subsequent calls with same text + profile use cache
- Different text or profile = new cache entry
- ETS cache: In-memory, lost on restart
- Disk cache: Persistent, respects TTL

```elixir
# These share cache entry (same text, same profile)
call |> say("Welcome")
call |> say("Welcome")

# These are different cache entries
call |> say("Welcome")
call |> say("Welcome", profile: :premium)
call |> say("Welcome!", profile: :standard)  # Different text
```
