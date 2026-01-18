defmodule ParrotMedia.WsAudioForker.Callback do
  @moduledoc """
  Behaviour for handling WebSocket Audio Forker events.

  Implement this behaviour to receive notifications about fork lifecycle events
  and incoming WebSocket messages (e.g., transcription results from AI services).

  ## Overview

  The WebSocket Audio Forker streams audio from SIP calls to external services
  (like speech-to-text providers) via WebSocket connections. This callback
  behaviour allows you to:

  - Track connection lifecycle (connected, disconnected, reconnecting)
  - Receive messages from the WebSocket server (transcription results, etc.)
  - Handle errors and backpressure warnings
  - Maintain state across the fork session

  ## Event Types

  The following events are delivered to `handle_fork_event/2`:

  ### Connection Events

  - `{:fork_event, fork_id, :connected}` - WebSocket connection established successfully.
    Emitted when the initial connection succeeds or after a successful reconnection.

  - `{:fork_event, fork_id, {:disconnected, reason}}` - Connection lost unexpectedly.
    The forker will attempt to reconnect automatically. The `reason` provides
    details about why the connection was lost (e.g., `:closed`, `{:error, :timeout}`).

  - `{:fork_event, fork_id, {:reconnecting, attempt}}` - Reconnection attempt in progress.
    The `attempt` is a positive integer indicating which retry attempt is being made.
    Useful for logging or updating UI state.

  - `{:fork_event, fork_id, {:failed, reason}}` - Permanent failure after retries exhausted.
    No more reconnection attempts will be made. The fork is effectively dead.
    You may want to alert operators or attempt to restart the fork.

  ### Data Events

  - `{:fork_event, fork_id, {:ws_message, data}}` - Message received from WebSocket.
    The `data` is the raw binary or string message from the server. Typically
    contains JSON-encoded transcription results or other processed data.

  - `{:fork_event, fork_id, {:backpressure_warning, drops}}` - Frames dropped due to
    backpressure. The `drops` count indicates how many audio frames were discarded
    because the WebSocket couldn't keep up. Consider adjusting buffer sizes or
    investigating network issues.

  ## Example Implementation

      defmodule MyApp.TranscriptionHandler do
        @behaviour ParrotMedia.WsAudioForker.Callback
        require Logger

        @impl true
        def init(args) do
          {:ok, %{call_id: args[:call_id], transcripts: []}}
        end

        @impl true
        def handle_fork_event({:fork_event, fork_id, :connected}, state) do
          Logger.info("Fork \#{fork_id} connected for call \#{state.call_id}")
          {:ok, state}
        end

        @impl true
        def handle_fork_event({:fork_event, fork_id, {:ws_message, data}}, state) do
          case Jason.decode(data) do
            {:ok, %{"transcript" => text}} ->
              Logger.debug("Received transcript: \#{text}")
              broadcast_transcript(state.call_id, text)
              {:ok, %{state | transcripts: [text | state.transcripts]}}

            {:ok, _other} ->
              {:ok, state}

            {:error, _} ->
              Logger.warning("Failed to decode message from fork \#{fork_id}")
              {:ok, state}
          end
        end

        @impl true
        def handle_fork_event({:fork_event, fork_id, {:failed, reason}}, state) do
          Logger.error("Fork \#{fork_id} failed permanently: \#{inspect(reason)}")
          notify_failure(state.call_id, reason)
          {:ok, state}
        end

        @impl true
        def handle_fork_event({:fork_event, fork_id, {:backpressure_warning, drops}}, state) do
          Logger.warning("Fork \#{fork_id} dropped \#{drops} frames due to backpressure")
          {:ok, state}
        end

        @impl true
        def handle_fork_event(_event, state) do
          {:ok, state}
        end

        defp broadcast_transcript(call_id, text) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "call:\#{call_id}", {:transcript, text})
        end

        defp notify_failure(call_id, reason) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "call:\#{call_id}", {:fork_failed, reason})
        end
      end

  ## Stopping the Forker

  Return `{:stop, reason, state}` from `handle_fork_event/2` to gracefully shut down
  the forker. This is useful when you receive a terminal message from the server
  or want to stop based on application logic:

      def handle_fork_event({:fork_event, _fork_id, {:ws_message, "END"}}, state) do
        {:stop, :normal, state}
      end

  ## Performance Considerations

  - Callbacks are invoked in the forker's process context
  - Keep processing fast to avoid blocking audio streaming
  - For heavy processing (e.g., database writes, HTTP calls), spawn a Task
    or send messages to a separate GenServer
  - The `init/1` callback is optional; if not implemented, the forker starts
    with the `callback_args` as the initial state

  ## Configuration

  When starting a fork, specify your callback module in the fork configuration:

      ParrotMedia.WsAudioForker.start_fork(%{
        fork_id: "my-fork-123",
        url: "wss://api.example.com/stream",
        callback: MyApp.TranscriptionHandler,
        callback_args: %{call_id: "call-456"}
      })

  """

  @typedoc "Unique identifier for a fork session"
  @type fork_id :: String.t()

  @typedoc "Callback state - can be any term"
  @type state :: term()

  @typedoc """
  Connection lifecycle events.

  - `:connected` - WebSocket connection established
  - `{:disconnected, reason}` - Connection lost (will retry)
  - `{:reconnecting, attempt}` - Attempting reconnection
  - `{:failed, reason}` - Permanent failure (retries exhausted)
  """
  @type connection_event ::
          :connected
          | {:disconnected, reason :: term()}
          | {:reconnecting, attempt :: pos_integer()}
          | {:failed, reason :: term()}

  @typedoc """
  Data events from the WebSocket connection.

  - `{:ws_message, data}` - Message received from WebSocket server
  - `{:backpressure_warning, drops}` - Frames dropped due to backpressure
  """
  @type data_event ::
          {:ws_message, data :: binary() | String.t()}
          | {:backpressure_warning, drops :: pos_integer()}

  @typedoc """
  Fork event delivered to callbacks.

  All events are wrapped in a `{:fork_event, fork_id, event}` tuple
  to allow pattern matching on both the fork identity and event type.
  """
  @type fork_event :: {:fork_event, fork_id(), connection_event() | data_event()}

  @doc """
  Initialize callback state.

  Called when the forker starts, before connecting to the WebSocket.
  Use this to set up initial state based on the configuration arguments.

  ## Parameters

  - `args` - Arguments from the fork configuration's `callback_args`

  ## Returns

  - `{:ok, initial_state}` - Initialize with the given state
  - `{:error, reason}` - Prevent the forker from starting

  ## Example

      @impl true
      def init(%{call_id: call_id, user_id: user_id}) do
        {:ok, %{
          call_id: call_id,
          user_id: user_id,
          connected_at: nil,
          message_count: 0
        }}
      end

  ## Notes

  This callback is optional. If not implemented, the forker will use
  the `callback_args` directly as the initial state.
  """
  @callback init(args :: term()) :: {:ok, state()} | {:error, reason :: term()}

  @doc """
  Handle a fork event.

  Called when fork state changes or data is received from the WebSocket.
  This is the primary callback for processing fork activity.

  ## Parameters

  - `event` - The fork event (see Event Types in module documentation)
  - `state` - Current callback state

  ## Returns

  - `{:ok, new_state}` - Continue with updated state
  - `{:stop, reason, new_state}` - Stop the forker (graceful shutdown)

  ## Example

      @impl true
      def handle_fork_event({:fork_event, fork_id, :connected}, state) do
        Logger.info("Fork \#{fork_id} connected")
        {:ok, %{state | connected_at: DateTime.utc_now()}}
      end

      @impl true
      def handle_fork_event({:fork_event, fork_id, {:ws_message, data}}, state) do
        # Process incoming message
        process_message(data)
        {:ok, %{state | message_count: state.message_count + 1}}
      end

      @impl true
      def handle_fork_event({:fork_event, _fork_id, {:failed, _reason}}, state) do
        # Stop on permanent failure
        {:stop, :fork_failed, state}
      end

      @impl true
      def handle_fork_event(_event, state) do
        {:ok, state}
      end

  ## Notes

  - This callback is invoked in the forker's process context
  - Keep processing fast to avoid blocking audio streaming
  - For heavy processing, spawn a separate task or send to another process
  """
  @callback handle_fork_event(event :: fork_event(), state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @optional_callbacks [init: 1]
end
