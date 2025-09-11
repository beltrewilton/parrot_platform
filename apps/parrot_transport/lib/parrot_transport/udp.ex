defmodule ParrotTransport.Udp do
  @moduledoc """
  UDP transport implementation.
  
  This module provides UDP packet transport without any protocol-specific knowledge.
  It simply receives and sends raw UDP packets, delegating to registered handlers.
  """
  
  use GenServer
  require Logger
  
  defmodule State do
    @moduledoc false
    defstruct [
      :local_ip,
      :local_port,
      :socket,
      handlers: [],
      trace: false
    ]
    
    @type t :: %__MODULE__{
      local_ip: :inet.ip_address() | nil,
      local_port: :inet.port_number() | nil,
      socket: :gen_udp.socket() | nil,
      handlers: list(pid()),
      trace: boolean()
    }
  end
  
  # API
  
  @doc """
  Starts a UDP transport listener.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    
    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end
  
  @doc """
  Stops the UDP transport.
  """
  def stop(transport) do
    GenServer.stop(transport)
  end
  
  # GenServer callbacks
  
  @impl true
  def init(opts) do
    ip_address = Keyword.get(opts, :ip, {0, 0, 0, 0})
    port = Keyword.get(opts, :port, 5060)
    trace = Keyword.get(opts, :trace, false)
    
    # Start with the configured handler if provided
    initial_handlers = case Keyword.get(opts, :handler) do
      nil -> []
      handler -> [handler]
    end
    
    case :gen_udp.open(port, [
      :binary,
      {:ip, ip_address},
      {:active, true},
      {:reuseaddr, true},
      {:recbuf, 65536},
      {:sndbuf, 65536}
    ]) do
      {:ok, socket} ->
        {:ok, {actual_ip, actual_port}} = :inet.sockname(socket)
        
        state = %State{
          local_ip: actual_ip,
          local_port: actual_port,
          socket: socket,
          handlers: initial_handlers,
          trace: trace
        }
        
        Logger.info("UDP transport started on #{format_address(actual_ip)}:#{actual_port}")
        
        {:ok, state}
        
      {:error, reason} ->
        Logger.error("Failed to open UDP socket on port #{port}: #{inspect(reason)}")
        {:stop, {:socket_error, reason}}
    end
  end
  
  @impl true
  def handle_call({:register_handler, handler_pid, _opts}, _from, state) do
    new_handlers = Enum.uniq([handler_pid | state.handlers])
    {:reply, :ok, %{state | handlers: new_handlers}}
  end
  
  def handle_call({:unregister_handler, handler_pid}, _from, state) do
    new_handlers = List.delete(state.handlers, handler_pid)
    {:reply, :ok, %{state | handlers: new_handlers}}
  end
  
  def handle_call(:get_local_address, _from, state) do
    {:reply, {:ok, {state.local_ip, state.local_port}}, state}
  end
  
  def handle_call({:send_response, data, {remote_ip, remote_port}}, _from, state) do
    result = send_data(state.socket, data, remote_ip, remote_port, state.trace)
    {:reply, result, state}
  end
  
  @impl true
  def handle_cast({:send_packet, data, {remote_ip, remote_port}}, state) do
    send_data(state.socket, data, remote_ip, remote_port, state.trace)
    {:noreply, state}
  end
  
  @impl true
  def handle_info({:udp, _socket, ip, port, data}, state) do
    if state.trace do
      Logger.debug("UDP received #{byte_size(data)} bytes from #{format_address(ip)}:#{port}")
    end
    
    # Create metadata for the packet
    metadata = %{
      transport: :udp,
      local_ip: state.local_ip,
      local_port: state.local_port,
      timestamp: System.monotonic_time()
    }
    
    # Send to all registered handlers
    for handler <- state.handlers do
      case handler do
        pid when is_pid(pid) ->
          send(pid, {:packet_received, data, {ip, port}, metadata})
        name when is_atom(name) ->
          case Process.whereis(name) do
            nil -> 
              Logger.warning("Handler #{name} not found")
            pid ->
              send(pid, {:packet_received, data, {ip, port}, metadata})
          end
      end
    end
    
    {:noreply, state}
  end
  
  def handle_info({:udp_error, _socket, reason}, state) do
    Logger.error("UDP socket error: #{inspect(reason)}")
    {:noreply, state}
  end
  
  def handle_info({:udp_closed, _socket}, state) do
    Logger.warning("UDP socket closed")
    {:stop, :socket_closed, state}
  end
  
  @impl true
  def terminate(reason, state) do
    if state.socket do
      :gen_udp.close(state.socket)
    end
    
    Logger.info("UDP transport terminated: #{inspect(reason)}")
    :ok
  end
  
  # Private helpers
  
  defp send_data(socket, data, remote_ip, remote_port, trace) do
    if trace do
      Logger.debug("UDP sending #{byte_size(data)} bytes to #{format_address(remote_ip)}:#{remote_port}")
    end
    
    case :gen_udp.send(socket, remote_ip, remote_port, data) do
      :ok -> 
        :ok
      {:error, reason} = error ->
        Logger.error("Failed to send UDP packet: #{inspect(reason)}")
        error
    end
  end
  
  defp format_address(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
  
  defp format_address(ip), do: inspect(ip)
end