defmodule ParrotTransport do
  @moduledoc """
  Transport layer with no protocol knowledge.
  
  This module provides a protocol-agnostic transport layer for sending and receiving
  network packets. It supports UDP, TCP, and TLS transports.
  """

  @doc """
  Starts a transport listener of the specified type.
  
  ## Options
    * `:port` - The port to listen on (required)
    * `:ip` - The IP address to bind to (defaults to {0,0,0,0})
    * `:name` - Optional name for the transport process
    * `:handler` - PID or registered name of the handler process
  
  ## Returns
    * `{:ok, transport_ref}` - The transport reference for sending packets
    * `{:error, reason}` - If the transport could not be started
  """
  def start_listener(type, opts) do
    case type do
      :udp ->
        ParrotTransport.Udp.start_link(opts)
      _other ->
        {:error, :not_implemented}
    end
  end

  @doc """
  Registers a handler process to receive packets from the transport.
  
  The handler will receive messages in the format:
  `{:packet_received, data, source, metadata}`
  
  Where:
    * `data` - The raw binary packet data
    * `source` - The source address as `{ip, port}`
    * `metadata` - Additional transport metadata
  """
  def register_handler(transport_ref, handler_pid, opts \\ []) do
    GenServer.call(transport_ref, {:register_handler, handler_pid, opts})
  end

  @doc """
  Sends a raw packet through the transport.
  
  ## Parameters
    * `transport_ref` - The transport reference
    * `data` - Raw binary data to send
    * `destination` - Target address as `{ip, port}`
  """
  def send_packet(transport_ref, data, destination) do
    GenServer.cast(transport_ref, {:send_packet, data, destination})
  end
  
  @doc """
  Unregisters a handler from the transport.
  """
  def unregister_handler(transport_ref, handler_pid) do
    GenServer.call(transport_ref, {:unregister_handler, handler_pid})
  end
  
  @doc """
  Gets the local address the transport is bound to.
  
  ## Returns
    * `{:ok, {ip, port}}` - The local address
    * `{:error, reason}` - If the address cannot be retrieved
  """
  def get_local_address(transport_ref) do
    GenServer.call(transport_ref, :get_local_address)
  end
end
