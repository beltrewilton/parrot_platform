# Contract: TTS Provider Behaviour

**Module**: `Parrot.TTS.Provider`
**Type**: Elixir Behaviour

## Callbacks

### synthesize/2

Synthesize text to audio using the provider's API.

```elixir
@callback synthesize(text :: String.t(), config :: keyword()) ::
  {:ok, audio_data :: binary(), format :: atom()} |
  {:error, reason :: term()}
```

**Parameters**:
- `text` - The text to synthesize (1 to 10,000 characters)
- `config` - Provider-specific configuration including:
  - `:voice` - Voice identifier
  - `:model` - Model identifier
  - `:format` - Desired output format
  - `:api_key` or other credentials

**Returns**:
- `{:ok, binary, atom}` - Audio data and format on success
- `{:error, term}` - Error reason on failure

**Error reasons**:
- `{:api_error, status_code, message}` - Provider API error
- `{:timeout, :connect | :receive}` - Connection or receive timeout
- `{:invalid_config, field}` - Missing or invalid configuration
- `{:rate_limited, retry_after}` - Rate limit exceeded

---

### list_voices/1

List available voices for the provider.

```elixir
@callback list_voices(credentials :: keyword()) ::
  {:ok, [voice_info :: map()]} |
  {:error, reason :: term()}
```

**Parameters**:
- `credentials` - API credentials for the provider

**Returns**:
- `{:ok, [map]}` - List of voice information maps
- `{:error, term}` - Error reason

**Voice info map**:
```elixir
%{
  id: "voice-id",
  name: "Voice Name",
  language: "en-US",
  gender: "female" | "male" | "neutral"
}
```

---

### validate_config/1

Validate provider configuration before use.

```elixir
@callback validate_config(config :: keyword()) ::
  :ok |
  {:error, reason :: term()}
```

**Parameters**:
- `config` - Provider configuration to validate

**Returns**:
- `:ok` - Configuration is valid
- `{:error, term}` - Validation error with reason

---

## Implementation Example

```elixir
defmodule MyApp.TTS.LocalProvider do
  @behaviour Parrot.TTS.Provider

  @impl true
  def synthesize(text, config) do
    voice = Keyword.get(config, :voice, "default")
    # Call local TTS engine
    case LocalTTS.synthesize(text, voice) do
      {:ok, audio} -> {:ok, audio, :wav}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_voices(_credentials) do
    {:ok, [
      %{id: "default", name: "Default Voice", language: "en-US", gender: "neutral"}
    ]}
  end

  @impl true
  def validate_config(config) do
    if Keyword.has_key?(config, :voice) do
      :ok
    else
      {:error, {:missing_field, :voice}}
    end
  end
end
```
