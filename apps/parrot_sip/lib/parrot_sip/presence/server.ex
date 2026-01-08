defmodule ParrotSip.Presence.Server do
  @moduledoc """
  Presence Subscription Manager for SIP Event Notification.

  This module handles the framework-level management of presence subscriptions:
  - Receiving SUBSCRIBE requests and creating subscriptions
  - Storing subscriptions by presentity for watcher lookup
  - Sending NOTIFYs to all watchers when presence changes

  ## RFC References

  - RFC 6665: SIP-Specific Event Notification (supersedes RFC 3265)
  - RFC 3856: A Presence Event Package for SIP
  - RFC 3863: Presence Information Data Format (PIDF)

  ## Architecture

  Uses ETS tables for concurrent read access:
  - `:presence_subscriptions` - subscription_id -> subscription data
  - `:presence_watchers` - presentity_uri -> list of watcher info (bag)

  Writes are coordinated through the GenServer to ensure consistency.
  Reads are direct ETS lookups for performance.

  ## Usage

      # Subscribe a watcher to a presentity
      {:ok, subscription_id, state} = PresenceServer.subscribe(subscribe_msg, &my_authorize/1)

      # Notify all watchers of a presence change
      {:ok, notify_count} = PresenceServer.notify("sip:alice@example.com", %{status: :open, note: "Available"})

      # Get all watchers for a presentity
      watchers = PresenceServer.get_watchers("sip:alice@example.com")

  """
  use GenServer

  require Logger

  alias ParrotSip.{Message, Branch}
  alias ParrotSip.Presence.Pidf
  alias ParrotSip.Headers.{Via, From, To, CSeq, Event, SubscriptionState, Contact}

  @subscription_table :presence_subscriptions
  @watcher_table :presence_watchers

  # Watcher info stored in ETS
  defmodule Watcher do
    @moduledoc false
    defstruct [:subscription_id, :watcher_uri, :presentity_uri, :event_package, :dialog_pid]

    @type t :: %__MODULE__{
            subscription_id: String.t(),
            watcher_uri: String.t(),
            presentity_uri: String.t(),
            event_package: String.t(),
            dialog_pid: pid() | nil
          }
  end

  # Subscription data stored in ETS
  defmodule SubscriptionData do
    @moduledoc false
    defstruct [
      :subscription_id,
      :watcher_uri,
      :presentity_uri,
      :event_package,
      :expires,
      :state,
      :dialog_pid,
      :contact,
      :call_id,
      :from_tag,
      :to_tag,
      :cseq,
      :created_at,
      :expires_at
    ]

    @type t :: %__MODULE__{
            subscription_id: String.t(),
            watcher_uri: String.t(),
            presentity_uri: String.t(),
            event_package: String.t(),
            expires: non_neg_integer(),
            state: :pending | :active | :terminated,
            dialog_pid: pid() | nil,
            contact: String.t() | nil,
            call_id: String.t() | nil,
            from_tag: String.t() | nil,
            to_tag: String.t() | nil,
            cseq: non_neg_integer(),
            created_at: integer(),
            expires_at: integer()
          }
  end

  # ============================================================================
  # API
  # ============================================================================

  @doc """
  Starts the Presence Server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Processes a SUBSCRIBE request and creates a subscription.

  The authorize function is called to determine if the subscription should be
  allowed. It should return:
  - `{:ok, :pending}` - Subscription accepted but pending authorization (202)
  - `{:ok, :active}` - Subscription immediately authorized (200)
  - `{:error, reason}` - Subscription rejected

  ## Parameters

  - `message` - The SUBSCRIBE request message
  - `authorize_fn` - Function to authorize the subscription: `(Message.t()) -> {:ok, :pending | :active} | {:error, term()}`

  ## Returns

  - `{:ok, subscription_id, :pending | :active}` - Subscription created
  - `{:error, reason}` - Subscription rejected
  """
  @spec subscribe(Message.t(), (Message.t() -> {:ok, :pending | :active} | {:error, term()})) ::
          {:ok, String.t(), :pending | :active} | {:error, term()}
  def subscribe(message, authorize_fn) do
    GenServer.call(__MODULE__, {:subscribe, message, authorize_fn})
  end

  @doc """
  Removes a subscription (unsubscribe).
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, :not_found}
  def unsubscribe(subscription_id) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id})
  end

  @doc """
  Authorizes a pending subscription, transitioning it to active state.
  """
  @spec authorize(String.t()) :: :ok | {:error, :not_found}
  def authorize(subscription_id) do
    GenServer.call(__MODULE__, {:authorize, subscription_id})
  end

  @doc """
  Sends NOTIFY to all watchers of a presentity.

  ## Parameters

  - `presentity_uri` - The SIP URI of the presentity
  - `presence_state` - Map with `:status` (:open | :closed) and optional `:note`

  ## Returns

  - `{:ok, notify_count}` - Number of watchers notified
  """
  @spec notify(String.t(), map()) :: {:ok, non_neg_integer()}
  def notify(presentity_uri, presence_state) do
    GenServer.call(__MODULE__, {:notify, presentity_uri, presence_state})
  end

  @doc """
  Builds a NOTIFY message for a specific subscription.
  """
  @spec build_notify(String.t(), map()) :: {:ok, Message.t()} | {:error, :not_found}
  def build_notify(subscription_id, presence_state) do
    case get_subscription(subscription_id) do
      {:ok, sub} ->
        notify_msg = do_build_notify(sub, presence_state)
        {:ok, notify_msg}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns all watchers subscribed to a presentity.
  Direct ETS lookup for performance.
  """
  @spec get_watchers(String.t()) :: [Watcher.t()]
  def get_watchers(presentity_uri) do
    case :ets.lookup(@watcher_table, presentity_uri) do
      [] ->
        []

      entries ->
        Enum.map(entries, fn {_presentity, watcher} -> watcher end)
    end
  end

  @doc """
  Returns subscription data by ID.
  Direct ETS lookup for performance.
  """
  @spec get_subscription(String.t()) :: {:ok, SubscriptionData.t()} | {:error, :not_found}
  def get_subscription(subscription_id) do
    case :ets.lookup(@subscription_table, subscription_id) do
      [{^subscription_id, sub}] -> {:ok, sub}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Clears all subscriptions. Used for testing.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS tables if they don't exist
    create_tables()

    # Start expiry cleanup timer
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:subscribe, message, authorize_fn}, _from, state) do
    result = do_subscribe(message, authorize_fn)
    {:reply, result, state}
  end

  def handle_call({:unsubscribe, subscription_id}, _from, state) do
    result = do_unsubscribe(subscription_id)
    {:reply, result, state}
  end

  def handle_call({:authorize, subscription_id}, _from, state) do
    result = do_authorize(subscription_id)
    {:reply, result, state}
  end

  def handle_call({:notify, presentity_uri, presence_state}, _from, state) do
    result = do_notify(presentity_uri, presence_state)
    {:reply, result, state}
  end

  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@subscription_table)
    :ets.delete_all_objects(@watcher_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    cleanup_expired_subscriptions()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_tables do
    # Subscription table: subscription_id -> SubscriptionData
    if :ets.whereis(@subscription_table) == :undefined do
      :ets.new(@subscription_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])
    end

    # Watcher table: presentity_uri -> Watcher (bag for multiple watchers)
    if :ets.whereis(@watcher_table) == :undefined do
      :ets.new(@watcher_table, [
        :named_table,
        :bag,
        :public,
        read_concurrency: true
      ])
    end
  end

  defp schedule_cleanup do
    # Check for expired subscriptions every second
    # This ensures timely cleanup without too much overhead
    Process.send_after(self(), :cleanup_expired, 1_000)
  end

  defp cleanup_expired_subscriptions do
    now = System.system_time(:second)

    # Find and remove expired subscriptions
    expired =
      :ets.foldl(
        fn {sub_id, sub}, acc ->
          if sub.expires_at <= now do
            [sub_id | acc]
          else
            acc
          end
        end,
        [],
        @subscription_table
      )

    # Remove each expired subscription
    Enum.each(expired, fn sub_id ->
      do_unsubscribe(sub_id)
    end)

    if length(expired) > 0 do
      Logger.debug("[Presence.Server] Cleaned up #{length(expired)} expired subscriptions")
    end
  end

  defp do_subscribe(message, authorize_fn) do
    # Call authorization function
    case authorize_fn.(message) do
      {:ok, initial_state} when initial_state in [:pending, :active] ->
        # Create subscription
        subscription_id = generate_subscription_id()
        now = System.system_time(:second)
        expires = message.expires || 3600

        # Extract information from message
        presentity_uri = extract_presentity(message)
        watcher_uri = extract_watcher(message)
        event_package = extract_event_package(message)
        contact = extract_contact(message)
        call_id = message.call_id
        from_tag = extract_from_tag(message)

        sub_data = %SubscriptionData{
          subscription_id: subscription_id,
          watcher_uri: watcher_uri,
          presentity_uri: presentity_uri,
          event_package: event_package,
          expires: expires,
          state: initial_state,
          dialog_pid: nil,
          contact: contact,
          call_id: call_id,
          from_tag: from_tag,
          to_tag: generate_tag(),
          cseq: 1,
          created_at: now,
          expires_at: now + expires
        }

        watcher_info = %Watcher{
          subscription_id: subscription_id,
          watcher_uri: watcher_uri,
          presentity_uri: presentity_uri,
          event_package: event_package,
          dialog_pid: nil
        }

        # Store in ETS
        :ets.insert(@subscription_table, {subscription_id, sub_data})
        :ets.insert(@watcher_table, {presentity_uri, watcher_info})

        Logger.info(
          "[Presence.Server] Created subscription #{subscription_id} for #{watcher_uri} watching #{presentity_uri}"
        )

        {:ok, subscription_id, initial_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_unsubscribe(subscription_id) do
    case :ets.lookup(@subscription_table, subscription_id) do
      [{^subscription_id, sub}] ->
        # Remove from subscription table
        :ets.delete(@subscription_table, subscription_id)

        # Remove from watcher table
        # Find and delete the matching watcher entry
        case :ets.lookup(@watcher_table, sub.presentity_uri) do
          entries ->
            Enum.each(entries, fn {presentity, watcher} ->
              if watcher.subscription_id == subscription_id do
                :ets.delete_object(@watcher_table, {presentity, watcher})
              end
            end)
        end

        Logger.debug("[Presence.Server] Removed subscription #{subscription_id}")
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  defp do_authorize(subscription_id) do
    case :ets.lookup(@subscription_table, subscription_id) do
      [{^subscription_id, sub}] ->
        # Update state to active
        updated_sub = %{sub | state: :active}
        :ets.insert(@subscription_table, {subscription_id, updated_sub})
        Logger.debug("[Presence.Server] Authorized subscription #{subscription_id}")
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  defp do_notify(presentity_uri, presence_state) do
    watchers = get_watchers(presentity_uri)

    # Send NOTIFY to each active watcher
    notify_count =
      Enum.reduce(watchers, 0, fn watcher, count ->
        case get_subscription(watcher.subscription_id) do
          {:ok, sub} when sub.state == :active ->
            _notify_msg = do_build_notify(sub, presence_state)
            # In production, this would send via transport
            # For now, we just log and count
            Logger.debug(
              "[Presence.Server] Would send NOTIFY to #{watcher.watcher_uri} for #{presentity_uri}"
            )

            # Increment CSeq for next NOTIFY
            updated_sub = %{sub | cseq: sub.cseq + 1}
            :ets.insert(@subscription_table, {sub.subscription_id, updated_sub})
            count + 1

          {:ok, _sub} ->
            # Not active (pending or terminated), don't notify
            count

          {:error, :not_found} ->
            count
        end
      end)

    {:ok, notify_count}
  end

  defp do_build_notify(sub, presence_state) do
    # Build PIDF body
    pidf_body = Pidf.build(sub.presentity_uri, presence_state)

    # Build Subscription-State header
    subscription_state =
      case sub.state do
        :active ->
          SubscriptionState.set_expires(to_string(sub.expires), SubscriptionState.new(:active))

        :pending ->
          SubscriptionState.new(:pending)

        :terminated ->
          SubscriptionState.set_reason("timeout", SubscriptionState.new(:terminated))
      end

    %Message{
      type: :request,
      method: :notify,
      request_uri: sub.watcher_uri,
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => Branch.generate()}
      },
      from: %From{
        display_name: nil,
        uri: sub.presentity_uri,
        parameters: %{"tag" => sub.to_tag}
      },
      to: %To{
        display_name: nil,
        uri: sub.watcher_uri,
        parameters: %{"tag" => sub.from_tag}
      },
      call_id: sub.call_id,
      cseq: %CSeq{number: sub.cseq, method: :notify},
      contact: %Contact{uri: sub.presentity_uri, parameters: %{}},
      event: %Event{event: sub.event_package, parameters: %{}},
      subscription_state: subscription_state,
      content_type: Pidf.content_type(),
      content_length: byte_size(pidf_body),
      other_headers: %{},
      body: pidf_body
    }
  end

  defp generate_subscription_id do
    "sub-#{:erlang.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
  end

  defp generate_tag do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp extract_presentity(message) do
    # Presentity is the To URI (who is being watched)
    case message.to do
      %To{uri: uri} when is_binary(uri) -> uri
      %{uri: uri} when is_binary(uri) -> uri
      _ -> message.request_uri
    end
  end

  defp extract_watcher(message) do
    # Watcher is the From URI (who is watching)
    case message.from do
      %From{uri: uri} when is_binary(uri) -> uri
      %{uri: uri} when is_binary(uri) -> uri
      _ -> nil
    end
  end

  defp extract_event_package(message) do
    case message.event do
      %Event{event: event} -> event
      _ -> "presence"
    end
  end

  defp extract_contact(message) do
    case message.contact do
      %Contact{uri: uri} when is_binary(uri) -> uri
      [%Contact{uri: uri} | _] when is_binary(uri) -> uri
      uri when is_binary(uri) -> uri
      _ -> nil
    end
  end

  defp extract_from_tag(message) do
    case message.from do
      %From{parameters: %{"tag" => tag}} -> tag
      _ -> nil
    end
  end
end
