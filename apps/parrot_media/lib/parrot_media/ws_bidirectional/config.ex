defmodule ParrotMedia.WsBidirectional.Config do
  @moduledoc """
  Configuration struct for bidirectional WebSocket audio connections.

  Config defines the connection parameters and settings for bidirectional
  audio streaming to WebSocket endpoints (e.g., OpenAI Realtime, AssemblyAI).

  ## Example

      {:ok, config} = Config.new(
        connection_id: "bidirectional_1",
        url: "wss://api.openai.com/v1/realtime",
        headers: [{"Authorization", "Bearer my_api_key"}],
        callback_module: MyApp.BidirectionalHandler,
        inbound_format: :pcm_16le,
        outbound_format: :pcm_16le,
        sample_rate: 16000,
        buffer_size: 100
      )

  ## Fields

  * `:connection_id` - Unique identifier for this connection (required)
  * `:url` - WebSocket URL, must start with ws:// or wss:// (required)
  * `:headers` - List of {name, value} tuples for WebSocket headers (default: [])
  * `:callback_module` - Module to receive audio callbacks (default: nil)
  * `:callback_state` - Initial state passed to callback module (default: %{})
  * `:inbound_format` - Audio encoding format for incoming audio, :pcm_16le, :pcmu, or :opus (default: :pcm_16le)
  * `:outbound_format` - Audio encoding format for outgoing audio, :pcm_16le, :pcmu, or :opus (default: :pcm_16le)
  * `:sample_rate` - Audio sample rate in Hz (default: 16000)
  * `:buffer_size` - Max frames to buffer during reconnection, 1-500 (default: 100)
  * `:jitter_buffer_ms` - Jitter buffer size in milliseconds (default: 60)
  * `:connect_timeout_ms` - WebSocket connection timeout in ms (default: 5000)
  * `:max_retries` - Maximum reconnection attempts before giving up (default: 5)

  ## Audio Formats

  * `:pcm_16le` - 16-bit little-endian PCM (linear16)
  * `:pcmu` - G.711 mu-law
  * `:opus` - Opus encoded audio

  ## Callback Module

  The callback module, if provided, should implement the `ParrotMedia.WsBidirectional.Callback`
  behaviour to receive audio events:

      defmodule MyApp.BidirectionalHandler do
        @behaviour ParrotMedia.WsBidirectional.Callback

        def handle_audio(audio_data, metadata, state) do
          # Process incoming audio
          {:ok, state}
        end
      end
  """

  @type t :: %__MODULE__{
          connection_id: String.t(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          callback_module: module() | nil,
          callback_state: term(),
          inbound_format: :pcm_16le | :pcmu | :opus,
          outbound_format: :pcm_16le | :pcmu | :opus,
          sample_rate: pos_integer(),
          buffer_size: pos_integer(),
          jitter_buffer_ms: pos_integer(),
          connect_timeout_ms: pos_integer(),
          max_retries: non_neg_integer()
        }

  @enforce_keys [:connection_id, :url]
  defstruct connection_id: nil,
            url: nil,
            headers: [],
            callback_module: nil,
            callback_state: %{},
            inbound_format: :pcm_16le,
            outbound_format: :pcm_16le,
            sample_rate: 16000,
            buffer_size: 100,
            jitter_buffer_ms: 60,
            connect_timeout_ms: 5000,
            max_retries: 5

  @max_buffer_size 500
  @valid_audio_formats [:pcm_16le, :pcmu, :opus]

  @doc """
  Creates a new Config from keyword options with validation.

  ## Required Options

  * `:connection_id` - Unique identifier for this connection
  * `:url` - WebSocket URL (must start with ws:// or wss://)

  ## Optional Options

  * `:headers` - List of {name, value} header tuples (default: [])
  * `:callback_module` - Module implementing Callback behaviour (default: nil)
  * `:callback_state` - Initial state for callback module (default: %{})
  * `:inbound_format` - :pcm_16le, :pcmu, or :opus (default: :pcm_16le)
  * `:outbound_format` - :pcm_16le, :pcmu, or :opus (default: :pcm_16le)
  * `:sample_rate` - Sample rate in Hz (default: 16000)
  * `:buffer_size` - Buffer size 1-500 (default: 100)
  * `:jitter_buffer_ms` - Jitter buffer in ms (default: 60)
  * `:connect_timeout_ms` - Connection timeout in ms (default: 5000)
  * `:max_retries` - Max reconnection attempts (default: 5)

  ## Returns

  * `{:ok, config}` - Successfully created and validated config
  * `{:error, reason}` - Validation failed

  ## Examples

      iex> Config.new(connection_id: "c1", url: "wss://api.example.com/stream")
      {:ok, %Config{connection_id: "c1", url: "wss://api.example.com/stream", ...}}

      iex> Config.new(connection_id: "c1", url: "http://invalid.com")
      {:error, :invalid_url_scheme}

      iex> Config.new(connection_id: "c1", url: "wss://api.example.com", buffer_size: 1000)
      {:error, :buffer_size_out_of_range}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with {:ok, connection_id} <- validate_required(opts, :connection_id),
         {:ok, url} <- validate_url(opts),
         :ok <- validate_url_scheme(url),
         {:ok, inbound_format} <- validate_inbound_format(Keyword.get(opts, :inbound_format, :pcm_16le)),
         {:ok, outbound_format} <- validate_outbound_format(Keyword.get(opts, :outbound_format, :pcm_16le)),
         {:ok, sample_rate} <- validate_sample_rate(Keyword.get(opts, :sample_rate, 16000)),
         {:ok, buffer_size} <- validate_buffer_size(Keyword.get(opts, :buffer_size, 100)),
         {:ok, jitter_buffer_ms} <- validate_jitter_buffer_ms(Keyword.get(opts, :jitter_buffer_ms, 60)),
         {:ok, headers} <- validate_headers(Keyword.get(opts, :headers, [])) do
      config = %__MODULE__{
        connection_id: connection_id,
        url: url,
        headers: headers,
        callback_module: Keyword.get(opts, :callback_module),
        callback_state: Keyword.get(opts, :callback_state, %{}),
        inbound_format: inbound_format,
        outbound_format: outbound_format,
        sample_rate: sample_rate,
        buffer_size: buffer_size,
        jitter_buffer_ms: jitter_buffer_ms,
        connect_timeout_ms: Keyword.get(opts, :connect_timeout_ms, 5000),
        max_retries: Keyword.get(opts, :max_retries, 5)
      }

      {:ok, config}
    end
  end

  @doc """
  Creates a new Config from keyword options.
  Raises ArgumentError on validation failure.

  ## Examples

      iex> Config.new!(connection_id: "c1", url: "wss://api.example.com/stream")
      %Config{connection_id: "c1", url: "wss://api.example.com/stream", ...}

      iex> Config.new!(connection_id: "c1", url: "http://invalid.com")
      ** (ArgumentError) invalid_url_scheme
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, to_string(reason)
    end
  end

  @doc """
  Validates an existing Config struct.

  Checks that all fields have valid values according to the validation rules.

  ## Returns

  * `:ok` - Config is valid
  * `{:error, reason}` - Validation failed

  ## Validation Rules

  * `:connection_id` must be a non-empty string
  * `:url` must start with ws:// or wss://
  * `:inbound_format` must be :pcm_16le, :pcmu, or :opus
  * `:outbound_format` must be :pcm_16le, :pcmu, or :opus
  * `:sample_rate` must be a positive integer
  * `:buffer_size` must be between 1 and 500
  * `:jitter_buffer_ms` must be a positive integer
  * `:headers` must be a list of {string, string} tuples

  ## Examples

      iex> Config.validate(%Config{connection_id: "c1", url: "wss://api.example.com"})
      :ok

      iex> Config.validate(%Config{connection_id: "", url: "wss://api.example.com"})
      {:error, :invalid_connection_id}

      iex> Config.validate(%Config{connection_id: "c1", url: "http://invalid.com"})
      {:error, :invalid_url_scheme}
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{connection_id: connection_id})
      when not is_binary(connection_id) or connection_id == "" do
    {:error, :invalid_connection_id}
  end

  def validate(%__MODULE__{url: url}) when not is_binary(url) or url == "" do
    {:error, :invalid_url}
  end

  def validate(%__MODULE__{url: url} = config) do
    with :ok <- validate_url_scheme(url),
         {:ok, _} <- validate_inbound_format(config.inbound_format),
         {:ok, _} <- validate_outbound_format(config.outbound_format),
         {:ok, _} <- validate_sample_rate(config.sample_rate),
         {:ok, _} <- validate_buffer_size(config.buffer_size),
         {:ok, _} <- validate_jitter_buffer_ms(config.jitter_buffer_ms),
         {:ok, _} <- validate_headers(config.headers) do
      :ok
    end
  end

  # Private validation helpers

  defp validate_required(opts, :connection_id) do
    case Keyword.fetch(opts, :connection_id) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _} ->
        {:error, :invalid_connection_id}

      :error ->
        {:error, :missing_connection_id}
    end
  end

  defp validate_url(opts) do
    case Keyword.fetch(opts, :url) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, ""} ->
        {:error, :invalid_url}

      {:ok, _} ->
        {:error, :invalid_url}

      :error ->
        {:error, :missing_url}
    end
  end

  defp validate_url_scheme(url) when is_binary(url) do
    if String.starts_with?(url, "ws://") or String.starts_with?(url, "wss://") do
      :ok
    else
      {:error, :invalid_url_scheme}
    end
  end

  defp validate_url_scheme(_url), do: {:error, :invalid_url}

  defp validate_inbound_format(format) when format in @valid_audio_formats do
    {:ok, format}
  end

  defp validate_inbound_format(_format), do: {:error, :invalid_inbound_format}

  defp validate_outbound_format(format) when format in @valid_audio_formats do
    {:ok, format}
  end

  defp validate_outbound_format(_format), do: {:error, :invalid_outbound_format}

  defp validate_sample_rate(rate) when is_integer(rate) and rate > 0 do
    {:ok, rate}
  end

  defp validate_sample_rate(_rate), do: {:error, :invalid_sample_rate}

  defp validate_buffer_size(size)
       when is_integer(size) and size >= 1 and size <= @max_buffer_size do
    {:ok, size}
  end

  defp validate_buffer_size(_size), do: {:error, :buffer_size_out_of_range}

  defp validate_jitter_buffer_ms(ms) when is_integer(ms) and ms > 0 do
    {:ok, ms}
  end

  defp validate_jitter_buffer_ms(_ms), do: {:error, :invalid_jitter_buffer_ms}

  defp validate_headers(headers) when is_list(headers) do
    if Enum.all?(headers, &valid_header?/1) do
      {:ok, headers}
    else
      {:error, :invalid_headers}
    end
  end

  defp validate_headers(_headers), do: {:error, :invalid_headers}

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value), do: true
  defp valid_header?(_), do: false
end
