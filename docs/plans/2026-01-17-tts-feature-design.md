# TTS Feature Design

**Date:** 2026-01-17
**Status:** Draft

## Overview

Add text-to-speech capabilities to the Parrot DSL, allowing dynamic audio prompts without pre-recorded files.

**Use cases:**
- Dynamic content (account balances, names, dates, confirmation numbers)
- Rapid prototyping (build IVRs without recording audio first)
- Multi-language support (same text, different voices/languages)

## DSL API

Mirror the existing file-based functions:

```elixir
# Basic usage - uses default profile
call |> say("Your balance is $#{balance}")

# With options
call |> say("Welcome back, #{name}", profile: :premium, voice: "rachel")

# TTS prompt with DTMF collection
call |> say_prompt("Enter your 4-digit PIN", max: 4, timeout: 10_000)

# Mix TTS and files in the same call flow
call
|> answer()
|> play("intro-music.wav")
|> say("Hello #{name}")
|> say_prompt("Enter your PIN", max: 4)
```

**New functions in `Parrot.Call`:**
- `say/2` - Say text using default profile
- `say/3` - Say text with options (profile, voice override, etc.)
- `say_prompt/3` - Say text then collect DTMF

**Operations stored as:**
```elixir
{:say, "text content", opts}
```

## Provider Configuration

Named profiles in application config:

```elixir
# config/config.exs
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
    ],
    spanish: [
      provider: :google,
      voice: "es-ES-Standard-A",
      language_code: "es-ES"
    ]
  ],

  credentials: [
    openai: [api_key: {:system, "OPENAI_API_KEY"}],
    elevenlabs: [api_key: {:system, "ELEVENLABS_API_KEY"}],
    google: [credentials_file: "priv/gcp-credentials.json"],
    polly: [region: "us-east-1"]
  ]
```

**Usage:**
```elixir
call |> say("Hello")                        # uses :standard (default)
call |> say("Hola", profile: :spanish)      # uses :spanish profile
call |> say("Hello", profile: :premium)     # uses :premium profile

# One-off override without defining a profile
call |> say("Hello", provider: :openai, voice: "nova")
```

**Supported providers at launch:**
- OpenAI TTS (`tts-1`, `tts-1-hd`)
- ElevenLabs (multilingual, turbo models)
- Google Cloud TTS (Standard, WaveNet, Neural2)
- Amazon Polly (Standard, Neural)

## Provider Behaviour

```elixir
defmodule Parrot.TTS.Provider do
  @moduledoc """
  Behaviour for TTS provider implementations.
  """

  @type audio_format :: :pcm | :mp3 | :wav | :ogg
  @type voice_config :: keyword()

  @doc "Generate speech audio from text"
  @callback synthesize(text :: String.t(), voice_config()) ::
    {:ok, audio_data :: binary(), audio_format()} |
    {:error, reason :: term()}

  @doc "List available voices for this provider"
  @callback list_voices(credentials :: keyword()) ::
    {:ok, [voice_info :: map()]} |
    {:error, reason :: term()}

  @doc "Validate provider configuration"
  @callback validate_config(config :: keyword()) ::
    :ok | {:error, reason :: term()}
end
```

Users can implement custom providers:

```elixir
defmodule MyApp.TTS.LocalProvider do
  @behaviour Parrot.TTS.Provider

  @impl true
  def synthesize(text, opts) do
    # Call local TTS engine (e.g., Piper, Coqui)
    {:ok, audio_binary, :wav}
  end

  # ... other callbacks
end
```

## Caching System

**Cache behaviour:**

```elixir
defmodule Parrot.TTS.Cache do
  @moduledoc """
  Behaviour for TTS audio caching backends.
  """

  @type cache_key :: String.t()
  @type audio_data :: binary()
  @type metadata :: %{format: atom(), provider: atom(), created_at: DateTime.t()}

  @callback get(cache_key()) :: {:ok, audio_data(), metadata()} | :miss
  @callback put(cache_key(), audio_data(), metadata()) :: :ok | {:error, term()}
  @callback delete(cache_key()) :: :ok
  @callback clear() :: :ok
end
```

