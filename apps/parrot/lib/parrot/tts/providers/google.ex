defmodule Parrot.TTS.Providers.Google do
  @moduledoc """
  Google Cloud TTS provider implementation.

  This module implements the `Parrot.TTS.Provider` behaviour for Google Cloud's
  Text-to-Speech API, enabling text-to-speech synthesis using Google's Neural2
  and Wavenet voices.

  ## Configuration

  The following configuration options are supported:

  - `:api_key` - Required. Your Google Cloud API key or OAuth 2.0 access token
  - `:language_code` - Optional. BCP-47 language code. Default: "en-US"
  - `:voice_name` - Optional. Voice name to use for synthesis. Default: "en-US-Neural2-C"
    Common voices: en-US-Neural2-A through J, en-US-Wavenet-A through F
  - `:format` - Optional. Audio output format. Default: :mp3
    Valid formats: :mp3, :linear16, :ogg_opus, :mulaw, :alaw
  - `:speaking_rate` - Optional. Speech speed multiplier (0.25 to 4.0). Default: 1.0
  - `:pitch` - Optional. Voice pitch adjustment (-20.0 to 20.0 semitones). Default: 0.0

  ## Example

      config = [
        api_key: "ya29.your-google-api-key",
        language_code: "en-US",
        voice_name: "en-US-Neural2-D",
        format: :mp3,
        speaking_rate: 1.0,
        pitch: 0.0
      ]

      {:ok, audio_binary} = Parrot.TTS.Providers.Google.synthesize("Hello, world!", config)

  ## API Reference

  - Endpoint: POST https://texttospeech.googleapis.com/v1/text:synthesize
  - Documentation: https://cloud.google.com/text-to-speech/docs/reference/rest/v1/text/synthesize
  """

  @behaviour Parrot.TTS.Provider

  # Google Cloud TTS API base URL
  @api_base_url "https://texttospeech.googleapis.com"

  # Google Cloud TTS API endpoint (full path for reference)
  @api_url "https://texttospeech.googleapis.com/v1/text:synthesize"

  # Valid audio output formats (Google uses different names than the atoms)
  @valid_formats ~w(mp3 linear16 ogg_opus mulaw alaw)a

  # Format mapping from atoms to Google API encoding names
  @format_mapping %{
    mp3: "MP3",
    linear16: "LINEAR16",
    ogg_opus: "OGG_OPUS",
    mulaw: "MULAW",
    alaw: "ALAW"
  }

  # Default configuration values
  @defaults [
    language_code: "en-US",
    voice_name: "en-US-Neural2-C",
    format: :mp3,
    speaking_rate: 1.0,
    pitch: 0.0
  ]

  # Speaking rate limits (0.25x to 4.0x)
  @min_speaking_rate 0.25
  @max_speaking_rate 4.0

  # Pitch limits (-20 to +20 semitones)
  @min_pitch -20.0
  @max_pitch 20.0

  # Static voice information for list_voices/1
  # Google has many voices; we focus on the popular Neural2 voices
  @voice_info [
    %{
      id: "en-US-Neural2-A",
      name: "Neural2 A",
      language: "en-US",
      gender: "MALE",
      description: "A clear male voice"
    },
    %{
      id: "en-US-Neural2-C",
      name: "Neural2 C",
      language: "en-US",
      gender: "FEMALE",
      description: "A natural female voice (default)"
    },
    %{
      id: "en-US-Neural2-D",
      name: "Neural2 D",
      language: "en-US",
      gender: "MALE",
      description: "A deep male voice"
    },
    %{
      id: "en-US-Neural2-E",
      name: "Neural2 E",
      language: "en-US",
      gender: "FEMALE",
      description: "A soft female voice"
    },
    %{
      id: "en-US-Neural2-F",
      name: "Neural2 F",
      language: "en-US",
      gender: "FEMALE",
      description: "An expressive female voice"
    },
    %{
      id: "en-US-Neural2-G",
      name: "Neural2 G",
      language: "en-US",
      gender: "FEMALE",
      description: "A bright female voice"
    },
    %{
      id: "en-US-Neural2-H",
      name: "Neural2 H",
      language: "en-US",
      gender: "FEMALE",
      description: "A warm female voice"
    },
    %{
      id: "en-US-Neural2-I",
      name: "Neural2 I",
      language: "en-US",
      gender: "MALE",
      description: "A friendly male voice"
    },
    %{
      id: "en-US-Neural2-J",
      name: "Neural2 J",
      language: "en-US",
      gender: "MALE",
      description: "A professional male voice"
    }
  ]

  # --- Public API Functions ---

  @doc """
  Returns the Google Cloud TTS API URL.
  """
  @spec api_url() :: String.t()
  def api_url, do: @api_url

  @doc """
  Returns the list of valid Google Cloud TTS audio formats.
  """
  @spec valid_formats() :: [atom()]
  def valid_formats, do: @valid_formats

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

      iex> Google.validate_config(api_key: "ya29.test-key")
      :ok

      iex> Google.validate_config([])
      {:error, :missing_api_key}
  """
  @impl Parrot.TTS.Provider
  @spec validate_config(keyword()) :: :ok | {:error, term()}
  def validate_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      with :ok <- validate_api_key(config),
           :ok <- validate_language_code(config),
           :ok <- validate_voice_name(config),
           :ok <- validate_format(config),
           :ok <- validate_speaking_rate(config),
           :ok <- validate_pitch(config) do
        :ok
      end
    else
      {:error, :config_must_be_keyword_list}
    end
  end

  def validate_config(_config), do: {:error, :config_must_be_keyword_list}

  @doc """
  Synthesizes text to audio using Google Cloud's TTS API.

  ## Parameters

  - `text` - The text to convert to speech
  - `config` - Keyword list of configuration options

  ## Returns

  - `{:ok, audio_binary}` - Success with binary audio data (decoded from base64)
  - `{:error, reason}` - Failure with error reason

  ## Examples

      iex> config = [api_key: "ya29.test-key", voice_name: "en-US-Neural2-A"]
      iex> Google.synthesize("Hello, world!", config)
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
  Lists available voices for Google Cloud TTS.

  Google has many voices available. This returns a static list of popular
  Neural2 voices without making an API call.

  ## Parameters

  - `config` - Keyword list with at least `:api_key`

  ## Returns

  - `{:ok, voices}` - List of voice information maps
  - `{:error, reason}` - Configuration error

  ## Examples

      iex> Google.list_voices(api_key: "ya29.test-key")
      {:ok, [%{id: "en-US-Neural2-A", name: "Neural2 A", language: "en-US"}, ...]}
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

  # Validate language_code option
  defp validate_language_code(config) do
    case Keyword.fetch(config, :language_code) do
      {:ok, code} when is_binary(code) -> :ok
      {:ok, _code} -> {:error, :language_code_must_be_string}
      :error -> :ok
    end
  end

  # Validate voice_name option
  defp validate_voice_name(config) do
    case Keyword.fetch(config, :voice_name) do
      {:ok, name} when is_binary(name) -> :ok
      {:ok, _name} -> {:error, :voice_name_must_be_string}
      :error -> :ok
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

  # Validate speaking_rate option
  defp validate_speaking_rate(config) do
    case Keyword.fetch(config, :speaking_rate) do
      {:ok, rate} when is_number(rate) ->
        if rate >= @min_speaking_rate and rate <= @max_speaking_rate do
          :ok
        else
          {:error, {:invalid_speaking_rate, rate}}
        end

      {:ok, rate} ->
        {:error, {:invalid_speaking_rate, rate}}

      :error ->
        :ok
    end
  end

  # Validate pitch option
  defp validate_pitch(config) do
    case Keyword.fetch(config, :pitch) do
      {:ok, pitch} when is_number(pitch) ->
        if pitch >= @min_pitch and pitch <= @max_pitch do
          :ok
        else
          {:error, {:invalid_pitch, pitch}}
        end

      {:ok, pitch} ->
        {:error, {:invalid_pitch, pitch}}

      :error ->
        :ok
    end
  end

  # Build request body for Google Cloud TTS API
  defp build_request_body(text, config) do
    language_code = Keyword.get(config, :language_code, @defaults[:language_code])
    voice_name = Keyword.get(config, :voice_name, @defaults[:voice_name])
    format = Keyword.get(config, :format, @defaults[:format])
    speaking_rate = Keyword.get(config, :speaking_rate, @defaults[:speaking_rate])
    pitch = Keyword.get(config, :pitch, @defaults[:pitch])

    audio_encoding = Map.fetch!(@format_mapping, format)

    body = %{
      "input" => %{
        "text" => text
      },
      "voice" => %{
        "languageCode" => language_code,
        "name" => voice_name
      },
      "audioConfig" => %{
        "audioEncoding" => audio_encoding
      }
    }

    # Add optional speaking_rate if not default
    body =
      if speaking_rate != @defaults[:speaking_rate] do
        put_in(body, ["audioConfig", "speakingRate"], speaking_rate)
      else
        body
      end

    # Add optional pitch if not default
    if pitch != @defaults[:pitch] do
      put_in(body, ["audioConfig", "pitch"], pitch)
    else
      body
    end
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

    case Req.post(req, url: "/v1/text:synthesize", json: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: %{"audioContent" => base64_audio}}} ->
        # Google returns base64-encoded audio that needs to be decoded
        case Base.decode64(base64_audio) do
          {:ok, audio_data} -> {:ok, audio_data}
          :error -> {:error, :invalid_base64_response}
        end

      {:ok, %Req.Response{status: 200, body: _body}} ->
        {:error, :missing_audio_content}

      {:ok, %Req.Response{status: 400}} ->
        {:error, :bad_request}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :forbidden}

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
