defmodule ParrotTransport.Connection do
  @moduledoc """
  TCP connection state machine with Content-Length framing.

  States:
  - :connecting - Establishing TCP connection
  - :connected - Active connection, receiving and sending data
  - :reconnecting - Connection lost, attempting to reconnect
  - :stopping - Graceful shutdown

  This module manages a single outbound TCP connection with automatic
  reconnection, message framing via Content-Length, and error handling.
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]
  require Logger

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket, Source, Metadata}
  alias ParrotTransport.Framing.ContentLength

  defmodule Data do
    @enforce_keys [:config, :handler]
    defstruct [
      :config,
      :handler,
      :socket,
      :local_ip,
      :local_port,
      :framing,
      :reconnect_timer,
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
            socket: :gen_tcp.socket() | nil,
            local_ip: :inet.ip_address() | nil,
            local_port: :inet.port_number() | nil,
            framing: ContentLength.t() | nil,
            reconnect_timer: reference() | nil,
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
  Starts a TCP connection to the specified remote endpoint.
  """
  @spec start_link(ListenerConfig.t(), pid()) :: GenStateMachine.on_start()
  def start_link(%ListenerConfig{transport: :tcp} = config, handler_pid) do
    opts = if config.name, do: [name: config.name], else: []
    GenStateMachine.start_link(__MODULE__, {config, handler_pid}, opts)
  end

  @doc """
  Sends data through the connection.
  """
  @spec send_data(GenStateMachine.server_ref(), binary()) :: :ok
  def send_data(conn, data) do
    GenStateMachine.cast(conn, {:send_data, data})
  end

  @doc """
  Stops the connection gracefully.
  """
  @spec stop(GenStateMachine.server_ref()) :: :ok
  def stop(conn) do
    GenStateMachine.call(conn, :stop)
  end
  
  # ============================================================================
  # gen_statem callbacks
  # ============================================================================

  @impl GenStateMachine
  def init({config, handler_pid}) do
    data = %Data{
      config: config,
      handler: handler_pid,
      framing: %ContentLength{}
    }

    {:ok, :connecting, data}
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

  # ============================================================================
  # State: :connected
  # ============================================================================

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected(:info, {:tcp, socket, binary_data}, %{socket: socket} = data) do
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

  def connected(:cast, {:send_data, data_to_send}, data) do
    case :gen_tcp.send(data.socket, data_to_send) do
      :ok ->
        new_data = %{data | packets_sent: data.packets_sent + 1}
        {:keep_state, new_data}

      {:error, reason} ->
        Logger.error("[Connection] Send failed: #{inspect(reason)}")
        :gen_tcp.close(data.socket)
        new_data = %{data | socket: nil, framing: %ContentLength{}, errors: data.errors + 1}
        {:next_state, :reconnecting, new_data}
    end
  end

  def connected({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
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

  # ============================================================================
  # State: :stopping
  # ============================================================================

  def stopping(:enter, _old_state, data) do
    if data.socket do
      :gen_tcp.close(data.socket)
    end

    Logger.info("[Connection] Stopped")
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
end