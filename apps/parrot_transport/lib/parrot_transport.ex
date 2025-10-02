defmodule ParrotTransport do
  @moduledoc """
  Public API for protocol-agnostic transport layer.

  This module provides the primary interface for starting listeners,
  registering handlers, and sending/receiving data over UDP, TCP, and TLS.

  All transports are completely protocol-agnostic and deliver raw binary
  packets to registered handlers via the IncomingPacket struct.
  """

  alias ParrotTransport.Types.ListenerConfig

  @doc """
  Starts a transport listener under the application's supervisor.

  For UDP listeners, use `register_handler/2` to receive packets.
  For TCP listeners, pass a handler PID in the config or use `start_tcp_listener/2`.

  ## Parameters
    * `config` - A `ListenerConfig` struct specifying transport type, port, and options

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, reason}` - Startup failure reason

  ## Examples

      config = %ListenerConfig{transport: :udp, port: 5060}
      {:ok, pid} = ParrotTransport.start_listener(config)
      :ok = ParrotTransport.register_handler(pid, self())
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

      _other ->
        {:error, :unsupported_transport}
    end
  end

  @doc """
  Starts a TCP listener with a specified handler.

  ## Parameters
    * `config` - A `ListenerConfig` struct with transport: :tcp
    * `handler_pid` - Process to receive incoming packets from accepted connections

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, reason}` - Startup failure reason
  """
  @spec start_tcp_listener(ListenerConfig.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_tcp_listener(%ListenerConfig{transport: :tcp} = config, handler_pid) do
    start_supervised_tcp_listener(config, handler_pid)
  end

  @doc """
  Starts a TLS listener with a specified handler.

  ## Parameters
    * `config` - A `ListenerConfig` struct with transport: :tls
    * `handler_pid` - Process to receive incoming packets from accepted connections

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, reason}` - Startup failure reason
  """
  @spec start_tls_listener(ListenerConfig.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_tls_listener(%ListenerConfig{transport: :tls} = config, handler_pid) do
    start_supervised_tls_listener(config, handler_pid)
  end

  @doc """
  Stops a running listener.

  ## Parameters
    * `listener` - Listener PID or registered name

  ## Returns
    * `:ok`
  """
  @spec stop_listener(GenStateMachine.server_ref()) :: :ok
  def stop_listener(listener) do
    ParrotTransport.UdpListener.stop(listener)
  end

  @doc """
  Registers a handler process to receive incoming packets.

  The handler will receive `{:incoming_packet, IncomingPacket.t()}` messages.

  ## Parameters
    * `listener` - Listener PID or registered name
    * `handler_pid` - Process to receive packets

  ## Returns
    * `:ok`
  """
  @spec register_handler(GenStateMachine.server_ref(), pid()) :: :ok
  def register_handler(listener, handler_pid) do
    ParrotTransport.UdpListener.register_handler(listener, handler_pid)
  end

  @doc """
  Sends data through a transport.

  ## Parameters
    * `listener` - Listener PID or registered name
    * `data` - Binary data to send
    * `destination` - Tuple of `{ip, port}`

  ## Returns
    * `:ok`
  """
  @spec send_data(GenStateMachine.server_ref(), binary(), {tuple(), integer()}) :: :ok
  def send_data(listener, data, destination) do
    ParrotTransport.UdpListener.send_data(listener, data, destination)
  end

  @doc """
  Gets the local address a listener is bound to.

  ## Parameters
    * `listener` - Listener PID or registered name

  ## Returns
    * `{:ok, {ip, port}}`
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
end
