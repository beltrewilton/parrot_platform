defmodule ParrotMedia.WsBidirectional.Connection do
  @moduledoc """
  WebSocket connection handler for bidirectional audio using the Fresh library.

  This module implements the Fresh callbacks to manage the WebSocket lifecycle
  and forward events to the parent WsBidirectionalConnector GenServer.

  ## Internal Use Only

  This module is an implementation detail of WsBidirectionalConnector and should not be
  used directly. Use the WsBidirectionalConnector public API instead.

  ## Architecture

  ```
  WsBidirectionalConnector (GenServer)
       |
       v
  Connection (Fresh WebSocket)
       |
       v
  Remote WebSocket Server (AI Provider)
  ```

  The Connection module:
  - Manages the raw WebSocket connection via Fresh
  - Sends connection lifecycle events to the parent WsBidirectionalConnector
  - Handles binary frames as audio data and text frames as JSON messages
  - Handles reconnection logic (delegated to Fresh)
  - Logs connection events for debugging
  """

  use Fresh
  require Logger

  @doc """
  Starts a WebSocket connection linked to the calling process.

  ## Options

  - `:uri` - WebSocket URL (required)
  - `:state` - Initial state containing `:parent` pid and `:connection_id` (required)
  - `:opts` - Fresh options including `:headers` (optional)

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
    Logger.debug("WsBidirectional.Connection #{state.connection_id}: WebSocket connected")

    # Notify parent that connection is established
    send(state.parent, {:connection_event, :connected})

    {:ok, state}
  end

  @doc false
  @impl Fresh
  def handle_in({:text, data}, state) do
    Logger.debug(
      "WsBidirectional.Connection #{state.connection_id}: Received text message, #{byte_size(data)} bytes"
    )

    # Text frames are JSON messages from the provider
    send(state.parent, {:connection_event, {:ws_message, data}})

    {:ok, state}
  end

  def handle_in({:binary, data}, state) do
    Logger.debug(
      "WsBidirectional.Connection #{state.connection_id}: Received binary audio, #{byte_size(data)} bytes"
    )

    # Binary frames are audio data from the provider
    send(state.parent, {:connection_event, {:ws_audio, data}})

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
      "WsBidirectional.Connection #{state.connection_id}: Disconnected, code: #{inspect(code)}, reason: #{inspect(reason)}"
    )

    # Notify parent of disconnection
    send(state.parent, {:connection_event, {:disconnected, {code, reason}}})

    # Tell Fresh to attempt reconnection
    # The reconnect_count is tracked in WsBidirectionalConnector, but Fresh handles the actual retry logic
    new_state = Map.update(state, :reconnect_attempt, 1, &(&1 + 1))
    send(state.parent, {:connection_event, {:reconnecting, new_state.reconnect_attempt}})

    {:reconnect, new_state}
  end

  @doc false
  @impl Fresh
  def handle_error(error, state) do
    Logger.warning("WsBidirectional.Connection #{state.connection_id}: Error: #{inspect(error)}")

    case error do
      {:encoding_failed, _reason} ->
        # Non-fatal error, continue
        {:ignore, state}

      {:casting_failed, _reason} ->
        # Non-fatal error, continue
        {:ignore, state}

      _other ->
        # For other errors, attempt reconnection
        send(state.parent, {:connection_event, {:disconnected, error}})
        :reconnect
    end
  end

  @doc false
  @impl Fresh
  def handle_info(msg, state) do
    Logger.debug(
      "WsBidirectional.Connection #{state.connection_id}: Unhandled info: #{inspect(msg)}"
    )

    {:ok, state}
  end

  @doc false
  @impl Fresh
  def handle_terminate(reason, state) do
    Logger.debug(
      "WsBidirectional.Connection #{state.connection_id}: Terminating, reason: #{inspect(reason)}"
    )

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
