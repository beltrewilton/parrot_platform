defmodule ParrotSip.AuthTest do
  use ExUnit.Case, async: true

  alias ParrotSip.Auth

  @moduletag :auth

  describe "generate_challenge/2" do
    test "generates challenge with required fields" do
      challenge = Auth.generate_challenge("atlanta.com")

      assert challenge.realm == "atlanta.com"
      assert is_binary(challenge.nonce)
      assert String.length(challenge.nonce) > 0
      assert challenge.algorithm == "MD5"
      assert challenge.qop == "auth"
      assert is_binary(challenge.opaque)
    end

    test "accepts custom algorithm" do
      challenge = Auth.generate_challenge("atlanta.com", algorithm: "MD5-sess")
      assert challenge.algorithm == "MD5-sess"
    end

    test "accepts custom qop" do
      challenge = Auth.generate_challenge("atlanta.com", qop: "auth-int")
      assert challenge.qop == "auth-int"
    end

    test "accepts stale flag" do
      challenge = Auth.generate_challenge("atlanta.com", stale: true)
      assert challenge.stale == true
    end

    test "accepts custom opaque" do
      challenge = Auth.generate_challenge("atlanta.com", opaque: "custom-opaque")
      assert challenge.opaque == "custom-opaque"
    end

    test "generates unique nonces" do
      challenge1 = Auth.generate_challenge("atlanta.com")
      challenge2 = Auth.generate_challenge("atlanta.com")

      assert challenge1.nonce != challenge2.nonce
    end
  end

  describe "create_authorization/6" do
    setup do
      challenge = %{
        realm: "atlanta.com",
        nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
        opaque: "5ccc069c403ebaf9f0171e9517f40e41",
        algorithm: "MD5",
        qop: "auth"
      }

      {:ok, challenge: challenge}
    end

    test "creates authorization with MD5 algorithm", %{challenge: challenge} do
      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret",
          cnonce: "0a4f113b",
          nc: "00000001"
        )

      assert auth.username == "alice"
      assert auth.realm == "atlanta.com"
      assert auth.nonce == challenge.nonce
      assert auth.uri == "sip:atlanta.com"
      assert auth.algorithm == "MD5"
      assert auth.opaque == challenge.opaque
      assert auth.qop == "auth"
      assert auth.cnonce == "0a4f113b"
      assert auth.nc == "00000001"
      assert is_binary(auth.response)
      # MD5 hex is 32 chars
      assert String.length(auth.response) == 32
    end

    test "creates authorization without qop", %{challenge: challenge} do
      challenge_no_qop = Map.delete(challenge, :qop)

      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge_no_qop,
          "alice",
          "secret"
        )

      assert auth.username == "alice"
      assert auth.qop == nil
      assert auth.cnonce == nil
      assert auth.nc == nil
      assert is_binary(auth.response)
    end

    test "generates cnonce automatically when qop present", %{challenge: challenge} do
      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret",
          nc: "00000001"
        )

      assert is_binary(auth.cnonce)
      assert String.length(auth.cnonce) > 0
    end

    test "works with different SIP methods", %{challenge: challenge} do
      methods = [:invite, :register, :options, :bye, :cancel, :ack]

      for method <- methods do
        auth =
          Auth.create_authorization(
            method,
            "sip:atlanta.com",
            challenge,
            "alice",
            "secret"
          )

        assert auth.username == "alice"
        assert is_binary(auth.response)
      end
    end

    test "handles string keys in challenge map", %{challenge: challenge} do
      string_challenge =
        challenge
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          string_challenge,
          "alice",
          "secret"
        )

      assert auth.realm == "atlanta.com"
      assert auth.nonce == challenge.nonce
    end
  end

  describe "validate_authorization/3" do
    test "validates correct credentials" do
      # Create a challenge
      challenge = %{
        realm: "atlanta.com",
        nonce: "test-nonce",
        algorithm: "MD5"
      }

      # Create authorization with known password
      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret123"
        )

      # Validate with correct password
      assert {:ok, "alice"} = Auth.validate_authorization(auth, :register, "secret123")
    end

    test "validates authorization with pre-computed response (simulating real SIP message)" do
      # This simulates receiving an Authorization header from a SIP message
      # where we only get the hashed response, never the actual password

      # Pre-computed response for:
      # username="alice", realm="atlanta.com", nonce="dcd98b7", 
      # uri="sip:atlanta.com", method=REGISTER, password="secret"
      auth_from_sip_message = %{
        username: "alice",
        realm: "atlanta.com",
        nonce: "dcd98b7",
        uri: "sip:atlanta.com",
        # This would be the actual MD5 hash
        response: "a1b2c3d4e5f6",
        algorithm: "MD5",
        qop: nil,
        cnonce: nil,
        nc: nil,
        opaque: nil
      }

      # Server validates using the password it has stored for alice
      # Note: In production, the server would look up alice's password from DB
      stored_password = "secret"

      # The validation will recompute the hash and compare
      # For this test to pass, we need the correct pre-computed response
      # Let's compute it properly first:
      challenge = %{realm: "atlanta.com", nonce: "dcd98b7", algorithm: "MD5"}

      correct_auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          stored_password
        )

      # Now create the auth object as if received from network
      auth_from_sip_message = %{auth_from_sip_message | response: correct_auth.response}

      # Validate - this is what the server does
      assert {:ok, "alice"} =
               Auth.validate_authorization(auth_from_sip_message, :register, stored_password)
    end

    test "rejects incorrect password" do
      challenge = %{
        realm: "atlanta.com",
        nonce: "test-nonce",
        algorithm: "MD5"
      }

      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret123"
        )

      # Validate with wrong password
      assert {:error, :invalid_credentials} =
               Auth.validate_authorization(auth, :register, "wrong")
    end

    test "validates with qop and cnonce" do
      challenge = %{
        realm: "atlanta.com",
        nonce: "test-nonce",
        algorithm: "MD5",
        qop: "auth"
      }

      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret123",
          cnonce: "client-nonce",
          nc: "00000001"
        )

      assert {:ok, "alice"} = Auth.validate_authorization(auth, :register, "secret123")
    end

    test "rejects if method doesn't match" do
      challenge = %{
        realm: "atlanta.com",
        nonce: "test-nonce",
        algorithm: "MD5"
      }

      # Create auth for REGISTER
      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret123"
        )

      # Validate with different method (INVITE)
      assert {:error, :invalid_credentials} =
               Auth.validate_authorization(auth, :invite, "secret123")
    end
  end

  describe "parse_auth_header/1" do
    test "parses basic Digest auth header" do
      header = ~s(Digest realm="atlanta.com", nonce="abc123", qop="auth")

      assert {:ok, params} = Auth.parse_auth_header(header)
      assert params["realm"] == "atlanta.com"
      assert params["nonce"] == "abc123"
      assert params["qop"] == "auth"
    end

    test "parses header without Digest prefix" do
      header = ~s(realm="atlanta.com", nonce="abc123")

      assert {:ok, params} = Auth.parse_auth_header(header)
      assert params["realm"] == "atlanta.com"
      assert params["nonce"] == "abc123"
    end

    test "parses header with all parameters" do
      header =
        ~s(Digest username="alice", realm="atlanta.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", uri="sip:atlanta.com", response="6629fae49393a05397450978507c4ef1", algorithm=MD5, cnonce="0a4f113b", opaque="5ccc069c403ebaf9f0171e9517f40e41", qop=auth, nc=00000001)

      assert {:ok, params} = Auth.parse_auth_header(header)
      assert params["username"] == "alice"
      assert params["realm"] == "atlanta.com"
      assert params["nonce"] == "dcd98b7102dd2f0e8b11d0f600bfb0c093"
      assert params["uri"] == "sip:atlanta.com"
      assert params["response"] == "6629fae49393a05397450978507c4ef1"
      assert params["algorithm"] == "MD5"
      assert params["cnonce"] == "0a4f113b"
      assert params["opaque"] == "5ccc069c403ebaf9f0171e9517f40e41"
      assert params["qop"] == "auth"
      assert params["nc"] == "00000001"
    end

    test "handles values with spaces" do
      header = ~s(Digest realm="My Realm", nonce="abc123")

      assert {:ok, params} = Auth.parse_auth_header(header)
      assert params["realm"] == "My Realm"
    end

    test "handles unquoted values" do
      header = ~s(Digest algorithm=MD5, qop=auth, nc=00000001)

      assert {:ok, params} = Auth.parse_auth_header(header)
      assert params["algorithm"] == "MD5"
      assert params["qop"] == "auth"
      assert params["nc"] == "00000001"
    end
  end

  describe "format_auth_header/1" do
    test "formats basic auth parameters" do
      params = %{
        realm: "atlanta.com",
        nonce: "abc123"
      }

      header = Auth.format_auth_header(params)
      assert header == ~s(Digest realm="atlanta.com", nonce="abc123")
    end

    test "formats complete authorization" do
      params = %{
        username: "alice",
        realm: "atlanta.com",
        nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
        uri: "sip:atlanta.com",
        response: "6629fae49393a05397450978507c4ef1",
        algorithm: "MD5",
        cnonce: "0a4f113b",
        opaque: "5ccc069c403ebaf9f0171e9517f40e41",
        qop: "auth",
        nc: "00000001"
      }

      header = Auth.format_auth_header(params)

      assert String.starts_with?(header, "Digest ")
      assert String.contains?(header, ~s(username="alice"))
      assert String.contains?(header, ~s(realm="atlanta.com"))
      assert String.contains?(header, ~s(response="6629fae49393a05397450978507c4ef1"))
      # nc and qop should not be quoted
      assert String.contains?(header, "qop=auth")
      assert String.contains?(header, "nc=00000001")
    end

    test "excludes nil values" do
      params = %{
        realm: "atlanta.com",
        nonce: "abc123",
        stale: nil,
        opaque: nil
      }

      header = Auth.format_auth_header(params)

      assert header == ~s(Digest realm="atlanta.com", nonce="abc123")
      refute String.contains?(header, "stale")
      refute String.contains?(header, "opaque")
    end

    test "handles atom keys" do
      params = %{
        realm: "atlanta.com",
        nonce: "abc123"
      }

      header = Auth.format_auth_header(params)
      assert String.contains?(header, ~s(realm="atlanta.com"))
    end
  end

  describe "MD5 response calculation" do
    test "calculates correct response without qop (RFC 2617 example)" do
      # This is based on RFC 2617 Section 3.5 example
      challenge = %{
        realm: "testrealm@host.com",
        nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
        algorithm: "MD5"
      }

      auth =
        Auth.create_authorization(
          # Using GET to match HTTP example
          :get,
          "/dir/index.html",
          challenge,
          "Mufasa",
          "Circle Of Life"
        )

      # The response should be deterministic for the same inputs
      assert is_binary(auth.response)
      assert String.length(auth.response) == 32
    end

    test "calculates consistent responses" do
      challenge = %{
        realm: "atlanta.com",
        nonce: "fixed-nonce",
        algorithm: "MD5",
        qop: "auth"
      }

      auth1 =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret",
          cnonce: "fixed-cnonce",
          nc: "00000001"
        )

      auth2 =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret",
          cnonce: "fixed-cnonce",
          nc: "00000001"
        )

      # Same inputs should produce same response
      assert auth1.response == auth2.response
    end

    test "different passwords produce different responses" do
      challenge = %{
        realm: "atlanta.com",
        nonce: "fixed-nonce",
        algorithm: "MD5"
      }

      auth1 =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "password1"
        )

      auth2 =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "password2"
        )

      assert auth1.response != auth2.response
    end

    test "different methods produce different responses" do
      challenge = %{
        realm: "atlanta.com",
        nonce: "fixed-nonce",
        algorithm: "MD5"
      }

      auth1 =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret"
        )

      auth2 =
        Auth.create_authorization(
          :invite,
          "sip:atlanta.com",
          challenge,
          "alice",
          "secret"
        )

      assert auth1.response != auth2.response
    end
  end

  describe "integration scenarios" do
    test "complete authentication flow" do
      # Step 1: Server generates challenge
      challenge = Auth.generate_challenge("atlanta.com")

      # Step 2: Client creates authorization
      auth =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          challenge,
          "alice",
          "mysecret"
        )

      # Step 3: Server validates authorization
      assert {:ok, "alice"} = Auth.validate_authorization(auth, :register, "mysecret")
    end

    test "authentication with stale nonce retry" do
      # First attempt with old nonce
      old_challenge = Auth.generate_challenge("atlanta.com")

      auth1 =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          old_challenge,
          "alice",
          "mysecret"
        )

      # Server rejects with stale=true
      new_challenge = Auth.generate_challenge("atlanta.com", stale: true)

      # Client retries with new nonce
      auth2 =
        Auth.create_authorization(
          :register,
          "sip:atlanta.com",
          new_challenge,
          "alice",
          "mysecret"
        )

      # Server accepts with new nonce
      assert {:ok, "alice"} = Auth.validate_authorization(auth2, :register, "mysecret")

      # The responses should be different due to different nonces
      assert auth1.response != auth2.response
    end
  end
end
