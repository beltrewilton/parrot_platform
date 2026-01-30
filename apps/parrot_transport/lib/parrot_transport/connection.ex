defmodule ParrotTransport.Connection do
  @moduledoc """
  TCP/TLS connection state machine with Content-Length framing.

  States:
  - :connecting - Establishing connection (TCP outbound only)
  - :connected - Active connection, receiving and sending data
  - :reconnecting - Connection lost, attempting to reconnect (TCP outbound only)
  - :stopping - Graceful shutdown

  This module manages TCP and TLS connections with automatic reconnection
  (for outbound TCP), message framing via Content-Length, and error handling.
  Both TCP and TLS connections use the same gen_statem architecture for
  consistent state management and queryability.
  """

  @behaviour :gen_statem
  require Logger

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket, Source, Metadata}
  alias ParrotTransport.Framing.ContentLength

  defmodule Data do
    @enforce_keys [:config, :handler, :transport]
    defstruct [
      :config,
      :handler,
      :socket,
      :local_ip,
      :local_port,
      :framing,
      :reconnect_timer,
      :tls_info,
      transport: :tcp,
      reconnect_attempts: 0,
      max_reconnect_attempts: :infinity,
      reconnect_interval: 1000,
      packets_received: 0,
      packets_sent: 0,
      errors: 0
    ]

    @type t :: %__MODULE__{
            config: ListenerConfig.t(),
            handler: pid(),
            socket: :gen_tcp.socket() | :ssl.sslsocket() | nil,
            local_ip: :inet.ip_address() | nil,
            local_port: :inet.port_number() | nil,
            framing: ContentLength.t() | nil,
            reconnect_timer: reference() | nil,
            tls_info: map() | nil,
            transport: :tcp | :tls,
            reconnect_attempts: non_neg_integer(),
            max_reconnect_attempts: non_neg_integer() | :infinity,
            reconnect_interval: non_neg_integer(),
            packets_received: non_neg_integer(),
            packets_sent: non_neg_integer(),
            errors: non_neg_integer()
          }
  end

  # ============================================================================
  # API
  # ============================================================================

  @doc """
  Starts a TCP connection to the specified remote endpoint (outbound).
  """
  @spec start_link(ListenerConfig.t(), pid()) :: :gen_statem.start_ret()
  def start_link(%ListenerConfig{transport: :tcp} = config, handler_pid) do
    opts = if config.name, do: [name: config.name], else: []
    :gen_statem.start_link(__MODULE__, {:outbound, config, handler_pid}, opts)
  end

  @doc """
  Starts a Connection with an already-connected TCP socket (inbound).
  Used by TcpListener when accepting connections.
  """
  @spec start_link_with_socket(ListenerConfig.t(), pid(), :gen_tcp.socket()) ::
          :gen_statem.start_ret()
  def start_link_with_socket(%ListenerConfig{transport: :tcp} = config, handler_pid, socket) do
    :gen_statem.start_link(__MODULE__, {:inbound_tcp, config, handler_pid, socket}, [])
  end

  @doc """
  Starts a Connection with an already-connected TLS/SSL socket (inbound).
  Used by TlsListener when accepting connections.

  This uses gen_statem for consistent state management with TCP connections.
  """
  @spec start_link_with_ssl_socket(ListenerConfig.t(), pid(), :ssl.sslsocket()) ::
          :gen_statem.start_ret()
  def start_link_with_ssl_socket(%ListenerConfig{transport: :tls} = config, handler_pid, ssl_socket) do
    :gen_statem.start_link(__MODULE__, {:inbound_tls, config, handler_pid, ssl_socket}, [])
  end

  @doc """
  Sends data through the connection.
  """
  @spec send_data(:gen_statem.server_ref(), binary()) :: :ok
  def send_data(conn, data) do
    :gen_statem.cast(conn, {:send_data, data})
  end

  @doc """
  Stops the connection gracefully.
  """
  @spec stop(:gen_statem.server_ref()) :: :ok
  def stop(conn) do
    :gen_statem.call(conn, :stop)
  end

  @doc """
  Gets the current state of the connection.
  """
  @spec get_state(:gen_statem.server_ref()) :: :connecting | :connected | :reconnecting | :stopping
  def get_state(conn) do
    :gen_statem.call(conn, :get_state)
  end

  @doc """
  DEPRECATED: Use `start_link_with_ssl_socket/3` instead.

  This legacy function spawns a simple process for TLS handling.
  The new gen_statem-based function provides consistent state management.
  """
  @deprecated "Use start_link_with_ssl_socket/3 instead"
  @spec start_tls(:ssl.sslsocket(), tuple(), tuple(), Data.t()) :: pid()
  def start_tls(ssl_socket, remote_addr, local_addr, data) do
    spawn_link(fn ->
      tls_connection_loop(ssl_socket, remote_addr, local_addr, data.handler, data.config, %ContentLength{})
    end)
  end

  # ============================================================================
  # :gen_statem callbacks
  # ============================================================================

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init({:outbound, config, handler_pid}) do
    # Outbound TCP connection - will attempt to connect
    data = %Data{
      config: config,
      handler: handler_pid,
      transport: :tcp,
      framing: %ContentLength{}
    }

    {:ok, :connecting, data}
  end

  def init({:inbound_tcp, config, handler_pid, socket}) do
    # Inbound TCP connection - socket already connected
    {:ok, {local_ip, local_port}} = :inet.sockname(socket)

    data = %Data{
      config: config,
      handler: handler_pid,
      transport: :tcp,
      socket: socket,
      local_ip: local_ip,
      local_port: local_port,
      framing: %ContentLength{}
    }

    Logger.info("[Connection] Accepted TCP connection from #{format_addr(config.ip)}:#{config.port}")

    {:ok, :connected, data}
  end

  def init({:inbound_tls, config, handler_pid, ssl_socket}) do
    # Inbound TLS connection - socket already connected and handshake complete
    {:ok, {local_ip, local_port}} = :ssl.sockname(ssl_socket)
    {:ok, {remote_ip, remote_port}} = :ssl.peername(ssl_socket)

    # Get TLS info for metadata
    tls_info = get_tls_info(ssl_socket)

    data = %Data{
      config: %{config | ip: remote_ip, port: remote_port},
      handler: handler_pid,
      transport: :tls,
      socket: ssl_socket,
      local_ip: local_ip,
      local_port: local_port,
      tls_info: tls_info,
      framing: %ContentLength{}
    }

    Logger.info("[Connection] Accepted TLS connection from #{format_addr(remote_ip)}:#{remote_port}")

    # Note: Socket will be set to active mode by caller after controlling_process transfer
    {:ok, :connected, data}
  end

  # ============================================================================
  # State: :connecting
  # ============================================================================

  def connecting(:enter, _old_state, _data) do
    # Attempt TCP connection
    send(self(), :attempt_connect)
    :keep_state_and_data
  end

  def connecting(:info, :attempt_connect, data) do
    opts = [
      :binary,
      {:active, true},
      {:packet, 0},
      {:recbuf, data.config.buffer_size},
      {:sndbuf, data.config.buffer_size}
    ]

    case :gen_tcp.connect(data.config.ip, data.config.port, opts, 5000) do
      {:ok, socket} ->
        {:ok, {local_ip, local_port}} = :inet.sockname(socket)

        new_data = %{data |
          socket: socket,
          local_ip: local_ip,
          local_port: local_port,
          reconnect_attempts: 0
        }

        Logger.info("[Connection] Connected to #{format_addr(data.config.ip)}:#{data.config.port}")

        {:next_state, :connected, new_data}

      {:error, reason} ->
        Logger.warning("[Connection] Failed to connect: #{inspect(reason)}")
        {:next_state, :reconnecting, data}
    end
  end

  def connecting({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def connecting({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :connecting}]}
  end

  # ============================================================================
  # State: :connected
  # ============================================================================

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected(:info, {:tcp, socket, binary_data}, %{socket: socket} = data) do
    if data.config.trace do
      Logger.info("[SIP TRACE] TCP recv from #{format_addr(data.config.ip)}:#{data.config.port}\n#{binary_data}")
    end

    # Process incoming data through framing
    case ContentLength.process(data.framing, binary_data) do
      {:ok, messages, new_framing} ->
        # Create packets for each complete message
        for message <- messages do
          packet = %IncomingPacket{
            data: message,
            source: %Source{
              transport: :tcp,
              remote_addr: {data.config.ip, data.config.port},
              local_addr: {data.local_ip, data.local_port},
              connection: self()
            },
            metadata: %Metadata{
              timestamp: System.monotonic_time(),
              connection_id: inspect(self())
            }
          }

          send(data.handler, {:incoming_packet, packet})
        end

        new_data = %{data |
          framing: new_framing,
          packets_received: data.packets_received + length(messages)
        }

        {:keep_state, new_data}

      {:error, reason} ->
        Logger.error("[Connection] Framing error: #{inspect(reason)}")
        new_data = %{data | errors: data.errors + 1}
        {:keep_state, new_data}
    end
  end

  def connected(:info, {:tcp_closed, socket}, %{socket: socket} = data) do
    Logger.warning("[Connection] Connection closed")
    :gen_tcp.close(socket)
    {:next_state, :reconnecting, %{data | socket: nil, framing: %ContentLength{}}}
  end

  def connected(:info, {:tcp_error, socket, reason}, %{socket: socket} = data) do
    Logger.error("[Connection] TCP error: #{inspect(reason)}")
    :gen_tcp.close(socket)
    {:next_state, :reconnecting, %{data | socket: nil, framing: %ContentLength{}, errors: data.errors + 1}}
  end

  # TLS message handlers
  def connected(:info, {:ssl, socket, binary_data}, %{socket: socket, transport: :tls} = data) do
    if data.config.trace do
      Logger.info("[SIP TRACE] TLS recv from #{format_addr(data.config.ip)}:#{data.config.port}\n#{binary_data}")
    end

    # Process incoming data through framing
    case ContentLength.process(data.framing, binary_data) do
      {:ok, messages, new_framing} ->
        # Create packets for each complete message
        for message <- messages do
          packet = %IncomingPacket{
            data: message,
            source: %Source{
              transport: :tls,
              remote_addr: {data.config.ip, data.config.port},
              local_addr: {data.local_ip, data.local_port},
              connection: self()
            },
            metadata: %Metadata{
              timestamp: System.monotonic_time(),
              connection_id: inspect(self()),
              tls_info: data.tls_info
            }
          }

          send(data.handler, {:incoming_packet, packet})
        end

        new_data = %{data |
          framing: new_framing,
          packets_received: data.packets_received + length(messages)
        }

        {:keep_state, new_data}

      {:error, reason} ->
        Logger.error("[Connection] TLS framing error: #{inspect(reason)}")
        new_data = %{data | errors: data.errors + 1}
        {:keep_state, new_data}
    end
  end

  def connected(:info, {:ssl_closed, socket}, %{socket: socket, transport: :tls} = data) do
    Logger.warning("[Connection] TLS connection closed")
    :ssl.close(socket)
    # TLS connections don't reconnect - just stop
    {:next_state, :stopping, %{data | socket: nil}}
  end

  def connected(:info, {:ssl_error, socket, reason}, %{socket: socket, transport: :tls} = data) do
    Logger.error("[Connection] TLS error: #{inspect(reason)}")
    :ssl.close(socket)
    {:next_state, :stopping, %{data | socket: nil, errors: data.errors + 1}}
  end

  # Send data - dispatch based on transport type
  def connected(:cast, {:send_data, data_to_send}, %{transport: :tcp} = data) do
    if data.config.trace do
      Logger.info("[SIP TRACE] TCP send to #{format_addr(data.config.ip)}:#{data.config.port}\n#{data_to_send}")
    end

    case :gen_tcp.send(data.socket, data_to_send) do
      :ok ->
        new_data = %{data | packets_sent: data.packets_sent + 1}
        {:keep_state, new_data}

      {:error, reason} ->
        Logger.error("[Connection] TCP send failed: #{inspect(reason)}")
        :gen_tcp.close(data.socket)
        new_data = %{data | socket: nil, framing: %ContentLength{}, errors: data.errors + 1}
        {:next_state, :reconnecting, new_data}
    end
  end

  def connected(:cast, {:send_data, data_to_send}, %{transport: :tls} = data) do
    if data.config.trace do
      Logger.info("[SIP TRACE] TLS send to #{format_addr(data.config.ip)}:#{data.config.port}\n#{data_to_send}")
    end

    case :ssl.send(data.socket, data_to_send) do
      :ok ->
        new_data = %{data | packets_sent: data.packets_sent + 1}
        {:keep_state, new_data}

      {:error, reason} ->
        Logger.error("[Connection] TLS send failed: #{inspect(reason)}")
        :ssl.close(data.socket)
        {:next_state, :stopping, %{data | socket: nil, errors: data.errors + 1}}
    end
  end

  def connected({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def connected({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :connected}]}
  end

  # ============================================================================
  # State: :reconnecting
  # ============================================================================

  def reconnecting(:enter, _old_state, data) do
    # Schedule reconnection attempt
    timer = Process.send_after(self(), :reconnect_attempt, data.reconnect_interval)

    new_data = %{data |
      reconnect_timer: timer,
      reconnect_attempts: data.reconnect_attempts + 1
    }

    Logger.info("[Connection] Reconnecting in #{data.reconnect_interval}ms (attempt #{new_data.reconnect_attempts})")

    {:keep_state, new_data}
  end

  def reconnecting(:info, :reconnect_attempt, data) do
    # Check if we should give up
    if data.max_reconnect_attempts != :infinity and data.reconnect_attempts >= data.max_reconnect_attempts do
      Logger.error("[Connection] Max reconnect attempts reached, giving up")
      {:stop, :max_reconnect_attempts_reached}
    else
      {:next_state, :connecting, %{data | reconnect_timer: nil}}
    end
  end

  def reconnecting({:call, from}, :stop, data) do
    if data.reconnect_timer do
      Process.cancel_timer(data.reconnect_timer)
    end

    {:next_state, :stopping, %{data | reconnect_timer: nil}, [{:reply, from, :ok}]}
  end

  def reconnecting({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :reconnecting}]}
  end

  # ============================================================================
  # State: :stopping
  # ============================================================================

  def stopping(:enter, _old_state, data) do
    if data.socket do
      close_socket(data.transport, data.socket)
    end

    Logger.info("[Connection] Stopped (#{data.transport})")
    {:stop, :normal}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp format_addr(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp format_addr(ip), do: inspect(ip)

  defp close_socket(:tcp, socket), do: :gen_tcp.close(socket)
  defp close_socket(:tls, socket), do: :ssl.close(socket)

  # ============================================================================
  # TLS Connection Loop (DEPRECATED - Legacy Simple Process)
  # ============================================================================

  defp tls_connection_loop(ssl_socket, remote_addr, local_addr, handler, config, framing) do
    # Set socket to active mode to receive messages
    :ssl.setopts(ssl_socket, [{:active, :once}])

    receive do
      {:ssl, ^ssl_socket, data} ->
        if config.trace do
          {remote_ip, remote_port} = remote_addr
          Logger.info("[SIP TRACE] TLS recv from #{format_addr(remote_ip)}:#{remote_port}\n#{data}")
        end

        # Process received data through framing
        case ContentLength.process(framing, data) do
          {:ok, messages, new_framing} when is_list(messages) ->
            # Send each complete message to handler
            for message <- messages do
              source = %Source{
                transport: :tls,
                remote_addr: remote_addr,
                local_addr: local_addr,
                connection: self()
              }

              metadata = %Metadata{
                timestamp: System.system_time(:millisecond),
                connection_id: inspect(self()),
                tls_info: get_tls_info(ssl_socket)
              }

              packet = %IncomingPacket{
                data: message,
                source: source,
                metadata: metadata
              }

              send(handler, {:incoming_packet, packet})
            end

            # Continue with updated framing state
            tls_connection_loop(ssl_socket, remote_addr, local_addr, handler, config, new_framing)

          {:error, reason} ->
            Logger.error("[TlsConnection] Framing error: #{inspect(reason)}")
            :ssl.close(ssl_socket)
        end

      {:"$gen_cast", {:send_data, data_to_send}} ->
        # Handle send from TransportHandler (comes via :gen_statem.cast)
        # Log trace if enabled
        Logger.debug("[TlsConnection] Sending #{byte_size(data_to_send)} bytes, trace=#{config.trace}")
        if config.trace do
          {remote_ip, remote_port} = remote_addr
          Logger.info("[SIP TRACE] TLS send to #{format_addr(remote_ip)}:#{remote_port}\n#{data_to_send}")
        end

        case :ssl.send(ssl_socket, data_to_send) do
          :ok ->
            # Continue loop after successful send
            tls_connection_loop(ssl_socket, remote_addr, local_addr, handler, config, framing)

          {:error, reason} ->
            Logger.error("[TlsConnection] Send failed: #{inspect(reason)}")
            :ssl.close(ssl_socket)
        end

      {:ssl_closed, ^ssl_socket} ->
        Logger.debug("[TlsConnection] Socket closed")
        :ok

      {:ssl_error, ^ssl_socket, reason} ->
        Logger.error("[TlsConnection] Socket error: #{inspect(reason)}")
        :ssl.close(ssl_socket)
    end
  end

  defp get_tls_info(ssl_socket) do
    case :ssl.connection_information(ssl_socket) do
      {:ok, info} ->
        %{
          protocol: Keyword.get(info, :protocol),
          cipher_suite: Keyword.get(info, :cipher_suite),
          sni_hostname: Keyword.get(info, :sni_hostname)
        }

      {:error, _} ->
        nil
    end
  end
end
