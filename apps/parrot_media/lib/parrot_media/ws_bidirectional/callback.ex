defmodule ParrotMedia.WsBidirectional.Callback do
  @moduledoc """
  Behaviour for handling bidirectional WebSocket connection events.

  Implement this behaviour to receive callbacks when connection state changes
  or messages arrive from the AI service.

  ## Example Implementation

      defmodule MyApp.AIHandler do
        @behaviour ParrotMedia.WsBidirectional.Callback

        @impl true
        def handle_event({:connected}, state) do
          Logger.info("Connected to AI service")
          {:ok, state}
        end

        @impl true
        def handle_event({:disconnected, reason}, state) do
          Logger.warning("Disconnected: \#{inspect(reason)}")
          {:ok, state}
        end

        @impl true
        def handle_event({:ws_message, json}, state) do
          case Jason.decode(json) do
            {:ok, %{"type" => "transcript", "text" => text}} ->
              Logger.info("AI transcript: \#{text}")
              {:ok, state}
            _ ->
              {:ok, state}
          end
        end

        @impl true
        def handle_event(_event, state) do
          {:ok, state}
        end
      end

  ## Callback Events

  ### Connection Lifecycle
  - `{:connected}` - WebSocket connected successfully
  - `{:disconnected, reason}` - Connection lost, `reason` is term
  - `{:reconnecting, attempt}` - Attempting reconnection, `attempt` is integer
  - `{:failed, reason}` - Permanent failure after max retries

  ### Messages
  - `{:ws_message, data}` - Non-audio message from WebSocket (text/JSON)

  ### Operational
  - `{:frames_dropped, count}` - Frames dropped due to backpressure
  """

  @typedoc """
  Connection lifecycle and message events.

  - `{:connected}` - WebSocket connection established
  - `{:disconnected, reason}` - Connection lost (may reconnect)
  - `{:reconnecting, attempt}` - Reconnection attempt in progress
  - `{:failed, reason}` - Permanent failure, no more reconnection attempts
  - `{:ws_message, data}` - Text/JSON message received from WebSocket
  - `{:frames_dropped, count}` - Audio frames dropped due to buffer overflow
  """
  @type event ::
          {:connected}
          | {:disconnected, reason :: term()}
          | {:reconnecting, attempt :: pos_integer()}
          | {:failed, reason :: term()}
          | {:ws_message, data :: binary() | String.t()}
          | {:frames_dropped, count :: pos_integer()}

  @typedoc """
  Callback state maintained across events.

  Initialized from `callback_state` in Config, updated via `handle_event/2` return.
  """
  @type state :: term()

  @doc """
  Handle a connection event or incoming message.

  Called when the connection state changes or a message arrives from the WebSocket.
  Return `{:ok, new_state}` to update state, or `{:error, reason}` to log an error.

  ## Parameters

  - `event` - The event that occurred (see event type)
  - `state` - Current callback state

  ## Returns

  - `{:ok, new_state}` - Continue with updated state
  - `{:error, reason}` - Log error and continue with unchanged state
  """
  @callback handle_event(event(), state()) :: {:ok, state()} | {:error, term()}

  @doc """
  Called when the connector is terminating.

  Optional callback for cleanup. The return value is ignored.

  ## Parameters

  - `reason` - Termination reason (`:normal`, `:shutdown`, or error)
  - `state` - Final callback state
  """
  @callback terminate(reason :: term(), state()) :: term()

  @optional_callbacks [terminate: 2]
end
