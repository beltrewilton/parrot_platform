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

  ## Parameters
    * `config` - A `ListenerConfig` struct specifying transport type, port, and options

  ## Returns
    * `{:ok, pid}` - Listener process PID
    * `{:error, reason}` - Startup failure reason

  ## Examples

      config = %ListenerConfig{transport: :udp, port: 5060}
      {:ok, pid} = ParrotTransport.start_listener(config)
  """
  @spec start_listener(ListenerConfig.t()) :: {:ok, pid()} | {:error, term()}
  def start_listener(%ListenerConfig{} = config) do
    case config.transport do
      :udp ->
        start_supervised_listener(ParrotTransport.UdpListener, config)

      :tcp ->
        {:error, :not_implemented}

      :tls ->
        {:error, :not_implemented}

      _other ->
        {:error, :unsupported_transport}
    end
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
end
