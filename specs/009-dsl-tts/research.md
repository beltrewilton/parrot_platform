# Research: DSL Text-to-Speech Support

**Feature**: 009-dsl-tts
**Date**: 2026-01-17

## 1. Provider API Research

### OpenAI TTS

**Decision**: Use OpenAI TTS API v1
**Rationale**: Well-documented, simple REST API, high-quality voices
**Alternatives considered**: None - OpenAI is a specified requirement

- **Endpoint**: `POST https://api.openai.com/v1/audio/speech`
- **Auth**: Bearer token via `Authorization` header
- **Request format**: JSON with `model`, `voice`, `input`, `response_format`
- **Models**: `tts-1` (fast), `tts-1-hd` (high quality)
- **Voices**: `alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`
- **Output formats**: `mp3`, `opus`, `aac`, `flac`, `wav`, `pcm`
- **Rate limits**: Varies by tier, typically 50 RPM for free tier

### ElevenLabs

**Decision**: Use ElevenLabs Text-to-Speech API v1
**Rationale**: Industry-leading voice quality, extensive voice library
**Alternatives considered**: None - ElevenLabs is a specified requirement

- **Endpoint**: `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`
- **Auth**: `xi-api-key` header
- **Request format**: JSON with `text`, `model_id`, `voice_settings`
- **Models**: `eleven_multilingual_v2`, `eleven_turbo_v2`
- **Output formats**: `mp3_44100_128`, `pcm_16000`, `pcm_22050`, `pcm_24000`, `pcm_44100`
- **Rate limits**: Based on character quota per month

### Google Cloud TTS

**Decision**: Use Google Cloud Text-to-Speech API v1
**Rationale**: Wide language support, Neural2 voices, enterprise-grade
**Alternatives considered**: None - Google is a specified requirement

- **Endpoint**: `POST https://texttospeech.googleapis.com/v1/text:synthesize`
- **Auth**: OAuth2 or API key
- **Request format**: JSON with `input`, `voice`, `audioConfig`
- **Voice types**: Standard, WaveNet, Neural2
- **Output formats**: `LINEAR16`, `MP3`, `OGG_OPUS`
- **Rate limits**: 1000 requests/minute default

### Amazon Polly

**Decision**: Use AWS Polly via AWS SDK
**Rationale**: AWS integration, Neural TTS, SSML support (not used initially)
**Alternatives considered**: Direct REST API - SDK is cleaner for AWS auth

- **SDK**: `ex_aws_polly` or direct Polly API
- **Auth**: AWS credentials (access key, secret, region)
- **Request format**: `SynthesizeSpeech` action
- **Voice types**: Standard, Neural
- **Output formats**: `mp3`, `ogg_vorbis`, `pcm`
- **Rate limits**: 80 concurrent requests default

---

## 2. Cache Key Strategy

**Decision**: SHA256 hash of canonical JSON representation
**Rationale**: Deterministic, collision-resistant, handles all config variations
**Alternatives considered**:
- MD5: Faster but less collision-resistant
- Simple string concat: Non-deterministic with maps

**Key components** (in order):
1. `text` - The text to synthesize
2. `provider` - Provider atom (`:openai`, `:elevenlabs`, etc.)
3. `voice` - Voice identifier
4. `model` - Model identifier (provider-specific)
5. `format` - Requested output format

**Implementation**:
```elixir
def cache_key(text, config) do
  canonical = Jason.encode!(%{
    text: text,
    provider: config.provider,
    voice: config.voice,
    model: config.model,
    format: config.format
  })
  :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
end
```

---

## 3. Audio Format Conversion

**Decision**: Use FFmpeg via Exile for format conversion
**Rationale**: Membrane already uses Exile for media processing; consistent approach
**Alternatives considered**:
- Native Elixir libs: Limited format support
- System ffmpeg call: Already have Exile dependency

**Format compatibility with Membrane pipelines**:
- Pipeline expects: Linear PCM (16-bit, mono, 8kHz for G.711)
- OpenAI returns: MP3, WAV, PCM (various sample rates)
- ElevenLabs returns: MP3, PCM (various sample rates)
- Google returns: MP3, OGG, LINEAR16
- Polly returns: MP3, OGG, PCM

**Conversion strategy**:
1. Request format closest to target (PCM when available)
2. Cache in provider's native format
3. Convert on playback if needed (leverage existing pipeline)

**Recommendation**: Request PCM where available, otherwise MP3. Existing `ParrotMedia.SwitchableFileSource` can handle MP3/WAV files.

---

## 4. HTTP Client Selection

**Decision**: Use Req
**Rationale**: Modern, simple API, built on Finch for connection pooling
**Alternatives considered**:
- HTTPoison: Older, hackney-based
- Tesla: More complex, middleware-based
- Finch directly: Too low-level

**Req features used**:
- Automatic JSON encoding/decoding
- Retry with exponential backoff
- Connection pooling via Finch
- Async/await pattern

**Implementation pattern**:
```elixir
def synthesize(text, config) do
  Req.post!(
    config.endpoint,
    headers: auth_headers(config),
    json: build_request(text, config),
    receive_timeout: 30_000,
    retry: :transient,
    max_retries: 2
  )
end
```

---

## 5. Concurrent Cache Access

**Decision**: Use GenServer-based coordination with deferred responses
**Rationale**: Prevents thundering herd, simple implementation
**Alternatives considered**:
- ETS-based locking: Complex, race conditions possible
- No coordination: Wasteful duplicate API calls

**Pattern**:
1. First request for uncached phrase starts synthesis
2. Subsequent requests for same phrase wait for first to complete
3. All waiters receive result from single API call

**Implementation**: Track in-flight requests in Synthesizer GenServer state, reply to all waiters when synthesis completes.
