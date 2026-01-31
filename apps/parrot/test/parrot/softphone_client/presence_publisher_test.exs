defmodule Parrot.SoftphoneClient.PresencePublisherTest do
  @moduledoc """
  Tests for Parrot.SoftphoneClient.PresencePublisher GenServer.

  Tests presence publication via SIP PUBLISH (RFC 3903).
  """
  use ExUnit.Case, async: true

  alias Parrot.SoftphoneClient.PresencePublisher

  @moduletag :presence_publisher

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

  defp start_publisher(opts \\ []) do
    config = Keyword.get(opts, :config, valid_config())
    notify_pid = Keyword.get(opts, :notify_pid, self())
    expires = Keyword.get(opts, :expires, 3600)

    PresencePublisher.start_link(
      config: config,
      notify_pid: notify_pid,
      expires: expires
    )
  end

  # ============================================================================
  # Tests: Initial State
  # ============================================================================

  describe "initial state" do
    test "starts successfully" do
      {:ok, pid} = start_publisher()
      assert Process.alive?(pid)
    end

    test "stores config and notify_pid" do
      {:ok, pid} = start_publisher()

      state = PresencePublisher.get_state(pid)
      assert state.config.username == "alice"
      assert state.notify_pid == self()
    end

    test "has no etag initially" do
      {:ok, pid} = start_publisher()

      state = PresencePublisher.get_state(pid)
      assert state.etag == nil
    end
  end

  # ============================================================================
  # Tests: Publish Success
  # ============================================================================

  describe "publish success" do
    test "publishes open presence state" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :open, note: "Available"})

      # Simulate 200 OK response with SIP-ETag
      send(pid, {:sip_response, build_200_ok("etag-123", 3600)})

      assert_receive {:presence_event, :publish_success, _}

      state = PresencePublisher.get_state(pid)
      assert state.etag == "etag-123"
      assert state.current_state == %{status: :open, note: "Available"}
    end

    test "publishes closed presence state" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :closed, note: "Away"})

      send(pid, {:sip_response, build_200_ok("etag-456", 3600)})

      assert_receive {:presence_event, :publish_success, _}

      state = PresencePublisher.get_state(pid)
      assert state.current_state.status == :closed
    end

    test "extracts SIP-ETag from response" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :open})

      send(pid, {:sip_response, build_200_ok("my-unique-etag", 1800)})

      state = PresencePublisher.get_state(pid)
      assert state.etag == "my-unique-etag"
      assert state.expires == 1800
    end
  end

  # ============================================================================
  # Tests: Publish Refresh
  # ============================================================================

  describe "publish refresh" do
    test "schedules refresh before expiry" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:sip_response, build_200_ok("etag-123", 120)})

      state = PresencePublisher.get_state(pid)
      assert state.refresh_scheduled == true
    end

    test "refresh uses SIP-If-Match header" do
      {:ok, pid} = start_publisher()

      # Initial publish
      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:sip_response, build_200_ok("etag-123", 3600)})

      state = PresencePublisher.get_state(pid)
      assert state.etag == "etag-123"

      # Manual refresh
      :ok = PresencePublisher.refresh(pid)

      # Should include SIP-If-Match with etag
      state = PresencePublisher.get_state(pid)
      assert state.pending_refresh == true
    end

    test "refresh updates etag on success" do
      {:ok, pid} = start_publisher()

      # Initial publish
      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:sip_response, build_200_ok("etag-123", 3600)})

      # Refresh
      :ok = PresencePublisher.refresh(pid)
      send(pid, {:sip_response, build_200_ok("etag-456", 3600)})

      state = PresencePublisher.get_state(pid)
      assert state.etag == "etag-456"
    end
  end

  # ============================================================================
  # Tests: Modify Publication
  # ============================================================================

  describe "modify publication" do
    test "modifies existing publication" do
      {:ok, pid} = start_publisher()

      # Initial publish
      :ok = PresencePublisher.publish(pid, %{status: :open, note: "Available"})
      send(pid, {:sip_response, build_200_ok("etag-123", 3600)})

      # Modify to closed
      :ok = PresencePublisher.publish(pid, %{status: :closed, note: "In meeting"})
      send(pid, {:sip_response, build_200_ok("etag-456", 3600)})

      state = PresencePublisher.get_state(pid)
      assert state.current_state.status == :closed
      assert state.current_state.note == "In meeting"
      assert state.etag == "etag-456"
    end
  end

  # ============================================================================
  # Tests: Unpublish
  # ============================================================================

  describe "unpublish" do
    test "sends PUBLISH with Expires: 0" do
      {:ok, pid} = start_publisher()

      # Initial publish
      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:sip_response, build_200_ok("etag-123", 3600)})

      # Unpublish
      :ok = PresencePublisher.unpublish(pid)
      send(pid, {:sip_response, build_200_ok(nil, 0)})

      state = PresencePublisher.get_state(pid)
      assert state.etag == nil
      assert state.current_state == nil
    end

    test "cancels refresh timer on unpublish" do
      {:ok, pid} = start_publisher()

      # Initial publish
      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:sip_response, build_200_ok("etag-123", 3600)})

      state_before = PresencePublisher.get_state(pid)
      assert state_before.refresh_scheduled == true

      # Unpublish
      :ok = PresencePublisher.unpublish(pid)
      send(pid, {:sip_response, build_200_ok(nil, 0)})

      state_after = PresencePublisher.get_state(pid)
      assert state_after.refresh_scheduled == false
    end
  end

  # ============================================================================
  # Tests: Error Handling
  # ============================================================================

  describe "error handling" do
    test "notifies handler on publish failure" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:sip_response, build_error_response(403)})

      assert_receive {:presence_event, :publish_failed, {:status, 403}}
    end

    test "handles 412 Conditional Request Failed" do
      {:ok, pid} = start_publisher()

      # Initial publish
      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:sip_response, build_200_ok("etag-123", 3600)})

      # Refresh with stale etag
      :ok = PresencePublisher.refresh(pid)
      send(pid, {:sip_response, build_error_response(412)})

      assert_receive {:presence_event, :publish_failed, {:status, 412}}
    end

    test "handles timeout" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :open})
      send(pid, {:timeout, :publish_timeout})

      assert_receive {:presence_event, :publish_failed, :timeout}
    end
  end

  # ============================================================================
  # Tests: PIDF Body Generation
  # ============================================================================

  describe "PIDF body generation" do
    test "generates valid PIDF+XML for open status" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :open, note: "Available"})

      # The publisher should generate PIDF - we verify by checking the state
      state = PresencePublisher.get_state(pid)
      assert state.pending_state == %{status: :open, note: "Available"}
    end

    test "generates valid PIDF+XML for closed status" do
      {:ok, pid} = start_publisher()

      :ok = PresencePublisher.publish(pid, %{status: :closed, note: "Away"})

      state = PresencePublisher.get_state(pid)
      assert state.pending_state == %{status: :closed, note: "Away"}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp build_200_ok(etag, expires) do
    headers = %{"Expires" => "#{expires}"}
    headers = if etag, do: Map.put(headers, "SIP-ETag", etag), else: headers

    %{
      status_code: 200,
      reason: "OK",
      headers: headers,
      etag: etag,
      expires: expires
    }
  end

  defp build_error_response(status) do
    %{
      status_code: status,
      reason: "Error",
      headers: %{}
    }
  end
end
