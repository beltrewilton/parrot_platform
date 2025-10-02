defmodule ParrotTransport.TcpListener do
  @moduledoc """
  TCP listener state machine for accepting inbound connections.

  States:
  - :listening - Accepting connections via acceptor pool
  - :stopping - Graceful shutdown

  This module manages a TCP listen socket and spawns Connection processes
  for each accepted client connection. Uses an acceptor pool pattern for
  concurrent connection acceptance.
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]
  require Logger

  alias ParrotTransport.Types.ListenerConfig
  alias ParrotTransport.Connection

  defmodule Data do
    @enforce_keys [:config, :handler]
    defstruct [
      :config,
      :handler,
      :listen_socket,
      :local_ip,
      :local_port,
      acceptors: [],
      connections: %{},
      accept_pool_size: 10,
      connections_accepted: 0
    ]

    @type t :: %__MODULE__{
            config: ListenerConfig.t(),
            handler: pid(),
            listen_socket: :gen_tcp.socket() | nil,
            local_ip: :inet.ip_address() | nil,
            local_port: :inet.port_number() | nil,
            acceptors: [pid()],
            connections: %{pid() => reference()},
            accept_pool_size: non_neg_integer(),
            connections_accepted: non_neg_integer()
          }
  end

  # ============================================================================
  # API
  # ============================================================================

  @doc """
  Starts a TCP listener.
  """
  @spec start_link(ListenerConfig.t(), pid()) :: GenStateMachine.on_start()
  def start_link(%ListenerConfig{transport: :tcp} = config, handler_pid) do
    opts = if config.name, do: [name: config.name], else: []
    GenStateMachine.start_link(__MODULE__, {config, handler_pid}, opts)
  end

  @doc """
  Gets the local address the listener is bound to.
  """
  @spec get_local_address(GenStateMachine.server_ref()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}}
  def get_local_address(listener) do
    GenStateMachine.call(listener, :get_local_address)
  end

  @doc """
  Stops the listener gracefully.
  """
  @spec stop(GenStateMachine.server_ref()) :: :ok
  def stop(listener) do
    GenStateMachine.call(listener, :stop)
  end

  # ============================================================================
  # gen_statem callbacks
  # ============================================================================

  @impl GenStateMachine
  def init({config, handler_pid}) do
    # Create listen socket synchronously for immediate error feedback
    case create_listen_socket(config) do
      {:ok, listen_socket, local_ip, local_port} ->
        data = %Data{
          config: config,
          handler: handler_pid,
          listen_socket: listen_socket,
          local_ip: local_ip,
          local_port: local_port,
          accept_pool_size: config.accept_pool_size
        }

        Logger.info("[TcpListener] Listening on #{format_addr(local_ip)}:#{local_port}")

        {:ok, :listening, data}

      {:error, reason} ->
        Logger.error("[TcpListener] Failed to bind socket: #{inspect(reason)}")
        {:stop, {:bind_error, reason}}
    end
  end

  # ============================================================================
  # State: :listening
  # ============================================================================

  def listening(:enter, _old_state, data) do
    # Spawn acceptor pool
    acceptors =
      for _ <- 1..data.accept_pool_size do
        spawn_acceptor(data.listen_socket, data.handler, self())
      end

    {:keep_state, %{data | acceptors: acceptors}}
  end

  def listening(:info, {:connection_accepted, conn_pid}, data) do
    # Monitor the connection process
    ref = Process.monitor(conn_pid)
    new_connections = Map.put(data.connections, conn_pid, ref)

    new_data = %{data |
      connections: new_connections,
      connections_accepted: data.connections_accepted + 1
    }

    {:keep_state, new_data}
  end

  def listening(:info, {:DOWN, ref, :process, pid, _reason}, data) do
    # Connection process died, clean up
    if Map.get(data.connections, pid) == ref do
      new_connections = Map.delete(data.connections, pid)
      {:keep_state, %{data | connections: new_connections}}
    else
      # Might be an acceptor that died - this is logged but we don't track them
      :keep_state_and_data
    end
  end

  def listening({:call, from}, :get_local_address, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, {data.local_ip, data.local_port}}}]}
  end

  def listening({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  # ============================================================================
  # State: :stopping
  # ============================================================================

  def stopping(:enter, _old_state, data) do
    # Close listen socket (this will cause acceptors to exit)
    if data.listen_socket do
      :gen_tcp.close(data.listen_socket)
    end

    # Stop all active connections gracefully
    for {conn_pid, _ref} <- data.connections do
      Connection.stop(conn_pid)
    end

    Logger.info("[TcpListener] Stopped")
    {:stop, :normal}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_listen_socket(config) do
    opts = [
      :binary,
      {:ip, config.ip},
      {:active, false},
      {:reuseaddr, true},
      {:backlog, 128},
      {:packet, 0}
    ]

    case :gen_tcp.listen(config.port, opts) do
      {:ok, listen_socket} ->
        {:ok, {actual_ip, actual_port}} = :inet.sockname(listen_socket)
        {:ok, listen_socket, actual_ip, actual_port}

      error ->
        error
    end
  end

  defp spawn_acceptor(listen_socket, handler, listener_pid) do
    spawn_link(fn -> acceptor_loop(listen_socket, handler, listener_pid) end)
  end

  defp acceptor_loop(listen_socket, handler, listener_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Create Connection config from socket info
        {:ok, {remote_ip, remote_port}} = :inet.peername(client_socket)

        # Spawn Connection process to handle this client
        # Note: Connection needs to be adapted to accept an already-connected socket
        case spawn_connection(client_socket, remote_ip, remote_port, handler) do
          {:ok, conn_pid} ->
            # Transfer socket ownership to Connection process
            :ok = :gen_tcp.controlling_process(client_socket, conn_pid)

            # Set socket to active mode so Connection receives messages
            :inet.setopts(client_socket, [{:active, true}])

            # Notify listener about new connection
            send(listener_pid, {:connection_accepted, conn_pid})

            # Continue accepting
            acceptor_loop(listen_socket, handler, listener_pid)

          {:error, reason} ->
            Logger.error("[TcpListener] Failed to spawn connection: #{inspect(reason)}")
            :gen_tcp.close(client_socket)
            acceptor_loop(listen_socket, handler, listener_pid)
        end

      {:error, :closed} ->
        # Listen socket closed, stop accepting
        :ok

      {:error, reason} ->
        Logger.error("[TcpListener] Accept failed: #{inspect(reason)}")
        # Brief pause before retry to avoid tight loop on persistent errors
        Process.sleep(100)
        acceptor_loop(listen_socket, handler, listener_pid)
    end
  end

  defp spawn_connection(client_socket, remote_ip, remote_port, handler) do
    # Create a config for the accepted connection
    config = %ListenerConfig{
      transport: :tcp,
      ip: remote_ip,
      port: remote_port
    }

    # Start Connection in "already connected" mode
    # We need to modify Connection to support this
    Connection.start_link_with_socket(config, handler, client_socket)
  end

  defp format_addr(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp format_addr(ip), do: inspect(ip)
end
