defmodule ParrotTransport.TlsListener do
  @moduledoc """
  TLS listener state machine for accepting secure inbound connections.

  States:
  - :listening - Accepting connections via acceptor pool
  - :stopping - Graceful shutdown

  This module manages a TLS listen socket and spawns Connection processes
  for each accepted client connection. Uses an acceptor pool pattern for
  concurrent connection acceptance with SSL/TLS encryption.
  """

  @behaviour :gen_statem
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
            listen_socket: :ssl.sslsocket() | nil,
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
  Starts a TLS listener.
  """
  @spec start_link(ListenerConfig.t(), pid()) :: :gen_statem.start_ret()
  def start_link(%ListenerConfig{transport: :tls} = config, handler_pid) do
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

  # ============================================================================
  # :gen_statem callbacks
  # ============================================================================

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
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

        Logger.info("[TlsListener] Listening on #{format_addr(local_ip)}:#{local_port}")

        {:ok, :listening, data}

      {:error, reason} ->
        Logger.error("[TlsListener] Failed to bind socket: #{inspect(reason)}")
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
        spawn_acceptor(data.listen_socket, data, self())
      end

    {:keep_state, %{data | acceptors: acceptors}}
  end

  def listening(:info, {:connection_accepted, conn_pid}, data) do
    # Monitor the connection process
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
    # Close listen socket
    if data.listen_socket do
      :ssl.close(data.listen_socket)
    end

    # Kill all acceptors
    for acceptor <- data.acceptors do
      Process.exit(acceptor, :shutdown)
    end

    # Close all connections
    for {conn_pid, _ref} <- data.connections do
      Process.exit(conn_pid, :shutdown)
    end

    Logger.info("[TlsListener] Stopped")
    {:stop, :normal}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_listen_socket(%ListenerConfig{} = config) do
    # Validate certificate and key files exist
    with :ok <- validate_cert_file(config.certfile),
         :ok <- validate_cert_file(config.keyfile) do
      # Build TLS options
      tcp_opts = [
        :binary,
        {:active, false},
        {:reuseaddr, true},
        {:ip, config.ip},
        {:certfile, to_charlist(config.certfile)},
        {:keyfile, to_charlist(config.keyfile)}
      ]

      # Add CA cert file if provided
      ssl_opts =
        if config.cacertfile do
          tcp_opts ++ [{:cacertfile, to_charlist(config.cacertfile)}]
        else
          tcp_opts
        end

      # Create SSL listen socket
      case :ssl.listen(config.port, ssl_opts) do
        {:ok, ssl_socket} ->
          {:ok, {ip, port}} = :ssl.sockname(ssl_socket)
          {:ok, ssl_socket, ip, port}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_cert_file(nil), do: {:error, :missing_cert_file}

  defp validate_cert_file(path) when is_binary(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, {:cert_not_found, path}}
    end
  end

  defp spawn_acceptor(listen_socket, data, listener_pid) do
    spawn_link(fn -> acceptor_loop(listen_socket, data, listener_pid) end)
  end

  defp acceptor_loop(listen_socket, data, listener_pid) do
    case :ssl.transport_accept(listen_socket) do
      {:ok, client_socket} ->
        # Perform SSL handshake
        case :ssl.handshake(client_socket) do
          {:ok, ssl_socket} ->
            # Get peer information
            {:ok, {remote_ip, remote_port}} = :ssl.peername(ssl_socket)
            {:ok, {local_ip, local_port}} = :ssl.sockname(ssl_socket)

            # Start connection process with config
            conn_pid =
              Connection.start_tls(
                ssl_socket,
                {remote_ip, remote_port},
                {local_ip, local_port},
                data
              )

            # Transfer socket ownership to connection process
            :ssl.controlling_process(ssl_socket, conn_pid)

            # Notify listener about new connection
            send(listener_pid, {:connection_accepted, conn_pid})

          {:error, reason} ->
            Logger.warning("[TlsListener] SSL handshake failed: #{inspect(reason)}")
            :ssl.close(client_socket)
        end

      {:error, :closed} ->
        # Listen socket closed, acceptor exits
        :ok

      {:error, reason} ->
        Logger.error("[TlsListener] Accept error: #{inspect(reason)}")
        Process.sleep(100)
    end

    # Continue accepting (tail recursion)
    acceptor_loop(listen_socket, data, listener_pid)
  end

  defp format_addr({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_addr({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
end
