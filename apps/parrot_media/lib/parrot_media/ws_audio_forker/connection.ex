defmodule ParrotMedia.WsAudioForker.Connection do
  @moduledoc """
  WebSocket connection handler for WsAudioForker using the Fresh library.

  This module implements the Fresh callbacks to manage the WebSocket lifecycle
  and forward events to the parent WsAudioForker GenServer.

  ## Internal Use Only

  This module is an implementation detail of WsAudioForker and should not be
  used directly. Use the WsAudioForker public API instead.

  ## Architecture

  ```
  WsAudioForker (GenServer)
       |
       v
  Connection (Fresh WebSocket)
       |
       v
  Remote WebSocket Server
  ```

  The Connection module:
  - Manages the raw WebSocket connection via Fresh
  - Sends connection lifecycle events to the parent WsAudioForker
  - Handles reconnection logic (delegated to Fresh)
  - Logs connection events for debugging
  """

  use Fresh
  require Logger

  @doc """
  Starts a WebSocket connection linked to the calling process.

  ## Options

  - `:uri` - WebSocket URL (required)
  - `:state` - Initial state containing `:parent` pid, `:fork_id`, `:max_retries` (required)
  - `:opts` - Fresh options including `:headers`, `:backoff_initial`, `:backoff_max` (optional)

  ## Returns

  - `{:ok, pid}` - Connection started successfully
  - `{:error, reason}` - Failed to start connection
  """
  def start_link(opts) do
    uri = Keyword.fetch!(opts, :uri)
    state = Keyword.fetch!(opts, :state)
    fresh_opts = Keyword.get(opts, :opts, [])

    Fresh.start_link(uri, __MODULE__, state, fresh_opts)
  end

  # ============================================================================
  # Fresh Callbacks
  # ============================================================================

  @doc false
  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Logger.debug("WsAudioForker.Connection #{state.fork_id}: WebSocket connected")

    # Reset reconnect_attempt counter on successful connection
    # Mark that we have successfully connected at least once
    new_state =
      state
      |> Map.put(:reconnect_attempt, 0)
      |> Map.put(:has_connected, true)

    # Notify parent that connection is established
    send(state.parent, {:connection_event, :connected})

    {:ok, new_state}
  end

  @doc false
  @impl Fresh
  def handle_in({:text, data}, state) do
    Logger.debug("WsAudioForker.Connection #{state.fork_id}: Received text message, #{byte_size(data)} bytes")

    # Forward message to parent
    send(state.parent, {:connection_event, {:ws_message, data}})

    {:ok, state}
  end

  def handle_in({:binary, data}, state) do
    Logger.debug("WsAudioForker.Connection #{state.fork_id}: Received binary message, #{byte_size(data)} bytes")

    # Forward message to parent
    send(state.parent, {:connection_event, {:ws_message, data}})

    {:ok, state}
  end

  @doc false
  @impl Fresh
  def handle_control({:ping, _data}, state) do
    {:ok, state}
  end

  def handle_control({:pong, _data}, state) do
    {:ok, state}
  end

  @doc false
  @impl Fresh
  def handle_disconnect(code, reason, state) do
    Logger.debug(
      "WsAudioForker.Connection #{state.fork_id}: Disconnected, code: #{inspect(code)}, reason: #{inspect(reason)}"
    )

    # Check if we ever successfully connected
    has_connected = Map.get(state, :has_connected, false)

    if has_connected do
      # Mid-stream failure: we were connected, then lost connection
      # Use normal retry logic with exponential backoff
      handle_midstream_failure(state, {code, reason})
    else
      # Initial connection failure: never successfully connected
      # Fail immediately without retrying
      Logger.warning(
        "WsAudioForker.Connection #{state.fork_id}: Initial connection failed, not retrying"
      )

      send(state.parent, {:connection_event, {:initial_connection_failed, {code, reason}}})
      {:close, {:initial_connection_failed, {code, reason}}}
    end
  end

  # Handle mid-stream failures with retry logic
  defp handle_midstream_failure(state, disconnect_reason) do
    # Notify parent of disconnection
    send(state.parent, {:connection_event, {:disconnected, disconnect_reason}})

    # Update reconnect attempt counter
    new_state = Map.update(state, :reconnect_attempt, 1, &(&1 + 1))
    max_retries = Map.get(state, :max_retries, 5)

    # Check if max retries exceeded (0 means unlimited)
    if max_retries > 0 and new_state.reconnect_attempt > max_retries do
      Logger.warning(
        "WsAudioForker.Connection #{state.fork_id}: Max retries (#{max_retries}) exceeded, stopping"
      )

      send(state.parent, {:connection_event, {:max_retries_exceeded, new_state.reconnect_attempt}})
      {:close, {:max_retries_exceeded, new_state.reconnect_attempt}}
    else
      send(state.parent, {:connection_event, {:reconnecting, new_state.reconnect_attempt}})
      {:reconnect, new_state}
    end
  end

  @doc false
  @impl Fresh
  def handle_error(error, state) do
    Logger.warning("WsAudioForker.Connection #{state.fork_id}: Error: #{inspect(error)}")

    case error do
      {:encoding_failed, _reason} ->
        # Non-fatal error, continue
        {:ignore, state}

      {:casting_failed, _reason} ->
        # Non-fatal error, continue
        {:ignore, state}

      _other ->
        # Check if we ever successfully connected
        has_connected = Map.get(state, :has_connected, false)

        if has_connected do
          # Mid-stream failure: we were connected, then got an error
          # Use normal retry logic with exponential backoff
          handle_midstream_failure(state, error)
        else
          # Initial connection failure: never successfully connected
          # Fail immediately without retrying
          Logger.warning(
            "WsAudioForker.Connection #{state.fork_id}: Initial connection failed (error), not retrying"
          )

          send(state.parent, {:connection_event, {:initial_connection_failed, error}})
          {:close, {:initial_connection_failed, error}}
        end
    end
  end

  @doc false
  @impl Fresh
  def handle_info(msg, state) do
    Logger.debug("WsAudioForker.Connection #{state.fork_id}: Unhandled info: #{inspect(msg)}")
    {:ok, state}
  end

  @doc false
  @impl Fresh
  def handle_terminate(reason, state) do
    Logger.debug("WsAudioForker.Connection #{state.fork_id}: Terminating, reason: #{inspect(reason)}")

    # Notify parent if this is an unexpected termination
    case reason do
      :normal -> :ok
      :shutdown -> :ok
      {:shutdown, _} -> :ok
      other -> send(state.parent, {:connection_event, {:failed, other}})
    end

    :ok
  end
end
