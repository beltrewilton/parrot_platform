defmodule Parrot.TTS.Provider do
  @moduledoc """
  Behaviour for TTS (Text-to-Speech) provider implementations.

  This behaviour defines the contract that all TTS provider implementations must follow,
  enabling integration with different TTS services like OpenAI, ElevenLabs, Google Cloud TTS,
  Amazon Polly, and others.

  ## Callbacks

  Providers must implement three callbacks:

  - `synthesize/2` - Converts text to audio binary data
  - `list_voices/1` - Lists available voices for the provider
  - `validate_config/1` - Validates provider configuration

  ## Example Implementation

      defmodule MyApp.TTSProvider.OpenAI do
        @behaviour Parrot.TTS.Provider

        @impl true
        def synthesize(text, config) do
          api_key = Keyword.fetch!(config, :api_key)
          voice = Keyword.get(config, :voice, "alloy")

          case make_api_request(text, voice, api_key) do
            {:ok, audio_binary} -> {:ok, audio_binary}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def list_voices(config) do
          api_key = Keyword.fetch!(config, :api_key)

          case fetch_voices(api_key) do
            {:ok, voices} ->
              formatted_voices = Enum.map(voices, fn v ->
                %{id: v.id, name: v.name, language: v.language}
              end)
              {:ok, formatted_voices}

            {:error, reason} ->
              {:error, reason}
          end
        end

        @impl true
        def validate_config(config) do
          cond do
            not Keyword.has_key?(config, :api_key) ->
              {:error, :missing_api_key}

            not is_binary(Keyword.get(config, :api_key)) ->
              {:error, :invalid_api_key}

            true ->
              :ok
          end
        end
      end

  ## Configuration

  The `config` parameter passed to callbacks is a keyword list that typically includes:

  - `:api_key` - API authentication key (required for most providers)
  - `:voice` - Voice ID to use for synthesis
  - `:model` - Model name (provider-specific)
  - `:format` - Audio format (`:mp3`, `:wav`, `:pcm`, `:ogg`, etc.)
  - `:speed` - Playback speed multiplier
  - `:pitch` - Voice pitch adjustment

  Each provider may support additional provider-specific options.

  ## Error Handling

  Callbacks should return standard error tuples with descriptive error atoms:

  - `:missing_api_key` - API key not provided
  - `:invalid_api_key` - API key invalid or authentication failed
  - `:rate_limited` - API rate limit exceeded
  - `:timeout` - Request timed out
  - `:synthesis_failed` - General synthesis error
  - `:api_error` - General API error
  - `:unsupported_format` - Requested audio format not supported
  """

  @doc """
  Synthesizes audio from text using the provider's TTS service.

  ## Parameters

  - `text` - The text to convert to speech (must be a binary string)
  - `config` - Provider configuration (keyword list)

  ## Returns

  - `{:ok, audio_binary}` - Success with audio data as binary
  - `{:error, reason}` - Failure with error reason

  ## Examples

      iex> provider.synthesize("Hello, world!", api_key: "sk-...")
      {:ok, <<binary_audio_data>>}

      iex> provider.synthesize("", api_key: "sk-...")
      {:error, :empty_text}

      iex> provider.synthesize("Hello", api_key: "invalid")
      {:error, :invalid_api_key}

  ## Error Reasons

  Common error atoms include:

  - `:invalid_api_key` - Authentication failed
  - `:timeout` - Request timed out
  - `:rate_limited` - Rate limit exceeded
  - `:synthesis_failed` - General synthesis error
  - `:empty_text` - Text parameter is empty
  - `:invalid_text_type` - Text is not a binary string
  """
  @callback synthesize(text :: String.t(), config :: keyword()) ::
              {:ok, audio_data :: binary()} | {:error, reason :: term()}

  @doc """
  Lists available voices for the provider.

  ## Parameters

  - `config` - Provider configuration (keyword list), typically requires `:api_key`

  ## Returns

  - `{:ok, voices}` - List of voice information maps
  - `{:error, reason}` - Failure with error reason

  ## Voice Format

  Each voice in the returned list should be a map with at least these keys:

  - `:id` - Unique voice identifier (string)
  - `:name` - Human-readable voice name (string)
  - `:language` - Language code (e.g., "en-US", "es-ES") (string)

  Additional optional keys may include:

  - `:gender` - Voice gender ("male", "female", "neutral")
  - `:description` - Voice description
  - `:preview_url` - URL to preview audio

  ## Examples

      iex> provider.list_voices(api_key: "sk-...")
      {:ok, [
        %{id: "alloy", name: "Alloy", language: "en-US"},
        %{id: "echo", name: "Echo", language: "en-US"}
      ]}

      iex> provider.list_voices([])
      {:error, :missing_api_key}

  ## Error Reasons

  Common error atoms include:

  - `:missing_api_key` - API key not provided
  - `:invalid_api_key` - Authentication failed
  - `:api_error` - General API error
  """
  @callback list_voices(config :: keyword()) ::
              {:ok, [voice_info :: map()]} | {:error, reason :: term()}

  @doc """
  Validates provider configuration before use.

  This callback allows providers to validate their configuration early, before
  attempting synthesis or voice listing operations. It should check for required
  keys, valid value types, and supported options.

  ## Parameters

  - `config` - Provider configuration (keyword list)

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, reason}` - Configuration is invalid with error reason

  ## Examples

      iex> provider.validate_config(api_key: "sk-...")
      :ok

      iex> provider.validate_config([])
      {:error, :missing_api_key}

      iex> provider.validate_config(api_key: "")
      {:error, :empty_api_key}

      iex> provider.validate_config(api_key: "sk-...", format: :flac)
      {:error, :unsupported_format}

  ## Error Reasons

  Common error atoms include:

  - `:missing_api_key` - API key not provided
  - `:empty_api_key` - API key is empty string
  - `:nil_api_key` - API key is nil
  - `:invalid_voice_type` - Voice parameter is not a string
  - `:unsupported_format` - Audio format not supported
  - `:config_must_be_keyword_list` - Config is not a keyword list
  - `:api_key_must_be_string` - API key is not a binary string
  """
  @callback validate_config(config :: keyword()) :: :ok | {:error, reason :: term()}
end
