defmodule ParrotTransport.WebsocketListener do
  @moduledoc """
  WebSocket listener state machine for accepting WebSocket connections.

  States:
  - :listening - Accepting WebSocket connections via Cowboy HTTP server
  - :stopping - Graceful shutdown

  This module manages a Cowboy HTTP server that upgrades connections to
  WebSocket and forwards received messages to a handler process.
  """

  @behaviour :gen_statem
  require Logger

  alias ParrotTransport.Types.ListenerConfig

  defmodule Data do
    @enforce_keys [:config, :handler]
    defstruct [
      :config,
      :handler,
      :http_pid,
      :http_ref,
      :local_ip,
      :local_port,
      connections: %{},
      connections_accepted: 0
    ]

    @type t :: %__MODULE__{
            config: ListenerConfig.t(),
            handler: pid(),
            http_pid: pid() | nil,
            http_ref: reference() | nil,
            local_ip: :inet.ip_address() | nil,
            local_port: :inet.port_number() | nil,
            connections: %{pid() => reference()},
            connections_accepted: non_neg_integer()
          }
  end

  # ============================================================================
  # API
  # ============================================================================

  @doc """
  Starts a WebSocket listener.
  """
  @spec start_link(ListenerConfig.t(), pid()) :: :gen_statem.start_ret()
  def start_link(%ListenerConfig{transport: :websocket} = config, handler_pid) do
    opts = if config.name, do: [name: config.name], else: []
    :gen_statem.start_link(__MODULE__, {config, handler_pid}, opts)
  end

  @doc """
  Gets the local address the listener is bound to.
  """
  @spec get_local_address(:gen_statem.server_ref()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}}
  def get_local_address(listener) do
    :gen_statem.call(listener, :get_local_address)
  end

  @doc """
  Stops the listener gracefully.
  """
  @spec stop(:gen_statem.server_ref()) :: :ok
  def stop(listener) do
    :gen_statem.call(listener, :stop)
  end

  @doc """
  Gets the current state of the listener.
  """
  @spec get_state(:gen_statem.server_ref()) :: :listening | :stopping
  def get_state(listener) do
    :gen_statem.call(listener, :get_state)
  end

  # ============================================================================
  # :gen_statem callbacks
  # ============================================================================

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init({config, handler_pid}) do
    # Create HTTP server for WebSocket upgrades
    case start_cowboy(config, handler_pid, self()) do
      {:ok, http_ref, http_pid, local_ip, local_port} ->
        data = %Data{
          config: config,
          handler: handler_pid,
          http_pid: http_pid,
          http_ref: http_ref,
          local_ip: local_ip,
          local_port: local_port
        }

        Logger.info("[WebsocketListener] Listening on #{format_addr(local_ip)}:#{local_port}")

        {:ok, :listening, data}

      {:error, reason} ->
        Logger.error("[WebsocketListener] Failed to start HTTP server: #{inspect(reason)}")
        {:stop, {:bind_error, reason}}
    end
  end

  # ============================================================================
  # State: :listening
  # ============================================================================

  def listening(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def listening(:info, {:connection_accepted, conn_pid}, data) do
    # Monitor the WebSocket connection process
    ref = Process.monitor(conn_pid)
    new_connections = Map.put(data.connections, conn_pid, ref)

    new_data = %{
      data
      | connections: new_connections,
        connections_accepted: data.connections_accepted + 1
    }

    {:keep_state, new_data}
  end

  def listening(:info, {:DOWN, ref, :process, pid, _reason}, data) do
    # WebSocket connection process died, clean up
    if Map.get(data.connections, pid) == ref do
      new_connections = Map.delete(data.connections, pid)
      {:keep_state, %{data | connections: new_connections}}
    else
      :keep_state_and_data
    end
  end

  def listening({:call, from}, :get_local_address, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, {data.local_ip, data.local_port}}}]}
  end

  def listening({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def listening({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :listening}]}
  end

  # ============================================================================
  # State: :stopping
  # ============================================================================

  def stopping(:enter, _old_state, data) do
    # Stop Cowboy HTTP server using the reference
    if data.http_ref do
      :cowboy.stop_listener(data.http_ref)
    end

    # Close all WebSocket connections
    for {conn_pid, _ref} <- data.connections do
      Process.exit(conn_pid, :shutdown)
    end

    Logger.info("[WebsocketListener] Stopped")
    {:stop, :normal}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_cowboy(%ListenerConfig{} = config, handler, listener_pid) do
    # Create Cowboy dispatch for WebSocket
    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {"/", ParrotTransport.WebsocketHandler, {handler, listener_pid}}
         ]}
      ])

    # Start Cowboy HTTP server
    ref = make_ref()

    transport_opts = [
      {:ip, config.ip},
      {:port, config.port}
    ]

    protocol_opts = %{
      env: %{dispatch: dispatch}
    }

    case :cowboy.start_clear(ref, transport_opts, protocol_opts) do
      {:ok, pid} ->
        # Get the actual bound port
        {local_ip, local_port} = :ranch.get_addr(ref)
        {:ok, ref, pid, local_ip, local_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_addr({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_addr({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
end
