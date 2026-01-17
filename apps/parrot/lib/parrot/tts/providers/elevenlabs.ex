defmodule Parrot.TTS.Providers.ElevenLabs do
  @moduledoc """
  ElevenLabs TTS provider implementation.

  This module implements the `Parrot.TTS.Provider` behaviour for ElevenLabs'
  Text-to-Speech API, enabling text-to-speech synthesis using ElevenLabs' voices.

  ## Configuration

  The following configuration options are supported:

  - `:api_key` - Required. Your ElevenLabs API key
  - `:voice_id` - Optional. Voice ID to use for synthesis. Default: Rachel's voice ID
  - `:model_id` - Optional. TTS model to use. Default: "eleven_monolingual_v1"
    Valid models: eleven_monolingual_v1, eleven_multilingual_v1, eleven_multilingual_v2, eleven_turbo_v2
  - `:output_format` - Optional. Audio output format. Default: :mp3_44100_128
    Valid formats: :mp3_44100_128, :mp3_44100_64, :pcm_16000, :pcm_22050, :pcm_24000, :pcm_44100
  - `:stability` - Optional. Voice stability (0.0 to 1.0). Default: 0.5
  - `:similarity_boost` - Optional. Voice similarity boost (0.0 to 1.0). Default: 0.75

  ## Example

      config = [
        api_key: "your-elevenlabs-api-key",
        voice_id: "21m00Tcm4TlvDq8ikWAM",
        model_id: "eleven_multilingual_v2",
        output_format: :mp3_44100_128,
        stability: 0.5,
        similarity_boost: 0.75
      ]

      {:ok, audio_binary} = Parrot.TTS.Providers.ElevenLabs.synthesize("Hello, world!", config)

  ## API Reference

  - Endpoint: POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}
  - Documentation: https://docs.elevenlabs.io/api-reference/text-to-speech
  """

  @behaviour Parrot.TTS.Provider

  # ElevenLabs API base URL
  @api_base_url "https://api.elevenlabs.io"

  # Valid models for ElevenLabs TTS
  @valid_models ~w(eleven_monolingual_v1 eleven_multilingual_v1 eleven_multilingual_v2 eleven_turbo_v2)

  # Valid audio output formats
  @valid_output_formats ~w(mp3_44100_128 mp3_44100_64 pcm_16000 pcm_22050 pcm_24000 pcm_44100)a

  # Default configuration values
  @defaults [
    # Rachel voice ID
    voice_id: "21m00Tcm4TlvDq8ikWAM",
    model_id: "eleven_monolingual_v1",
    output_format: :mp3_44100_128,
    stability: 0.5,
    similarity_boost: 0.75
  ]

  # Static voice information for list_voices/1
  # Popular ElevenLabs voices
  @voice_info [
    %{
      id: "21m00Tcm4TlvDq8ikWAM",
      name: "Rachel",
      language: "en-US",
      description: "A calm and professional female voice"
    },
    %{
      id: "AZnzlk1XvdvUeBnXmlld",
      name: "Domi",
      language: "en-US",
      description: "A strong and confident female voice"
    },
    %{
      id: "EXAVITQu4vr4xnSDxMaL",
      name: "Bella",
      language: "en-US",
      description: "A soft and warm female voice"
    },
    %{
      id: "ErXwobaYiN019PkySvjV",
      name: "Antoni",
      language: "en-US",
      description: "A well-rounded and expressive male voice"
    },
    %{
      id: "MF3mGyEYCl7XYWbV9V6O",
      name: "Elli",
      language: "en-US",
      description: "A young and emotional female voice"
    },
    %{
      id: "TxGEqnHWrfWFTfGW9XjX",
      name: "Josh",
      language: "en-US",
      description: "A young and conversational male voice"
    },
    %{
      id: "VR6AewLTigWG4xSOukaG",
      name: "Arnold",
      language: "en-US",
      description: "A crisp and authoritative male voice"
    },
    %{
      id: "pNInz6obpgDQGcFmaJgB",
      name: "Adam",
      language: "en-US",
      description: "A deep and resonant male voice"
    },
    %{
      id: "yoZ06aMxZJJ28mfd3POQ",
      name: "Sam",
      language: "en-US",
      description: "A dynamic and engaging male voice"
    }
  ]

  # --- Public API Functions ---

  @doc """
  Returns the ElevenLabs TTS API base URL.
  """
  @spec api_base_url() :: String.t()
  def api_base_url, do: @api_base_url

  @doc """
  Returns the list of valid ElevenLabs TTS models.
  """
  @spec valid_models() :: [String.t()]
  def valid_models, do: @valid_models

  @doc """
  Returns the list of valid ElevenLabs TTS output formats.
  """
  @spec valid_output_formats() :: [atom()]
  def valid_output_formats, do: @valid_output_formats

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

      iex> ElevenLabs.validate_config(api_key: "test-key")
      :ok

      iex> ElevenLabs.validate_config([])
      {:error, :missing_api_key}
  """
  @impl Parrot.TTS.Provider
  @spec validate_config(keyword()) :: :ok | {:error, term()}
  def validate_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      with :ok <- validate_api_key(config),
           :ok <- validate_voice_id(config),
           :ok <- validate_model_id(config),
           :ok <- validate_output_format(config),
           :ok <- validate_stability(config),
           :ok <- validate_similarity_boost(config) do
        :ok
      end
    else
      {:error, :config_must_be_keyword_list}
    end
  end

  def validate_config(_config), do: {:error, :config_must_be_keyword_list}

  @doc """
  Synthesizes text to audio using ElevenLabs' TTS API.

  ## Parameters

  - `text` - The text to convert to speech
  - `config` - Keyword list of configuration options

  ## Returns

  - `{:ok, audio_binary}` - Success with binary audio data
  - `{:error, reason}` - Failure with error reason

  ## Examples

      iex> config = [api_key: "test-key", voice_id: "21m00Tcm4TlvDq8ikWAM"]
      iex> ElevenLabs.synthesize("Hello, world!", config)
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
  Lists available voices for ElevenLabs TTS.

  ElevenLabs has many voices, but this returns a static list of popular ones
  without making an API call.

  ## Parameters

  - `config` - Keyword list with at least `:api_key`

  ## Returns

  - `{:ok, voices}` - List of voice information maps
  - `{:error, reason}` - Configuration error

  ## Examples

      iex> ElevenLabs.list_voices(api_key: "test-key")
      {:ok, [%{id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", language: "en-US"}, ...]}
  """
  @impl Parrot.TTS.Provider
  @spec list_voices(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_voices(config) do
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

  # Validate voice_id option
  defp validate_voice_id(config) do
    case Keyword.fetch(config, :voice_id) do
      {:ok, voice_id} when is_binary(voice_id) -> :ok
      {:ok, _voice_id} -> {:error, :voice_id_must_be_string}
      :error -> :ok
    end
  end

  # Validate model_id option
  defp validate_model_id(config) do
    case Keyword.fetch(config, :model_id) do
      {:ok, model_id} when is_binary(model_id) ->
        if model_id in @valid_models do
          :ok
        else
          {:error, {:invalid_model_id, model_id}}
        end

      {:ok, _model_id} ->
        {:error, :model_id_must_be_string}

      :error ->
        :ok
    end
  end

  # Validate output_format option
  defp validate_output_format(config) do
    case Keyword.fetch(config, :output_format) do
      {:ok, format} when is_atom(format) ->
        if format in @valid_output_formats do
          :ok
        else
          {:error, {:invalid_output_format, format}}
        end

      {:ok, format} ->
        {:error, {:invalid_output_format, format}}

      :error ->
        :ok
    end
  end

  # Validate stability option (0.0 to 1.0)
  defp validate_stability(config) do
    case Keyword.fetch(config, :stability) do
      {:ok, stability} when is_number(stability) ->
        if stability >= 0.0 and stability <= 1.0 do
          :ok
        else
          {:error, {:invalid_stability, stability}}
        end

      {:ok, stability} ->
        {:error, {:invalid_stability, stability}}

      :error ->
        :ok
    end
  end

  # Validate similarity_boost option (0.0 to 1.0)
  defp validate_similarity_boost(config) do
    case Keyword.fetch(config, :similarity_boost) do
      {:ok, boost} when is_number(boost) ->
        if boost >= 0.0 and boost <= 1.0 do
          :ok
        else
          {:error, {:invalid_similarity_boost, boost}}
        end

      {:ok, boost} ->
        {:error, {:invalid_similarity_boost, boost}}

      :error ->
        :ok
    end
  end

  # Build request body for ElevenLabs API
  defp build_request_body(text, config) do
    model_id = Keyword.get(config, :model_id, @defaults[:model_id])
    stability = Keyword.get(config, :stability, @defaults[:stability])
    similarity_boost = Keyword.get(config, :similarity_boost, @defaults[:similarity_boost])

    %{
      "text" => text,
      "model_id" => model_id,
      "voice_settings" => %{
        "stability" => stability,
        "similarity_boost" => similarity_boost
      }
    }
  end

  # Build authorization headers
  defp build_headers(config) do
    api_key = Keyword.fetch!(config, :api_key)

    [
      {"xi-api-key", api_key},
      {"content-type", "application/json"}
    ]
  end

  # Build request URL with voice_id and optional output_format
  defp build_request_url(config) do
    voice_id = Keyword.get(config, :voice_id, @defaults[:voice_id])
    output_format = Keyword.get(config, :output_format, @defaults[:output_format])

    "/v1/text-to-speech/#{voice_id}?output_format=#{output_format}"
  end

  # Make the actual API request
  defp make_api_request(text, config) do
    body = build_request_body(text, config)
    headers = build_headers(config)
    url = build_request_url(config)

    # Build request, optionally using test plug for testing
    req =
      Req.new(base_url: @api_base_url)
      |> maybe_add_plug(config)

    case Req.post(req, url: url, json: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: audio_data}} ->
        {:ok, audio_data}

      {:ok, %Req.Response{status: 400}} ->
        {:error, :bad_request}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %Req.Response{status: 402}} ->
        {:error, :quota_exceeded}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :voice_not_found}

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
