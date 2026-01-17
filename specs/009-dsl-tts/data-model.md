# Data Model: DSL Text-to-Speech Support

**Feature**: 009-dsl-tts
**Date**: 2026-01-17

## Entities

### Profile

A named configuration for TTS synthesis.

```elixir
%Parrot.TTS.Profile{
  name: atom(),           # :default, :premium, :spanish, etc.
  provider: atom(),       # :openai, :elevenlabs, :google, :polly
  voice: String.t(),      # Provider-specific voice ID
  model: String.t(),      # Provider-specific model ID
  format: atom(),         # :mp3, :pcm, :wav, :ogg
  credentials: keyword()  # Provider-specific credentials
}
```

**Validation rules**:
- `name` must be a valid atom
- `provider` must be one of the supported provider atoms
- `voice` and `model` are optional; defaults provided per provider
- `credentials` can reference environment variables via `{:system, "VAR_NAME"}`

**Source**: Application configuration at `:parrot, :tts, :profiles`

---

### CacheEntry

Stored audio data with metadata.

```elixir
%Parrot.TTS.CacheEntry{
  key: String.t(),           # SHA256 hash of text + config
  audio_data: binary(),      # Raw audio bytes
  format: atom(),            # :mp3, :pcm, :wav, :ogg
  provider: atom(),          # Which provider generated this
  size_bytes: non_neg_integer(),
  created_at: DateTime.t(),
  expires_at: DateTime.t() | nil  # nil = never expires (ETS)
}
```

**Validation rules**:
- `key` must be 64-character hex string (SHA256)
- `audio_data` must not be empty
- `format` must be a known audio format

**Lifecycle**:
- Created: On first synthesis of a text+config combination
- Read: On cache hit for subsequent requests
- Deleted: On TTL expiration (disk cache) or explicit clear

---

### SynthesisRequest

Internal request tracking for concurrent access handling.

```elixir
%Parrot.TTS.SynthesisRequest{
  cache_key: String.t(),
  text: String.t(),
  profile: Profile.t(),
  waiters: [GenServer.from()],  # Processes waiting for result
  started_at: DateTime.t()
}
```

**State transitions**:
1. `pending` → Request received, synthesis starting
2. `in_progress` → API call in flight
3. `completed` → Result cached, waiters notified
4. `failed` → Error occurred, waiters notified with error

---

## Relationships

```
┌─────────────┐      1:N      ┌─────────────────┐
│   Profile   │──────────────▶│   CacheEntry    │
│             │               │ (keyed by hash) │
└─────────────┘               └─────────────────┘
       │
       │ 1:N
       ▼
┌─────────────────────┐
│ SynthesisRequest    │
│ (in-flight only)    │
└─────────────────────┘
```

- One Profile can generate many CacheEntries (different text, same voice)
- One Profile can have multiple SynthesisRequests in-flight
- CacheEntries are independent once created (no Profile reference stored)

---

## Configuration Schema

```elixir
# config/config.exs
config :parrot, :tts,
  default_profile: :standard,

  profiles: [
    standard: [
      provider: :openai,
      voice: "alloy",
      model: "tts-1",
      format: :mp3
    ],
    premium: [
      provider: :elevenlabs,
      voice: "rachel",
      model: "eleven_multilingual_v2",
      format: :mp3
    ]
  ],

  credentials: [
    openai: [api_key: {:system, "OPENAI_API_KEY"}],
    elevenlabs: [api_key: {:system, "ELEVENLABS_API_KEY"}],
    google: [credentials_file: "priv/gcp-credentials.json"],
    polly: [region: "us-east-1"]
  ],

  cache: [
    backend: Parrot.TTS.Cache.ETS,
    max_entries: 10_000
    # Or for disk:
    # backend: Parrot.TTS.Cache.Disk,
    # path: "priv/tts_cache",
    # ttl: :timer.hours(24 * 7)
  ]
```

---

## Operations on Call

New operations added to `Parrot.Call.__operations__`:

```elixir
# say/2
{:say, "text content", []}

# say/3 with options
{:say, "text content", [profile: :premium, voice: "nova"]}

# say_prompt/3
{:say_prompt, "text content", [max: 4, timeout: 10_000]}
```

These are processed by `ActionExecutor` which:
1. Resolves profile from options or default
2. Calls `Synthesizer.get_audio/3`
3. Delegates to existing `:play` infrastructure
