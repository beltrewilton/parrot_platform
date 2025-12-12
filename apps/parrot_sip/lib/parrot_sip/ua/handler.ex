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

  @optional_callbacks [
    handle_ringing: 4,
    handle_rejected: 4,
    handle_hangup: 4,
    handle_cancel: 3,
    handle_registered: 4,
    handle_registration_failed: 4
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
      def handle_hangup(_ua, _message, _entity, state), do: {:ok, state}

      @impl true
      def handle_cancel(_ua, _entity, state), do: {:ok, state}

      @impl true
      def handle_registered(_ua, _response, _reg_id, state), do: {:ok, state}

      @impl true
      def handle_registration_failed(_ua, _response, _reg_id, state), do: {:ok, state}

      defoverridable [
        handle_ringing: 4,
        handle_rejected: 4,
        handle_hangup: 4,
        handle_cancel: 3,
        handle_registered: 4,
        handle_registration_failed: 4
      ]
    end
  end
end
