defmodule Parrot.Presence do
  @moduledoc """
  API for triggering presence notifications in Parrot VoIP applications.

  This module provides a simple, fire-and-forget interface for notifying
  presence changes from anywhere in your application. When called, it
  asynchronously triggers NOTIFY messages to all subscribers watching
  the given presentity.

  ## RFC References

  - RFC 3856 Section 4: Notifier Processing - defines how notifiers process
    subscription state changes and send NOTIFY requests
  - RFC 3863: Presence Information Data Format (PIDF) - defines the XML format
    for presence information in NOTIFY bodies
  - RFC 3265 Section 3.1.6: Notifier NOTIFY Behavior - specifies NOTIFY message
    construction and delivery requirements

  ## Usage

  Call `notify/2` from anywhere in your application to trigger a presence update:

      # In a call handler
      def handle_bridge_complete(:answered, call) do
        Parrot.Presence.notify(call.assigns.extension, %{status: :closed, note: "On a call"})
        {:noreply, call}
      end

      def handle_hangup(call) do
        Parrot.Presence.notify(call.assigns.extension, %{status: :open, note: "Available"})
        {:noreply, call}
      end

      # In a registration handler
      def store_binding(aor, contact, expires) do
        Parrot.Presence.notify(aor, %{status: :open, note: "Available"})
        :ok
      end

  ## Presence State

  The presence state is a map that typically contains:

  - `:status` - Either `:open` (available) or `:closed` (unavailable)
  - `:note` - Optional human-readable description (e.g., "Available", "On a call")

  Additional fields may be included depending on your application's needs.

  ## How It Works

  When `notify/2` is called:

  1. The framework looks up all subscribers watching the given presentity
  2. For each subscriber, a SIP NOTIFY message is sent with the presence state
  3. The call returns immediately - delivery happens asynchronously

  This design allows presence updates to be triggered from time-critical
  code paths without blocking on network operations.
  """

  require Logger

  alias ParrotSip.Presence.Pidf

  @doc """
  Notify subscribers about a presence state change.

  This is a fire-and-forget, asynchronous operation. It returns `:ok`
  immediately and the actual NOTIFY messages are sent in the background.

  ## Arguments

  - `presentity` - The SIP URI of the entity whose presence changed
  - `presence_state` - A map containing the presence state, typically with:
    - `:status` - Either `:open` (available) or `:closed` (unavailable)
    - `:note` - Optional human-readable description

  ## Returns

  Always returns `:ok` immediately. The actual notification happens
  asynchronously.

  ## Examples

      # User is now on a call
      Parrot.Presence.notify("sip:alice@example.com", %{status: :closed, note: "On a call"})

      # User hung up, now available
      Parrot.Presence.notify("sip:alice@example.com", %{status: :open, note: "Available"})

      # User went offline
      Parrot.Presence.notify("sip:alice@example.com", %{status: :closed, note: "Offline"})

      # Minimal update with just status
      Parrot.Presence.notify("sip:alice@example.com", %{status: :open})

  ## RFC References

  Per RFC 3856 Section 4, when the presence state changes, the notifier
  MUST send a NOTIFY request to each active subscription for the presentity.
  The NOTIFY body contains PIDF+XML per RFC 3863.

  """
  @spec notify(String.t(), map()) :: :ok
  def notify(presentity, presence_state) do
    # Fire-and-forget: spawn async task for notification delivery
    # Use Task.Supervisor if available for fault isolation, otherwise Task.start
    case get_presence_handler() do
      nil ->
        Logger.debug("No presence handler configured, skipping notification for #{presentity}")
        :ok

      handler ->
        do_notify_async(handler, presentity, presence_state)
    end
  end

  # Get the presence handler from the router configuration
  defp get_presence_handler do
    case Application.get_env(:parrot, :router) do
      nil ->
        nil

      router ->
        # Check if the router has a presence handler
        if function_exported?(router, :__presence_handler__, 0) do
          router.__presence_handler__()
        else
          nil
        end
    end
  end

  # Spawn async task for notification delivery
  # RFC 3265 Section 3.1.6: Notifier NOTIFY Behavior
  defp do_notify_async(handler, presentity, presence_state) do
    task_fun = fn ->
      do_notify_sync(handler, presentity, presence_state)
    end

    # Use Task.Supervisor if available for better fault isolation
    case Process.whereis(Parrot.TaskSupervisor) do
      nil ->
        # Fall back to bare Task.start if supervisor not available
        Task.start(task_fun)

      _pid ->
        Task.Supervisor.start_child(Parrot.TaskSupervisor, task_fun)
    end

    :ok
  end

  # Synchronous notification logic (runs in spawned task)
  defp do_notify_sync(handler, presentity, presence_state) do
    # RFC 3856 Section 4: Get all subscriptions for this presentity
    subscriptions = handler.get_subscriptions(presentity)

    if subscriptions == [] do
      Logger.debug("No subscriptions for #{presentity}, no NOTIFY messages to send")
    else
      # RFC 3863: Generate PIDF+XML body
      pidf_body = Pidf.build(presentity, presence_state)

      # RFC 3265 Section 3.1.6: Send NOTIFY to each subscriber
      Enum.each(subscriptions, fn subscription ->
        send_notify(subscription, presentity, pidf_body)
      end)
    end
  end

  # Default subscription expiry in seconds (RFC 3856 Section 6.4)
  @default_expires 3600

  # Send a NOTIFY message to a single subscriber
  # RFC 3265 Section 3.1.6: NOTIFY requests are sent to refresh subscriptions
  defp send_notify(subscription, presentity, pidf_body) do
    dialog_id = Map.get(subscription, :dialog_id)
    watcher = Map.get(subscription, :watcher)
    # RFC 6665 Section 4.1.3: Subscription-State SHOULD include expires parameter
    expires = Map.get(subscription, :expires)

    if dialog_id do
      Logger.debug(
        "Sending NOTIFY for #{presentity} to watcher #{watcher} via dialog #{dialog_id}"
      )

      # Build NOTIFY message per RFC 3265 Section 3.1.6
      notify_msg = build_notify_message(presentity, pidf_body, expires)

      # Send via dialog
      case ParrotSip.DialogStatem.uac_request(dialog_id, notify_msg) do
        {:ok, _request} ->
          Logger.debug("NOTIFY sent successfully to #{watcher}")

        {:error, reason} ->
          Logger.warning("Failed to send NOTIFY to #{watcher}: #{inspect(reason)}")
      end
    else
      Logger.warning("Subscription for #{watcher} has no dialog_id, cannot send NOTIFY")
    end
  end

  @doc """
  Builds a NOTIFY request message for presence notification.

  This function creates a properly formatted SIP NOTIFY message with all
  required headers per RFC 3265 Section 3.1.6 and RFC 6665 Section 4.1.3.

  ## Arguments

  - `presentity` - The SIP URI of the entity whose presence is being reported
  - `pidf_body` - The PIDF+XML body containing the presence state
  - `expires` - Remaining subscription time in seconds (nil defaults to 3600)

  ## Returns

  A `ParrotSip.Message` struct ready to be sent via the dialog.

  ## RFC References

  - RFC 3265 Section 3.1.6: NOTIFY MUST contain Event and Subscription-State headers
  - RFC 6665 Section 4.1.3: Subscription-State SHOULD include expires parameter
  - RFC 3856 Section 4: Presence NOTIFY message construction

  ## Examples

      iex> msg = Parrot.Presence.build_notify_message("sip:alice@example.com", "<pidf/>", 3600)
      iex> msg.method
      :notify
      iex> msg.event.event
      "presence"

  """
  @spec build_notify_message(String.t(), String.t(), non_neg_integer() | nil) ::
          ParrotSip.Message.t()
  def build_notify_message(presentity, pidf_body, expires) do
    alias ParrotSip.Message
    alias ParrotSip.Headers.{Event, SubscriptionState, ContentType}

    # RFC 6665 Section 4.1.3: Use provided expires or default
    actual_expires = expires || @default_expires

    Message.new_request(:notify, presentity)
    |> Map.put(:event, %Event{event: "presence", parameters: %{}})
    |> Map.put(:subscription_state, %SubscriptionState{
      state: :active,
      parameters: %{"expires" => Integer.to_string(actual_expires)}
    })
    |> Map.put(:content_type, %ContentType{
      type: "application",
      subtype: "pidf+xml",
      parameters: %{}
    })
    |> Message.set_body(pidf_body)
  end
end
