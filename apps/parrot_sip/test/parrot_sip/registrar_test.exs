defmodule ParrotSip.RegistrarTest do
  use ExUnit.Case, async: false

  alias ParrotSip.Registrar
  alias ParrotSip.Message
  alias ParrotSip.Auth
  alias ParrotSip.Auth.NonceStore
  alias ParrotSip.Headers.{From, To, Via, CSeq, Contact}

  @moduletag :auth

  # RFC 3261 Section 10: Registrations
  # RFC 3261 Section 22: Usage of HTTP Authentication
  # RFC 2617: HTTP Authentication (Digest)

  # Test handler that implements the get_password/1 callback
  defmodule TestRegistrationHandler do
    use Parrot.RegistrationHandler

    @impl true
    def get_password("alice"), do: {:ok, "secret123"}
    def get_password("bob"), do: {:ok, "bobspassword"}
    def get_password(_), do: :error

    @impl true
    def authenticate(%{username: username}) do
      # Just check the user exists - password validation is done by framework
      case get_password(username) do
        {:ok, _} -> :ok
        :error -> :error
      end
    end

    @impl true
    def store_binding(aor, contact, expires) do
      # Store in process dictionary for test verification
      bindings = Process.get(:test_bindings, %{})
      contacts = Map.get(bindings, aor, [])

      new_contacts =
        if expires > 0 do
          [{contact, expires} | Enum.reject(contacts, fn {c, _} -> c == contact end)]
        else
          Enum.reject(contacts, fn {c, _} -> c == contact end)
        end

      Process.put(:test_bindings, Map.put(bindings, aor, new_contacts))
      :ok
    end

    @impl true
    def get_bindings(aor) do
      bindings = Process.get(:test_bindings, %{})
      contacts = Map.get(bindings, aor, [])
      Enum.map(contacts, fn {contact, _expires} -> contact end)
    end
  end

  setup do
    # Start nonce store for tests
    {:ok, nonce_store} = NonceStore.start_link(name: :test_registrar_nonce_store)

    on_exit(fn ->
      if Process.alive?(nonce_store), do: GenServer.stop(nonce_store)
    end)

    # Clear test bindings
    Process.delete(:test_bindings)

    %{
      nonce_store: nonce_store,
      handler: TestRegistrationHandler,
      realm: "example.com"
    }
  end

  describe "process_register/4 - unauthenticated request" do
    test "returns 401 challenge for REGISTER without Authorization header", ctx do
      register_msg = build_register_request()

      result = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      assert {:challenge, response} = result
      assert response.status_code == 401
      assert response.reason_phrase == "Unauthorized"

      # Should have WWW-Authenticate header
      www_auth = Message.get_header(response, "www-authenticate")
      assert www_auth != nil
      assert String.contains?(www_auth, "Digest")
      assert String.contains?(www_auth, ~s(realm="example.com"))
      assert String.contains?(www_auth, "nonce=")
    end

    test "generates unique nonces for each 401 challenge", ctx do
      register_msg = build_register_request()

      {:challenge, response1} = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      {:challenge, response2} = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      www_auth1 = Message.get_header(response1, "www-authenticate")
      www_auth2 = Message.get_header(response2, "www-authenticate")

      # Extract nonces and verify they're different
      {:ok, params1} = Auth.parse_auth_header(www_auth1)
      {:ok, params2} = Auth.parse_auth_header(www_auth2)

      assert params1["nonce"] != params2["nonce"]
    end
  end

  describe "process_register/4 - authenticated request" do
    test "returns 200 OK for valid credentials", ctx do
      # First get a challenge to get a valid nonce
      register_msg = build_register_request()

      {:challenge, challenge_response} = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      www_auth = Message.get_header(challenge_response, "www-authenticate")
      {:ok, challenge_params} = Auth.parse_auth_header(www_auth)

      # Build authorization response
      auth = Auth.create_authorization(
        :register,
        "sip:example.com",
        challenge_params,
        "alice",
        "secret123"
      )

      auth_header = Auth.format_auth_header(auth)

      # Create authenticated REGISTER
      auth_register = build_register_request()
      auth_register = Message.put_header(auth_register, "Authorization", auth_header)

      result = Registrar.process_register(
        auth_register,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      assert {:ok, response} = result
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
    end

    test "returns 403 Forbidden for invalid password", ctx do
      # Get a valid nonce first
      register_msg = build_register_request()

      {:challenge, challenge_response} = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      www_auth = Message.get_header(challenge_response, "www-authenticate")
      {:ok, challenge_params} = Auth.parse_auth_header(www_auth)

      # Build authorization with WRONG password
      auth = Auth.create_authorization(
        :register,
        "sip:example.com",
        challenge_params,
        "alice",
        "wrongpassword"
      )

      auth_header = Auth.format_auth_header(auth)

      auth_register = build_register_request()
      auth_register = Message.put_header(auth_register, "Authorization", auth_header)

      result = Registrar.process_register(
        auth_register,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      assert {:error, response} = result
      assert response.status_code == 403
      assert response.reason_phrase == "Forbidden"
    end

    test "returns 403 Forbidden for unknown user", ctx do
      # Get a valid nonce first
      register_msg = build_register_request()

      {:challenge, challenge_response} = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      www_auth = Message.get_header(challenge_response, "www-authenticate")
      {:ok, challenge_params} = Auth.parse_auth_header(www_auth)

      # Build authorization for unknown user
      auth = Auth.create_authorization(
        :register,
        "sip:example.com",
        challenge_params,
        "unknown_user",
        "anypassword"
      )

      auth_header = Auth.format_auth_header(auth)

      auth_register = build_register_request()
      auth_register = Message.put_header(auth_register, "Authorization", auth_header)

      result = Registrar.process_register(
        auth_register,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      assert {:error, response} = result
      assert response.status_code == 403
    end

    test "returns 401 with stale=true for expired nonce", ctx do
      # Start nonce store with very short TTL
      GenServer.stop(ctx.nonce_store)
      {:ok, short_ttl_store} = NonceStore.start_link(name: :test_short_ttl_store, ttl_seconds: 1)

      register_msg = build_register_request()

      {:challenge, challenge_response} = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        short_ttl_store
      )

      www_auth = Message.get_header(challenge_response, "www-authenticate")
      {:ok, challenge_params} = Auth.parse_auth_header(www_auth)

      # Wait for nonce to expire
      Process.sleep(1100)

      # Try to authenticate with expired nonce
      auth = Auth.create_authorization(
        :register,
        "sip:example.com",
        challenge_params,
        "alice",
        "secret123"
      )

      auth_header = Auth.format_auth_header(auth)

      auth_register = build_register_request()
      auth_register = Message.put_header(auth_register, "Authorization", auth_header)

      result = Registrar.process_register(
        auth_register,
        ctx.handler,
        ctx.realm,
        short_ttl_store
      )

      # Should get 401 with stale=true
      assert {:challenge, response} = result
      assert response.status_code == 401

      www_auth_stale = Message.get_header(response, "www-authenticate")
      assert String.contains?(www_auth_stale, "stale=true") or
             String.contains?(www_auth_stale, ~s(stale="true"))

      GenServer.stop(short_ttl_store)
    end

    test "detects replay attacks", ctx do
      register_msg = build_register_request()

      {:challenge, challenge_response} = Registrar.process_register(
        register_msg,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      www_auth = Message.get_header(challenge_response, "www-authenticate")
      {:ok, challenge_params} = Auth.parse_auth_header(www_auth)

      # Build authorization with specific nc
      auth = Auth.create_authorization(
        :register,
        "sip:example.com",
        challenge_params,
        "alice",
        "secret123",
        nc: "00000001"
      )

      auth_header = Auth.format_auth_header(auth)

      auth_register = build_register_request()
      auth_register = Message.put_header(auth_register, "Authorization", auth_header)

      # First request should succeed
      {:ok, _} = Registrar.process_register(
        auth_register,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      # Replay with same nc should fail
      result = Registrar.process_register(
        auth_register,
        ctx.handler,
        ctx.realm,
        ctx.nonce_store
      )

      assert {:error, response} = result
      assert response.status_code == 403
    end
  end

  describe "process_register/4 - binding management" do
    test "stores binding on successful registration", ctx do
      # Authenticate and register
      {:ok, _response} = authenticate_and_register(ctx, "alice", "secret123")

      # Verify binding was stored
      bindings = Process.get(:test_bindings, %{})
      assert Map.has_key?(bindings, "sip:alice@example.com")

      contacts = bindings["sip:alice@example.com"]
      assert length(contacts) > 0
    end

    test "200 OK includes registered contacts", ctx do
      {:ok, response} = authenticate_and_register(ctx, "alice", "secret123")

      # Response should include Contact header(s)
      contact = response.contact
      assert contact != nil
    end

    test "handles unregister (expires=0)", ctx do
      # First register
      {:ok, _} = authenticate_and_register(ctx, "alice", "secret123", expires: 3600)

      # Then unregister with expires=0
      {:ok, response} = authenticate_and_register(ctx, "alice", "secret123", expires: 0)

      assert response.status_code == 200

      # Binding should be removed
      bindings = Process.get(:test_bindings, %{})
      contacts = Map.get(bindings, "sip:alice@example.com", [])
      assert contacts == []
    end
  end

  describe "extract_credentials/1" do
    test "extracts credentials from Authorization header" do
      auth_header = ~s(Digest username="alice", realm="example.com", nonce="abc123", uri="sip:example.com", response="xyz789", algorithm=MD5, qop=auth, nc=00000001, cnonce="client123")

      register_msg = build_register_request()
      register_msg = Message.put_header(register_msg, "Authorization", auth_header)

      {:ok, credentials} = Registrar.extract_credentials(register_msg)

      assert credentials.username == "alice"
      assert credentials.realm == "example.com"
      assert credentials.nonce == "abc123"
      assert credentials.uri == "sip:example.com"
      assert credentials.response == "xyz789"
      assert credentials.nc == "00000001"
    end

    test "returns error when no Authorization header" do
      register_msg = build_register_request()

      assert {:error, :no_credentials} = Registrar.extract_credentials(register_msg)
    end
  end

  # Helper functions

  defp build_register_request do
    msg = Message.new_request(:register, "sip:example.com")

    via = %Via{
      protocol: "SIP/2.0",
      transport: "UDP",
      host: "192.168.1.100",
      port: 5060,
      parameters: %{"branch" => "z9hG4bK-test-branch"}
    }

    from = %From{
      uri: "sip:alice@example.com",
      display_name: "Alice",
      parameters: %{"tag" => "from-tag-123"}
    }

    to = %To{
      uri: "sip:alice@example.com",
      display_name: "Alice",
      parameters: %{}
    }

    cseq = %CSeq{number: 1, method: :register}

    contact = %Contact{
      uri: "sip:alice@192.168.1.100:5060",
      parameters: %{}
    }

    %{msg |
      via: [via],
      from: from,
      to: to,
      cseq: cseq,
      call_id: "test-call-id@example.com",
      contact: contact,
      expires: 3600,
      max_forwards: 70,
      type: :request,
      direction: :incoming
    }
  end

  defp authenticate_and_register(ctx, username, password, opts \\ []) do
    expires = Keyword.get(opts, :expires, 3600)

    # Get challenge
    register_msg = build_register_request()
    register_msg = %{register_msg | expires: expires}

    {:challenge, challenge_response} = Registrar.process_register(
      register_msg,
      ctx.handler,
      ctx.realm,
      ctx.nonce_store
    )

    www_auth = Message.get_header(challenge_response, "www-authenticate")
    {:ok, challenge_params} = Auth.parse_auth_header(www_auth)

    # Build authenticated request
    auth = Auth.create_authorization(
      :register,
      "sip:example.com",
      challenge_params,
      username,
      password
    )

    auth_header = Auth.format_auth_header(auth)

    auth_register = build_register_request()
    auth_register = %{auth_register | expires: expires}
    auth_register = Message.put_header(auth_register, "Authorization", auth_header)

    Registrar.process_register(
      auth_register,
      ctx.handler,
      ctx.realm,
      ctx.nonce_store
    )
  end
end
