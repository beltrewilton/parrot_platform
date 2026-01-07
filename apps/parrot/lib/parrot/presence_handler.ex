defmodule Parrot.PresenceHandler do
  @moduledoc """
  Behaviour for handling SIP presence (SUBSCRIBE/NOTIFY/PUBLISH) in Parrot VoIP applications.

  The PresenceHandler provides callbacks for presence management. The framework
  handles the SIP mechanics (SUBSCRIBE/NOTIFY/PUBLISH message handling), while
  your implementation provides authorization, storage, and presence state logic.

  ## Usage

  Use `use Parrot.PresenceHandler` in your module to get default implementations
  of all callbacks:

      defmodule MyApp.PresenceHandler do
        use Parrot.PresenceHandler

        def authorize_subscription(watcher, presentity) do
          if MyDB.can_watch?(watcher, presentity), do: :allow, else: :deny
        end

        def get_presence(presentity) do
          case MyDB.get_user_state(presentity) do
            :available -> %{status: :open, note: "Available"}
            :busy -> %{status: :closed, note: "On a call"}
            :offline -> %{status: :closed, note: "Offline"}
          end
        end
      end

  ## Callbacks

  ### `authorize_subscription/2`

  Called when a SUBSCRIBE request is received. Return `:allow`, `:deny`, or
  `:pending` (for approval flows).

  ### `store_subscription/1`

  Called after authorization to persist the subscription. Receives a map with
  subscription details like watcher, presentity, dialog_id, and expires.

  ### `get_subscriptions/1`

  Called to get all watchers for a presentity. Used when sending NOTIFY messages
  to all subscribers.

  ### `get_presence/1`

  Called to get the current presence state for a presentity. Returns a map with
  `:status` (`:open` or `:closed`) and `:note` (human-readable description).

  ### `handle_publish/2`

  Called when a user publishes their presence state via PUBLISH request.

  ## Triggering Presence Updates

  Use `Parrot.Presence.notify/2` to trigger presence updates from anywhere in
  your application:

      # In a call handler
      def handle_bridge_complete(:answered, call) do
        Parrot.Presence.notify(call.assigns.extension, %{status: :busy})
        {:noreply, call}
      end

      def handle_hangup(call) do
        Parrot.Presence.notify(call.assigns.extension, %{status: :available})
        {:noreply, call}
      end

  """

  @doc """
  Called when a SUBSCRIBE request is received to authorize the subscription.

  ## Arguments

  - `watcher` - The SIP URI of the entity wanting to subscribe
  - `presentity` - The SIP URI of the entity being watched

  ## Return Values

  - `:allow` - Accept the subscription
  - `:deny` - Reject the subscription
  - `:pending` - Hold for approval (triggers approval flow)

  ## Example

      def authorize_subscription(watcher, presentity) do
        if MyDB.can_watch?(watcher, presentity), do: :allow, else: :deny
      end
  """
  @callback authorize_subscription(watcher :: String.t(), presentity :: String.t()) ::
              :allow | :deny | :pending

  @doc """
  Called to store a subscription after authorization.

  ## Arguments

  - `subscription` - A map containing:
    - `:watcher` - The SIP URI of the subscriber
    - `:presentity` - The SIP URI being watched
    - `:dialog_id` - The dialog ID for this subscription
    - `:expires` - Expiration time in seconds

  ## Return Values

  - `:ok` - Subscription stored successfully
  - `{:error, reason}` - Storage failed

  ## Example

      def store_subscription(subscription) do
        MyDB.save_subscription(subscription)
        :ok
      end
  """
  @callback store_subscription(subscription :: map()) :: :ok | {:error, term()}

  @doc """
  Called to get all watchers for a presentity.

  ## Arguments

  - `presentity` - The SIP URI of the entity whose watchers we want

  ## Return Values

  Returns a list of subscription maps, each containing at least:
  - `:watcher` - The SIP URI of the subscriber
  - `:dialog_id` - The dialog ID for sending NOTIFY

  ## Example

      def get_subscriptions(presentity) do
        MyDB.get_watchers(presentity)
      end
  """
  @callback get_subscriptions(presentity :: String.t()) :: [map()]

  @doc """
  Called to get the current presence state for a presentity.

  ## Arguments

  - `presentity` - The SIP URI of the entity whose presence we want

  ## Return Values

  Returns a map with:
  - `:status` - Either `:open` (available) or `:closed` (unavailable)
  - `:note` - Human-readable description (e.g., "Available", "On a call")

  ## Example

      def get_presence(presentity) do
        case MyDB.get_user_state(presentity) do
          :available -> %{status: :open, note: "Available"}
          :busy -> %{status: :closed, note: "On a call"}
          :offline -> %{status: :closed, note: "Offline"}
        end
      end
  """
  @callback get_presence(presentity :: String.t()) :: %{status: :open | :closed, note: String.t()}

  @doc """
  Called when a user publishes their presence state.

  ## Arguments

  - `presentity` - The SIP URI of the entity publishing their state
  - `presence_state` - A map with presence data (typically contains `:status` and optionally `:note`)

  ## Return Values

  - `:ok` - Presence updated successfully
  - `{:error, reason}` - Update failed

  ## Example

      def handle_publish(presentity, presence_state) do
        MyDB.set_user_state(presentity, presence_state)
        :ok
      end
  """
  @callback handle_publish(presentity :: String.t(), presence_state :: map()) ::
              :ok | {:error, term()}

  @doc """
  Provides default implementations for all callbacks.

  When you `use Parrot.PresenceHandler`, you get:

  1. Default implementations of all callbacks
  2. The `@behaviour Parrot.PresenceHandler` annotation

  Override any callback by defining it in your module.

  ## Default Behaviors

  - `authorize_subscription/2` - Returns `:allow` for all subscriptions
  - `store_subscription/1` - Returns `:ok` (no-op)
  - `get_subscriptions/1` - Returns `[]` (empty list)
  - `get_presence/1` - Returns `%{status: :closed, note: "Unknown"}`
  - `handle_publish/2` - Returns `:ok` (no-op)
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.PresenceHandler

      @impl Parrot.PresenceHandler
      def authorize_subscription(_watcher, _presentity) do
        :allow
      end

      @impl Parrot.PresenceHandler
      def store_subscription(_subscription) do
        :ok
      end

      @impl Parrot.PresenceHandler
      def get_subscriptions(_presentity) do
        []
      end

      @impl Parrot.PresenceHandler
      def get_presence(_presentity) do
        %{status: :closed, note: "Unknown"}
      end

      @impl Parrot.PresenceHandler
      def handle_publish(_presentity, _presence_state) do
        :ok
      end

      defoverridable authorize_subscription: 2,
                     store_subscription: 1,
                     get_subscriptions: 1,
                     get_presence: 1,
                     handle_publish: 2
    end
  end
end
