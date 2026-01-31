defmodule Parrot.SoftphoneClient.Config do
  @moduledoc """
  Configuration validation and helpers for SoftphoneClient.

  This module validates the config map returned by a handler's `init/1` callback
  and provides helper functions for working with config.

  ## Usage

  Config is returned by your handler's `init/1` callback:

      def init(opts) do
        config = %{
          username: "alice",
          domain: "example.com",
          auth_password: fetch_password(opts.user_id),
          register_expires: 3600,
          auto_register: true,
          transport: :udp,
          supported_codecs: [:opus, :pcma]
        }
        {:ok, config, initial_state}
      end

  The SoftphoneClient validates this config using `Config.validate/1`.

  ## Required Keys

  - `:username` - SIP username
  - `:domain` - SIP domain

  ## Optional Keys (with defaults)

  - `:display_name` - Display name for From header (default: nil)
  - `:auth_username` - Auth username (default: same as username)
  - `:auth_password` - Auth password (default: nil)
  - `:registrar` - Registrar URI (default: "sip:{domain}")
  - `:register_expires` - Registration expiry in seconds (default: 3600)
  - `:auto_register` - Auto-register on start (default: true)
  - `:transport` - :udp | :tcp | :tls | :ws (default: :udp)
  - `:local_ip` - Local IP to bind (default: nil, auto-detect)
  - `:local_port` - Local port to bind (default: 0, ephemeral)
  - `:outbound_proxy` - Outbound proxy URI (default: nil)
  - `:supported_codecs` - List of codec atoms (default: [:pcma, :opus])
  """

  @type t :: %{
          required(:username) => String.t(),
          required(:domain) => String.t(),
          optional(:display_name) => String.t() | nil,
          optional(:auth_username) => String.t() | nil,
          optional(:auth_password) => String.t() | nil,
          optional(:registrar) => String.t() | nil,
          optional(:register_expires) => non_neg_integer(),
          optional(:auto_register) => boolean(),
          optional(:transport) => :udp | :tcp | :tls | :ws,
          optional(:local_ip) => String.t() | nil,
          optional(:local_port) => non_neg_integer(),
          optional(:outbound_proxy) => String.t() | nil,
          optional(:supported_codecs) => [atom()]
        }

  @default_values %{
    display_name: nil,
    auth_username: nil,
    auth_password: nil,
    registrar: nil,
    register_expires: 3600,
    auto_register: true,
    transport: :udp,
    local_ip: nil,
    local_port: 0,
    outbound_proxy: nil,
    supported_codecs: [:pcma, :opus]
  }

  @valid_transports [:udp, :tcp, :tls, :ws]

  @doc """
  Validates a config map returned by a handler's `init/1` callback.

  Returns `{:ok, normalized_config}` with defaults applied, or `{:error, reason}`.

  ## Example

      config = %{username: "alice", domain: "example.com"}
      {:ok, validated} = Config.validate(config)
      # validated has all defaults applied
  """
  @spec validate(map()) :: {:ok, t()} | {:error, term()}
  def validate(config) when is_map(config) do
    with :ok <- validate_required(config),
         :ok <- validate_values(config) do
      {:ok, apply_defaults(config)}
    end
  end

  def validate(_), do: {:error, :config_must_be_map}

  @doc """
  Returns the SIP URI (Address of Record) for a config.

  ## Example

      Config.aor(%{username: "alice", domain: "example.com"})
      # => "sip:alice@example.com"
  """
  @spec aor(t()) :: String.t()
  def aor(%{username: username, domain: domain}) do
    "sip:#{username}@#{domain}"
  end

  @doc """
  Returns the registrar URI for a config.

  Uses explicit registrar if set, otherwise defaults to "sip:{domain}".
  """
  @spec registrar(t()) :: String.t()
  def registrar(%{registrar: registrar}) when is_binary(registrar) and registrar != "" do
    registrar
  end

  def registrar(%{domain: domain}) do
    "sip:#{domain}"
  end

  @doc """
  Returns the auth username, defaulting to username if not set.
  """
  @spec auth_username(t()) :: String.t()
  def auth_username(%{auth_username: auth_username}) when is_binary(auth_username) do
    auth_username
  end

  def auth_username(%{username: username}), do: username

  # Private functions

  defp validate_required(config) do
    missing =
      [:username, :domain]
      |> Enum.filter(fn key ->
        value = Map.get(config, key)
        is_nil(value) or value == ""
      end)

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_required, keys}}
    end
  end

  defp validate_values(config) do
    cond do
      Map.has_key?(config, :transport) and config.transport not in @valid_transports ->
        {:error, {:invalid_transport, config.transport}}

      Map.has_key?(config, :register_expires) and config.register_expires < 60 ->
        {:error, {:invalid_expires, "must be >= 60 seconds"}}

      true ->
        :ok
    end
  end

  defp apply_defaults(config) do
    Map.merge(@default_values, config)
  end
end
