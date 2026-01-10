defmodule ParrotSip.Registrar do
  @moduledoc """
  SIP Registrar implementation with Digest authentication.

  This module handles REGISTER request processing including:
  - 401 Unauthorized challenge generation
  - Digest authentication validation
  - Registration binding management via handler callbacks

  ## Authentication Flow (RFC 3261 Section 22)

  1. Client sends REGISTER without Authorization header
  2. Registrar responds with 401 Unauthorized + WWW-Authenticate challenge
  3. Client sends REGISTER with Authorization header containing digest response
  4. Registrar validates credentials and responds with 200 OK or 403 Forbidden

  ## Usage

      # Process an incoming REGISTER request
      case Registrar.process_register(message, handler, realm, nonce_store) do
        {:ok, response} ->
          # Send 200 OK
          Server.response(response, uas)

        {:challenge, response} ->
          # Send 401 Unauthorized
          Server.response(response, uas)

        {:error, response} ->
          # Send 403 Forbidden
          Server.response(response, uas)
      end

  ## Handler Requirements

  The handler module must implement:
  - `get_password/1` - Return password for username
  - `authenticate/1` - Additional authentication logic
  - `store_binding/3` - Store registration binding
  - `get_bindings/1` - Retrieve current bindings

  ## RFC References

  - RFC 3261 Section 10: Registrations
  - RFC 3261 Section 22: Usage of HTTP Authentication
  - RFC 2617: HTTP Authentication (Digest)
  """

  require Logger

  alias ParrotSip.Message
  alias ParrotSip.Auth
  alias ParrotSip.Auth.NonceStore
  alias ParrotSip.Headers.{From, Contact}

  @type result ::
          {:ok, Message.t()}
          | {:challenge, Message.t()}
          | {:error, Message.t()}

  @doc """
  Processes a REGISTER request with authentication.

  ## Parameters

  - `message` - The incoming REGISTER request
  - `handler` - Handler module implementing RegistrationHandler callbacks
  - `realm` - Authentication realm (usually the domain)
  - `nonce_store` - NonceStore server for nonce management

  ## Returns

  - `{:ok, response}` - Authentication successful, 200 OK response
  - `{:challenge, response}` - No/invalid credentials, 401 Unauthorized response
  - `{:error, response}` - Authentication failed, 403 Forbidden response
  """
  @spec process_register(Message.t(), module(), String.t(), GenServer.server()) :: result()
  def process_register(message, handler, realm, nonce_store) do
    case extract_credentials(message) do
      {:error, :no_credentials} ->
        # No Authorization header - send 401 challenge
        challenge_response = build_challenge_response(message, realm, nonce_store)
        {:challenge, challenge_response}

      {:ok, credentials} ->
        # Validate credentials
        validate_and_process(message, credentials, handler, realm, nonce_store)
    end
  end

  @doc """
  Extracts credentials from the Authorization header of a REGISTER request.

  ## Returns

  - `{:ok, credentials}` - Map with parsed Authorization parameters
  - `{:error, :no_credentials}` - No Authorization header present
  """
  @spec extract_credentials(Message.t()) :: {:ok, map()} | {:error, :no_credentials}
  def extract_credentials(message) do
    case Message.get_header(message, "authorization") do
      nil ->
        {:error, :no_credentials}

      auth_header ->
        case Auth.parse_auth_header(auth_header) do
          {:ok, params} ->
            {:ok, build_credentials_map(params)}

          {:error, _} ->
            {:error, :no_credentials}
        end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp validate_and_process(message, credentials, handler, realm, nonce_store) do
    # Step 1: Validate the nonce
    nc = credentials[:nc]

    case NonceStore.validate_nonce(nonce_store, credentials.nonce, nc) do
      {:error, :invalid_nonce} ->
        # Unknown nonce - reject
        {:error, build_forbidden_response(message)}

      {:error, :stale_nonce} ->
        # Expired nonce - send new challenge with stale=true
        challenge_response = build_challenge_response(message, realm, nonce_store, stale: true)
        {:challenge, challenge_response}

      {:error, :replay_detected} ->
        # Replay attack - reject
        Logger.warning("[Registrar] Replay attack detected for user #{credentials.username}")
        {:error, build_forbidden_response(message)}

      :ok ->
        # Step 2: Get password from handler
        validate_with_password(message, credentials, handler, realm)
    end
  end

  defp validate_with_password(message, credentials, handler, _realm) do
    username = credentials.username

    # Get password from handler
    case handler.get_password(username) do
      {:ok, password} ->
        # Step 3: Validate the digest response
        validate_digest(message, credentials, password, handler)

      :error ->
        # Unknown user
        Logger.debug("[Registrar] Unknown user: #{username}")
        {:error, build_forbidden_response(message)}
    end
  end

  defp validate_digest(message, credentials, password, handler) do
    # Build credentials struct for validation
    auth_credentials = %{
      username: credentials.username,
      realm: credentials.realm,
      nonce: credentials.nonce,
      uri: credentials.uri,
      response: credentials.response,
      algorithm: credentials.algorithm || "MD5",
      cnonce: credentials[:cnonce],
      opaque: credentials[:opaque],
      qop: credentials[:qop],
      nc: credentials[:nc]
    }

    case Auth.validate_authorization(auth_credentials, :register, password) do
      {:ok, username} ->
        # Step 4: Call handler's authenticate callback for any additional checks
        auth_info = %{
          username: username,
          realm: credentials.realm,
          nonce: credentials.nonce
        }

        case handler.authenticate(auth_info) do
          :ok ->
            # Step 5: Process the registration
            process_registration(message, handler)

          :error ->
            {:error, build_forbidden_response(message)}
        end

      {:error, :invalid_credentials} ->
        Logger.debug("[Registrar] Invalid digest response for user: #{credentials.username}")
        {:error, build_forbidden_response(message)}
    end
  end

  defp process_registration(message, handler) do
    # Extract AOR from To header
    aor = extract_aor(message)

    # Extract Contact and Expires
    {contact_uri, expires} = extract_contact_info(message)

    # Store the binding
    case handler.store_binding(aor, contact_uri, expires) do
      :ok ->
        # Build 200 OK with current bindings
        bindings = handler.get_bindings(aor)
        {:ok, build_success_response(message, bindings, expires)}

      {:error, reason} ->
        Logger.error("[Registrar] Failed to store binding: #{inspect(reason)}")
        {:error, build_server_error_response(message)}
    end
  end

  defp build_challenge_response(message, realm, nonce_store, opts \\ []) do
    # Generate new nonce
    nonce = NonceStore.generate_nonce(nonce_store)
    stale = Keyword.get(opts, :stale, false)

    challenge = Auth.generate_challenge(realm, stale: stale)
    challenge = %{challenge | nonce: nonce}

    www_auth = Auth.format_auth_header(challenge)

    response = Message.reply(message, 401, "Unauthorized")
    response = Message.put_header(response, "WWW-Authenticate", www_auth)

    %{response | body: "", content_length: 0}
  end

  defp build_forbidden_response(message) do
    response = Message.reply(message, 403, "Forbidden")
    %{response | body: "", content_length: 0}
  end

  defp build_server_error_response(message) do
    response = Message.reply(message, 500, "Server Internal Error")
    %{response | body: "", content_length: 0}
  end

  defp build_success_response(message, bindings, expires) do
    response = Message.reply(message, 200, "OK")

    # Build Contact header(s) from bindings
    # Bindings can be:
    # - Rich binding maps: %{contact: uri, expires: int, registered_at: int, q: float (optional)}
    # - Simple URI strings (legacy format, deprecated)
    contacts =
      case bindings do
        [] ->
          # No bindings - return the original contact
          message.contact

        bindings when is_list(bindings) ->
          now = System.system_time(:second)

          Enum.map(bindings, fn binding ->
            build_contact_from_binding(binding, expires, now)
          end)
      end

    response = %{response | contact: contacts, expires: expires}
    %{response | body: "", content_length: 0}
  end

  # Build Contact from rich binding map with optional q-value
  # RFC 3261 Section 10.3: Response MUST include Contact with expires
  # RFC 3261 Section 10.2.1.2: q-value indicates Contact preference (0.0-1.0)
  defp build_contact_from_binding(
         %{contact: uri, expires: binding_expires, registered_at: registered_at} = binding,
         _default_expires,
         now
       ) do
    # Calculate remaining time
    elapsed = now - registered_at
    remaining = max(0, binding_expires - elapsed)

    params = %{"expires" => to_string(remaining)}

    # Add q-value if present
    params =
      case Map.get(binding, :q) do
        nil -> params
        q when is_float(q) -> Map.put(params, "q", :io_lib.format("~.1f", [q]) |> to_string())
      end

    %Contact{uri: uri, parameters: params}
  end

  # Legacy format: simple URI string (deprecated, for backwards compatibility)
  defp build_contact_from_binding(uri, expires, _now) when is_binary(uri) do
    %Contact{uri: uri, parameters: %{"expires" => to_string(expires)}}
  end

  defp extract_aor(message) do
    # AOR comes from To header
    case message.to do
      %From{uri: uri} -> uri_to_string(uri)
      %{uri: uri} -> uri_to_string(uri)
      _ -> nil
    end
  end

  defp extract_contact_info(message) do
    # Get Contact URI
    contact_uri =
      case message.contact do
        %Contact{uri: uri} -> uri_to_string(uri)
        [%Contact{uri: uri} | _] -> uri_to_string(uri)
        uri when is_binary(uri) -> uri
        _ -> nil
      end

    # Get Expires (from Contact parameters or Expires header)
    expires =
      case message.contact do
        %Contact{parameters: %{"expires" => exp}} ->
          parse_expires(exp)

        _ ->
          message.expires || 3600
      end

    {contact_uri, expires}
  end

  defp parse_expires(exp) when is_binary(exp) do
    case Integer.parse(exp) do
      {int, ""} -> int
      _ -> 3600
    end
  end

  defp parse_expires(exp) when is_integer(exp), do: exp
  defp parse_expires(_), do: 3600

  # Convert URI struct to string
  defp uri_to_string(%ParrotSip.Uri{} = uri), do: ParrotSip.Uri.to_string(uri)
  defp uri_to_string(uri) when is_binary(uri), do: uri
  defp uri_to_string(_), do: nil

  defp build_credentials_map(params) do
    %{
      username: params["username"],
      realm: params["realm"],
      nonce: params["nonce"],
      uri: params["uri"],
      response: params["response"],
      algorithm: params["algorithm"],
      cnonce: params["cnonce"],
      opaque: params["opaque"],
      qop: params["qop"],
      nc: params["nc"]
    }
  end
end
