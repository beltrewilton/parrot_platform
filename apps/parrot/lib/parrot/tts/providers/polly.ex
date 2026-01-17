defmodule Parrot.TTS.Providers.Polly do
  @moduledoc """
  Amazon Polly TTS provider implementation.

  This module implements the `Parrot.TTS.Provider` behaviour for Amazon Polly's
  Text-to-Speech API, enabling text-to-speech synthesis using Polly's Neural and
  Standard engines.

  ## Configuration

  The following configuration options are supported:

  - `:access_key_id` - Required. Your AWS Access Key ID
  - `:secret_access_key` - Required. Your AWS Secret Access Key
  - `:region` - Optional. AWS region for Polly endpoint. Default: "us-east-1"
  - `:voice_id` - Optional. Voice to use for synthesis. Default: "Joanna"
    Valid Neural voices: Joanna, Matthew, Ivy, Justin, Kendra, Kimberly, Salli, Joey, Amy, Brian, Emma, Olivia
  - `:engine` - Optional. TTS engine to use. Default: "neural"
    Valid engines: standard, neural, generative
  - `:format` - Optional. Audio output format. Default: :mp3
    Valid formats: :mp3, :ogg_vorbis, :pcm
  - `:sample_rate` - Optional. Audio sample rate. Default: "24000" for neural, "22050" for standard

  ## Example

      config = [
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        voice_id: "Joanna",
        engine: "neural",
        format: :mp3
      ]

      {:ok, audio_binary} = Parrot.TTS.Providers.Polly.synthesize("Hello, world!", config)

  ## AWS Authentication

  This implementation uses AWS Signature Version 4 for authentication.
  Credentials must be provided via the configuration options.

  ## API Reference

  - Endpoint: POST https://polly.{region}.amazonaws.com/v1/speech
  - Documentation: https://docs.aws.amazon.com/polly/latest/dg/API_SynthesizeSpeech.html
  """

  @behaviour Parrot.TTS.Provider

  # Valid Neural voices for Amazon Polly (US English focused + some British)
  @valid_voices ~w(Joanna Matthew Ivy Justin Kendra Kimberly Salli Joey Amy Brian Emma Olivia)

  # Valid TTS engines
  @valid_engines ~w(standard neural generative)

  # Valid audio output formats
  @valid_formats ~w(mp3 ogg_vorbis pcm)a

  # Default configuration values
  @defaults [
    voice_id: "Joanna",
    engine: "neural",
    format: :mp3,
    region: "us-east-1",
    sample_rate: "24000"
  ]

  # AWS service name for signing
  @service "polly"

  # Static voice information for list_voices/1
  @voice_info [
    %{
      id: "Joanna",
      name: "Joanna",
      language: "en-US",
      gender: "female",
      engine: "neural",
      description: "US English female voice (Neural)"
    },
    %{
      id: "Matthew",
      name: "Matthew",
      language: "en-US",
      gender: "male",
      engine: "neural",
      description: "US English male voice (Neural)"
    },
    %{
      id: "Ivy",
      name: "Ivy",
      language: "en-US",
      gender: "female",
      engine: "neural",
      description: "US English child female voice (Neural)"
    },
    %{
      id: "Justin",
      name: "Justin",
      language: "en-US",
      gender: "male",
      engine: "neural",
      description: "US English child male voice (Neural)"
    },
    %{
      id: "Kendra",
      name: "Kendra",
      language: "en-US",
      gender: "female",
      engine: "neural",
      description: "US English female voice (Neural)"
    },
    %{
      id: "Kimberly",
      name: "Kimberly",
      language: "en-US",
      gender: "female",
      engine: "neural",
      description: "US English female voice (Neural)"
    },
    %{
      id: "Salli",
      name: "Salli",
      language: "en-US",
      gender: "female",
      engine: "neural",
      description: "US English female voice (Neural)"
    },
    %{
      id: "Joey",
      name: "Joey",
      language: "en-US",
      gender: "male",
      engine: "neural",
      description: "US English male voice (Neural)"
    },
    %{
      id: "Amy",
      name: "Amy",
      language: "en-GB",
      gender: "female",
      engine: "neural",
      description: "British English female voice (Neural)"
    },
    %{
      id: "Brian",
      name: "Brian",
      language: "en-GB",
      gender: "male",
      engine: "neural",
      description: "British English male voice (Neural)"
    },
    %{
      id: "Emma",
      name: "Emma",
      language: "en-GB",
      gender: "female",
      engine: "neural",
      description: "British English female voice (Neural)"
    },
    %{
      id: "Olivia",
      name: "Olivia",
      language: "en-AU",
      gender: "female",
      engine: "neural",
      description: "Australian English female voice (Neural)"
    }
  ]

  # --- Public API Functions ---

  @doc """
  Returns the list of valid Polly voices.
  """
  @spec valid_voices() :: [String.t()]
  def valid_voices, do: @valid_voices

  @doc """
  Returns the list of valid Polly engines.
  """
  @spec valid_engines() :: [String.t()]
  def valid_engines, do: @valid_engines

  @doc """
  Returns the default configuration values.
  """
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  @doc """
  Returns the default AWS region.
  """
  @spec default_region() :: String.t()
  def default_region, do: @defaults[:region]

  # --- Provider Behaviour Callbacks ---

  @doc """
  Validates the provider configuration.

  ## Parameters

  - `config` - Keyword list of configuration options

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, reason}` - Configuration is invalid

  ## Examples

      iex> Polly.validate_config(access_key_id: "AKIA...", secret_access_key: "secret")
      :ok

      iex> Polly.validate_config([])
      {:error, :missing_access_key_id}
  """
  @impl Parrot.TTS.Provider
  @spec validate_config(keyword()) :: :ok | {:error, term()}
  def validate_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      with :ok <- validate_access_key_id(config),
           :ok <- validate_secret_access_key(config),
           :ok <- validate_voice_id(config),
           :ok <- validate_engine(config),
           :ok <- validate_format(config) do
        :ok
      end
    else
      {:error, :config_must_be_keyword_list}
    end
  end

  def validate_config(_config), do: {:error, :config_must_be_keyword_list}

  @doc """
  Synthesizes text to audio using Amazon Polly's TTS API.

  ## Parameters

  - `text` - The text to convert to speech
  - `config` - Keyword list of configuration options

  ## Returns

  - `{:ok, audio_binary}` - Success with binary audio data
  - `{:error, reason}` - Failure with error reason

  ## Examples

      iex> config = [access_key_id: "AKIA...", secret_access_key: "secret", voice_id: "Joanna"]
      iex> Polly.synthesize("Hello, world!", config)
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
  Lists available voices for Amazon Polly.

  Returns a static list of common Neural voices without making an API call.

  ## Parameters

  - `config` - Keyword list with AWS credentials

  ## Returns

  - `{:ok, voices}` - List of voice information maps
  - `{:error, reason}` - Configuration error

  ## Examples

      iex> Polly.list_voices(access_key_id: "AKIA...", secret_access_key: "secret")
      {:ok, [%{id: "Joanna", name: "Joanna", language: "en-US", engine: "neural"}, ...]}
  """
  @impl Parrot.TTS.Provider
  @spec list_voices(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_voices(config) do
    with :ok <- validate_access_key_id(config),
         :ok <- validate_secret_access_key(config) do
      {:ok, @voice_info}
    end
  end

  # --- Private Functions ---

  # Validate text input
  defp validate_text(text) when is_binary(text) and byte_size(text) > 0, do: :ok
  defp validate_text(text) when is_binary(text), do: {:error, :empty_text}
  defp validate_text(_text), do: {:error, :invalid_text_type}

  # Validate AWS Access Key ID
  defp validate_access_key_id(config) do
    case Keyword.fetch(config, :access_key_id) do
      {:ok, nil} -> {:error, :nil_access_key_id}
      {:ok, ""} -> {:error, :empty_access_key_id}
      {:ok, key} when is_binary(key) -> :ok
      {:ok, _} -> {:error, :access_key_id_must_be_string}
      :error -> {:error, :missing_access_key_id}
    end
  end

  # Validate AWS Secret Access Key
  defp validate_secret_access_key(config) do
    case Keyword.fetch(config, :secret_access_key) do
      {:ok, nil} -> {:error, :nil_secret_access_key}
      {:ok, ""} -> {:error, :empty_secret_access_key}
      {:ok, key} when is_binary(key) -> :ok
      {:ok, _} -> {:error, :secret_access_key_must_be_string}
      :error -> {:error, :missing_secret_access_key}
    end
  end

  # Validate voice_id option
  defp validate_voice_id(config) do
    case Keyword.fetch(config, :voice_id) do
      {:ok, voice_id} when is_binary(voice_id) ->
        if voice_id in @valid_voices do
          :ok
        else
          {:error, {:invalid_voice_id, voice_id}}
        end

      {:ok, _voice_id} ->
        {:error, :voice_id_must_be_string}

      :error ->
        :ok
    end
  end

  # Validate engine option
  defp validate_engine(config) do
    case Keyword.fetch(config, :engine) do
      {:ok, engine} when is_binary(engine) ->
        if engine in @valid_engines do
          :ok
        else
          {:error, {:invalid_engine, engine}}
        end

      {:ok, _engine} ->
        {:error, :engine_must_be_string}

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

  # Build request body for Polly API
  defp build_request_body(text, config) do
    voice_id = Keyword.get(config, :voice_id, @defaults[:voice_id])
    engine = Keyword.get(config, :engine, @defaults[:engine])
    format = Keyword.get(config, :format, @defaults[:format])
    sample_rate = Keyword.get(config, :sample_rate, @defaults[:sample_rate])

    %{
      "Text" => text,
      "VoiceId" => voice_id,
      "Engine" => engine,
      "OutputFormat" => format_to_string(format),
      "SampleRate" => sample_rate,
      "TextType" => "text"
    }
  end

  # Convert atom format to Polly API string format
  defp format_to_string(:mp3), do: "mp3"
  defp format_to_string(:ogg_vorbis), do: "ogg_vorbis"
  defp format_to_string(:pcm), do: "pcm"

  # Build the Polly API endpoint URL
  defp build_api_url(config) do
    region = Keyword.get(config, :region, @defaults[:region])
    "https://polly.#{region}.amazonaws.com"
  end

  # Make the actual API request
  defp make_api_request(text, config) do
    body = build_request_body(text, config)
    region = Keyword.get(config, :region, @defaults[:region])
    base_url = build_api_url(config)
    path = "/v1/speech"

    # Build signed headers
    headers = build_signed_headers(body, path, region, config)

    # Build request, optionally using test plug for testing
    req =
      Req.new(base_url: base_url)
      |> maybe_add_plug(config)

    case Req.post(req, url: path, json: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: audio_data}} ->
        {:ok, audio_data}

      {:ok, %Req.Response{status: 400, body: body}} ->
        handle_error_response(400, body)

      {:ok, %Req.Response{status: 403}} ->
        {:error, :invalid_credentials}

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

  # Handle specific error responses from Polly
  defp handle_error_response(400, body) when is_map(body) do
    case Map.get(body, "__type") do
      "TextLengthExceededException" -> {:error, :text_too_long}
      _ -> {:error, :bad_request}
    end
  end

  defp handle_error_response(400, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> handle_error_response(400, decoded)
      _ -> {:error, :bad_request}
    end
  end

  defp handle_error_response(400, _body), do: {:error, :bad_request}

  # Build signed headers for AWS Signature V4
  # Note: This is a simplified implementation for MVP.
  # For production, consider using ex_aws or a dedicated signing library.
  defp build_signed_headers(body, path, region, config) do
    access_key_id = Keyword.fetch!(config, :access_key_id)
    secret_access_key = Keyword.fetch!(config, :secret_access_key)

    # Get current timestamp
    now = DateTime.utc_now()
    amz_date = format_amz_date(now)
    date_stamp = format_date_stamp(now)

    # Create host
    host = "polly.#{region}.amazonaws.com"

    # Create payload hash
    payload = Jason.encode!(body)
    payload_hash = hash_sha256(payload)

    # Create canonical headers
    canonical_headers = "content-type:application/json\nhost:#{host}\nx-amz-date:#{amz_date}\n"
    signed_headers = "content-type;host;x-amz-date"

    # Create canonical request
    canonical_request = """
    POST
    #{path}

    #{canonical_headers}
    #{signed_headers}
    #{payload_hash}\
    """

    # Create string to sign
    algorithm = "AWS4-HMAC-SHA256"
    credential_scope = "#{date_stamp}/#{region}/#{@service}/aws4_request"

    string_to_sign =
      "#{algorithm}\n#{amz_date}\n#{credential_scope}\n#{hash_sha256(canonical_request)}"

    # Create signing key
    signing_key = get_signature_key(secret_access_key, date_stamp, region, @service)

    # Create signature
    signature = hmac_sha256_hex(signing_key, string_to_sign)

    # Create authorization header
    authorization =
      "#{algorithm} Credential=#{access_key_id}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    [
      {"authorization", authorization},
      {"content-type", "application/json"},
      {"host", host},
      {"x-amz-date", amz_date}
    ]
  end

  # Format date for x-amz-date header
  defp format_amz_date(datetime) do
    datetime
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601(:basic)
    |> String.replace("-", "")
    |> String.replace(":", "")
    |> Kernel.<>("Z")
  end

  # Format date stamp for credential scope
  defp format_date_stamp(datetime) do
    datetime
    |> DateTime.to_date()
    |> Date.to_iso8601(:basic)
  end

  # SHA256 hash (hex encoded)
  defp hash_sha256(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  # HMAC-SHA256
  defp hmac_sha256(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  # HMAC-SHA256 (hex encoded)
  defp hmac_sha256_hex(key, data) do
    hmac_sha256(key, data)
    |> Base.encode16(case: :lower)
  end

  # Get AWS signature key
  defp get_signature_key(secret_key, date_stamp, region, service) do
    k_date = hmac_sha256("AWS4" <> secret_key, date_stamp)
    k_region = hmac_sha256(k_date, region)
    k_service = hmac_sha256(k_region, service)
    hmac_sha256(k_service, "aws4_request")
  end

  # Add test plug if provided in config (for testing with Req.Test)
  defp maybe_add_plug(req, config) do
    case Keyword.fetch(config, :plug) do
      {:ok, plug} -> Req.Request.put_new_option(req, :plug, plug)
      :error -> req
    end
  end
end
