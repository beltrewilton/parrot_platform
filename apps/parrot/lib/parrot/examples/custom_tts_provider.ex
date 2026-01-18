defmodule Parrot.Examples.CustomTTSProvider do
  @moduledoc """
  Example custom TTS provider demonstrating how to implement `Parrot.TTS.Provider`.

  This module provides a complete, working example of a custom TTS provider that
  generates mock audio data. Use this as a template for implementing your own
  TTS provider integration.

  ## Usage

  This provider can be used directly for testing or as a fallback:

      # Use with Synthesizer via a profile map
      profile = %{
        provider: Parrot.Examples.CustomTTSProvider,
        cache: Parrot.TTS.Cache.ETS,
        voice: "alice",
        model: "mock-v1",
        format: :wav,
        api_key: "test-key"
      }

      {:ok, audio, :wav} = Parrot.TTS.Synthesizer.get_audio("Hello!", profile)

  ## Configuration

  Configure in your application config:

      config :parrot, :tts,
        profiles: [
          mock: [
            provider: Parrot.Examples.CustomTTSProvider,
            voice: "alice",
            format: :wav
          ]
        ],
        credentials: [
          {Parrot.Examples.CustomTTSProvider, [api_key: "mock-key"]}
        ]

  ## Implementing Your Own Provider

  To create your own TTS provider:

  1. Create a new module with `@behaviour Parrot.TTS.Provider`
  2. Implement `synthesize/2`, `list_voices/1`, and `validate_config/1`
  3. Configure the provider in your application config
  4. Use via `Parrot.TTS.Synthesizer.get_audio/3`

  See `Parrot.TTS.Provider` moduledoc for detailed documentation.
  """

  @behaviour Parrot.TTS.Provider

  # ===========================================================================
  # Voice Definitions
  # ===========================================================================

  # Static list of available voices for this provider.
  # Each voice must have at least :id, :name, and :language keys.
  # Additional keys like :gender and :description are optional but recommended.
  @voices [
    %{
      id: "alice",
      name: "Alice",
      language: "en-US",
      gender: "female",
      description: "A friendly, conversational voice"
    },
    %{
      id: "bob",
      name: "Bob",
      language: "en-US",
      gender: "male",
      description: "A deep, professional voice"
    },
    %{
      id: "clara",
      name: "Clara",
      language: "en-GB",
      gender: "female",
      description: "A British English voice"
    },
    %{
      id: "demo",
      name: "Demo",
      language: "en-US",
      gender: "neutral",
      description: "Default demonstration voice"
    }
  ]

  @voice_ids Enum.map(@voices, & &1.id)

  # Supported audio formats
  @supported_formats [:wav, :mp3, :pcm, :ogg]

  # ===========================================================================
  # Public API - Behaviour Callbacks
  # ===========================================================================

  @doc """
  Synthesizes text to audio.

  This mock implementation generates deterministic audio data based on the
  text content and voice selection. In a real implementation, you would
  call your TTS engine or API here.

  ## Parameters

  - `text` - The text to synthesize (must be non-empty binary)
  - `config` - Keyword list with configuration:
    - `:api_key` - Required authentication key
    - `:voice` - Voice ID (default: "demo")
    - `:format` - Audio format (default: :wav)

  ## Returns

  - `{:ok, audio_binary, format}` - Success with audio data and format
  - `{:error, reason}` - Error with descriptive atom

  ## Examples

      config = [api_key: "key", voice: "alice", format: :wav]
      {:ok, audio, :wav} = CustomTTSProvider.synthesize("Hello!", config)

  """
  @impl true
  @spec synthesize(String.t(), keyword()) :: {:ok, binary(), atom()} | {:error, term()}
  def synthesize(text, config) when is_binary(text) and byte_size(text) > 0 do
    with :ok <- validate_config(config) do
      voice = Keyword.get(config, :voice, "demo")
      format = Keyword.get(config, :format, :wav)

      # Generate mock audio data
      # In a real implementation, this is where you would:
      # - Call an HTTP API
      # - Execute a command-line TTS tool
      # - Use a native library via NIF/Port
      audio_data = generate_mock_audio(text, voice, format)

      {:ok, audio_data, format}
    end
  end

  def synthesize("", _config), do: {:error, :empty_text}
  def synthesize(_text, _config), do: {:error, :invalid_text_type}

  @doc """
  Lists available voices for this provider.

  Returns a list of voice information maps. Each map contains at minimum
  `:id`, `:name`, and `:language` keys.

  ## Parameters

  - `config` - Keyword list with at least `:api_key`

  ## Returns

  - `{:ok, [voice_map]}` - List of voice information
  - `{:error, reason}` - Error with descriptive atom

  ## Examples

      config = [api_key: "key"]
      {:ok, voices} = CustomTTSProvider.list_voices(config)
      # => {:ok, [%{id: "alice", name: "Alice", ...}, ...]}

  """
  @impl true
  @spec list_voices(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_voices(config) do
    with :ok <- validate_api_key(config) do
      {:ok, @voices}
    end
  end

  @doc """
  Validates the provider configuration.

  Checks that all required configuration is present and valid before
  attempting synthesis. This allows early failure with descriptive errors.

  ## Parameters

  - `config` - Keyword list to validate

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, reason}` - Configuration is invalid

  ## Validation Rules

  - `:api_key` must be present and a non-empty string
  - `:voice` (if present) must be a known voice ID
  - `:format` (if present) must be a supported format

  ## Examples

      # Valid configuration
      :ok = CustomTTSProvider.validate_config([api_key: "key"])

      # Missing required key
      {:error, :missing_api_key} = CustomTTSProvider.validate_config([])

      # Invalid voice
      {:error, {:invalid_voice, "unknown"}} =
        CustomTTSProvider.validate_config([api_key: "k", voice: "unknown"])

  """
  @impl true
  @spec validate_config(keyword()) :: :ok | {:error, term()}
  def validate_config(config) do
    with :ok <- validate_is_keyword_list(config),
         :ok <- validate_api_key(config),
         :ok <- validate_voice(config),
         :ok <- validate_format(config) do
      :ok
    end
  end

  # ===========================================================================
  # Public Helpers
  # ===========================================================================

  @doc """
  Returns the list of supported audio formats.
  """
  @spec supported_formats() :: [atom()]
  def supported_formats, do: @supported_formats

  @doc """
  Returns the list of valid voice IDs.
  """
  @spec voice_ids() :: [String.t()]
  def voice_ids, do: @voice_ids

  # ===========================================================================
  # Private Validation Functions
  # ===========================================================================

  defp validate_is_keyword_list(config) do
    if Keyword.keyword?(config) do
      :ok
    else
      {:error, :config_must_be_keyword_list}
    end
  end

  defp validate_api_key(config) do
    case Keyword.fetch(config, :api_key) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        :ok

      {:ok, nil} ->
        {:error, :nil_api_key}

      {:ok, ""} ->
        {:error, :empty_api_key}

      {:ok, _} ->
        {:error, :api_key_must_be_string}

      :error ->
        {:error, :missing_api_key}
    end
  end

  defp validate_voice(config) do
    case Keyword.fetch(config, :voice) do
      {:ok, voice} when is_binary(voice) ->
        if voice in @voice_ids do
          :ok
        else
          {:error, {:invalid_voice, voice}}
        end

      {:ok, _} ->
        {:error, :voice_must_be_string}

      :error ->
        # Voice is optional - use default
        :ok
    end
  end

  defp validate_format(config) do
    case Keyword.fetch(config, :format) do
      {:ok, format} when is_atom(format) ->
        if format in @supported_formats do
          :ok
        else
          {:error, {:unsupported_format, format}}
        end

      {:ok, format} ->
        {:error, {:invalid_format, format}}

      :error ->
        # Format is optional - use default
        :ok
    end
  end

  # ===========================================================================
  # Private Audio Generation
  # ===========================================================================

  # Generates mock audio data that is deterministic based on input.
  # This allows testing cache behavior and ensures consistent results.
  #
  # In a real implementation, replace this with your actual TTS call:
  #
  #   defp generate_audio(text, voice, format) do
  #     # Example: Call espeak command-line tool
  #     {output, 0} = System.cmd("espeak", [
  #       "-v", voice_to_espeak(voice),
  #       "--stdout",
  #       text
  #     ])
  #     output
  #   end
  #
  #   defp generate_audio(text, voice, format) do
  #     # Example: Call a local HTTP TTS service
  #     {:ok, %{body: audio}} = Req.post("http://localhost:5000/tts",
  #       json: %{text: text, voice: voice, format: format}
  #     )
  #     audio
  #   end
  #
  defp generate_mock_audio(text, voice, format) do
    # Create a deterministic "audio" binary based on input
    # The actual content is a hash - useful for testing
    input = "#{voice}:#{format}:#{text}"
    hash = :crypto.hash(:sha256, input)

    # Add a simple header to simulate format-specific structure
    header = format_header(format)

    header <> hash
  end

  # Returns a mock header for different audio formats
  defp format_header(:wav) do
    # Simplified WAV header bytes (RIFF...WAVE)
    <<"RIFF", 0::32, "WAVE">>
  end

  defp format_header(:mp3) do
    # MP3 frame sync bytes
    <<0xFF, 0xFB, 0x90, 0x00>>
  end

  defp format_header(:ogg) do
    # OGG magic bytes
    <<"OggS">>
  end

  defp format_header(:pcm) do
    # PCM has no header
    <<>>
  end

  defp format_header(_) do
    <<>>
  end
end
