defmodule Parrot.Examples.MiniPBX.PresenceTest do
  @moduledoc """
  Tests for the Mini PBX Presence handler.

  Tests presence functionality:
  - Subscription authorization
  - Presence state storage and retrieval
  - Subscription management
  - Presence publishing
  """
  use ExUnit.Case, async: false

  alias Parrot.Examples.MiniPBX.{Presence, Storage}

  # Start storage once for all tests
  setup_all do
    :mnesia.start()

    case Storage.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Storage.clear_all()
    :ok
  end

  describe "authorize_subscription/2" do
    test "allows internal subscriptions" do
      watcher = "sip:1001@pbx.local"
      presentity = "sip:1002@pbx.local"

      assert :allow = Presence.authorize_subscription(watcher, presentity)
    end
  end

  describe "store_subscription/1" do
    test "stores subscription in Mnesia" do
      subscription = %{
        watcher: "sip:1001@pbx.local",
        presentity: "sip:1002@pbx.local",
        dialog_id: "dialog-123",
        expires: 3600
      }

      assert :ok = Presence.store_subscription(subscription)

      # Verify it was stored
      subscriptions = Presence.get_subscriptions("sip:1002@pbx.local")
      assert length(subscriptions) == 1
      assert hd(subscriptions).watcher == "sip:1001@pbx.local"
    end
  end

  describe "get_subscriptions/1" do
    test "returns empty list for unknown presentity" do
      subscriptions = Presence.get_subscriptions("sip:unknown@pbx.local")
      assert subscriptions == []
    end

    test "returns all watchers for a presentity" do
      # Add multiple subscriptions
      Presence.store_subscription(%{
        watcher: "sip:1001@pbx.local",
        presentity: "sip:1002@pbx.local",
        dialog_id: "dialog-1",
        expires: 3600
      })

      Presence.store_subscription(%{
        watcher: "sip:1003@pbx.local",
        presentity: "sip:1002@pbx.local",
        dialog_id: "dialog-2",
        expires: 3600
      })

      subscriptions = Presence.get_subscriptions("sip:1002@pbx.local")
      assert length(subscriptions) == 2
    end
  end

  describe "get_presence/1" do
    test "returns offline for unknown presentity" do
      presence = Presence.get_presence("sip:unknown@pbx.local")

      assert presence.status == :closed
      assert presence.note =~ ~r/offline/i
    end

    test "returns available status" do
      presentity = "sip:1001@pbx.local"
      :ok = Presence.handle_publish(presentity, %{status: :available})

      presence = Presence.get_presence(presentity)

      assert presence.status == :open
      assert presence.note =~ ~r/available/i
    end

    test "returns busy status" do
      presentity = "sip:1001@pbx.local"
      :ok = Presence.handle_publish(presentity, %{status: :busy})

      presence = Presence.get_presence(presentity)

      assert presence.status == :closed
      assert presence.note =~ ~r/busy/i or presence.note =~ ~r/call/i
    end

    test "returns dnd status" do
      presentity = "sip:1001@pbx.local"
      :ok = Presence.handle_publish(presentity, %{status: :dnd})

      presence = Presence.get_presence(presentity)

      assert presence.status == :closed
      assert presence.note =~ ~r/disturb/i or presence.note =~ ~r/dnd/i
    end
  end

  describe "handle_publish/2" do
    test "stores presence state" do
      presentity = "sip:1001@pbx.local"

      assert :ok = Presence.handle_publish(presentity, %{status: :available})

      # Verify it was stored
      {:ok, status} = Storage.get_presence_state(presentity)
      assert status == :available
    end

    test "updates existing presence state" do
      presentity = "sip:1001@pbx.local"

      :ok = Presence.handle_publish(presentity, %{status: :available})
      :ok = Presence.handle_publish(presentity, %{status: :busy})

      {:ok, status} = Storage.get_presence_state(presentity)
      assert status == :busy
    end
  end
end
