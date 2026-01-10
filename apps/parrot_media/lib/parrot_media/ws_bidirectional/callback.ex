defmodule ParrotMedia.WsBidirectional.Callback do
  @moduledoc """
  Behaviour for handling bidirectional WebSocket connection events.

  STUB IMPLEMENTATION - To be completed in T006.

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

  # TODO: Implement callback definitions in T006
  # @type event ::
  #         {:connected}
  #         | {:disconnected, reason :: term()}
  #         | {:reconnecting, attempt :: pos_integer()}
  #         | {:failed, reason :: term()}
  #         | {:ws_message, data :: binary() | String.t()}
  #         | {:frames_dropped, count :: pos_integer()}
  #
  # @type state :: term()
  #
  # @callback handle_event(event(), state()) :: {:ok, state()} | {:error, term()}
  # @callback terminate(reason :: term(), state()) :: term()
  #
  # @optional_callbacks [terminate: 2]
end
