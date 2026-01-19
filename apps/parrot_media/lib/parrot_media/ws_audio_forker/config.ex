defmodule ParrotMedia.WsAudioForker.Config do
  @moduledoc """
  Configuration struct for WebSocket Audio Forker.

  Config defines the connection parameters and settings for forking audio
  to WebSocket endpoints (e.g., Deepgram, AssemblyAI, OpenAI Realtime).

  ## Example

      {:ok, config} = Config.new(
        fork_id: "transcription_1",
        url: "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=16000",
        headers: [{"Authorization", "Token my_api_key"}],
        callback_module: MyApp.TranscriptionHandler,
        audio_format: :pcm_16le,
        buffer_size: 100
      )

  ## Fields

  * `:fork_id` - Unique identifier for this fork (required)
  * `:url` - WebSocket URL, must start with ws:// or wss:// (required)
  * `:headers` - List of {name, value} tuples for WebSocket headers (default: [])
  * `:callback_module` - Module to receive transcription callbacks (default: nil)
  * `:callback_state` - Initial state passed to callback module (default: %{})
  * `:audio_format` - Audio encoding format, :pcm_16le or :opus (default: :pcm_16le)
  * `:buffer_size` - Max frames to buffer during reconnection, 1-500 (default: 100)
  * `:connect_timeout_ms` - WebSocket connection timeout in ms (default: 5000)
  * `:max_retries` - Maximum reconnection attempts before giving up, 0 for unlimited (default: 5)
  * `:backoff_initial_ms` - Initial backoff delay in ms for reconnection (default: 1000)
  * `:backoff_max_ms` - Maximum backoff delay in ms for reconnection (default: 30000)

  ## Audio Formats

  * `:pcm_16le` - 16-bit little-endian PCM (linear16), 16kHz mono
  * `:opus` - Opus encoded audio

  ## Callback Module

  The callback module, if provided, should implement the `ParrotMedia.WsAudioForker.Callback`
  behaviour to receive transcription events:

      defmodule MyApp.TranscriptionHandler do
        @behaviour ParrotMedia.WsAudioForker.Callback

        def handle_transcript(text, metadata, state) do
          IO.puts("Transcript: \#{text}")
          {:ok, state}
        end
      end
  """

  @type t :: %__MODULE__{
          fork_id: String.t(),
          url: String.t(),
          headers: list({String.t(), String.t()}),
          callback_module: module() | nil,
          callback_state: term(),
          audio_format: :pcm_16le | :opus,
          buffer_size: pos_integer(),
          connect_timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          backoff_initial_ms: pos_integer(),
          backoff_max_ms: pos_integer()
        }

  @enforce_keys [:fork_id, :url]
  defstruct [
    :fork_id,
    :url,
    headers: [],
    callback_module: nil,
    callback_state: %{},
    audio_format: :pcm_16le,
    buffer_size: 100,
    connect_timeout_ms: 5000,
    max_retries: 5,
    backoff_initial_ms: 1000,
    backoff_max_ms: 30_000
  ]

  @max_buffer_size 500
  @valid_audio_formats [:pcm_16le, :opus]

  @doc """
  Creates a new Config from keyword options with validation.

  ## Required Options

  * `:fork_id` - Unique identifier for this fork
  * `:url` - WebSocket URL (must start with ws:// or wss://)

  ## Optional Options

  * `:headers` - List of {name, value} header tuples (default: [])
  * `:callback_module` - Module implementing Callback behaviour (default: nil)
  * `:callback_state` - Initial state for callback module (default: %{})
  * `:audio_format` - :pcm_16le or :opus (default: :pcm_16le)
  * `:buffer_size` - Buffer size 1-500 (default: 100)
  * `:connect_timeout_ms` - Connection timeout in ms (default: 5000)
  * `:max_retries` - Max reconnection attempts, 0 for unlimited (default: 5)
  * `:backoff_initial_ms` - Initial backoff delay in ms (default: 1000)
  * `:backoff_max_ms` - Maximum backoff delay in ms (default: 30000)

  ## Returns

  * `{:ok, config}` - Successfully created and validated config
  * `{:error, reason}` - Validation failed

  ## Examples

      iex> Config.new(fork_id: "f1", url: "wss://api.example.com/stream")
      {:ok, %Config{fork_id: "f1", url: "wss://api.example.com/stream", ...}}

      iex> Config.new(fork_id: "f1", url: "http://invalid.com")
      {:error, :invalid_url_scheme}

      iex> Config.new(fork_id: "f1", url: "wss://api.example.com", buffer_size: 1000)
      {:error, :buffer_size_out_of_range}
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    backoff_initial = Keyword.get(opts, :backoff_initial_ms, 1000)
    backoff_max = Keyword.get(opts, :backoff_max_ms, 30_000)

    with {:ok, fork_id} <- validate_required(opts, :fork_id),
         {:ok, url} <- validate_required(opts, :url),
         :ok <- validate_url_scheme(url),
         {:ok, audio_format} <- validate_audio_format(Keyword.get(opts, :audio_format, :pcm_16le)),
         {:ok, buffer_size} <- validate_buffer_size(Keyword.get(opts, :buffer_size, 100)),
         {:ok, headers} <- validate_headers(Keyword.get(opts, :headers, [])),
         :ok <- validate_backoff(backoff_initial, backoff_max) do
      config = %__MODULE__{
        fork_id: fork_id,
        url: url,
        headers: headers,
        callback_module: Keyword.get(opts, :callback_module),
        callback_state: Keyword.get(opts, :callback_state, %{}),
        audio_format: audio_format,
        buffer_size: buffer_size,
        connect_timeout_ms: Keyword.get(opts, :connect_timeout_ms, 5000),
        max_retries: Keyword.get(opts, :max_retries, 5),
        backoff_initial_ms: backoff_initial,
        backoff_max_ms: backoff_max
      }

      {:ok, config}
    end
  end

  @doc """
  Validates an existing Config struct.

  Checks that all fields have valid values according to the validation rules.

  ## Returns

  * `:ok` - Config is valid
  * `{:error, reason}` - Validation failed

  ## Validation Rules

  * `:fork_id` must be a non-empty string
  * `:url` must start with ws:// or wss://
  * `:audio_format` must be :pcm_16le or :opus
  * `:buffer_size` must be between 1 and 500

  ## Examples

      iex> Config.validate(%Config{fork_id: "f1", url: "wss://api.example.com"})
      :ok

      iex> Config.validate(%Config{fork_id: "", url: "wss://api.example.com"})
      {:error, :invalid_fork_id}

      iex> Config.validate(%Config{fork_id: "f1", url: "http://invalid.com"})
      {:error, :invalid_url_scheme}
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{fork_id: fork_id}) when not is_binary(fork_id) or fork_id == "" do
    {:error, :invalid_fork_id}
  end

  def validate(%__MODULE__{url: url}) when not is_binary(url) or url == "" do
    {:error, :invalid_url}
  end

  def validate(%__MODULE__{url: url} = config) do
    with :ok <- validate_url_scheme(url),
         {:ok, _} <- validate_audio_format(config.audio_format),
         {:ok, _} <- validate_buffer_size(config.buffer_size),
         {:ok, _} <- validate_headers(config.headers),
         :ok <- validate_backoff(config.backoff_initial_ms, config.backoff_max_ms) do
      :ok
    end
  end

  # Private validation helpers

  defp validate_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _} ->
        {:error, :"invalid_#{key}"}

      :error ->
        {:error, :"missing_#{key}"}
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

  defp validate_audio_format(format) when format in @valid_audio_formats do
    {:ok, format}
  end

  defp validate_audio_format(_format), do: {:error, :invalid_audio_format}

  defp validate_buffer_size(size)
       when is_integer(size) and size >= 1 and size <= @max_buffer_size do
    {:ok, size}
  end

  defp validate_buffer_size(_size), do: {:error, :buffer_size_out_of_range}

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

  defp validate_backoff(initial, _max) when not is_integer(initial) or initial < 1 do
    {:error, :invalid_backoff_initial}
  end

  defp validate_backoff(_initial, max) when not is_integer(max) or max < 1 do
    {:error, :invalid_backoff_max}
  end

  defp validate_backoff(initial, max) when initial > max do
    {:error, :backoff_initial_exceeds_max}
  end

  defp validate_backoff(_initial, _max), do: :ok
end
