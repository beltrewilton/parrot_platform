# Feature Specification: DSL Text-to-Speech Support

**Feature Branch**: `009-dsl-tts`
**Created**: 2026-01-17
**Status**: Draft
**Input**: Add text-to-speech capabilities to Parrot DSL with provider-agnostic design, caching, and error handling

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Basic TTS Playback (Priority: P1)

As a developer building an IVR, I want to play dynamically generated speech from text so that I can provide personalized messages without pre-recording audio files.

**Why this priority**: This is the core functionality - without TTS playback, none of the other features matter. Enables dynamic content like account balances, names, and confirmation numbers.

**Independent Test**: Can be fully tested by calling `say("Hello, your balance is $50")` and hearing the synthesized audio played to the caller.

**Acceptance Scenarios**:

1. **Given** an answered call, **When** I call `say("Your balance is $50.00")`, **Then** the caller hears the synthesized speech
2. **Given** an answered call, **When** I call `say("Hello", profile: :premium)`, **Then** the speech is synthesized using the premium provider profile
3. **Given** an answered call with text containing special characters, **When** I call `say("Your order #12345 is ready")`, **Then** the text is spoken naturally without errors

---

### User Story 2 - TTS with DTMF Collection (Priority: P1)

As a developer building an IVR, I want to play a TTS prompt and then collect DTMF digits so that I can create interactive menus with dynamic prompts.

**Why this priority**: Prompting and collecting input is fundamental to IVR systems. This combines TTS with the existing DTMF collection capability.

**Independent Test**: Can be fully tested by calling `say_prompt("Enter your PIN", max: 4)` and verifying both audio playback and digit collection work.

**Acceptance Scenarios**:

1. **Given** an answered call, **When** I call `say_prompt("Enter your 4-digit PIN", max: 4, timeout: 10_000)`, **Then** the caller hears the prompt and can enter digits
2. **Given** an answered call with pending collect, **When** the TTS finishes playing, **Then** DTMF collection begins automatically
3. **Given** a say_prompt call, **When** the user enters a terminator digit, **Then** collection ends and `handle_dtmf_collected/2` is invoked

---

### User Story 3 - Provider Profiles Configuration (Priority: P2)

As a developer, I want to configure named TTS provider profiles so that I can easily switch between providers and voices without changing code.

**Why this priority**: Multiple providers support different use cases (cost vs quality, languages). Named profiles make this manageable.

**Independent Test**: Can be tested by configuring two profiles (standard and premium) and verifying `say("Hello")` uses standard while `say("Hello", profile: :premium)` uses premium.

**Acceptance Scenarios**:

1. **Given** application config with a default profile, **When** I call `say("Hello")` without options, **Then** the default profile is used
2. **Given** application config with multiple profiles, **When** I call `say("Hola", profile: :spanish)`, **Then** the spanish profile is used
3. **Given** a profile with specific voice settings, **When** TTS is synthesized, **Then** the configured voice is used

---

### User Story 4 - TTS Caching (Priority: P2)

As a developer, I want TTS audio to be cached so that repeated phrases don't incur additional API calls and latency.

**Why this priority**: Caching reduces costs and latency for common phrases. Essential for production use but not required for basic functionality.

**Independent Test**: Can be tested by calling `say("Welcome")` twice and verifying the second call uses cached audio (no API call).

**Acceptance Scenarios**:

1. **Given** an empty cache, **When** I call `say("Welcome")`, **Then** the audio is fetched from the provider and cached
2. **Given** cached audio for "Welcome", **When** I call `say("Welcome")` again, **Then** the cached audio is used without API call
3. **Given** different text or voice settings, **When** I call `say("Welcome", voice: "different")`, **Then** a new cache entry is created

---

### User Story 5 - TTS Error Handling (Priority: P3)

As a developer, I want to handle TTS failures gracefully so that my IVR doesn't crash when a provider is unavailable.

**Why this priority**: Error handling is important for production robustness but basic functionality works without it.

**Independent Test**: Can be tested by configuring an invalid API key and verifying `handle_tts_error/3` is invoked.

**Acceptance Scenarios**:

1. **Given** a TTS provider failure, **When** synthesis fails, **Then** the handler's `handle_tts_error/3` callback is invoked
2. **Given** a default handler implementation, **When** TTS fails, **Then** the error is logged and the call continues
3. **Given** a custom error handler that plays fallback audio, **When** TTS fails, **Then** the fallback audio plays

---

### User Story 6 - Custom TTS Provider (Priority: P3)

As a developer, I want to implement custom TTS providers so that I can use local TTS engines or unsupported cloud providers.

**Why this priority**: Extensibility is valuable for advanced users but not required for most use cases.

