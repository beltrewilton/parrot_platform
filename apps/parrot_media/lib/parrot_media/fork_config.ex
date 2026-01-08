defmodule ParrotMedia.ForkConfig do
  @moduledoc """
  Configuration struct for media forking to external services.

  ForkConfig defines the destination and parameters for forking RTP media
  streams to external services (e.g., for transcription, recording, or analysis).

  ## Example

      config = ForkConfig.new(
        id: "transcription_fork",
        destination_address: "192.168.1.100",
        destination_port: 5000
      )

  ## Fields

  * `:id` - Unique identifier for this fork (required)
  * `:destination_address` - IP address as tuple or string (required)
  * `:destination_port` - UDP port number 1-65535 (required)
  * `:transport` - Transport type, currently only `:rtp` is supported (default: `:rtp`)
  * `:enabled` - Whether the fork is enabled (default: `true`)
  """

  @type t :: %__MODULE__{
          id: String.t(),
          destination_address: :inet.ip4_address() | String.t(),
          destination_port: 1..65535,
          transport: :rtp,
          enabled: boolean()
        }

  @enforce_keys [:id, :destination_address, :destination_port]
  defstruct [
    :id,
    :destination_address,
    :destination_port,
    transport: :rtp,
    enabled: true
  ]

  @doc """
  Creates a new ForkConfig from keyword options.

  ## Required Options

  * `:id` - Unique identifier for this fork
  * `:destination_address` - IP address (string or tuple format)
  * `:destination_port` - Port number (1-65535)

  ## Optional Options

  * `:transport` - Transport type (default: `:rtp`)
  * `:enabled` - Whether fork is enabled (default: `true`)

  ## Examples

      ForkConfig.new(
        id: "my_fork",
        destination_address: {192, 168, 1, 100},
        destination_port: 5000
      )

      ForkConfig.new(
        id: "my_fork",
        destination_address: "10.0.0.1",
        destination_port: 6000,
        enabled: false
      )
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    id = Keyword.fetch!(opts, :id)
    destination_address = opts |> Keyword.fetch!(:destination_address) |> parse_address()
    destination_port = Keyword.fetch!(opts, :destination_port)
    transport = Keyword.get(opts, :transport, :rtp)
    enabled = Keyword.get(opts, :enabled, true)

    %__MODULE__{
      id: id,
      destination_address: destination_address,
      destination_port: destination_port,
      transport: transport,
      enabled: enabled
    }
  end

  @doc """
  Validates a ForkConfig struct.

  Returns `:ok` if valid, or `{:error, reason}` if invalid.

  ## Validation Rules

  * `:id` must not be nil
  * `:destination_port` must be between 1 and 65535
  * `:transport` must be `:rtp` (only supported transport currently)

  ## Examples

      iex> ForkConfig.validate(%ForkConfig{id: "f1", destination_address: {127,0,0,1}, destination_port: 5000, transport: :rtp, enabled: true})
      :ok

      iex> ForkConfig.validate(%ForkConfig{id: nil, destination_address: {127,0,0,1}, destination_port: 5000, transport: :rtp, enabled: true})
      {:error, :invalid_id}
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{id: nil}), do: {:error, :invalid_id}

  def validate(%__MODULE__{destination_port: port}) when port < 1 or port > 65535,
    do: {:error, :invalid_port}

  def validate(%__MODULE__{transport: transport}) when transport != :rtp,
    do: {:error, :unsupported_transport}

  def validate(%__MODULE__{}), do: :ok

  @doc """
  Parses an IP address from string to tuple format.

  If already a tuple, returns it unchanged.

  ## Examples

      iex> ForkConfig.parse_address("192.168.1.1")
      {192, 168, 1, 1}

      iex> ForkConfig.parse_address({10, 0, 0, 1})
      {10, 0, 0, 1}
  """
  @spec parse_address(String.t() | :inet.ip4_address()) :: :inet.ip4_address()
  def parse_address(address) when is_tuple(address), do: address

  def parse_address(address) when is_binary(address) do
    {:ok, ip_tuple} = :inet.parse_address(String.to_charlist(address))
    ip_tuple
  end
end
