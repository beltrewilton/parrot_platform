defmodule Parrot.SoftphoneHandler do
  @moduledoc """
  Behavior for handling softphone client events.

  Implement this behavior to receive callbacks for registration,
  presence, and call lifecycle events when using `Parrot.SoftphoneClient`.

  ## Usage

  Define a handler module that uses this behavior:

      defmodule MyApp.PhoneHandler do
        use Parrot.SoftphoneHandler

        @impl true
        def handle_registered(info, state) do
          Logger.info("Registered as \#{info.aor}")
          {:ok, state}
        end

        @impl true
        def handle_presence_update(presentity, presence, state) do
          Logger.info("\#{presentity} is \#{presence.status}")
          {:ok, state}
        end

        @impl true
        def handle_incoming_call(call_info, state) do
          # Auto-answer incoming calls
          {:answer, [], state}
        end

        @impl true
        def handle_call_answered(call_id, state) do
          {:ok, Map.put(state, :active_call, call_id)}
        end

        @impl true
        def handle_call_rejected(call_id, reason, state) do
          Logger.warning("Call \#{call_id} rejected: \#{inspect(reason)}")
          {:ok, state}
        end

        @impl true
        def handle_call_ended(call_id, reason, state) do
          Logger.info("Call \#{call_id} ended: \#{inspect(reason)}")
          {:ok, Map.delete(state, :active_call)}
        end
      end

  ## Required Callbacks

  The following callbacks must be implemented:

  - `handle_registered/2` - Called when registration succeeds
  - `handle_presence_update/3` - Called when a watched presentity's status changes
  - `handle_incoming_call/2` - Called when an incoming call arrives
  - `handle_call_answered/2` - Called when an outbound call is answered
  - `handle_call_rejected/3` - Called when an outbound call is rejected
  - `handle_call_ended/3` - Called when any call ends

  ## Optional Callbacks

  The following callbacks have default implementations that return `{:ok, state}`:

  - `handle_registration_failed/2` - Called when registration fails
  - `handle_unregistered/1` - Called when unregistered (explicitly or expired)
  - `handle_subscription_terminated/3` - Called when a presence subscription ends
  - `handle_publish_success/1` - Called when presence publish succeeds
  - `handle_publish_failed/2` - Called when presence publish fails
  - `handle_ringing/2` - Called when remote party is ringing (180)

  ## State Management

  All callbacks receive and return handler state. This state is managed by the
  `SoftphoneClient` and persisted across callbacks.
  """

  @type state :: term()

  @type registration_info :: %{
          aor: String.t(),
          expires: non_neg_integer(),
          contacts: [String.t()]
        }

  @type presence_state :: %{
          status: :open | :closed,
          note: String.t() | nil
        }

  @type call_info :: %{
          call_id: String.t(),
          from: String.t(),
          to: String.t()
        }

  # ============================================================================
  # Registration Callbacks
  # ============================================================================

  @doc """
  Called when registration with the SIP server succeeds.

  ## Parameters

  - `info` - Registration information including:
    - `:aor` - Address of Record (e.g., "sip:alice@example.com")
    - `:expires` - Registration expiry in seconds
    - `:contacts` - List of registered contact URIs
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Continue with updated state
  """
  @callback handle_registered(registration_info(), state()) :: {:ok, state()}

  @doc """
  Called when registration fails.

  ## Parameters

  - `reason` - Failure reason (e.g., `:timeout`, `:auth_failed`, `{:status, 403}`)
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Accept failure, don't retry
  - `{:retry, delay_ms, new_state}` - Retry registration after delay
  """
  @callback handle_registration_failed(reason :: term(), state()) ::
              {:ok, state()} | {:retry, delay_ms :: non_neg_integer(), state()}

  @doc """
  Called when the client becomes unregistered.

  This can happen due to explicit unregister, registration expiry,
  or server-initiated termination.

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_unregistered(state()) :: {:ok, state()}

  # ============================================================================
  # Presence Callbacks
  # ============================================================================

  @doc """
  Called when a subscribed presentity's presence state changes.

  ## Parameters

  - `presentity` - SIP URI of the watched user (e.g., "sip:bob@example.com")
  - `presence` - Presence state:
    - `:status` - `:open` (available) or `:closed` (unavailable)
    - `:note` - Optional status message
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_presence_update(presentity :: String.t(), presence_state(), state()) ::
              {:ok, state()}

  @doc """
  Called when a presence subscription is terminated.

  ## Parameters

  - `presentity` - SIP URI of the presentity
  - `reason` - Termination reason (e.g., `:expired`, `:rejected`, `:noresource`)
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_subscription_terminated(
              presentity :: String.t(),
              reason :: term(),
              state()
            ) :: {:ok, state()}

  @doc """
  Called when presence publication succeeds.

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_publish_success(state()) :: {:ok, state()}

  @doc """
  Called when presence publication fails.

  ## Parameters

  - `reason` - Failure reason
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_publish_failed(reason :: term(), state()) :: {:ok, state()}

  # ============================================================================
  # Call Callbacks
  # ============================================================================

  @doc """
  Called when an incoming call arrives.

  ## Parameters

  - `call_info` - Call information:
    - `:call_id` - Unique call identifier
    - `:from` - Caller's SIP URI
    - `:to` - Called SIP URI (your AOR)
  - `state` - Current handler state

  ## Returns

  - `{:answer, opts, new_state}` - Answer the call with optional codec preferences
  - `{:ring, new_state}` - Send ringing response, await user action
  - `{:reject, status_code, new_state}` - Reject with SIP status (e.g., 486 Busy)
  """
  @callback handle_incoming_call(call_info(), state()) ::
              {:answer, opts :: keyword(), state()}
              | {:reject, status_code :: non_neg_integer(), state()}
              | {:ring, state()}

  @doc """
  Called when an outbound call is answered (200 OK received).

  ## Parameters

  - `call_id` - The call identifier
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_call_answered(call_id :: String.t(), state()) :: {:ok, state()}

  @doc """
  Called when an outbound call is rejected (4xx/5xx/6xx received).

  ## Parameters

  - `call_id` - The call identifier
  - `reason` - Rejection reason (e.g., `{:status, 486}`, `:timeout`)
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_call_rejected(call_id :: String.t(), reason :: term(), state()) ::
              {:ok, state()}

  @doc """
  Called when a call ends (BYE received or sent).

  ## Parameters

  - `call_id` - The call identifier
  - `reason` - End reason (e.g., `:local_hangup`, `:remote_hangup`, `:error`)
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_call_ended(call_id :: String.t(), reason :: term(), state()) ::
              {:ok, state()}

  @doc """
  Called when remote party is ringing (180 Ringing received).

  ## Parameters

  - `call_id` - The call identifier
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}`
  """
  @callback handle_ringing(call_id :: String.t(), state()) :: {:ok, state()}

  # ============================================================================
  # Optional Callbacks
  # ============================================================================

  @optional_callbacks [
    handle_registration_failed: 2,
    handle_unregistered: 1,
    handle_subscription_terminated: 3,
    handle_publish_success: 1,
    handle_publish_failed: 2,
    handle_ringing: 2
  ]

  # ============================================================================
  # __using__ Macro
  # ============================================================================

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.SoftphoneHandler

      # Default implementations for optional callbacks

      @impl Parrot.SoftphoneHandler
      def handle_registration_failed(_reason, state), do: {:ok, state}

      @impl Parrot.SoftphoneHandler
      def handle_unregistered(state), do: {:ok, state}

      @impl Parrot.SoftphoneHandler
      def handle_subscription_terminated(_presentity, _reason, state), do: {:ok, state}

      @impl Parrot.SoftphoneHandler
      def handle_publish_success(state), do: {:ok, state}

      @impl Parrot.SoftphoneHandler
      def handle_publish_failed(_reason, state), do: {:ok, state}

      @impl Parrot.SoftphoneHandler
      def handle_ringing(_call_id, state), do: {:ok, state}

      defoverridable handle_registration_failed: 2,
                     handle_unregistered: 1,
                     handle_subscription_terminated: 3,
                     handle_publish_success: 1,
                     handle_publish_failed: 2,
                     handle_ringing: 2
    end
  end
end