**Independent Test**: Can be tested by implementing a mock provider that returns static audio and verifying it's called.

**Acceptance Scenarios**:

1. **Given** a custom module implementing the Provider behaviour, **When** configured as a profile's provider, **Then** my custom synthesize/2 is called
2. **Given** a custom provider returning audio, **When** TTS is requested, **Then** the returned audio is played to the caller

---

### Edge Cases

- What happens when the TTS provider times out mid-synthesis? System invokes `handle_tts_error/3` with timeout error.
- How does the system handle empty text passed to `say("")`? System returns immediately without playing audio (no-op).
- What happens when cache storage (disk) runs out of space? Disk cache fails gracefully, synthesis still works but isn't cached.
- How are very long texts (>10,000 characters) handled? Provider may reject; system invokes error callback.
- What happens when multiple concurrent calls request the same uncached phrase? First request synthesizes and caches; others wait for cache.

## Requirements *(mandatory)*

### Functional Requirements

**Core TTS Functions**
- **FR-001**: System MUST provide `say/2` function that synthesizes and plays text using the default profile
- **FR-002**: System MUST provide `say/3` function that synthesizes and plays text with specified options (profile, voice overrides)
- **FR-003**: System MUST provide `say_prompt/3` function that plays TTS then collects DTMF digits
- **FR-004**: TTS functions MUST integrate with existing media pipeline infrastructure

**Provider System**
- **FR-005**: System MUST define a Provider behaviour with `synthesize/2`, `list_voices/2`, and `validate_config/1` callbacks
- **FR-006**: System MUST include built-in providers for OpenAI TTS, ElevenLabs, Google Cloud TTS, and Amazon Polly
- **FR-007**: System MUST support custom provider implementations via the Provider behaviour

**Configuration**
- **FR-008**: System MUST support named provider profiles in application configuration
- **FR-009**: System MUST support a default_profile setting that applies when no profile is specified
- **FR-010**: System MUST support credential configuration via environment variables or direct values
- **FR-011**: System MUST allow per-call overrides of profile settings (voice, provider)

**Caching**
- **FR-012**: System MUST define a Cache behaviour with `get/1`, `put/3`, `delete/1`, and `clear/0` callbacks
- **FR-013**: System MUST provide an ETS-based in-memory cache backend
- **FR-014**: System MUST provide a disk-based persistent cache backend
- **FR-015**: Cache keys MUST be deterministic hashes of text + voice configuration
- **FR-016**: System MUST support configurable cache TTL for disk cache

**Error Handling**
- **FR-017**: System MUST invoke handler's `handle_tts_error/3` callback when synthesis fails
- **FR-018**: System MUST provide a default `handle_tts_error/3` implementation that logs and continues
- **FR-019**: Handlers MUST be able to override `handle_tts_error/3` to implement custom error handling

**Audio Format**
- **FR-020**: System MUST convert provider audio formats to formats compatible with the media pipeline
- **FR-021**: System MUST support at minimum: PCM, MP3, WAV, and OGG audio formats from providers

### Key Entities

- **Profile**: A named configuration containing provider, voice, model, and other settings
- **Provider**: A module implementing the TTS Provider behaviour that synthesizes text to audio
- **Cache Backend**: A module implementing the Cache behaviour for storing synthesized audio
- **Cache Entry**: Stored audio data with metadata (format, provider, creation timestamp)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Developers can add TTS to a call flow with a single function call (`say/2`)
- **SC-002**: Cached TTS phrases play within 100ms (no perceptible delay vs file playback)
- **SC-003**: System supports at least 4 TTS providers (OpenAI, ElevenLabs, Google, Polly)
- **SC-004**: New providers can be added by implementing a single behaviour (3 callbacks)
- **SC-005**: TTS failures do not crash the call - error callback is invoked instead
- **SC-006**: Same text + profile combination always uses cached audio after first synthesis

## Assumptions

- Developers have valid API keys/credentials for their chosen TTS providers
- Network connectivity to TTS provider APIs is available
- The existing media pipeline can play audio from file paths
- Temporary file storage is available for audio caching
- TTS provider APIs return audio in standard formats (MP3, WAV, PCM, OGG)

## Dependencies

- Existing `play/2,3` infrastructure in ActionExecutor
- Existing `prompt/3` and DTMF collection infrastructure
- Existing MediaSession and pipeline infrastructure
- HTTP client for provider API calls (likely Req or similar)

## Out of Scope

- SSML (Speech Synthesis Markup Language) support
- Voice cloning or custom voice training
- Real-time streaming TTS (audio streams as generated)
- Automatic language detection
- Pre-warming cache on application startup
- Template/variable interpolation system (users handle string building)
