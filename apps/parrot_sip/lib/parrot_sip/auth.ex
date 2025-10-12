defmodule ParrotSip.Auth do
  @moduledoc """
  SIP Digest Authentication implementation according to RFC 2617 and RFC 3261.

  This module provides functions for:
  - Generating authentication challenges (401/407 responses)
  - Creating authorization headers for requests
  - Validating authentication credentials

  ## RFC References
  - RFC 2617: HTTP Authentication: Basic and Digest Access Authentication
  - RFC 3261 Section 22: Usage of HTTP Authentication
  - RFC 3261 Section 26.3.2.2: Digest Authentication
  """

  require Logger

  @type auth_params :: %{
          realm: String.t(),
          nonce: String.t(),
          opaque: String.t() | nil,
          stale: boolean() | nil,
          algorithm: String.t(),
          qop: String.t() | nil
        }

  @type credentials :: %{
          username: String.t(),
          password: String.t(),
          realm: String.t(),
          nonce: String.t(),
          uri: String.t(),
          response: String.t(),
          algorithm: String.t(),
          cnonce: String.t() | nil,
          opaque: String.t() | nil,
          qop: String.t() | nil,
          nc: String.t() | nil
        }

  @doc """
  Generates a WWW-Authenticate or Proxy-Authenticate challenge header.

  ## Parameters
  - `realm` - The authentication realm (typically the domain)
  - `opts` - Additional options:
    - `:qop` - Quality of protection ("auth" or "auth-int"), defaults to "auth"
    - `:algorithm` - Hash algorithm ("MD5" or "MD5-sess"), defaults to "MD5"
    - `:stale` - Whether the nonce is stale (for re-authentication)
    - `:opaque` - Server data that should be returned unchanged

  ## Examples

      iex> challenge = ParrotSip.Auth.generate_challenge("atlanta.com")
      iex> challenge[:realm]
      "atlanta.com"
      iex> String.length(challenge[:nonce]) > 0
      true
  """
  @spec generate_challenge(String.t(), keyword()) :: auth_params()
  def generate_challenge(realm, opts \\ []) do
    %{
      realm: realm,
      nonce: generate_nonce(),
      opaque: Keyword.get(opts, :opaque, generate_opaque()),
      stale: Keyword.get(opts, :stale),
      algorithm: Keyword.get(opts, :algorithm, "MD5"),
      qop: Keyword.get(opts, :qop, "auth")
    }
  end

  @doc """
  Creates an Authorization or Proxy-Authorization header value.

  ## Parameters
  - `method` - SIP method (INVITE, REGISTER, etc.)
  - `uri` - Request URI
  - `challenge` - Authentication challenge parameters from 401/407 response
  - `username` - User's username
  - `password` - User's password
  - `opts` - Additional options:
    - `:cnonce` - Client nonce (required if qop is present)
    - `:nc` - Nonce count (required if qop is present)

  ## Examples

      iex> challenge = %{realm: "atlanta.com", nonce: "abc123", algorithm: "MD5", qop: "auth"}
      iex> auth = ParrotSip.Auth.create_authorization(:register, "sip:atlanta.com", 
      ...>   challenge, "alice", "secret", cnonce: "xyz789", nc: "00000001")
      iex> auth[:username]
      "alice"
      iex> auth[:realm]
      "atlanta.com"
  """
  @spec create_authorization(atom(), String.t(), map(), String.t(), String.t(), keyword()) ::
          credentials()
  def create_authorization(method, uri, challenge, username, password, opts \\ []) do
    # Extract qop if present
    qop = challenge[:qop] || challenge["qop"]

    # Generate client nonce if qop is present
    cnonce =
      if qop do
        Keyword.get(opts, :cnonce, generate_cnonce())
      end

    # Nonce count (must be provided if qop is present)
    nc =
      if qop do
        Keyword.get(opts, :nc, "00000001")
      end

    # Calculate the response hash
    response =
      calculate_response(
        method,
        uri,
        username,
        password,
        challenge[:realm] || challenge["realm"],
        challenge[:nonce] || challenge["nonce"],
        cnonce,
        nc,
        qop,
        challenge[:algorithm] || challenge["algorithm"] || "MD5"
      )

    %{
      username: username,
      realm: challenge[:realm] || challenge["realm"],
      nonce: challenge[:nonce] || challenge["nonce"],
      uri: uri,
      response: response,
      algorithm: challenge[:algorithm] || challenge["algorithm"] || "MD5",
      cnonce: cnonce,
      opaque: challenge[:opaque] || challenge["opaque"],
      qop: qop,
      nc: nc
    }
  end

  @doc """
  Validates an authorization against expected credentials.

  ## Parameters
  - `auth` - Authorization credentials from the request
  - `method` - SIP method
  - `password` - Expected password for the username

  ## Returns
  - `{:ok, username}` if authentication succeeds
  - `{:error, reason}` if authentication fails

  ## Examples

      iex> auth = %{
      ...>   username: "alice",
      ...>   realm: "atlanta.com",
      ...>   nonce: "abc123",
      ...>   uri: "sip:atlanta.com",
      ...>   response: "...",
      ...>   algorithm: "MD5"
      ...> }
      iex> {:error, _} = ParrotSip.Auth.validate_authorization(auth, :register, "wrong_password")
  """
  @spec validate_authorization(credentials(), atom(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def validate_authorization(auth, method, password) do
    # Recalculate the expected response
    expected_response =
      calculate_response(
        method,
        auth.uri,
        auth.username,
        password,
        auth.realm,
        auth.nonce,
        auth.cnonce,
        auth.nc,
        auth.qop,
        auth.algorithm || "MD5"
      )

    if expected_response == auth.response do
      {:ok, auth.username}
    else
      {:error, :invalid_credentials}
    end
  end

  @doc """
  Parses an Authorization or WWW-Authenticate header value.

  ## Examples

      iex> header = ~s(Digest realm="atlanta.com", nonce="abc123", qop="auth")
      iex> {:ok, params} = ParrotSip.Auth.parse_auth_header(header)
      iex> params["realm"]
      "atlanta.com"
  """
  @spec parse_auth_header(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse_auth_header(header_value) when is_binary(header_value) do
    # Remove "Digest " prefix if present
    header_value = String.replace_prefix(header_value, "Digest ", "")

    # Parse comma-separated key=value pairs
    params =
      header_value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(pair, "=", parts: 2) do
          [key, value] ->
            # Remove quotes if present
            clean_value = String.trim(value, "\"")
            Map.put(acc, String.trim(key), clean_value)

          _ ->
            acc
        end
      end)

    {:ok, params}
  rescue
    _ -> {:error, :invalid_auth_header}
  end

  @doc """
  Formats authentication parameters into a header value string.

  ## Examples

      iex> params = %{realm: "atlanta.com", nonce: "abc123"}
      iex> ParrotSip.Auth.format_auth_header(params)
      ~s(Digest realm="atlanta.com", nonce="abc123")
  """
  @spec format_auth_header(map()) :: String.t()
  def format_auth_header(params) do
    # Build the Digest auth string
    auth_params =
      params
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} ->
        key = to_string(k)
        # Quote string values except nc, qop (when it's the selected value, not offered)
        if key in ["nc", "qop"] and not String.contains?(to_string(v), " ") do
          "#{key}=#{v}"
        else
          "#{key}=\"#{v}\""
        end
      end)
      |> Enum.join(", ")

    "Digest " <> auth_params
  end

  # Private functions

  defp calculate_response(
         method,
         uri,
         username,
         password,
         realm,
         nonce,
         cnonce,
         nc,
         qop,
         algorithm
       ) do
    # HA1 calculation
    ha1 =
      case algorithm do
        "MD5-sess" ->
          initial_ha1 = md5_hex("#{username}:#{realm}:#{password}")
          md5_hex("#{initial_ha1}:#{nonce}:#{cnonce}")

        # MD5
        _ ->
          md5_hex("#{username}:#{realm}:#{password}")
      end

    # HA2 calculation
    ha2 = md5_hex("#{String.upcase(to_string(method))}:#{uri}")

    # Response calculation
    if qop in ["auth", "auth-int"] do
      md5_hex("#{ha1}:#{nonce}:#{nc}:#{cnonce}:#{qop}:#{ha2}")
    else
      md5_hex("#{ha1}:#{nonce}:#{ha2}")
    end
  end

  defp md5_hex(data) do
    :crypto.hash(:md5, data)
    |> Base.encode16(case: :lower)
  end

  defp generate_nonce do
    # Generate a time-based nonce
    timestamp = System.system_time(:second)
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    "#{timestamp}:#{random}"
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  defp generate_cnonce do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  defp generate_opaque do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
