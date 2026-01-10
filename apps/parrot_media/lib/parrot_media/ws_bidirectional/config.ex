defmodule ParrotMedia.WsBidirectional.Config do
  @moduledoc """
  Configuration for bidirectional WebSocket audio connections.

  This is a TDD stub - tests are written first, implementation follows.
  """

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

  # TDD stub - implementation not yet written
  # These functions will be implemented after tests are verified to fail

  @doc """
  Creates a new Config struct from keyword options.
  Returns {:ok, config} on success or {:error, reason} on validation failure.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(_opts) do
    # TDD stub - not implemented
    raise "Not implemented - TDD stub"
  end

  @doc """
  Creates a new Config struct from keyword options.
  Raises ArgumentError on validation failure.
  """
  @spec new!(keyword()) :: t()
  def new!(_opts) do
    # TDD stub - not implemented
    raise "Not implemented - TDD stub"
  end

  @doc """
  Validates an existing Config struct.
  Returns :ok on success or {:error, reason} on validation failure.
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(_config) do
    # TDD stub - not implemented
    raise "Not implemented - TDD stub"
  end
end
