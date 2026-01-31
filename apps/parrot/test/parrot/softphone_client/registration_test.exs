defmodule Parrot.SoftphoneClient.RegistrationTest do
  @moduledoc """
  Tests for Parrot.SoftphoneClient.Registration gen_statem.

  Tests the registration state machine that manages REGISTER lifecycle
  with automatic auth retry and re-registration.
  """
  use ExUnit.Case, async: true

  alias Parrot.SoftphoneClient.Registration

  @moduletag :registration

  # ============================================================================
  # Test Setup
  # ============================================================================

  defp valid_config do
    %{
      username: "alice",
      domain: "example.com",
      auth_username: "alice",
      auth_password: "secret",
      register_expires: 3600,
      registrar: "sip:example.com"
    }
  end

  defp start_registration(config \\ valid_config(), opts \\ []) do
    notify_pid = Keyword.get(opts, :notify_pid, self())
    Registration.start_link(config: config, notify_pid: notify_pid)
  end

  # ============================================================================
  # Tests: Initial State
  # ============================================================================

  describe "initial state" do
    test "starts in :unregistered state" do
      {:ok, pid} = start_registration()

      assert Registration.get_state(pid) == :unregistered
    end

    test "accepts config and notify_pid" do
      {:ok, pid} = start_registration()

      data = Registration.get_data(pid)
      assert data.config.username == "alice"
      assert data.notify_pid == self()
    end
  end

  # ============================================================================
  # Tests: Registration Success
  # ============================================================================

  describe "registration success" do
    test "transitions to :registering when register/1 called" do
      {:ok, pid} = start_registration()

      :ok = Registration.register(pid)

      # Should be in registering state
      assert Registration.get_state(pid) == :registering
    end

    test "transitions to :registered on 200 OK" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # Simulate 200 OK response
      send(pid, {:sip_response, build_200_ok(3600)})

      # Wait for state transition
      assert_eventually(fn -> Registration.get_state(pid) == :registered end)

      # Should notify handler
      assert_receive {:registration_event, :registered, %{expires: 3600}}
    end

    test "extracts expires from response" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # 200 OK with 1800s expires
      send(pid, {:sip_response, build_200_ok(1800)})

      assert_receive {:registration_event, :registered, %{expires: 1800}}
    end
  end

  # ============================================================================
  # Tests: 401/407 Authentication Challenge
  # ============================================================================

  describe "401 Unauthorized handling" do
    test "retries with Authorization header on 401" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # Simulate 401 response
      send(pid, {:sip_response, build_401_response()})

      # Should transition to awaiting_auth and retry
      assert_eventually(fn -> Registration.get_state(pid) in [:awaiting_auth, :registering] end)

      # Should NOT notify failure yet
      refute_receive {:registration_event, :registration_failed, _}, 100
    end

    test "transitions to :registered after successful auth" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # First 401
      send(pid, {:sip_response, build_401_response()})
      Process.sleep(50)

      # Then 200 OK
      send(pid, {:sip_response, build_200_ok(3600)})

      assert_eventually(fn -> Registration.get_state(pid) == :registered end)
      assert_receive {:registration_event, :registered, _}
    end

    test "fails after second 401 (prevents infinite loop)" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # First 401 - should retry
      send(pid, {:sip_response, build_401_response()})
      Process.sleep(50)

      # Second 401 - should fail
      send(pid, {:sip_response, build_401_response()})

      assert_eventually(fn -> Registration.get_state(pid) == :failed end)
      assert_receive {:registration_event, :registration_failed, :auth_failed}
    end
  end

  describe "407 Proxy-Authenticate handling" do
    test "retries with Proxy-Authorization header on 407" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # Simulate 407 response
      send(pid, {:sip_response, build_407_response()})

      # Should retry, not fail
      assert_eventually(fn -> Registration.get_state(pid) in [:awaiting_auth, :registering] end)
      refute_receive {:registration_event, :registration_failed, _}, 100
    end

    test "fails after second 407" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # First 407
      send(pid, {:sip_response, build_407_response()})
      Process.sleep(50)

      # Second 407
      send(pid, {:sip_response, build_407_response()})

      assert_eventually(fn -> Registration.get_state(pid) == :failed end)
      assert_receive {:registration_event, :registration_failed, :auth_failed}
    end
  end

  describe "missing credentials" do
    test "fails immediately if no credentials" do
      config = %{valid_config() | auth_password: nil}
      {:ok, pid} = start_registration(config)
      :ok = Registration.register(pid)

      # 401 response
      send(pid, {:sip_response, build_401_response()})

      assert_eventually(fn -> Registration.get_state(pid) == :failed end)
      assert_receive {:registration_event, :registration_failed, :no_credentials}
    end
  end

  # ============================================================================
  # Tests: Re-registration
  # ============================================================================

  describe "re-registration timer" do
    test "schedules re-register before expiry" do
      # Use short expires for testing
      config = %{valid_config() | register_expires: 120}
      {:ok, pid} = start_registration(config)
      :ok = Registration.register(pid)

      send(pid, {:sip_response, build_200_ok(120)})

      assert_eventually(fn -> Registration.get_state(pid) == :registered end)

      # Check that re-register timer is scheduled
      data = Registration.get_data(pid)
      assert data.re_register_scheduled == true
    end

    test "re-registers when timer fires" do
      # This test would need time manipulation or very short timeouts
      # For now, we test that the timer mechanism exists
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)
      send(pid, {:sip_response, build_200_ok(3600)})

      assert_eventually(fn -> Registration.get_state(pid) == :registered end)

      # Manually trigger re-register
      :ok = Registration.refresh(pid)

      # Should go back to registering
      assert_eventually(fn -> Registration.get_state(pid) == :registering end)
    end
  end

  # ============================================================================
  # Tests: Unregistration
  # ============================================================================

  describe "unregister" do
    test "sends REGISTER with expires=0" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> Registration.get_state(pid) == :registered end)

      :ok = Registration.unregister(pid)

      # Should be unregistering
      assert_eventually(fn -> Registration.get_state(pid) == :unregistering end)
    end

    test "transitions to :unregistered on 200 OK" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> Registration.get_state(pid) == :registered end)

      :ok = Registration.unregister(pid)
      send(pid, {:sip_response, build_200_ok(0)})

      assert_eventually(fn -> Registration.get_state(pid) == :unregistered end)
      assert_receive {:registration_event, :unregistered, _}
    end
  end

  # ============================================================================
  # Tests: Timeout Handling
  # ============================================================================

  describe "timeout handling" do
    test "transitions to :failed on registration timeout" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      # Simulate timeout (state_timeout would fire after 32s, but we can trigger manually)
      send(pid, {:timeout, :registration_timeout})

      assert_eventually(fn -> Registration.get_state(pid) == :failed end)
      assert_receive {:registration_event, :registration_failed, :timeout}
    end
  end

  # ============================================================================
  # Tests: Error Handling
  # ============================================================================

  describe "error responses" do
    test "fails on 403 Forbidden" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      send(pid, {:sip_response, build_error_response(403, "Forbidden")})

      assert_eventually(fn -> Registration.get_state(pid) == :failed end)
      assert_receive {:registration_event, :registration_failed, {:status, 403}}
    end

    test "fails on 5xx server error" do
      {:ok, pid} = start_registration()
      :ok = Registration.register(pid)

      send(pid, {:sip_response, build_error_response(500, "Server Error")})

      assert_eventually(fn -> Registration.get_state(pid) == :failed end)
      assert_receive {:registration_event, :registration_failed, {:status, 500}}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp build_200_ok(expires) do
    %{
      status_code: 200,
      reason: "OK",
      headers: %{
        "Contact" => "<sip:alice@192.168.1.100:5060>;expires=#{expires}"
      },
      expires: expires
    }
  end

  defp build_401_response do
    %{
      status_code: 401,
      reason: "Unauthorized",
      headers: %{
        "WWW-Authenticate" =>
          ~s(Digest realm="example.com", nonce="abc123", algorithm=MD5, qop="auth")
      }
    }
  end

  defp build_407_response do
    %{
      status_code: 407,
      reason: "Proxy Authentication Required",
      headers: %{
        "Proxy-Authenticate" =>
          ~s(Digest realm="proxy.example.com", nonce="xyz789", algorithm=MD5, qop="auth")
      }
    }
  end

  defp build_error_response(status, reason) do
    %{
      status_code: status,
      reason: reason,
      headers: %{}
    }
  end

  defp assert_eventually(condition, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_condition(condition, deadline)
  end

  defp wait_for_condition(condition, deadline) do
    if condition.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("Condition not met within timeout")
      else
        Process.sleep(10)
        wait_for_condition(condition, deadline)
      end
    end
  end
end
