defmodule Parrot.PresenceHandlerTest do
  use ExUnit.Case, async: true

  describe "behaviour definition" do
    test "defines authorize_subscription/2 callback" do
      callbacks = Parrot.PresenceHandler.behaviour_info(:callbacks)
      assert {:authorize_subscription, 2} in callbacks
    end

    test "defines store_subscription/1 callback" do
      callbacks = Parrot.PresenceHandler.behaviour_info(:callbacks)
      assert {:store_subscription, 1} in callbacks
    end

    test "defines get_subscriptions/1 callback" do
      callbacks = Parrot.PresenceHandler.behaviour_info(:callbacks)
      assert {:get_subscriptions, 1} in callbacks
    end

    test "defines get_presence/1 callback" do
      callbacks = Parrot.PresenceHandler.behaviour_info(:callbacks)
      assert {:get_presence, 1} in callbacks
    end

    test "defines handle_publish/2 callback" do
      callbacks = Parrot.PresenceHandler.behaviour_info(:callbacks)
      assert {:handle_publish, 2} in callbacks
    end

    test "defines all 5 expected callbacks" do
      callbacks = Parrot.PresenceHandler.behaviour_info(:callbacks)
      assert length(callbacks) == 5
    end
  end

  describe "authorize_subscription/2" do
    defmodule AuthorizeAllowHandler do
      use Parrot.PresenceHandler

      def authorize_subscription(_watcher, _presentity) do
        :allow
      end
    end

    defmodule AuthorizeDenyHandler do
      use Parrot.PresenceHandler

      def authorize_subscription(_watcher, _presentity) do
        :deny
      end
    end

    defmodule AuthorizePendingHandler do
      use Parrot.PresenceHandler

      def authorize_subscription(_watcher, _presentity) do
        :pending
      end
    end

    defmodule AuthorizeConditionalHandler do
      use Parrot.PresenceHandler

      def authorize_subscription(watcher, presentity) do
        # Simulate checking if watcher can watch presentity
        if watcher == "sip:allowed@example.com" and presentity == "sip:alice@example.com" do
          :allow
        else
          :deny
        end
      end
    end

    test "returns :allow when subscription is authorized" do
      assert :allow ==
               AuthorizeAllowHandler.authorize_subscription(
                 "sip:bob@example.com",
                 "sip:alice@example.com"
               )
    end

    test "returns :deny when subscription is not authorized" do
      assert :deny ==
               AuthorizeDenyHandler.authorize_subscription(
                 "sip:bob@example.com",
                 "sip:alice@example.com"
               )
    end

    test "returns :pending for approval flows" do
      assert :pending ==
               AuthorizePendingHandler.authorize_subscription(
                 "sip:bob@example.com",
                 "sip:alice@example.com"
               )
    end

    test "can implement conditional authorization logic" do
      # Allowed watcher
      assert :allow ==
               AuthorizeConditionalHandler.authorize_subscription(
                 "sip:allowed@example.com",
                 "sip:alice@example.com"
               )

      # Not allowed watcher
      assert :deny ==
               AuthorizeConditionalHandler.authorize_subscription(
                 "sip:bob@example.com",
                 "sip:alice@example.com"
               )
    end
  end

  describe "store_subscription/1" do
    defmodule StoreHandler do
      use Parrot.PresenceHandler

      def store_subscription(subscription) do
        # In a real implementation, this would persist to a database
        send(self(), {:stored, subscription})
        :ok
      end
    end

    test "stores subscription and returns :ok" do
      subscription = %{
        watcher: "sip:bob@example.com",
        presentity: "sip:alice@example.com",
        expires: 3600,
        dialog_id: "dialog-123"
      }

      assert :ok == StoreHandler.store_subscription(subscription)
      assert_receive {:stored, ^subscription}
    end

    test "subscription contains expected fields" do
      subscription = %{
        watcher: "sip:bob@example.com",
        presentity: "sip:alice@example.com",
        expires: 3600,
        dialog_id: "dialog-123"
      }

      :ok = StoreHandler.store_subscription(subscription)
      assert_receive {:stored, stored}

      assert stored.watcher == "sip:bob@example.com"
      assert stored.presentity == "sip:alice@example.com"
      assert stored.expires == 3600
      assert stored.dialog_id == "dialog-123"
    end
  end

  describe "get_subscriptions/1" do
    defmodule GetSubscriptionsHandler do
      use Parrot.PresenceHandler

      def get_subscriptions(presentity) do
        # Simulate returning watchers for a presentity
        case presentity do
          "sip:alice@example.com" ->
            [
              %{watcher: "sip:bob@example.com", dialog_id: "dialog-1", expires: 3600},
              %{watcher: "sip:carol@example.com", dialog_id: "dialog-2", expires: 1800}
            ]

          "sip:nobody@example.com" ->
            []

          _ ->
            []
        end
      end
    end

    test "returns list of watchers for a presentity" do
      watchers = GetSubscriptionsHandler.get_subscriptions("sip:alice@example.com")

      assert length(watchers) == 2
      assert Enum.any?(watchers, &(&1.watcher == "sip:bob@example.com"))
      assert Enum.any?(watchers, &(&1.watcher == "sip:carol@example.com"))
    end

    test "returns empty list when no watchers exist" do
      watchers = GetSubscriptionsHandler.get_subscriptions("sip:nobody@example.com")
      assert watchers == []
    end

    test "each watcher has expected fields" do
      [watcher | _] = GetSubscriptionsHandler.get_subscriptions("sip:alice@example.com")

      assert Map.has_key?(watcher, :watcher)
      assert Map.has_key?(watcher, :dialog_id)
      assert Map.has_key?(watcher, :expires)
    end
  end

  describe "get_presence/1" do
    defmodule GetPresenceHandler do
      use Parrot.PresenceHandler

      def get_presence(presentity) do
        case presentity do
          "sip:available@example.com" ->
            %{status: :open, note: "Available"}

          "sip:busy@example.com" ->
            %{status: :closed, note: "On a call"}

          "sip:offline@example.com" ->
            %{status: :closed, note: "Offline"}

          _ ->
            %{status: :closed, note: "Unknown"}
        end
      end
    end

    test "returns presence with :open status for available user" do
      presence = GetPresenceHandler.get_presence("sip:available@example.com")

      assert presence.status == :open
      assert presence.note == "Available"
    end

    test "returns presence with :closed status for busy user" do
      presence = GetPresenceHandler.get_presence("sip:busy@example.com")

      assert presence.status == :closed
      assert presence.note == "On a call"
    end

    test "returns presence with :closed status for offline user" do
      presence = GetPresenceHandler.get_presence("sip:offline@example.com")

      assert presence.status == :closed
      assert presence.note == "Offline"
    end

    test "presence map contains status and note keys" do
      presence = GetPresenceHandler.get_presence("sip:available@example.com")

      assert Map.has_key?(presence, :status)
      assert Map.has_key?(presence, :note)
    end
  end

  describe "handle_publish/2" do
    defmodule PublishHandler do
      use Parrot.PresenceHandler

      def handle_publish(presentity, presence_state) do
        # In a real implementation, this would update the presence in a database
        send(self(), {:published, presentity, presence_state})
        :ok
      end
    end

    test "handles publish and returns :ok" do
      presence_state = %{status: :open, note: "Available"}

      assert :ok == PublishHandler.handle_publish("sip:alice@example.com", presence_state)
      assert_receive {:published, "sip:alice@example.com", ^presence_state}
    end

    test "handles various presence states" do
      # Available
      assert :ok ==
               PublishHandler.handle_publish("sip:alice@example.com", %{
                 status: :open,
                 note: "Available"
               })

      # Busy
      assert :ok ==
               PublishHandler.handle_publish("sip:alice@example.com", %{
                 status: :closed,
                 note: "On a call"
               })

      # Away
      assert :ok ==
               PublishHandler.handle_publish("sip:alice@example.com", %{
                 status: :closed,
                 note: "Away"
               })
    end
  end

  describe "use Parrot.PresenceHandler" do
    defmodule MinimalHandler do
      use Parrot.PresenceHandler
    end

    test "provides default authorize_subscription/2 implementation" do
      # Default should allow all subscriptions
      assert :allow ==
               MinimalHandler.authorize_subscription(
                 "sip:bob@example.com",
                 "sip:alice@example.com"
               )
    end

    test "provides default store_subscription/1 implementation" do
      subscription = %{watcher: "sip:bob@example.com", presentity: "sip:alice@example.com"}
      assert :ok == MinimalHandler.store_subscription(subscription)
    end

    test "provides default get_subscriptions/1 implementation" do
      # Default should return empty list
      assert [] == MinimalHandler.get_subscriptions("sip:alice@example.com")
    end

    test "provides default get_presence/1 implementation" do
      # Default should return unknown/closed status
      presence = MinimalHandler.get_presence("sip:alice@example.com")
      assert presence.status == :closed
      assert presence.note == "Unknown"
    end

    test "provides default handle_publish/2 implementation" do
      assert :ok == MinimalHandler.handle_publish("sip:alice@example.com", %{status: :open})
    end
  end

  describe "overriding callbacks" do
    defmodule CustomHandler do
      use Parrot.PresenceHandler

      # In-memory storage for testing
      def init_state do
        Agent.start_link(fn -> %{subscriptions: [], presence: %{}} end, name: __MODULE__)
      end

      def authorize_subscription(watcher, presentity) do
        # Only allow users from same domain to watch each other
        watcher_domain = get_domain(watcher)
        presentity_domain = get_domain(presentity)

        if watcher_domain == presentity_domain, do: :allow, else: :deny
      end

      def store_subscription(subscription) do
        Agent.update(__MODULE__, fn state ->
          %{state | subscriptions: [subscription | state.subscriptions]}
        end)

        :ok
      end

      def get_subscriptions(presentity) do
        Agent.get(__MODULE__, fn state ->
          Enum.filter(state.subscriptions, &(&1.presentity == presentity))
        end)
      end

      def get_presence(presentity) do
        Agent.get(__MODULE__, fn state ->
          Map.get(state.presence, presentity, %{status: :closed, note: "Offline"})
        end)
      end

      def handle_publish(presentity, presence_state) do
        Agent.update(__MODULE__, fn state ->
          %{state | presence: Map.put(state.presence, presentity, presence_state)}
        end)

        :ok
      end

      defp get_domain(uri) do
        case String.split(uri, "@") do
          [_, domain] -> domain
          _ -> ""
        end
      end
    end

    setup do
      {:ok, _pid} = CustomHandler.init_state()
      :ok
    end

    test "custom authorize_subscription allows same domain" do
      assert :allow ==
               CustomHandler.authorize_subscription(
                 "sip:bob@example.com",
                 "sip:alice@example.com"
               )
    end

    test "custom authorize_subscription denies different domains" do
      assert :deny ==
               CustomHandler.authorize_subscription(
                 "sip:bob@other.com",
                 "sip:alice@example.com"
               )
    end

    test "custom store_subscription persists subscriptions" do
      subscription = %{
        watcher: "sip:bob@example.com",
        presentity: "sip:alice@example.com",
        expires: 3600
      }

      assert :ok == CustomHandler.store_subscription(subscription)

      # Verify it was stored
      subscriptions = CustomHandler.get_subscriptions("sip:alice@example.com")
      assert length(subscriptions) == 1
      assert hd(subscriptions).watcher == "sip:bob@example.com"
    end

    test "custom get_presence returns stored presence" do
      # Initially offline
      assert %{status: :closed, note: "Offline"} ==
               CustomHandler.get_presence("sip:alice@example.com")

      # Publish available status
      CustomHandler.handle_publish("sip:alice@example.com", %{status: :open, note: "Available"})

      # Now should be available
      assert %{status: :open, note: "Available"} ==
               CustomHandler.get_presence("sip:alice@example.com")
    end

    test "custom handle_publish updates presence state" do
      # Update presence
      assert :ok ==
               CustomHandler.handle_publish("sip:alice@example.com", %{
                 status: :closed,
                 note: "On a call"
               })

      # Verify it was updated
      presence = CustomHandler.get_presence("sip:alice@example.com")
      assert presence.status == :closed
      assert presence.note == "On a call"
    end
  end

  describe "integration scenario" do
    defmodule ScenarioHandler do
      use Parrot.PresenceHandler

      def init_state do
        Agent.start_link(fn -> %{subscriptions: [], presence: %{}} end, name: __MODULE__)
      end

      def authorize_subscription(_watcher, _presentity), do: :allow

      def store_subscription(subscription) do
        Agent.update(__MODULE__, fn state ->
          %{state | subscriptions: [subscription | state.subscriptions]}
        end)

        :ok
      end

      def get_subscriptions(presentity) do
        Agent.get(__MODULE__, fn state ->
          Enum.filter(state.subscriptions, &(&1.presentity == presentity))
        end)
      end

      def get_presence(presentity) do
        Agent.get(__MODULE__, fn state ->
          Map.get(state.presence, presentity, %{status: :closed, note: "Unknown"})
        end)
      end

      def handle_publish(presentity, presence_state) do
        Agent.update(__MODULE__, fn state ->
          %{state | presence: Map.put(state.presence, presentity, presence_state)}
        end)

        :ok
      end
    end

    setup do
      {:ok, _pid} = ScenarioHandler.init_state()
      :ok
    end

    test "full presence flow: subscribe -> publish -> notify watchers" do
      presentity = "sip:alice@example.com"
      watcher = "sip:bob@example.com"

      # 1. Watcher subscribes to presentity
      assert :allow == ScenarioHandler.authorize_subscription(watcher, presentity)

      subscription = %{
        watcher: watcher,
        presentity: presentity,
        dialog_id: "dialog-123",
        expires: 3600
      }

      assert :ok == ScenarioHandler.store_subscription(subscription)

      # 2. Presentity publishes their presence
      assert :ok ==
               ScenarioHandler.handle_publish(presentity, %{status: :open, note: "Available"})

      # 3. Get watchers to notify
      watchers = ScenarioHandler.get_subscriptions(presentity)
      assert length(watchers) == 1
      assert hd(watchers).watcher == watcher

      # 4. Get presence to send in NOTIFY
      presence = ScenarioHandler.get_presence(presentity)
      assert presence.status == :open
      assert presence.note == "Available"
    end
  end
end
