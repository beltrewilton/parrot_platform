defmodule ParrotTransport.UdpListener do
  @moduledoc """
  UDP listener state machine.

  States:
  - :initializing - Creating and binding socket
  - :bound - Receiving packets
  - :stopping - Graceful shutdown

  UDP is connectionless, but the listener itself has lifecycle states
  that need proper management.
  """

  @behaviour :gen_statem
  require Logger

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket, Source, Metadata}

  defmodule Data do
    @enforce_keys [:config]
    defstruct [
      :config,
      :socket,
      :local_ip,
      :local_port,
      handlers: [],
      packets_received: 0,
      packets_sent: 0,
      errors: 0
    ]

    @type t :: %__MODULE__{
            config: ListenerConfig.t(),
            socket: :gen_udp.socket() | nil,
            local_ip: :inet.ip_address() | nil,
            local_port: :inet.port_number() | nil,
            handlers: [pid()],
            packets_received: non_neg_integer(),
            packets_sent: non_neg_integer(),
            errors: non_neg_integer()
          }
  end

  # ============================================================================
  # API
  # ============================================================================

  @doc """
  Starts a UDP listener.
  """
  @spec start_link(ListenerConfig.t()) :: :gen_statem.start_ret()
  def start_link(%ListenerConfig{transport: :udp} = config) do
    if config.name do
      :gen_statem.start_link({:local, config.name}, __MODULE__, config, [])
    else
      :gen_statem.start_link(__MODULE__, config, [])
    end
  end

  @doc """
  Registers a handler to receive incoming packets.
  """
  @spec register_handler(:gen_statem.server_ref(), pid()) :: :ok
  def register_handler(listener, handler_pid) do
    :gen_statem.call(listener, {:register_handler, handler_pid})
  end

  @doc """
  Sends data through the UDP socket.
  """
  @spec send_data(:gen_statem.server_ref(), binary(), tuple()) :: :ok
  def send_data(listener, data, {dest_ip, dest_port}) do
    :gen_statem.cast(listener, {:send_data, data, dest_ip, dest_port})
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
  def init(config) do
    # Bind socket synchronously during init to catch errors early
    case create_socket(config) do
      {:ok, socket, local_ip, local_port} ->
        data = %Data{
          config: config,
          socket: socket,
          local_ip: local_ip,
          local_port: local_port
        }

        Logger.info("[UdpListener] Bound to #{format_addr(local_ip)}:#{local_port}")

        {:ok, :bound, data}

      {:error, reason} ->
        Logger.error("[UdpListener] Failed to bind socket: #{inspect(reason)}")
        {:stop, {:bind_error, reason}}
    end
  end

  # ============================================================================
  # State: :bound (operational)
  # ============================================================================

  def bound(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def bound(:info, {:udp, socket, remote_ip, remote_port, binary_data}, %{socket: socket} = data) do
    # Log SIP trace if enabled
    if data.config.trace do
      Logger.info("[SIP TRACE] UDP recv from #{format_addr(remote_ip)}:#{remote_port}\n#{binary_data}")
    end

    # Create packet
    packet = %IncomingPacket{
      data: binary_data,
      source: %Source{
        transport: :udp,
        remote_addr: {remote_ip, remote_port},
        local_addr: {data.local_ip, data.local_port},
        connection: nil
      },
      metadata: %Metadata{
        timestamp: System.monotonic_time()
      }
    }

    # Route to all handlers
    for handler <- data.handlers do
      send(handler, {:incoming_packet, packet})
    end

    new_data = %{data | packets_received: data.packets_received + 1}
    {:keep_state, new_data}
  end

  def bound(:info, {:udp_error, socket, reason}, %{socket: socket} = data) do
    Logger.error("[UdpListener] UDP error: #{inspect(reason)}")
    new_data = %{data | errors: data.errors + 1}
    {:keep_state, new_data}
  end

  def bound(:info, {:udp_closed, socket}, %{socket: socket} = _data) do
    Logger.warning("[UdpListener] UDP socket closed unexpectedly")
    {:stop, :socket_closed}
  end

  def bound(:cast, {:send_data, data_to_send, dest_ip, dest_port}, data) do
    # Log SIP trace if enabled
    if data.config.trace do
      Logger.info("[SIP TRACE] UDP send to #{format_addr(dest_ip)}:#{dest_port}\n#{data_to_send}")
    end

    case :gen_udp.send(data.socket, dest_ip, dest_port, data_to_send) do
      :ok ->
        new_data = %{data | packets_sent: data.packets_sent + 1}
        {:keep_state, new_data}

      {:error, reason} ->
        Logger.error("[UdpListener] Send failed: #{inspect(reason)}")
        new_data = %{data | errors: data.errors + 1}
        {:keep_state, new_data}
    end
  end

  def bound({:call, from}, {:register_handler, handler_pid}, data) do
    # Monitor handler
    Process.monitor(handler_pid)
    new_handlers = Enum.uniq([handler_pid | data.handlers])
    {:keep_state, %{data | handlers: new_handlers}, [{:reply, from, :ok}]}
  end

  def bound({:call, from}, :get_local_address, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, {data.local_ip, data.local_port}}}]}
  end

  def bound(:info, {:DOWN, _ref, :process, handler_pid, _reason}, data) do
    # Handler died, remove it
    new_handlers = List.delete(data.handlers, handler_pid)
    {:keep_state, %{data | handlers: new_handlers}}
  end

  def bound({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  # ============================================================================
  # State: :stopping
  # ============================================================================

  def stopping(:enter, _old_state, data) do
    # Close socket
    if data.socket do
      :gen_udp.close(data.socket)
    end

    Logger.info("[UdpListener] Stopped")
    {:stop, :normal}
  end

  # ============================================================================
  # Private functions
  # ============================================================================

  defp create_socket(config) do
    opts = [
      :binary,
      {:ip, config.ip},
      {:active, true},
      {:reuseaddr, true},
      {:recbuf, config.buffer_size},
      {:sndbuf, config.buffer_size}
    ]

    case :gen_udp.open(config.port, opts) do
      {:ok, socket} ->
        {:ok, {actual_ip, actual_port}} = :inet.sockname(socket)
        {:ok, socket, actual_ip, actual_port}

      error ->
        error
    end
  end

  defp format_addr(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp format_addr(ip), do: inspect(ip)
end
