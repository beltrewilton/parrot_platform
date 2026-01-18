defmodule Parrot.TTS.Providers.OpenAI do
  @moduledoc """
  OpenAI TTS provider implementation.

  This module implements the `Parrot.TTS.Provider` behaviour for OpenAI's
  Text-to-Speech API, enabling text-to-speech synthesis using OpenAI's TTS models.

  ## Configuration

  The following configuration options are supported:

  - `:api_key` - Required. Your OpenAI API key (starts with "sk-")
  - `:voice` - Optional. Voice to use for synthesis. Default: "alloy"
    Valid voices: alloy, echo, fable, onyx, nova, shimmer
  - `:model` - Optional. TTS model to use. Default: "tts-1"
    Valid models: tts-1 (optimized for speed), tts-1-hd (optimized for quality)
  - `:format` - Optional. Audio output format. Default: :mp3
    Valid formats: :mp3, :opus, :aac, :flac, :wav, :pcm
  - `:speed` - Optional. Speech speed multiplier (0.25 to 4.0). Default: 1.0

  ## Example

      config = [
        api_key: "sk-your-api-key",
        voice: "nova",
        model: "tts-1-hd",
        format: :mp3,
        speed: 1.0
      ]

      {:ok, audio_binary} = Parrot.TTS.Providers.OpenAI.synthesize("Hello, world!", config)

  ## API Reference

  - Endpoint: POST https://api.openai.com/v1/audio/speech
  - Documentation: https://platform.openai.com/docs/api-reference/audio/createSpeech
  """

  @behaviour Parrot.TTS.Provider

  # OpenAI TTS API base URL
  @api_base_url "https://api.openai.com"

  # OpenAI TTS API endpoint (full path for reference)
  @api_url "https://api.openai.com/v1/audio/speech"

  # Valid voices for OpenAI TTS
  @valid_voices ~w(alloy echo fable onyx nova shimmer)

  # Valid models for OpenAI TTS
  @valid_models ~w(tts-1 tts-1-hd)

  # Valid audio output formats
  @valid_formats ~w(mp3 opus aac flac wav pcm)a

  # Default configuration values
  @defaults [
    voice: "alloy",
    model: "tts-1",
    format: :mp3,
    speed: 1.0
  ]

  # Speed range limits
  @min_speed 0.25
  @max_speed 4.0

  # Static voice information for list_voices/1
  @voice_info [
    %{
      id: "alloy",
      name: "Alloy",
      language: "en-US",
      description: "A versatile, balanced voice"
    },
    %{
      id: "echo",
      name: "Echo",
      language: "en-US",
      description: "A warm, reassuring voice"
    },
    %{
      id: "fable",
      name: "Fable",
      language: "en-US",
      description: "A narrative, storytelling voice"
    },
    %{
      id: "onyx",
      name: "Onyx",
      language: "en-US",
      description: "A deep, authoritative voice"
    },
    %{
      id: "nova",
      name: "Nova",
      language: "en-US",
      description: "A friendly, conversational voice"
    },
    %{
      id: "shimmer",
      name: "Shimmer",
      language: "en-US",
      description: "A clear, expressive voice"
    }
  ]

  # --- Public API Functions ---

  @doc """
  Returns the OpenAI TTS API URL.
  """
  @spec api_url() :: String.t()
  def api_url, do: @api_url

  @doc """
  Returns the list of valid OpenAI TTS voices.
  """
  @spec valid_voices() :: [String.t()]
  def valid_voices, do: @valid_voices

  @doc """
  Returns the list of valid OpenAI TTS models.
  """
  @spec valid_models() :: [String.t()]
  def valid_models, do: @valid_models

  @doc """
  Returns the default configuration values.
  """
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  # --- Provider Behaviour Callbacks ---

  @doc """
  Validates the provider configuration.

  ## Parameters

  - `config` - Keyword list of configuration options

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, reason}` - Configuration is invalid

  ## Examples

      iex> OpenAI.validate_config(api_key: "sk-test-key")
      :ok

      iex> OpenAI.validate_config([])
      {:error, :missing_api_key}
  """
  @impl Parrot.TTS.Provider
  @spec validate_config(keyword()) :: :ok | {:error, term()}
  def validate_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      with :ok <- validate_api_key(config),
           :ok <- validate_voice(config),
           :ok <- validate_model(config),
           :ok <- validate_format(config),
           :ok <- validate_speed(config) do
        :ok
      end
    else
      {:error, :config_must_be_keyword_list}
    end
  end

  def validate_config(_config), do: {:error, :config_must_be_keyword_list}

  @doc """
  Synthesizes text to audio using OpenAI's TTS API.

  ## Parameters

  - `text` - The text to convert to speech
  - `config` - Keyword list of configuration options

  ## Returns

  - `{:ok, audio_binary}` - Success with binary audio data
  - `{:error, reason}` - Failure with error reason

  ## Examples

      iex> config = [api_key: "sk-test-key", voice: "alloy"]
      iex> OpenAI.synthesize("Hello, world!", config)
      {:ok, <<binary_audio_data>>}
  """
  @impl Parrot.TTS.Provider
  @spec synthesize(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def synthesize(text, config) do
    with :ok <- validate_text(text),
         :ok <- validate_config(config) do
      make_api_request(text, config)
    end
  end

  @doc """
  Lists available voices for OpenAI TTS.

  OpenAI has a fixed set of voices, so this returns a static list without
  making an API call.

  ## Parameters

  - `config` - Keyword list with at least `:api_key`

  ## Returns

  - `{:ok, voices}` - List of voice information maps
  - `{:error, reason}` - Configuration error

  ## Examples

      iex> OpenAI.list_voices(api_key: "sk-test-key")
      {:ok, [%{id: "alloy", name: "Alloy", language: "en-US"}, ...]}
  """
  @impl Parrot.TTS.Provider
  @spec list_voices(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_voices(config) do
    # Validate that api_key is present (even though we don't use it for static list)
    case validate_api_key(config) do
      :ok -> {:ok, @voice_info}
      error -> error
    end
  end

  # --- Private Functions ---

  # Validate text input
  defp validate_text(text) when is_binary(text) and byte_size(text) > 0, do: :ok
  defp validate_text(text) when is_binary(text), do: {:error, :empty_text}
  defp validate_text(_text), do: {:error, :invalid_text_type}

  # Validate API key
  defp validate_api_key(config) do
    case Keyword.fetch(config, :api_key) do
      {:ok, nil} -> {:error, :nil_api_key}
      {:ok, ""} -> {:error, :empty_api_key}
      {:ok, key} when is_binary(key) -> :ok
      {:ok, _} -> {:error, :api_key_must_be_string}
      :error -> {:error, :missing_api_key}
    end
  end

  # Validate voice option
  defp validate_voice(config) do
    case Keyword.fetch(config, :voice) do
      {:ok, voice} when is_binary(voice) ->
        if voice in @valid_voices do
          :ok
        else
          {:error, {:invalid_voice, voice}}
        end

      {:ok, _voice} ->
        {:error, :voice_must_be_string}

      :error ->
        :ok
    end
  end

  # Validate model option
  defp validate_model(config) do
    case Keyword.fetch(config, :model) do
      {:ok, model} when is_binary(model) ->
        if model in @valid_models do
          :ok
        else
          {:error, {:invalid_model, model}}
        end

      {:ok, _model} ->
        {:error, :model_must_be_string}

      :error ->
        :ok
    end
  end

  # Validate format option
  defp validate_format(config) do
    case Keyword.fetch(config, :format) do
      {:ok, format} when is_atom(format) ->
        if format in @valid_formats do
          :ok
        else
          {:error, {:invalid_format, format}}
        end

      {:ok, format} ->
        {:error, {:invalid_format, format}}

      :error ->
        :ok
    end
  end

  # Validate speed option
  defp validate_speed(config) do
    case Keyword.fetch(config, :speed) do
      {:ok, speed} when is_number(speed) ->
        if speed >= @min_speed and speed <= @max_speed do
          :ok
        else
          {:error, {:invalid_speed, speed}}
        end

      {:ok, speed} ->
        {:error, {:invalid_speed, speed}}

      :error ->
        :ok
    end
  end

  # Build request body for OpenAI API
  defp build_request_body(text, config) do
    voice = Keyword.get(config, :voice, @defaults[:voice])
    model = Keyword.get(config, :model, @defaults[:model])
    format = Keyword.get(config, :format, @defaults[:format])
    speed = Keyword.get(config, :speed, @defaults[:speed])

    %{
      "input" => text,
      "voice" => voice,
      "model" => model,
      "response_format" => Atom.to_string(format),
      "speed" => speed
    }
  end

  # Build authorization headers
  defp build_headers(config) do
    api_key = Keyword.fetch!(config, :api_key)

    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]
  end

  # Make the actual API request
  defp make_api_request(text, config) do
    body = build_request_body(text, config)
    headers = build_headers(config)

    # Build request, optionally using test plug for testing
    req =
      Req.new(base_url: @api_base_url)
      |> maybe_add_plug(config)

    case Req.post(req, url: "/v1/audio/speech", json: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: audio_data}} ->
        {:ok, audio_data}

      {:ok, %Req.Response{status: 400}} ->
        {:error, :bad_request}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %Req.Response{status: 402}} ->
        {:error, :insufficient_quota}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :api_error}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :connection_refused}

      {:error, %Req.TransportError{reason: _reason}} ->
        {:error, :network_error}

      {:error, _reason} ->
        {:error, :network_error}
    end
  end

  # Add test plug if provided in config (for testing with Req.Test)
  defp maybe_add_plug(req, config) do
    case Keyword.fetch(config, :plug) do
      {:ok, plug} -> Req.Request.put_new_option(req, :plug, plug)
      :error -> req
    end
  end
end
