defmodule ParrotSip.UA.Config do
  @moduledoc """
  Configuration structure for User Agent (UA).

  This struct holds all the configuration needed for a SIP User Agent,
  including identity, registration, and default headers.

  ## Example

      config = %ParrotSip.UA.Config{
        from: %ParrotSip.Headers.From{
          display_name: "Alice",
          uri: "sip:alice@example.com",
          parameters: %{}
        },
        contact: %ParrotSip.Headers.Contact{
          uri: "sip:alice@192.168.1.100:5060",
          parameters: %{}
        },
        outbound_proxy: "sip:proxy.example.com:5060",
        registration: %ParrotSip.UA.Registration{
          enabled: true,
          username: "alice",
          password: "secret123",
          expires: 3600,
          retry_interval: 60
        },
        headers: %{
          "User-Agent" => "ParrotSip/1.0"
        },
        local_host: "192.168.1.100",
        local_port: 5060,
        transport: :udp
      }
  """

  alias ParrotSip.Headers.{From, Contact}

  @type headers_config :: %{String.t() => String.t()}

  @type t :: %__MODULE__{
          from: From.t(),
          contact: Contact.t() | nil,
          outbound_proxy: String.t() | nil,
          registration: ParrotSip.UA.Registration.t() | nil,
          headers: headers_config(),
          local_host: String.t() | nil,
          local_port: integer() | nil,
          transport: :udp | :tcp | :tls
        }

  @enforce_keys [:from]
  defstruct [
    :from,
    contact: nil,
    outbound_proxy: nil,
    registration: nil,
    headers: %{},
    local_host: nil,
    local_port: nil,
    transport: :udp
  ]


  @doc """
  Validates the configuration.

  Returns `{:ok, config}` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{from: %From{uri: uri}} = config) when is_binary(uri) do
    with :ok <- validate_registration(config.registration, config.outbound_proxy) do
      {:ok, config}
    end
  end

  def validate(%__MODULE__{}) do
    {:error, :invalid_from_uri}
  end

  defp validate_registration(nil, _outbound_proxy), do: :ok

  defp validate_registration(%{enabled: false}, _outbound_proxy), do: :ok

  defp validate_registration(%{enabled: true}, outbound_proxy)
       when is_binary(outbound_proxy) and byte_size(outbound_proxy) > 0 do
    :ok
  end

  defp validate_registration(%{enabled: true}, _outbound_proxy) do
    {:error, :registration_requires_outbound_proxy}
  end

  defp validate_registration(_, _), do: :ok
end
