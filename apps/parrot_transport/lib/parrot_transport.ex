defmodule ParrotTransport do
  @moduledoc """
  Public API for protocol-agnostic transport layer.

  This module provides the primary interface for starting listeners,
  registering handlers, and sending/receiving data over UDP, TCP, TLS, and WebSocket.

  All transports are completely protocol-agnostic and deliver raw binary
  packets to registered handlers via the IncomingPacket struct.
  """

  alias ParrotTransport.Types.ListenerConfig

  @doc """
  Starts a UDP transport listener under the application's supervisor.

  This function only supports UDP. For TCP, TLS, or WebSocket listeners,
  use the dedicated functions (`start_tcp_listener/2`, `start_tls_listener/2`,
  or `start_websocket_listener/2`) which require a handler PID.

  ## Parameters
    * `config` - A `ListenerConfig` struct with `transport: :udp`

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, :use_start_tcp_listener}` - If TCP transport specified
    * `{:error, :use_start_tls_listener}` - If TLS transport specified
    * `{:error, :use_start_websocket_listener}` - If WebSocket transport specified
    * `{:error, :unsupported_transport}` - If unknown transport specified
    * `{:error, reason}` - Other startup failure reason

  ## Examples

      # Start UDP listener on port 5060
      config = %ListenerConfig{transport: :udp, port: 5060}
      {:ok, listener} = ParrotTransport.start_listener(config)
      :ok = ParrotTransport.register_handler(listener, self())

      # Start UDP listener on random port (port 0)
      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, listener} = ParrotTransport.start_listener(config)
      {:ok, {ip, port}} = ParrotTransport.get_local_address(listener)
  """
  @spec start_listener(ListenerConfig.t()) :: {:ok, pid()} | {:error, term()}
  def start_listener(%ListenerConfig{} = config) do
    case config.transport do
      :udp ->
        start_supervised_listener(ParrotTransport.UdpListener, config)

      :tcp ->
        {:error, :use_start_tcp_listener}

      :tls ->
        {:error, :use_start_tls_listener}

      :websocket ->
        {:error, :use_start_websocket_listener}

      _other ->
        {:error, :unsupported_transport}
    end
  end

  @doc """
  Starts a TCP listener with a specified handler.

  The listener will accept incoming TCP connections and spawn a Connection
  process for each client. Received data is automatically framed using
  Content-Length headers and delivered as complete messages to the handler.

  ## Parameters
    * `config` - A `ListenerConfig` struct with `transport: :tcp`
    * `handler_pid` - Process to receive `{:incoming_packet, IncomingPacket.t()}` messages

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, :eaddrinuse}` - Port already in use
    * `{:error, reason}` - Other startup failure reason

  ## Examples

      # Start TCP listener on port 5060
      config = %ListenerConfig{transport: :tcp, port: 5060}
      {:ok, listener} = ParrotTransport.start_tcp_listener(config, self())

      # Wait for incoming connection and packet
      receive do
        {:incoming_packet, %IncomingPacket{data: data, source: source}} ->
          IO.puts("Received: \#{data}")
          IO.inspect(source.connection)  # Connection process PID
      end
  """
  @spec start_tcp_listener(ListenerConfig.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_tcp_listener(%ListenerConfig{transport: :tcp} = config, handler_pid) do
    start_supervised_tcp_listener(config, handler_pid)
  end

  @doc """
  Starts a TLS listener with a specified handler.

  The listener will accept incoming TLS connections after SSL handshake and
  spawn a Connection process for each client. Received data is automatically
  framed using Content-Length headers and delivered as complete messages.

  ## Parameters
    * `config` - A `ListenerConfig` struct with `transport: :tls`, including:
      - `certfile` - Path to PEM certificate file (required)
      - `keyfile` - Path to PEM private key file (required)
      - `cacertfile` - Path to CA certificate file (optional)
    * `handler_pid` - Process to receive `{:incoming_packet, IncomingPacket.t()}` messages

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, :eaddrinuse}` - Port already in use
    * `{:error, {:cert_not_found, path}}` - Certificate file not found
    * `{:error, reason}` - Other startup failure reason

  ## Examples

      # Start TLS listener on port 5061
      config = %ListenerConfig{
        transport: :tls,
        port: 5061,
        certfile: "priv/cert.pem",
        keyfile: "priv/key.pem"
      }
      {:ok, listener} = ParrotTransport.start_tls_listener(config, self())

      # Wait for incoming TLS connection
      receive do
        {:incoming_packet, %IncomingPacket{metadata: metadata}} ->
          IO.inspect(metadata.tls_info)  # TLS protocol, cipher suite, SNI
      end
  """
  @spec start_tls_listener(ListenerConfig.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_tls_listener(%ListenerConfig{transport: :tls} = config, handler_pid) do
    start_supervised_tls_listener(config, handler_pid)
  end

  @doc """
  Starts a WebSocket listener with a specified handler.

  The listener starts an HTTP server that upgrades connections to WebSocket.
  Both text and binary WebSocket frames are supported and delivered as
  IncomingPacket messages to the handler.

  ## Parameters
    * `config` - A `ListenerConfig` struct with `transport: :websocket`
    * `handler_pid` - Process to receive `{:incoming_packet, IncomingPacket.t()}` messages

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, :eaddrinuse}` - Port already in use
    * `{:error, reason}` - Other startup failure reason

  ## Examples

      # Start WebSocket listener on port 8080
      config = %ListenerConfig{transport: :websocket, port: 8080}
      {:ok, listener} = ParrotTransport.start_websocket_listener(config, self())

      # Wait for incoming WebSocket messages
      receive do
        {:incoming_packet, %IncomingPacket{data: data, source: source}} ->
          IO.puts("WebSocket message: \#{data}")
          # source.transport == :websocket
      end
  """
  @spec start_websocket_listener(ListenerConfig.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_websocket_listener(%ListenerConfig{transport: :websocket} = config, handler_pid) do
    start_supervised_websocket_listener(config, handler_pid)
  end

  @doc """
  Stops a running listener gracefully.

  This function works with UDP listeners. For TCP, TLS, and WebSocket listeners,
  use the module-specific stop functions or simply terminate the listener process.

  ## Parameters
    * `listener` - Listener PID or registered name

  ## Returns
    * `:ok`

  ## Examples

      config = %ListenerConfig{transport: :udp, port: 5060}
      {:ok, listener} = ParrotTransport.start_listener(config)
      :ok = ParrotTransport.stop_listener(listener)
  """
  @spec stop_listener(GenStateMachine.server_ref()) :: :ok
  def stop_listener(listener) do
    ParrotTransport.UdpListener.stop(listener)
  end

  @doc """
  Registers a handler process to receive incoming packets from a UDP listener.

  The handler will receive `{:incoming_packet, IncomingPacket.t()}` messages
  for each UDP datagram received. Multiple handlers can be registered and will
  all receive copies of incoming packets.

  Note: This function is only for UDP listeners. TCP, TLS, and WebSocket listeners
  require the handler PID to be passed when starting the listener.

  ## Parameters
    * `listener` - UDP listener PID or registered name
    * `handler_pid` - Process to receive `{:incoming_packet, IncomingPacket.t()}` messages

  ## Returns
    * `:ok`

  ## Examples

      config = %ListenerConfig{transport: :udp, port: 5060}
      {:ok, listener} = ParrotTransport.start_listener(config)
      :ok = ParrotTransport.register_handler(listener, self())

      # Wait for UDP packets
      receive do
        {:incoming_packet, %IncomingPacket{data: data, source: source}} ->
          IO.puts("Received UDP from \#{inspect(source.remote_addr)}: \#{data}")
      end
  """
  @spec register_handler(GenStateMachine.server_ref(), pid()) :: :ok
  def register_handler(listener, handler_pid) do
    ParrotTransport.UdpListener.register_handler(listener, handler_pid)
  end

  @doc """
  Sends data through a UDP transport.

  This function is for UDP listeners only. For TCP, TLS, and WebSocket connections,
  data is sent via the connection process (available in `IncomingPacket.source.connection`).

  ## Parameters
    * `listener` - UDP listener PID or registered name
    * `data` - Binary data to send
    * `destination` - Tuple of `{ip_tuple, port}` where ip_tuple is `{a, b, c, d}`

  ## Returns
    * `:ok`

  ## Examples

      config = %ListenerConfig{transport: :udp, port: 5060}
      {:ok, listener} = ParrotTransport.start_listener(config)

      # Send UDP packet
      destination = {{127, 0, 0, 1}, 5070}
      :ok = ParrotTransport.send_data(listener, "Hello UDP", destination)
  """
  @spec send_data(GenStateMachine.server_ref(), binary(), {tuple(), integer()}) :: :ok
  def send_data(listener, data, destination) do
    ParrotTransport.UdpListener.send_data(listener, data, destination)
  end

  @doc """
  Gets the local address a UDP listener is bound to.

  This is useful when starting a listener on port 0 (random port) to discover
  which port was actually assigned. For TCP, TLS, and WebSocket listeners,
  use the module-specific `get_local_address/1` functions.

  ## Parameters
    * `listener` - UDP listener PID or registered name

  ## Returns
    * `{:ok, {ip_tuple, port}}` where ip_tuple is `{a, b, c, d}`

  ## Examples

      config = %ListenerConfig{transport: :udp, port: 0}
      {:ok, listener} = ParrotTransport.start_listener(config)
      {:ok, {ip, port}} = ParrotTransport.get_local_address(listener)
      IO.puts("Listening on port: \#{port}")
  """
  @spec get_local_address(GenStateMachine.server_ref()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}}
  def get_local_address(listener) do
    ParrotTransport.UdpListener.get_local_address(listener)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_supervised_listener(module, config) do
    child_spec = %{
      id: config.name || make_ref(),
      start: {module, :start_link, [config]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(ParrotTransport.ListenerSupervisor, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, {:bind_error, reason}} ->
        {:error, reason}

      {:error, {:shutdown, {:bind_error, reason}}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_supervised_tcp_listener(config, handler_pid) do
    child_spec = %{
      id: config.name || make_ref(),
      start: {ParrotTransport.TcpListener, :start_link, [config, handler_pid]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(ParrotTransport.ListenerSupervisor, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, {:bind_error, reason}} ->
        {:error, reason}

      {:error, {:shutdown, {:bind_error, reason}}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_supervised_tls_listener(config, handler_pid) do
    child_spec = %{
      id: config.name || make_ref(),
      start: {ParrotTransport.TlsListener, :start_link, [config, handler_pid]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(ParrotTransport.ListenerSupervisor, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, {:bind_error, reason}} ->
        {:error, reason}

      {:error, {:shutdown, {:bind_error, reason}}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_supervised_websocket_listener(config, handler_pid) do
    child_spec = %{
      id: config.name || make_ref(),
      start: {ParrotTransport.WebsocketListener, :start_link, [config, handler_pid]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(ParrotTransport.ListenerSupervisor, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, {:already_started, pid}}

      {:error, {:bind_error, reason}} ->
        {:error, reason}

      {:error, {:shutdown, {:bind_error, reason}}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
