defmodule Parrot.TTS.Provider do
  @moduledoc """
  Behaviour for TTS (Text-to-Speech) provider implementations.

  This behaviour defines the contract that all TTS provider implementations must follow,
  enabling integration with different TTS services like OpenAI, ElevenLabs, Google Cloud TTS,
  Amazon Polly, or your own custom TTS solution.

  ## Callbacks

  Providers must implement three callbacks:

  - `synthesize/2` - Converts text to audio binary data
  - `list_voices/1` - Lists available voices for the provider
  - `validate_config/1` - Validates provider configuration

  ## Creating a Custom Provider

  To create a custom TTS provider, implement this behaviour in a new module.
  Here is a complete example of a custom provider that wraps a local TTS engine:

      defmodule MyApp.TTS.LocalProvider do
        @moduledoc \"\"\"
        Custom TTS provider that wraps a local text-to-speech engine.

        This example shows how to implement a custom provider that integrates
        with a hypothetical local TTS command-line tool.
        \"\"\"
        @behaviour Parrot.TTS.Provider

        # Define supported voices for your provider
        @voices [
          %{id: "default", name: "Default Voice", language: "en-US"},
          %{id: "female", name: "Female Voice", language: "en-US"},
          %{id: "male", name: "Male Voice", language: "en-US"}
        ]

        @impl true
        def synthesize(text, config) when is_binary(text) and byte_size(text) > 0 do
          with :ok <- validate_config(config) do
            voice = Keyword.get(config, :voice, "default")
            format = Keyword.get(config, :format, :wav)

            # Call your TTS engine here
            case call_tts_engine(text, voice, format) do
              {:ok, audio_binary} ->
                {:ok, audio_binary, format}

              {:error, reason} ->
                {:error, reason}
            end
          end
        end

        def synthesize("", _config), do: {:error, :empty_text}
        def synthesize(_text, _config), do: {:error, :invalid_text_type}

        @impl true
        def list_voices(config) do
          with :ok <- validate_config(config) do
            {:ok, @voices}
          end
        end

        @impl true
        def validate_config(config) do
          cond do
            not Keyword.keyword?(config) ->
              {:error, :config_must_be_keyword_list}

            not Keyword.has_key?(config, :api_key) ->
              {:error, :missing_api_key}

            Keyword.get(config, :api_key) in [nil, ""] ->
              {:error, :invalid_api_key}

            not is_binary(Keyword.get(config, :api_key)) ->
              {:error, :api_key_must_be_string}

            Keyword.has_key?(config, :voice) and
                Keyword.get(config, :voice) not in Enum.map(@voices, & &1.id) ->
              {:error, {:invalid_voice, Keyword.get(config, :voice)}}

            true ->
              :ok
          end
        end

        # Private helper to call the actual TTS engine
        defp call_tts_engine(text, voice, format) do
          # Your implementation here - examples:
          #
          # Option 1: Shell out to a command-line tool
          # {output, 0} = System.cmd("espeak", ["-v", voice, text, "--stdout"])
          # {:ok, output}
          #
          # Option 2: Call a local HTTP service
          # Req.post("http://localhost:5000/synthesize", json: %{text: text, voice: voice})
          #
          # Option 3: Use a NIF or Port for a native library
          # MyNativeTTS.synthesize(text, voice, format)

          # Placeholder implementation
          {:ok, <<0, 0, 0, 0>>}
        end
      end

  ## Configuring Your Custom Provider

  Once implemented, configure your custom provider in your application config:

      # config/config.exs
      config :parrot, :tts,
        default_profile: :custom,
        profiles: [
          custom: [
            provider: MyApp.TTS.LocalProvider,
            voice: "female",
            format: :wav
          ]
        ],
        credentials: [
          {MyApp.TTS.LocalProvider, [api_key: "local-key"]}
        ],
        cache: [
          backend: Parrot.TTS.Cache.ETS
        ]

  Or use the provider directly with a profile map:

      profile = %{
        provider: MyApp.TTS.LocalProvider,
        cache: Parrot.TTS.Cache.ETS,
        voice: "female",
        model: "default",
        format: :wav,
        api_key: "local-key"
      }

      {:ok, audio, format} = Parrot.TTS.Synthesizer.get_audio("Hello!", profile)

  ## Built-in Providers

  Parrot includes these built-in providers:

  - `Parrot.TTS.Providers.OpenAI` - OpenAI TTS API
  - `Parrot.TTS.Providers.ElevenLabs` - ElevenLabs TTS API
  - `Parrot.TTS.Providers.Google` - Google Cloud Text-to-Speech
  - `Parrot.TTS.Providers.Amazon` - Amazon Polly

  Configure built-in providers using their short names:

      profiles: [
        standard: [provider: :openai, voice: "alloy"]
      ]

  ## Configuration Options

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
  - `:empty_api_key` - API key is an empty string
  - `:nil_api_key` - API key is nil
  - `:rate_limited` - API rate limit exceeded
  - `:timeout` - Request timed out
  - `:synthesis_failed` - General synthesis error
  - `:api_error` - General API error
  - `:unsupported_format` - Requested audio format not supported
  - `:empty_text` - Text parameter is empty
  - `:invalid_text_type` - Text is not a binary string

  ## Testing Your Provider

  Test your custom provider by verifying it implements the behaviour correctly:

      defmodule MyApp.TTS.LocalProviderTest do
        use ExUnit.Case, async: true

        alias MyApp.TTS.LocalProvider

        test "implements Provider behaviour" do
          behaviours = LocalProvider.__info__(:attributes)[:behaviour] || []
          assert Parrot.TTS.Provider in behaviours
        end

        test "synthesize/2 returns audio binary" do
          config = [api_key: "test-key", voice: "default"]
          assert {:ok, audio, :wav} = LocalProvider.synthesize("Hello", config)
          assert is_binary(audio)
        end

        test "list_voices/1 returns voice list" do
          config = [api_key: "test-key"]
          assert {:ok, voices} = LocalProvider.list_voices(config)
          assert is_list(voices)
          assert Enum.all?(voices, &Map.has_key?(&1, :id))
        end

        test "validate_config/1 validates configuration" do
          assert :ok = LocalProvider.validate_config([api_key: "test"])
          assert {:error, :missing_api_key} = LocalProvider.validate_config([])
        end
      end

  See `Parrot.Examples.CustomTTSProvider` for a complete working example.
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
