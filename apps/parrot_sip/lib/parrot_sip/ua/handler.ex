defmodule ParrotSip.UA.Handler do
  @moduledoc """
  Behaviour for UA event handlers.

  Implement this behaviour to handle call events in your UA application.
  All callbacks receive the UA pid as the first argument, allowing you
  to call UA functions (like `UA.answer/3`) from within callbacks.

  ## Example

      defmodule MyPhone do
        use ParrotSip.UA.Handler

        @impl true
        def init(_config) do
          {:ok, %{}}
        end

        @impl true
        def handle_incoming(ua, invite, entity, state) do
          # Answer the call
          ParrotSip.UA.answer(ua, entity, sdp: generate_sdp())
          {:ok, state}
        end

        @impl true
        def handle_hangup(_ua, _message, _entity, state) do
          {:ok, state}
        end
      end
  """

  @type entity :: ParrotSip.UA.Entity.t()
  @type state :: term()

  # Initialization
  @callback init(init_arg :: term()) :: {:ok, state()}

  # Inbound call
  @callback handle_incoming(ua :: pid(), invite :: map(), entity(), state()) ::
              {:ok, state()}

  # Outbound call responses
  @callback handle_ringing(ua :: pid(), response :: map(), entity(), state()) ::
              {:ok, state()}

  @callback handle_answered(ua :: pid(), response :: map(), entity(), state()) ::
              {:ok, state()}

  @callback handle_rejected(ua :: pid(), response :: map(), entity(), state()) ::
              {:ok, state()}

  @doc """
  Called when receiving 3xx redirect response.

  The contacts list is sorted by q-value (highest first).
  Contacts without q-value default to q=1.0.

  Return `{:redirect, contact, new_state}` to retry with the selected contact,
  or `{:stop, reason, new_state}` to terminate the call attempt.
  """
  @callback handle_redirect(
              ua :: pid(),
              status_code :: integer(),
              response :: map(),
              contacts :: list(),
              state()
            ) ::
              {:redirect, contact :: map(), state()}
              | {:stop, reason :: term(), state()}

  # Both directions
  @callback handle_hangup(ua :: pid(), message :: map(), entity(), state()) ::
              {:ok, state()}

  @callback handle_cancel(ua :: pid(), entity(), state()) ::
              {:ok, state()}

  # Registration
  @callback handle_registered(ua :: pid(), response :: map(), reg_id :: term(), state()) ::
              {:ok, state()}

  @callback handle_registration_failed(ua :: pid(), response :: map(), reg_id :: term(), state()) ::
              {:ok, state()}

  # UPDATE (RFC 3311)
  @doc """
  Called when an outgoing UPDATE request succeeds (200 OK received).

  Use this to process the SDP answer and update media parameters.
  """
  @callback handle_update_complete(ua :: pid(), response :: map(), entity(), state()) ::
              {:ok, state()}

  @doc """
  Called when an outgoing UPDATE request fails (4xx-6xx response).

  Common failure codes:
  - 488 Not Acceptable Here - Media parameters not acceptable
  - 491 Request Pending - Another request is being processed
  """
  @callback handle_update_failed(
              ua :: pid(),
              status :: integer(),
              response :: map(),
              entity(),
              state()
            ) ::
              {:ok, state()}

  @optional_callbacks [
    handle_ringing: 4,
    handle_rejected: 4,
    handle_redirect: 5,
    handle_hangup: 4,
    handle_cancel: 3,
    handle_registered: 4,
    handle_registration_failed: 4,
    handle_update_complete: 4,
    handle_update_failed: 5
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour ParrotSip.UA.Handler

      # Default implementations for optional callbacks

      @impl true
      def handle_ringing(_ua, _response, _entity, state), do: {:ok, state}

      @impl true
      def handle_rejected(_ua, _response, _entity, state), do: {:ok, state}

      @impl true
      def handle_redirect(_ua, status_code, _response, _contacts, state) do
        # Default: treat redirect as rejection (stop)
        {:stop, {:redirect, status_code}, state}
      end

      @impl true
      def handle_hangup(_ua, _message, _entity, state), do: {:ok, state}

      @impl true
      def handle_cancel(_ua, _entity, state), do: {:ok, state}

      @impl true
      def handle_registered(_ua, _response, _reg_id, state), do: {:ok, state}

      @impl true
      def handle_registration_failed(_ua, _response, _reg_id, state), do: {:ok, state}

      @impl true
      def handle_update_complete(_ua, _response, _entity, state), do: {:ok, state}

      @impl true
      def handle_update_failed(_ua, _status, _response, _entity, state), do: {:ok, state}

      defoverridable handle_ringing: 4,
                     handle_rejected: 4,
                     handle_redirect: 5,
                     handle_hangup: 4,
                     handle_cancel: 3,
                     handle_registered: 4,
                     handle_registration_failed: 4,
                     handle_update_complete: 4,
                     handle_update_failed: 5
    end
  end
end
