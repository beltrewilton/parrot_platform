defmodule Parrot.Presence do
  @moduledoc """
  API for triggering presence notifications in Parrot VoIP applications.

  This module provides a simple, fire-and-forget interface for notifying
  presence changes from anywhere in your application. When called, it
  asynchronously triggers NOTIFY messages to all subscribers watching
  the given presentity.

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

  """
  @spec notify(String.t(), map()) :: :ok
  def notify(_presentity, _presence_state) do
    # This is a fire-and-forget operation.
    # In the full implementation, this would:
    # 1. Look up the configured PresenceHandler via the application config
    # 2. Call handler.get_subscriptions(presentity) to get all watchers
    # 3. For each watcher, send a SIP NOTIFY with the presence state
    #
    # For now, this returns :ok as a placeholder for the async operation.
    # The actual SIP mechanics will be handled by the framework when
    # integrated with the SIP stack.
    :ok
  end
end
