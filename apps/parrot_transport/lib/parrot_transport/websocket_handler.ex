defmodule ParrotTransport.WebsocketHandler do
  @moduledoc """
  Cowboy WebSocket handler for incoming WebSocket connections.

  This module implements the :cowboy_websocket behavior to handle
  WebSocket connections and forward received messages to a handler process.
  """

  @behaviour :cowboy_websocket

  require Logger

  alias ParrotTransport.Types.{IncomingPacket, Source, Metadata}

  # ============================================================================
  # Cowboy HTTP Callbacks
  # ============================================================================

  @impl :cowboy_websocket
  def init(req, state) do
    # Upgrade to WebSocket
    {:cowboy_websocket, req, state}
  end

  # ============================================================================
  # Cowboy WebSocket Callbacks
  # ============================================================================

  @impl :cowboy_websocket
  def websocket_init({handler, listener_pid}) do
    # Get connection info
    remote_addr = get_peer_addr()
    local_addr = get_local_addr()

    # Notify listener about new connection
    send(listener_pid, {:connection_accepted, self()})

    state = %{
      handler: handler,
      remote_addr: remote_addr,
      local_addr: local_addr
    }

    {:ok, state}
  end

  @impl :cowboy_websocket
  def websocket_handle({:text, data}, state) do
    send_packet(data, state)
    {:ok, state}
  end

  def websocket_handle({:binary, data}, state) do
    send_packet(data, state)
    {:ok, state}
  end

  def websocket_handle(_frame, state) do
    # Ignore ping, pong, and other control frames
    {:ok, state}
  end

  @impl :cowboy_websocket
  def websocket_info(_info, state) do
    {:ok, state}
  end

  @impl :cowboy_websocket
  def terminate(_reason, _req, _state) do
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp send_packet(data, state) do
    packet = %IncomingPacket{
      data: data,
      source: %Source{
        transport: :websocket,
        remote_addr: state.remote_addr,
        local_addr: state.local_addr,
        connection: self()
      },
      metadata: %Metadata{
        timestamp: System.monotonic_time(),
        connection_id: inspect(self())
      }
    }

    send(state.handler, {:incoming_packet, packet})
  end

  defp get_peer_addr do
    # Cowboy stores connection info in process dictionary
    case :cowboy_req.peer(:cowboy_req) do
      {ip, port} -> {ip, port}
      _ -> {{0, 0, 0, 0}, 0}
    end
  rescue
    _ -> {{0, 0, 0, 0}, 0}
  end

  defp get_local_addr do
    # Get local socket info from process
    case Process.get(:socket) do
      nil ->
        {{0, 0, 0, 0}, 0}

      socket ->
        case :inet.sockname(socket) do
          {:ok, {ip, port}} -> {ip, port}
          _ -> {{0, 0, 0, 0}, 0}
        end
    end
  rescue
    _ -> {{0, 0, 0, 0}, 0}
  end
end
