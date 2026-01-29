defmodule ParrotSip.Presence.ServerTest do
  @moduledoc """
  Tests for ParrotSip.Presence.Server - the presence subscription manager.

  This module handles:
  - Receiving SUBSCRIBE requests and creating subscriptions
  - Storing subscriptions by presentity for watcher lookup
  - Sending NOTIFYs to all watchers when presence changes

  ## RFC References

  - RFC 6665: SIP-Specific Event Notification
  - RFC 3856: A Presence Event Package for SIP
  - RFC 3863: Presence Information Data Format (PIDF)
  """
  use ExUnit.Case, async: false

  alias ParrotSip.Presence.Server, as: PresenceServer
  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, From, To, CSeq, Contact, Event}

  setup do
    # Ensure presence server is started fresh for each test
    case GenServer.whereis(PresenceServer) do
      nil -> :ok
      _pid ->
        # Server is already running from application, just clear state
        PresenceServer.clear_all()
    end

    :ok
  end

  describe "subscribe/3 - RFC 6665 Section 4.2" do
    test "accepts SUBSCRIBE and creates subscription in pending state" do
      presentity = "sip:alice@example.com"
      watcher = "sip:bob@example.com"
      subscribe_msg = build_subscribe_message(presentity, watcher)

      result = PresenceServer.subscribe(subscribe_msg, &mock_authorize/1)

      assert {:ok, subscription_id, :pending} = result
      assert is_binary(subscription_id)
    end

    test "stores subscription for watcher lookup" do
      presentity = "sip:alice@example.com"
      watcher = "sip:bob@example.com"
      subscribe_msg = build_subscribe_message(presentity, watcher)

      {:ok, subscription_id, _state} = PresenceServer.subscribe(subscribe_msg, &mock_authorize/1)

      # Should be able to find watchers for this presentity
      watchers = PresenceServer.get_watchers(presentity)
      assert length(watchers) == 1
      assert hd(watchers).subscription_id == subscription_id
    end

    test "multiple watchers can subscribe to same presentity" do
      presentity = "sip:alice@example.com"

      # Two different watchers subscribe
      subscribe1 = build_subscribe_message(presentity, "sip:bob@example.com")
      subscribe2 = build_subscribe_message(presentity, "sip:carol@example.com")

      {:ok, sub_id1, _} = PresenceServer.subscribe(subscribe1, &mock_authorize/1)
      {:ok, sub_id2, _} = PresenceServer.subscribe(subscribe2, &mock_authorize/1)

      watchers = PresenceServer.get_watchers(presentity)
      assert length(watchers) == 2

      watcher_ids = Enum.map(watchers, & &1.subscription_id)
      assert sub_id1 in watcher_ids
      assert sub_id2 in watcher_ids
    end

    test "returns 202 Accepted for pending authorization" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      # Authorize function returns :pending
      authorize_fn = fn _msg -> {:ok, :pending} end

      result = PresenceServer.subscribe(subscribe_msg, authorize_fn)

      assert {:ok, _subscription_id, :pending} = result
    end

    test "returns 200 OK for immediate authorization" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      # Authorize function returns :active (immediate approval)
      authorize_fn = fn _msg -> {:ok, :active} end

      result = PresenceServer.subscribe(subscribe_msg, authorize_fn)

      assert {:ok, _subscription_id, :active} = result
    end

    test "rejects subscription when authorization fails" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      # Authorize function rejects
      authorize_fn = fn _msg -> {:error, :forbidden} end

      result = PresenceServer.subscribe(subscribe_msg, authorize_fn)

      assert {:error, :forbidden} = result

      # No watcher should be stored
      assert [] = PresenceServer.get_watchers(presentity)
    end

    test "extracts event package from Event header" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize/1)

      # Verify the subscription has correct event package
      {:ok, sub} = PresenceServer.get_subscription(subscription_id)
      assert sub.event_package == "presence"
    end

    test "respects Expires header for subscription duration" do
      presentity = "sip:alice@example.com"
      subscribe_msg =
        build_subscribe_message(presentity, "sip:bob@example.com")
        |> Map.put(:expires, 7200)

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize/1)

      {:ok, sub} = PresenceServer.get_subscription(subscription_id)
      assert sub.expires == 7200
    end
  end

  describe "unsubscribe/1 - SUBSCRIBE with expires=0" do
    test "removes subscription when expires=0" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize/1)
      assert length(PresenceServer.get_watchers(presentity)) == 1

      # Unsubscribe
      :ok = PresenceServer.unsubscribe(subscription_id)

      assert [] = PresenceServer.get_watchers(presentity)
      assert {:error, :not_found} = PresenceServer.get_subscription(subscription_id)
    end
  end

  describe "notify/2 - RFC 6665 Section 4.2.2" do
    test "sends NOTIFY to all watchers of a presentity" do
      # Setup - two watchers
      presentity = "sip:alice@example.com"
      subscribe1 = build_subscribe_message(presentity, "sip:bob@example.com")
      subscribe2 = build_subscribe_message(presentity, "sip:carol@example.com")

      {:ok, _sub_id1, _} = PresenceServer.subscribe(subscribe1, &mock_authorize_active/1)
      {:ok, _sub_id2, _} = PresenceServer.subscribe(subscribe2, &mock_authorize_active/1)

      # Notify all watchers
      presence_state = %{status: :open, note: "Available"}
      result = PresenceServer.notify(presentity, presence_state)

      # Should succeed for both watchers
      assert {:ok, notify_count} = result
      assert notify_count == 2
    end

    test "generates PIDF XML body for NOTIFY" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize_active/1)

      # Get the NOTIFY message that would be sent
      presence_state = %{status: :open, note: "On a call"}
      {:ok, notify_msg} = PresenceServer.build_notify(subscription_id, presence_state)

      # Verify PIDF content
      assert notify_msg.body =~ ~r/<presence.*xmlns="urn:ietf:params:xml:ns:pidf"/
      assert notify_msg.body =~ ~r/entity="#{Regex.escape(presentity)}"/
      assert notify_msg.body =~ ~r/<basic>open<\/basic>/
      assert notify_msg.body =~ ~r/<note>On a call<\/note>/
      assert notify_msg.content_type == "application/pidf+xml"
    end

    test "NOTIFY includes Subscription-State header" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize_active/1)

      {:ok, notify_msg} = PresenceServer.build_notify(subscription_id, %{status: :open})

      assert notify_msg.subscription_state != nil
      assert notify_msg.subscription_state.state == :active
    end

    test "NOTIFY includes Event header matching subscription" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize_active/1)

      {:ok, notify_msg} = PresenceServer.build_notify(subscription_id, %{status: :open})

      # Verify Event header is present (accessing .event will fail if nil)
      assert notify_msg.event.event == "presence"
    end

    test "returns ok with 0 count when no watchers" do
      result = PresenceServer.notify("sip:nobody@example.com", %{status: :closed})

      assert {:ok, 0} = result
    end
  end

  describe "authorize/2 - subscription authorization" do
    test "transitions subscription from pending to active" do
      presentity = "sip:alice@example.com"
      subscribe_msg = build_subscribe_message(presentity, "sip:bob@example.com")

      # Start in pending state
      {:ok, subscription_id, :pending} = PresenceServer.subscribe(subscribe_msg, &mock_authorize/1)

      # Authorize the subscription
      :ok = PresenceServer.authorize(subscription_id)

      {:ok, sub} = PresenceServer.get_subscription(subscription_id)
      assert sub.state == :active
    end
  end

  describe "get_watchers/1" do
    test "returns empty list for unknown presentity" do
      assert [] = PresenceServer.get_watchers("sip:unknown@example.com")
    end

    test "returns watcher information" do
      presentity = "sip:alice@example.com"
      watcher_uri = "sip:bob@example.com"
      subscribe_msg = build_subscribe_message(presentity, watcher_uri)

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize/1)

      [watcher] = PresenceServer.get_watchers(presentity)

      assert watcher.subscription_id == subscription_id
      assert watcher.watcher_uri == watcher_uri
      assert watcher.event_package == "presence"
    end
  end

  describe "subscription expiry" do
    @tag :slow
    test "subscription is removed after expiry" do
      presentity = "sip:alice@example.com"
      # Very short expiry for testing
      subscribe_msg =
        build_subscribe_message(presentity, "sip:bob@example.com")
        |> Map.put(:expires, 1)

      {:ok, subscription_id, _} = PresenceServer.subscribe(subscribe_msg, &mock_authorize_active/1)

      # Should exist initially
      assert {:ok, _} = PresenceServer.get_subscription(subscription_id)

      # Wait for expiry (cleanup runs every second, so wait at least 2 seconds)
      Process.sleep(2500)

      # Should be gone
      assert {:error, :not_found} = PresenceServer.get_subscription(subscription_id)
      assert [] = PresenceServer.get_watchers(presentity)
    end
  end

  # Helper functions

  defp mock_authorize(_msg), do: {:ok, :pending}
  defp mock_authorize_active(_msg), do: {:ok, :active}

  defp build_subscribe_message(presentity, watcher) do
    %Message{
      type: :request,
      method: :subscribe,
      request_uri: presentity,
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-#{:erlang.unique_integer([:positive])}"}
      },
      from: %From{
        display_name: "Watcher",
        uri: watcher,
        parameters: %{"tag" => "from-tag-#{:erlang.unique_integer([:positive])}"}
      },
      to: %To{
        display_name: "Presentity",
        uri: presentity,
        parameters: %{}
      },
      call_id: "subscribe-#{:erlang.unique_integer([:positive])}@example.com",
      cseq: %CSeq{number: 1, method: :subscribe},
      contact: %Contact{
        uri: watcher,
        parameters: %{}
      },
      event: %Event{event: "presence", parameters: %{}},
      expires: 3600,
      other_headers: %{},
      body: ""
    }
  end
end