**Cache key generation** - deterministic hash of text + voice config:
```elixir
# Key = hash of: text + provider + voice + model + any audio settings
"tts_a1b2c3d4e5f6..."
```

**Built-in backends:**

```elixir
# ETS (in-memory, default)
config :parrot, :tts_cache,
  backend: Parrot.TTS.Cache.ETS,
  max_entries: 10_000

# Disk
config :parrot, :tts_cache,
  backend: Parrot.TTS.Cache.Disk,
  path: "priv/tts_cache",
  ttl: :timer.hours(24 * 7)
```

**Async flow:**
1. `say/2` called - check cache
2. Cache hit - play immediately
3. Cache miss - fetch from provider async, cache result, play when ready

## Error Handling

**Handler callback:**

```elixir
defmodule Parrot.InviteHandler do
  @callback handle_tts_error(
    text :: String.t(),
    error :: term(),
    call :: Parrot.Call.t()
  ) :: {:noreply, Parrot.Call.t()} | Parrot.Call.t()
end
```

**Default implementation** (skip and continue):

```elixir
def handle_tts_error(text, error, call) do
  Logger.warning("TTS failed for #{inspect(text)}: #{inspect(error)}")
  {:noreply, call}
end
```

**Custom handling examples:**

```elixir
# Play fallback audio
def handle_tts_error(_text, _error, call) do
  call |> play("sorry-technical-difficulties.wav")
end

# Retry with different provider
def handle_tts_error(text, _error, call) do
  call |> say(text, profile: :backup_provider)
end

# Hang up on critical prompts
def handle_tts_error(_text, _error, call) do
  call |> play("goodbye.wav") |> hangup()
end
```

## Integration with Media Layer

**ActionExecutor changes:**

```elixir
defp execute_operation({:say, text, opts}, call, context) do
  profile = Keyword.get(opts, :profile, default_profile())

  case Parrot.TTS.Synthesizer.get_audio(text, profile, opts) do
    {:ok, audio_file_path} ->
      execute_operation({:play, audio_file_path, opts}, call, context)

    {:error, reason} ->
      invoke_callback(:handle_tts_error, [text, reason], call, context)
  end
end

defp execute_operation({:say_prompt, text, collect_opts}, call, context) do
  call = Call.assign(call, :__pending_collect__, collect_opts)
  execute_operation({:say, text, []}, call, context)
end
```

**Synthesizer module:**

```elixir
defmodule Parrot.TTS.Synthesizer do
  def get_audio(text, profile, opts) do
    cache_key = build_cache_key(text, profile, opts)

    case Cache.get(cache_key) do
      {:ok, audio_data, meta} ->
        {:ok, write_temp_file(audio_data, meta.format)}

      :miss ->
        fetch_and_cache(text, profile, opts, cache_key)
    end
  end
end
```

Audio flows through existing `MediaSession` and pipeline infrastructure unchanged.

## Module Structure

**New modules:**

```
apps/parrot/lib/parrot/tts/
├── provider.ex              # Provider behaviour
├── cache.ex                 # Cache behaviour
├── cache/
│   ├── ets.ex               # ETS backend
│   └── disk.ex              # Disk backend
├── providers/
│   ├── openai.ex            # OpenAI TTS
│   ├── elevenlabs.ex        # ElevenLabs
│   ├── google.ex            # Google Cloud TTS
│   └── polly.ex             # Amazon Polly
└── synthesizer.ex           # Coordination logic
```

**Modified modules:**
- `Parrot.Call` - Add `say/2`, `say/3`, `say_prompt/3`
- `Parrot.InviteHandler` - Add `handle_tts_error/3` callback
- `Parrot.Bridge.ActionExecutor` - Handle `:say` operations

## Out of Scope

Explicitly NOT included:
- No pre-warming / startup caching
- No SSML support (users can add via custom provider if needed)
- No template system (users interpolate strings themselves)
- No streaming TTS (async fetch + cache is sufficient)
- No automatic language detection
- No voice cloning APIs
