defmodule Parrot.SoftphoneClient.PresenceSubscriptionTest do
  @moduledoc """
  Tests for Parrot.SoftphoneClient.PresenceSubscription gen_statem.

  Tests the presence subscription state machine that manages watching
  a single presentity's presence state.
  """
  use ExUnit.Case, async: true

  alias Parrot.SoftphoneClient.PresenceSubscription

  @moduletag :presence_subscription

  # ============================================================================
  # Test Setup
  # ============================================================================

  defp valid_config do
    %{
      username: "alice",
      domain: "example.com",
      auth_username: "alice",
      auth_password: "secret"
    }
  end

  defp start_subscription(presentity, opts \\ []) do
    config = Keyword.get(opts, :config, valid_config())
    notify_pid = Keyword.get(opts, :notify_pid, self())

    PresenceSubscription.start_link(
      presentity: presentity,
      config: config,
      notify_pid: notify_pid
    )
  end

  # ============================================================================
  # Tests: Initial State
  # ============================================================================

  describe "initial state" do
    test "starts in :idle state" do
      {:ok, pid} = start_subscription("sip:bob@example.com")

      assert PresenceSubscription.get_state(pid) == :idle
    end

    test "stores presentity and config" do
      {:ok, pid} = start_subscription("sip:bob@example.com")

      data = PresenceSubscription.get_data(pid)
      assert data.presentity == "sip:bob@example.com"
      assert data.config.username == "alice"
    end
  end

  # ============================================================================
  # Tests: Subscribe Success
  # ============================================================================

  describe "subscribe success" do
    test "transitions to :subscribing when subscribe/1 called" do
      {:ok, pid} = start_subscription("sip:bob@example.com")

      :ok = PresenceSubscription.subscribe(pid)

      assert PresenceSubscription.get_state(pid) == :subscribing
    end

    test "transitions to :active on 200 OK" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)

      # Simulate 200 OK response
      send(pid, {:sip_response, build_200_ok(3600)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)
    end

    test "extracts expires from response" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)

      send(pid, {:sip_response, build_200_ok(1800)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      data = PresenceSubscription.get_data(pid)
      assert data.expires == 1800
    end
  end

  # ============================================================================
  # Tests: NOTIFY Handling
  # ============================================================================

  describe "NOTIFY handling" do
    test "parses PIDF presence from NOTIFY body" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      # Simulate NOTIFY with presence data
      send(pid, {:sip_notify, build_notify_open()})

      assert_receive {:presence_event, :presence_update, "sip:bob@example.com", presence}
      assert presence.status == :open
    end

    test "notifies handler of closed status" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      send(pid, {:sip_notify, build_notify_closed()})

      assert_receive {:presence_event, :presence_update, "sip:bob@example.com", presence}
      assert presence.status == :closed
    end

    test "handles NOTIFY with Subscription-State: terminated" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      send(pid, {:sip_notify, build_notify_terminated(:expired)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :terminated end)
      assert_receive {:presence_event, :subscription_terminated, "sip:bob@example.com", :expired}
    end

    test "handles termination reason: rejected" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      send(pid, {:sip_notify, build_notify_terminated(:rejected)})

      assert_receive {:presence_event, :subscription_terminated, "sip:bob@example.com", :rejected}
    end
  end

  # ============================================================================
  # Tests: Subscription Refresh
  # ============================================================================

  describe "subscription refresh" do
    test "schedules refresh before expiry" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(120)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      data = PresenceSubscription.get_data(pid)
      assert data.refresh_scheduled == true
    end

    test "manual refresh transitions to :refreshing" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      :ok = PresenceSubscription.refresh(pid)

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :refreshing end)
    end

    test "refresh success returns to :active" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      :ok = PresenceSubscription.refresh(pid)
      send(pid, {:sip_response, build_200_ok(3600)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)
    end
  end

  # ============================================================================
  # Tests: Unsubscribe
  # ============================================================================

  describe "unsubscribe" do
    test "sends SUBSCRIBE with expires=0" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      :ok = PresenceSubscription.unsubscribe(pid)

      # Should transition to terminated or unsubscribing
      assert_eventually(fn ->
        state = PresenceSubscription.get_state(pid)
        state in [:terminated, :unsubscribing]
      end)
    end

    test "transitions to :terminated on success" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)
      send(pid, {:sip_response, build_200_ok(3600)})
      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :active end)

      :ok = PresenceSubscription.unsubscribe(pid)
      send(pid, {:sip_response, build_200_ok(0)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :terminated end)
    end
  end

  # ============================================================================
  # Tests: Timeout Handling
  # ============================================================================

  describe "timeout handling" do
    test "transitions to :terminated on subscribe timeout" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)

      # Simulate timeout
      send(pid, {:timeout, :subscribe_timeout})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :terminated end)
      assert_receive {:presence_event, :subscription_terminated, "sip:bob@example.com", :timeout}
    end
  end

  # ============================================================================
  # Tests: Error Handling
  # ============================================================================

  describe "error responses" do
    test "transitions to :terminated on 403 Forbidden" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)

      send(pid, {:sip_response, build_error_response(403)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :terminated end)
      assert_receive {:presence_event, :subscription_terminated, "sip:bob@example.com", {:status, 403}}
    end

    test "transitions to :terminated on 489 Bad Event" do
      {:ok, pid} = start_subscription("sip:bob@example.com")
      :ok = PresenceSubscription.subscribe(pid)

      send(pid, {:sip_response, build_error_response(489)})

      assert_eventually(fn -> PresenceSubscription.get_state(pid) == :terminated end)
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
        "Expires" => "#{expires}"
      },
      expires: expires
    }
  end

  defp build_notify_open do
    %{
      subscription_state: :active,
      body: pidf_open(),
      headers: %{
        "Subscription-State" => "active;expires=3540",
        "Event" => "presence",
        "Content-Type" => "application/pidf+xml"
      }
    }
  end

  defp build_notify_closed do
    %{
      subscription_state: :active,
      body: pidf_closed(),
      headers: %{
        "Subscription-State" => "active;expires=3540",
        "Event" => "presence",
        "Content-Type" => "application/pidf+xml"
      }
    }
  end

  defp build_notify_terminated(reason) do
    %{
      subscription_state: :terminated,
      reason: reason,
      body: "",
      headers: %{
        "Subscription-State" => "terminated;reason=#{reason}",
        "Event" => "presence"
      }
    }
  end

  defp build_error_response(status) do
    %{
      status_code: status,
      reason: "Error",
      headers: %{}
    }
  end

  defp pidf_open do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <presence xmlns="urn:ietf:params:xml:ns:pidf"
              entity="sip:bob@example.com">
      <tuple id="tuple1">
        <status>
          <basic>open</basic>
        </status>
        <note>Available</note>
      </tuple>
    </presence>
    """
  end

  defp pidf_closed do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <presence xmlns="urn:ietf:params:xml:ns:pidf"
              entity="sip:bob@example.com">
      <tuple id="tuple1">
        <status>
          <basic>closed</basic>
        </status>
        <note>Away</note>
      </tuple>
    </presence>
    """
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
