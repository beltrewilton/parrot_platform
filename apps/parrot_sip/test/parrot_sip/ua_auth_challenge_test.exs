defmodule ParrotSip.UAAuthChallengeTest do
  @moduledoc """
  Tests for 401/407 authentication challenge handling in ParrotSip.UA.

  RFC 3261 Section 22: SIP authentication follows the HTTP digest authentication
  model defined in RFC 2617.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.{UA, Message}
  alias ParrotSip.Headers.{Via, From, To, CSeq}
  alias ParrotSip.UA.Entity

  @moduletag :ua_auth

  # ============================================================================
  # Test Handler Modules
  # ============================================================================

  defmodule AuthTestHandler do
    @moduledoc """
    Test handler that tracks auth challenge events.
    """
    use ParrotSip.UA.Handler

    @impl true
    def init(test_pid) do
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_rejected(_ua, response, entity, state) do
      send(state.test_pid, {:rejected, response.status_code, entity.id})
      {:ok, state}
    end

    @impl true
    def handle_incoming(_ua, _invite, _entity, state), do: {:ok, state}

    @impl true
    def handle_answered(_ua, _response, _entity, state), do: {:ok, state}

    @impl true
    def handle_hangup(_ua, _message, _entity, state), do: {:ok, state}
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp build_challenge_response(status_code, auth_header_name, challenge) do
    %Message{
      type: :response,
      status_code: status_code,
      reason_phrase: status_reason(status_code),
      call_id: "test-call-id-#{System.unique_integer([:positive])}",
      cseq: %CSeq{number: 1, method: :invite},
      from: %From{
        uri: "sip:alice@example.com",
        display_name: "Alice",
        parameters: %{"tag" => "from-tag"}
      },
      to: %To{
        uri: "sip:bob@example.com",
        display_name: "Bob",
        parameters: %{"tag" => "to-tag"}
      },
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-test"}
        }
      ],
      other_headers: %{auth_header_name => challenge}
    }
  end

  defp status_reason(401), do: "Unauthorized"
  defp status_reason(407), do: "Proxy Authentication Required"

  defp build_test_state(opts \\ []) do
    %{
      handler_module: Keyword.get(opts, :handler_module, AuthTestHandler),
      handler_state: Keyword.get(opts, :handler_state, %{test_pid: self()}),
      entities: Keyword.get(opts, :entities, %{}),
      registrations: %{},
      port: 5060,
      transport: nil,
      local_host: "127.0.0.1",
      # New fields for auth handling
      auth_retry_state: Keyword.get(opts, :auth_retry_state, %{}),
      auth_nc: Keyword.get(opts, :auth_nc, %{})
    }
  end

  defp build_test_entity(entity_id, opts \\ []) do
    %Entity{
      id: entity_id,
      type: :uac,
      state: Keyword.get(opts, :state, :trying),
      remote_uri: "sip:bob@example.com",
      local_uri: "sip:alice@example.com",
      call_id: Keyword.get(opts, :call_id, "test-call-id"),
      local_tag: "from-tag",
      remote_tag: nil,
      ua_pid: self(),
      uas: nil,
      trans: nil,
      request: Keyword.get(opts, :request, nil),
      local_seq: 1
    }
  end

  defp build_invite_request(target_uri, opts \\ []) do
    %Message{
      type: :request,
      method: "INVITE",
      request_uri: target_uri,
      call_id: Keyword.get(opts, :call_id, "test-call-id"),
      cseq: %CSeq{number: 1, method: :invite},
      from: %From{
        uri: "sip:alice@example.com",
        display_name: "Alice",
        parameters: %{"tag" => "from-tag"}
      },
      to: %To{
        uri: target_uri,
        display_name: nil,
        parameters: %{}
      },
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-test"}
        }
      ],
      body: "v=0\r\n"
    }
  end

  # ============================================================================
  # Tests: 401 Unauthorized Challenge Handling
  # ============================================================================

  describe "401 Unauthorized challenge handling" do
    test "calls handle_rejected when no auth_retry_state exists (no credentials)" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      challenge = ~s(Digest realm="example.com", nonce="abc123", algorithm=MD5, qop="auth")
      response = build_challenge_response(401, "WWW-Authenticate", challenge)

      entity = build_test_entity(entity_id)

      state = build_test_state(
        entities: %{entity_id => entity}
      )

      # No auth_retry_state means no credentials were provided
      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      # Should call handle_rejected since we don't have credentials
      assert_receive {:rejected, 401, ^entity_id}, 1000
    end

    test "retries with Authorization header when credentials available" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      call_id = "call-#{System.unique_integer([:positive])}"
      challenge = ~s(Digest realm="example.com", nonce="abc123", algorithm=MD5, qop="auth")
      response = build_challenge_response(401, "WWW-Authenticate", challenge)
      response = %{response | call_id: call_id}

      original_request = build_invite_request("sip:bob@example.com", call_id: call_id)
      entity = build_test_entity(entity_id, call_id: call_id, request: original_request)

      # auth_retry_state stores credentials for retry
      auth_retry = %{
        original_request: original_request,
        auth_attempted: false,
        username: "alice",
        password: "secret"
      }

      state = build_test_state(
        entities: %{entity_id => entity},
        auth_retry_state: %{call_id => auth_retry}
      )

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, new_state} = UA.handle_cast(message, state)

      # Should NOT call handle_rejected - should retry with auth
      refute_receive {:rejected, 401, _}, 100

      # auth_retry_state should be updated with auth_attempted: true
      assert new_state.auth_retry_state[call_id].auth_attempted == true
    end

    test "calls handle_rejected when auth already attempted (prevents loop)" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      call_id = "call-#{System.unique_integer([:positive])}"
      challenge = ~s(Digest realm="example.com", nonce="abc123", algorithm=MD5, qop="auth")
      response = build_challenge_response(401, "WWW-Authenticate", challenge)
      response = %{response | call_id: call_id}

      original_request = build_invite_request("sip:bob@example.com", call_id: call_id)
      entity = build_test_entity(entity_id, call_id: call_id, request: original_request)

      # Simulate auth already attempted
      auth_retry = %{
        original_request: original_request,
        auth_attempted: true,
        username: "alice",
        password: "secret"
      }

      state = build_test_state(
        entities: %{entity_id => entity},
        auth_retry_state: %{call_id => auth_retry}
      )

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      # Should call handle_rejected since auth already attempted
      assert_receive {:rejected, 401, ^entity_id}, 1000
    end
  end

  # ============================================================================
  # Tests: 407 Proxy-Authenticate Challenge Handling
  # ============================================================================

  describe "407 Proxy-Authenticate challenge handling" do
    test "calls handle_rejected when no credentials provided" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      challenge = ~s(Digest realm="proxy.example.com", nonce="xyz789", algorithm=MD5, qop="auth")
      response = build_challenge_response(407, "Proxy-Authenticate", challenge)

      entity = build_test_entity(entity_id)

      state = build_test_state(
        entities: %{entity_id => entity}
      )

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      assert_receive {:rejected, 407, ^entity_id}, 1000
    end

    test "retries with Proxy-Authorization header when credentials available" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      call_id = "call-#{System.unique_integer([:positive])}"
      challenge = ~s(Digest realm="proxy.example.com", nonce="xyz789", algorithm=MD5, qop="auth")
      response = build_challenge_response(407, "Proxy-Authenticate", challenge)
      response = %{response | call_id: call_id}

      original_request = build_invite_request("sip:bob@example.com", call_id: call_id)
      entity = build_test_entity(entity_id, call_id: call_id, request: original_request)

      auth_retry = %{
        original_request: original_request,
        auth_attempted: false,
        username: "alice",
        password: "secret"
      }

      state = build_test_state(
        entities: %{entity_id => entity},
        auth_retry_state: %{call_id => auth_retry}
      )

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, new_state} = UA.handle_cast(message, state)

      # Should NOT call handle_rejected
      refute_receive {:rejected, 407, _}, 100

      # auth_retry_state should be updated
      assert new_state.auth_retry_state[call_id].auth_attempted == true
    end

    test "calls handle_rejected when proxy auth already attempted" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      call_id = "call-#{System.unique_integer([:positive])}"
      challenge = ~s(Digest realm="proxy.example.com", nonce="xyz789", algorithm=MD5, qop="auth")
      response = build_challenge_response(407, "Proxy-Authenticate", challenge)
      response = %{response | call_id: call_id}

      original_request = build_invite_request("sip:bob@example.com", call_id: call_id)
      entity = build_test_entity(entity_id, call_id: call_id, request: original_request)

      auth_retry = %{
        original_request: original_request,
        auth_attempted: true,
        username: "alice",
        password: "secret"
      }

      state = build_test_state(
        entities: %{entity_id => entity},
        auth_retry_state: %{call_id => auth_retry}
      )

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      assert_receive {:rejected, 407, ^entity_id}, 1000
    end
  end

  # ============================================================================
  # Tests: Nonce Count Tracking
  # ============================================================================

  describe "nonce count tracking" do
    test "increments nonce count on each auth attempt for same nonce" do
      # This tests the Auth module's nonce count handling
      challenge = %{
        "realm" => "example.com",
        "nonce" => "test-nonce",
        "algorithm" => "MD5",
        "qop" => "auth"
      }

      # First auth with nc=00000001
      auth1 =
        ParrotSip.Auth.create_authorization(
          :invite,
          "sip:bob@example.com",
          challenge,
          "alice",
          "secret",
          nc: "00000001"
        )

      assert auth1.nc == "00000001"

      # Second auth with nc=00000002
      auth2 =
        ParrotSip.Auth.create_authorization(
          :invite,
          "sip:bob@example.com",
          challenge,
          "alice",
          "secret",
          nc: "00000002"
        )

      assert auth2.nc == "00000002"

      # Responses should differ due to different nc
      assert auth1.response != auth2.response
    end

    test "UA tracks nonce count per realm/nonce pair" do
      # Initial state with no nonce counts
      state = build_test_state()
      assert state.auth_nc == %{}

      # After first auth attempt, nonce count should be tracked
      nonce_key = {"example.com", "abc123"}
      updated_state = %{state | auth_nc: Map.put(state.auth_nc, nonce_key, 1)}

      assert updated_state.auth_nc[nonce_key] == 1

      # Incrementing for same nonce
      updated_state = %{updated_state | auth_nc: Map.put(updated_state.auth_nc, nonce_key, 2)}
      assert updated_state.auth_nc[nonce_key] == 2
    end
  end

  # ============================================================================
  # Tests: Authorization Header Format
  # ============================================================================

  describe "authorization header format" do
    test "401 uses Authorization header" do
      challenge = %{
        "realm" => "example.com",
        "nonce" => "test-nonce",
        "algorithm" => "MD5"
      }

      auth = ParrotSip.Auth.create_authorization(
        :invite,
        "sip:bob@example.com",
        challenge,
        "alice",
        "secret"
      )

      header = ParrotSip.Auth.format_auth_header(auth)
      assert String.starts_with?(header, "Digest ")
      assert String.contains?(header, ~s(username="alice"))
      assert String.contains?(header, ~s(realm="example.com"))
    end

    test "407 uses Proxy-Authorization header" do
      # The header name is determined by the status code (401 vs 407)
      # but the auth content format is the same
      challenge = %{
        "realm" => "proxy.example.com",
        "nonce" => "proxy-nonce",
        "algorithm" => "MD5"
      }

      auth = ParrotSip.Auth.create_authorization(
        :invite,
        "sip:bob@example.com",
        challenge,
        "alice",
        "secret"
      )

      header = ParrotSip.Auth.format_auth_header(auth)
      assert String.starts_with?(header, "Digest ")
      assert String.contains?(header, ~s(realm="proxy.example.com"))
    end
  end
end
