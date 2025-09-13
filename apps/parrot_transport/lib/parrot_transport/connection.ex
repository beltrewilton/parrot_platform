defmodule ParrotTransport.Connection do
  @moduledoc """
  Connection state machine for managing transport connections.
  
  This module uses gen_statem to manage connection lifecycle states
  such as connecting, connected, disconnected, and reconnecting.
  """
  
  use GenStateMachine, callback_mode: [:state_functions, :state_enter]
  require Logger
  
  defmodule Data do
    @moduledoc false
    defstruct [
      :transport,
      :remote_ip,
      :remote_port,
      :local_ip,
      :local_port,
      :reconnect_timer,
      :keepalive_timer,
      handlers: [],
      reconnect_attempts: 0,
      max_reconnect_attempts: 10,
      reconnect_interval: 5000,
      keepalive_interval: 30000
    ]
    
    @type t :: %__MODULE__{
      transport: pid() | nil,
      remote_ip: :inet.ip_address() | nil,
      remote_port: :inet.port_number() | nil,
      local_ip: :inet.ip_address() | nil,
      local_port: :inet.port_number() | nil,
      reconnect_timer: reference() | nil,
      keepalive_timer: reference() | nil,
      handlers: list(pid()),
      reconnect_attempts: non_neg_integer(),
      max_reconnect_attempts: non_neg_integer(),
      reconnect_interval: non_neg_integer(),
      keepalive_interval: non_neg_integer()
    }
  end
  
  # API
  
  @doc """
  Starts a connection state machine.
  """
  def start_link(opts) do
    GenStateMachine.start_link(__MODULE__, opts, name: opts[:name])
  end
  
  @doc """
  Connects to a remote endpoint.
  """
  def connect(conn, remote_ip, remote_port) do
    GenStateMachine.call(conn, {:connect, remote_ip, remote_port})
  end
  
  @doc """
  Disconnects from the remote endpoint.
  """
  def disconnect(conn) do
    GenStateMachine.call(conn, :disconnect)
  end
  
  @doc """
  Sends data through the connection.
  """
  def send_data(conn, data) do
    GenStateMachine.cast(conn, {:send_data, data})
  end
  
  @doc """
  Gets the current connection state.
  """
  def get_state(conn) do
    GenStateMachine.call(conn, :get_state)
  end
  
  # GenStateMachine callbacks
  
  @impl true
  def init(opts) do
    data = %Data{
      transport: opts[:transport],
      max_reconnect_attempts: opts[:max_reconnect_attempts] || 10,
      reconnect_interval: opts[:reconnect_interval] || 5000,
      keepalive_interval: opts[:keepalive_interval] || 30000
    }
    
    {:ok, :disconnected, data}
  end
  
  # State: disconnected
  
  def disconnected(:enter, _old_state, _data) do
    Logger.debug("Connection entered disconnected state")
    :keep_state_and_data
  end
  
  def disconnected({:call, from}, {:connect, remote_ip, remote_port}, data) do
    Logger.info("Connecting to #{format_address(remote_ip)}:#{remote_port}")
    
    new_data = %{data | 
      remote_ip: remote_ip,
      remote_port: remote_port,
      reconnect_attempts: 0
    }
    
    {:next_state, :connecting, new_data, [{:reply, from, :ok}]}
  end
  
  def disconnected({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :disconnected}]}
  end
  
  # State: connecting
  
  def connecting(:enter, _old_state, _data) do
    Logger.debug("Connection entering connecting state")
    
    # Simulate connection establishment (in real implementation, this would
    # involve actual network operations)
    send(self(), :connection_established)
    
    :keep_state_and_data
  end
  
  def connecting(:info, :connection_established, data) do
    Logger.info("Connection established to #{format_address(data.remote_ip)}:#{data.remote_port}")
    
    # Start keepalive timer
    timer = Process.send_after(self(), :keepalive, data.keepalive_interval)
    new_data = %{data | keepalive_timer: timer}
    
    # Notify handlers
    for handler <- data.handlers do
      send(handler, {:connection_state, :connected})
    end
    
    {:next_state, :connected, new_data}
  end
  
  def connecting(:info, :connection_failed, data) do
    Logger.warning("Connection failed to #{format_address(data.remote_ip)}:#{data.remote_port}")
    
    if data.reconnect_attempts < data.max_reconnect_attempts do
      {:next_state, :reconnecting, data}
    else
      {:next_state, :disconnected, data}
    end
  end
  
  def connecting({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :connecting}]}
  end
  
  # State: connected
  
  def connected(:enter, _old_state, _data) do
    Logger.debug("Connection entered connected state")
    :keep_state_and_data
  end
  
  def connected({:cast, _}, {:send_data, data_to_send}, data) do
    # Send data through transport
    if data.transport do
      ParrotTransport.send_packet(data.transport, data_to_send, {data.remote_ip, data.remote_port})
    end
    
    :keep_state_and_data
  end
  
  def connected(:info, :keepalive, data) do
    # Send keepalive (implementation depends on protocol)
    Logger.debug("Sending keepalive")
    
    # Reschedule keepalive
    timer = Process.send_after(self(), :keepalive, data.keepalive_interval)
    new_data = %{data | keepalive_timer: timer}
    
    {:keep_state, new_data}
  end
  
  def connected({:call, from}, :disconnect, data) do
    # Cancel keepalive timer
    if data.keepalive_timer do
      Process.cancel_timer(data.keepalive_timer)
    end
    
    # Notify handlers
    for handler <- data.handlers do
      send(handler, {:connection_state, :disconnected})
    end
    
    {:next_state, :disconnected, %{data | keepalive_timer: nil}, [{:reply, from, :ok}]}
  end
  
  def connected({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :connected}]}
  end
  
  def connected(:info, :connection_lost, data) do
    Logger.warning("Connection lost to #{format_address(data.remote_ip)}:#{data.remote_port}")
    
    # Cancel keepalive timer
    if data.keepalive_timer do
      Process.cancel_timer(data.keepalive_timer)
    end
    
    {:next_state, :reconnecting, %{data | keepalive_timer: nil}}
  end
  
  # State: reconnecting
  
  def reconnecting(:enter, _old_state, data) do
    Logger.info("Attempting to reconnect (attempt #{data.reconnect_attempts + 1}/#{data.max_reconnect_attempts})")
    
    # Schedule reconnection attempt
    timer = Process.send_after(self(), :reconnect_attempt, data.reconnect_interval)
    new_data = %{data | 
      reconnect_timer: timer,
      reconnect_attempts: data.reconnect_attempts + 1
    }
    
    {:keep_state, new_data}
  end
  
  def reconnecting(:info, :reconnect_attempt, data) do
    if data.reconnect_attempts >= data.max_reconnect_attempts do
      Logger.error("Max reconnection attempts reached. Giving up.")
      {:next_state, :disconnected, %{data | reconnect_timer: nil}}
    else
      {:next_state, :connecting, %{data | reconnect_timer: nil}}
    end
  end
  
  def reconnecting({:call, from}, :disconnect, data) do
    # Cancel reconnect timer
    if data.reconnect_timer do
      Process.cancel_timer(data.reconnect_timer)
    end
    
    {:next_state, :disconnected, %{data | reconnect_timer: nil}, [{:reply, from, :ok}]}
  end
  
  def reconnecting({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :reconnecting}]}
  end
  
  # Helper functions
  
  defp format_address(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
  
  defp format_address(ip), do: inspect(ip)
end