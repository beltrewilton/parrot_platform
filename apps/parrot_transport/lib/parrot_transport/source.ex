defmodule ParrotTransport.Source do
  @moduledoc """
  Manages source addresses for network packets.
  
  This module tracks and manages source addresses for incoming packets,
  useful for NAT traversal and connection tracking.
  """
  
  defstruct [
    :transport_type,
    :local,
    :remote,
    :timestamp,
    :metadata
  ]
  
  @type t :: %__MODULE__{
    transport_type: :udp | :tcp | :tls,
    local: {:inet.ip_address(), :inet.port_number()},
    remote: {:inet.ip_address(), :inet.port_number()},
    timestamp: integer(),
    metadata: map()
  }
  
  @doc """
  Creates a new source from packet information.
  """
  def new(transport_type, local_addr, remote_addr, metadata \\ %{}) do
    %__MODULE__{
      transport_type: transport_type,
      local: local_addr,
      remote: remote_addr,
      timestamp: System.monotonic_time(),
      metadata: metadata
    }
  end
  
  @doc """
  Updates the timestamp for a source.
  """
  def touch(%__MODULE__{} = source) do
    %{source | timestamp: System.monotonic_time()}
  end
  
  @doc """
  Checks if a source has expired based on the given timeout in milliseconds.
  """
  def expired?(%__MODULE__{timestamp: timestamp}, timeout_ms) do
    now = System.monotonic_time()
    elapsed = System.convert_time_unit(now - timestamp, :native, :millisecond)
    elapsed > timeout_ms
  end
  
  @doc """
  Formats a source as a string for logging.
  """
  def to_string(%__MODULE__{} = source) do
    {local_ip, local_port} = source.local
    {remote_ip, remote_port} = source.remote
    
    "#{source.transport_type}://#{format_address(local_ip)}:#{local_port}<->#{format_address(remote_ip)}:#{remote_port}"
  end
  
  defp format_address(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
  
  defp format_address(ip), do: inspect(ip)
end