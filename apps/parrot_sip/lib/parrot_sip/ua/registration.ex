defmodule ParrotSip.UA.Registration do
  @moduledoc """
  Configuration for SIP registration.

  This struct defines how the UA should register with a SIP registrar
  via the configured outbound proxy.

  ## Fields
  - `enabled` - Whether registration is enabled
  - `username` - Username for authentication
  - `password` - Password for authentication
  - `expires` - Registration expiration time in seconds (default: 3600)
  - `retry_interval` - Seconds to wait before retry on failure (default: 60)
  - `auth_realm` - Authentication realm (optional, usually auto-detected from challenge)

  ## Example

      registration = %ParrotSip.UA.Registration{
        enabled: true,
        username: "alice",
        password: "secret123",
        expires: 3600,
        retry_interval: 60
      }
  """

  @type t :: %__MODULE__{
          enabled: boolean(),
          username: String.t() | nil,
          password: String.t() | nil,
          expires: pos_integer(),
          retry_interval: pos_integer(),
          auth_realm: String.t() | nil
        }

  @enforce_keys [:enabled]
  defstruct [
    :enabled,
    username: nil,
    password: nil,
    expires: 3600,
    retry_interval: 60,
    auth_realm: nil
  ]

  @doc """
  Validates registration configuration.

  Returns `{:ok, registration}` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{enabled: false} = reg) do
    {:ok, reg}
  end

  def validate(%__MODULE__{enabled: true, username: username, password: password} = reg)
      when is_binary(username) and is_binary(password) do
    {:ok, reg}
  end

  def validate(%__MODULE__{enabled: true}) do
    {:error, :registration_requires_credentials}
  end
end
