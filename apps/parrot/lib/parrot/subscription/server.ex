defmodule Parrot.Subscription.Server do
  @moduledoc """
  GenServer that manages the lifecycle of a single presence subscription.

  The Subscription.Server is responsible for:
  - Processing SUBSCRIBE requests in a separate process (not inline in transaction)
  - Invoking handler's authorization callback
  - Sending SIP responses (200 OK, 403 Forbidden, 202 Accepted)
  - Triggering initial NOTIFY after response is sent
  - Managing subscription state and expiration

  ## Architecture (RFC 6665 Compliance)

  The critical design decision is running subscription processing in a separate
  process from the SIP transaction state machine. This ensures proper response
  ordering per RFC 6665 Section 4.2.2:

  > "The notifier MUST create a subscription and send a NOTIFY request to
  > inform the subscriber of the current resource state."

  The sequence MUST be:
  1. Send 200 OK response
  2. THEN send initial NOTIFY

  By using `{:continue, :send_response_and_notify}` in init, we:
  1. Return from start_link immediately (unblocking the transaction)
  2. Process response and NOTIFY in handle_continue (synchronous from our perspective)

  ## Usage

  The server is typically started by Bridge.Handler when a SUBSCRIBE is received:

      {:ok, pid} = Parrot.Subscription.Server.start_link(
        handler: MyApp.PresenceHandler,
        subscribe_data: %{
          watcher: "sip:alice@example.com",
          presentity: "sip:bob@example.com",
          expires: 3600,
          call_id: "abc123@host"
        },
        context: %{
          uas: uas,
          sip_msg: sip_msg,
          response_fn: fn response, uas -> ... end
        }
      )

  ## Registry

  Each Subscription.Server registers itself in `Parrot.Registry` with the key
  `{:subscription, dialog_id}` for lookup by other components.
  """

  use GenServer
  require Logger

  alias ParrotSip.Message

  defstruct [
    :subscription,
    :handler,
    :context,
    :authorization_result
  ]

  # Subscription struct to hold subscription data
  defmodule Subscription do
    @moduledoc false
    defstruct [
      :id,
      :watcher,
      :presentity,
      :expires,
      :dialog_id,
      :call_id,
      :state
    ]
  end

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a Subscription.Server process.

  ## Options

  * `:handler` - (required) Module implementing `Parrot.PresenceHandler`
  * `:subscribe_data` - (required) Map with subscription data:
    * `:watcher` - The SIP URI of the subscriber
    * `:presentity` - The SIP URI being watched
    * `:expires` - Expiration time in seconds
    * `:call_id` - The Call-ID from the SUBSCRIBE
  * `:context` - (required) Map with SIP context:
    * `:uas` - The UAS transaction reference
    * `:sip_msg` - The original SUBSCRIBE message
    * `:response_fn` - Function to send responses (for testing)

  ## Examples

      {:ok, pid} = Parrot.Subscription.Server.start_link(
        handler: MyApp.PresenceHandler,
        subscribe_data: %{watcher: "sip:a@b.com", presentity: "sip:c@d.com", expires: 3600}
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    handler = Keyword.fetch!(opts, :handler)
    subscribe_data = Keyword.fetch!(opts, :subscribe_data)
    context = Keyword.fetch!(opts, :context)

    GenServer.start_link(__MODULE__, {handler, subscribe_data, context})
  end

  @doc """
  Gets the current subscription struct.

  ## Examples

      subscription = Parrot.Subscription.Server.get_subscription(pid)
      subscription.state
      #=> :active
  """
  @spec get_subscription(GenServer.server()) :: Subscription.t()
  def get_subscription(server) do
    GenServer.call(server, :get_subscription)
  end

  @doc """
  Dispatches an event to the subscription server.

  ## Events

  * `{:refresh, new_expires}` - Extend subscription duration
  * `:terminate` - End the subscription

  ## Examples

      :ok = Parrot.Subscription.Server.dispatch(pid, {:refresh, 7200})
      :ok = Parrot.Subscription.Server.dispatch(pid, :terminate)
  """
  @spec dispatch(GenServer.server(), term()) :: :ok
  def dispatch(server, event) do
    GenServer.call(server, {:dispatch, event})
  end

  @doc """
  Looks up a Subscription.Server process by its dialog_id.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` if no process
  is registered for the given dialog_id.

  ## Examples

      {:ok, pid} = Parrot.Subscription.Server.lookup_by_dialog_id(dialog_id)
      {:error, :not_found} = Parrot.Subscription.Server.lookup_by_dialog_id("unknown")
  """
  @spec lookup_by_dialog_id(term()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_by_dialog_id(dialog_id) do
    if registry_available?() do
      case Registry.lookup(Parrot.Registry, {:subscription, dialog_id}) do
        [{pid, _}] -> {:ok, pid}
        [] -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  # ===========================================================================
  # Registry Helpers
  # ===========================================================================

  defp registry_available? do
    case Process.whereis(Parrot.Registry) do
      nil -> false
      _pid -> true
    end
  end

  defp register_in_registry(nil), do: :ok

  defp register_in_registry(dialog_id) do
    if registry_available?() do
      try do
        Registry.register(Parrot.Registry, {:subscription, dialog_id}, nil)
      rescue
        ArgumentError -> :ok
        e in ErlangError ->
          if e.original == :noproc, do: :ok, else: reraise(e, __STACKTRACE__)
      catch
        :exit, {:noproc, _} -> :ok
        :error, :noproc -> :ok
      end
    end

    :ok
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init({handler, subscribe_data, context}) do
    # Extract subscribe data
    watcher = Map.fetch!(subscribe_data, :watcher)
    presentity = Map.fetch!(subscribe_data, :presentity)
    expires = Map.get(subscribe_data, :expires, 3600)
    call_id = Map.get(subscribe_data, :call_id)

    # Generate unique subscription ID
    subscription_id = generate_subscription_id()

    Logger.debug(
      "Subscription.Server starting: watcher=#{watcher}, presentity=#{presentity}, " <>
        "expires=#{expires}, id=#{subscription_id}"
    )

    # Store test PID for handler callbacks (if in test environment)
    if test_pid = Map.get(context, :test_pid) do
      Process.put(:test_pid, test_pid)
    end

    # Invoke handler's authorize_subscription callback
    # This happens synchronously during init, but response/NOTIFY are deferred
    authorization_result = handler.authorize_subscription(watcher, presentity)

    Logger.debug("Subscription.Server authorization result: #{inspect(authorization_result)}")

    # Build initial subscription struct
    subscription = %Subscription{
      id: subscription_id,
      watcher: watcher,
      presentity: presentity,
      expires: expires,
      call_id: call_id,
      state: authorization_state(authorization_result)
    }

    state = %__MODULE__{
      subscription: subscription,
      handler: handler,
      context: context,
      authorization_result: authorization_result
    }

    # Defer response sending and NOTIFY triggering to handle_continue
    # This ensures start_link returns before we try to send response/NOTIFY,
    # which unblocks the transaction state machine
    {:ok, state, {:continue, :send_response_and_notify}}
  end

  @impl true
  def handle_continue(:send_response_and_notify, state) do
    %{
      subscription: subscription,
      handler: handler,
      context: context,
      authorization_result: authorization_result
    } = state

    # Get SIP message and response function from context
    sip_msg = Map.fetch!(context, :sip_msg)
    response_fn = Map.get(context, :response_fn)
    uas = Map.get(context, :uas)

    updated_subscription =
      case authorization_result do
        :allow ->
          # RFC 6665 Section 4.2.1.1: Authorized subscription
          handle_allowed_subscription(subscription, handler, sip_msg, response_fn, uas, context)

        :deny ->
          # RFC 6665 Section 4.2.1.2: Denied subscription
          handle_denied_subscription(sip_msg, response_fn, uas)
          subscription

        :pending ->
          # RFC 6665 Section 4.2.1.3: Pending subscription
          handle_pending_subscription(subscription, handler, sip_msg, response_fn, uas, context)
      end

    # Register in Parrot.Registry after dialog_id is set
    register_in_registry(updated_subscription.dialog_id)

    {:noreply, %{state | subscription: updated_subscription}}
  end

  @impl true
  def handle_call(:get_subscription, _from, state) do
    {:reply, state.subscription, state}
  end

  def handle_call({:dispatch, {:refresh, new_expires}}, _from, state) do
    subscription = %{state.subscription | expires: new_expires}
    {:reply, :ok, %{state | subscription: subscription}}
  end

  def handle_call({:dispatch, :terminate}, _from, state) do
    subscription = %{state.subscription | state: :terminated}
    {:reply, :ok, %{state | subscription: subscription}}
  end

  def handle_call({:dispatch, _event}, _from, state) do
    # Unknown event - just return ok
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Subscription.Server received unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp handle_allowed_subscription(subscription, handler, sip_msg, response_fn, uas, context) do
    # Step 1: Build 200 OK response with Expires header
    response =
      Message.reply(sip_msg, 200, "OK")
      |> Map.put(:expires, subscription.expires)

    # Step 2: Send response SYNCHRONOUSLY (this is the critical fix)
    # Response must be fully sent before we trigger NOTIFY
    {:ok, final_response} = send_response(response, response_fn, uas)

    # Extract dialog_id from the response (includes To tag)
    dialog_id = Message.dialog_id(final_response)

    Logger.debug("Subscription.Server: Sent 200 OK, dialog_id=#{inspect(dialog_id)}")

    # Update subscription with dialog_id
    updated_subscription = %{subscription | dialog_id: dialog_id}

    # Step 3: Store subscription (via handler callback)
    subscription_data = %{
      watcher: subscription.watcher,
      presentity: subscription.presentity,
      dialog_id: dialog_id,
      expires: subscription.expires,
      subscription_id: subscription.id
    }

    handler.store_subscription(subscription_data)

    # Step 4: NOW trigger initial NOTIFY (AFTER response is sent)
    # RFC 6665 Section 4.2.2: NOTIFY sent after 200 OK
    trigger_initial_notify(handler, updated_subscription, context)

    # Return updated subscription with dialog_id
    updated_subscription
  end

  defp handle_denied_subscription(sip_msg, response_fn, uas) do
    # RFC 6665: Send 403 Forbidden for denied subscriptions
    response = Message.reply(sip_msg, 403, "Forbidden")
    send_response(response, response_fn, uas)

    Logger.debug("Subscription.Server: Sent 403 Forbidden")
  end

  defp handle_pending_subscription(subscription, handler, sip_msg, response_fn, uas, _context) do
    # RFC 6665 Section 4.2.1.3: Send 202 Accepted for pending subscriptions
    response =
      Message.reply(sip_msg, 202, "Accepted")
      |> Map.put(:expires, subscription.expires)

    {:ok, final_response} = send_response(response, response_fn, uas)

    # Extract dialog_id from the response
    dialog_id = Message.dialog_id(final_response)

    Logger.debug("Subscription.Server: Sent 202 Accepted, dialog_id=#{inspect(dialog_id)}")

    # Update subscription with dialog_id
    updated_subscription = %{subscription | dialog_id: dialog_id}

    # Store subscription with pending state
    subscription_data = %{
      watcher: subscription.watcher,
      presentity: subscription.presentity,
      dialog_id: dialog_id,
      expires: subscription.expires,
      subscription_id: subscription.id,
      state: :pending
    }

    handler.store_subscription(subscription_data)

    # Don't send NOTIFY for pending subscriptions until approved
    # Return updated subscription with dialog_id
    updated_subscription
  end

  defp send_response(response, response_fn, uas) when is_function(response_fn, 2) do
    # Test mode - use callback
    case response_fn.(response, uas) do
      {:ok, final_response} ->
        # Test provided a proper return value
        {:ok, final_response}

      :ok ->
        # Test callback didn't return the response, use original
        {:ok, response}

      _ ->
        # Test callback didn't return expected format, use original response
        {:ok, response}
    end
  end

  defp send_response(response, _response_fn, uas) do
    # Production mode - use UAS transaction
    ParrotSip.Transaction.Server.response(response, uas)
  end

  defp trigger_initial_notify(handler, subscription, context) do
    # Get current presence state from handler
    presence_state = handler.get_presence(subscription.presentity)

    Logger.debug(
      "Subscription.Server: Triggering initial NOTIFY for #{subscription.watcher} " <>
        "watching #{subscription.presentity}, presence=#{inspect(presence_state)}"
    )

    # Check if we have a test notify function
    notify_fn = Map.get(context, :notify_fn)

    if notify_fn do
      # Test mode - use callback
      notify_msg = build_notify_message(subscription, presence_state)
      notify_fn.(notify_msg, nil)
    else
      # Production mode - send via client transaction
      send_notify_via_transaction(subscription, presence_state)
    end
  end

  defp send_notify_via_transaction(subscription, presence_state) do
    # Convert dialog_id map to string for Registry lookup
    dialog_id_str = ParrotSip.Dialog.to_string(subscription.dialog_id)

    # Build PIDF+XML body
    pidf_body = ParrotSip.Presence.Pidf.build(subscription.presentity, presence_state)

    # Build NOTIFY message template
    notify_template =
      Parrot.Presence.build_notify_message(
        subscription.presentity,
        pidf_body,
        subscription.expires
      )

    # Build in-dialog request with proper headers
    case ParrotSip.DialogStatem.uac_request(dialog_id_str, notify_template) do
      {:ok, notify_request} ->
        Logger.debug("Subscription.Server: Built NOTIFY request, sending via client transaction")

        # Send via client transaction layer
        callback = fn result ->
          case result do
            {:message, response} ->
              Logger.debug(
                "Subscription.Server: NOTIFY response: #{response.status_code} #{response.reason_phrase}"
              )

            {:stop, reason} ->
              Logger.warning("Subscription.Server: NOTIFY transaction stopped: #{inspect(reason)}")

            other ->
              Logger.debug("Subscription.Server: NOTIFY callback: #{inspect(other)}")
          end
        end

        # Extract destination from request_uri
        nexthop = notify_request.request_uri

        Logger.debug("Subscription.Server: Sending NOTIFY to nexthop: #{nexthop}")
        ParrotSip.Transaction.Client.request(notify_request, nexthop, callback)

      {:error, reason} ->
        Logger.warning(
          "Subscription.Server: Failed to build NOTIFY for #{subscription.watcher}: #{inspect(reason)}"
        )
    end
  end

  defp build_notify_message(subscription, presence_state) do
    # Build a minimal NOTIFY message for testing
    # In production, this goes through DialogStatem.uac_request
    %{
      method: :notify,
      subscription_id: subscription.id,
      watcher: subscription.watcher,
      presentity: subscription.presentity,
      presence_state: presence_state
    }
  end

  defp generate_subscription_id do
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "sub-#{:erlang.unique_integer([:positive])}-#{random}"
  end

  defp authorization_state(:allow), do: :active
  defp authorization_state(:deny), do: :terminated
  defp authorization_state(:pending), do: :pending
end
