defmodule ParrotTransport.Supervisor do
  @moduledoc """
  Supervisor for transport processes.
  
  This supervisor manages UDP, TCP, and TLS transport processes.
  """
  
  use Supervisor
  
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    children = [
      # Transport processes will be started dynamically
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
  
  @doc """
  Starts a new transport process under supervision.
  """
  def start_transport(type, opts) do
    child_spec = case type do
      :udp ->
        %{
          id: {ParrotTransport.Udp, opts[:port] || 5060},
          start: {ParrotTransport.Udp, :start_link, [opts]},
          restart: :permanent,
          type: :worker
        }
      _other ->
        {:error, :not_implemented}
    end
    
    case child_spec do
      {:error, _} = error -> error
      spec -> Supervisor.start_child(__MODULE__, spec)
    end
  end
  
  @doc """
  Stops a transport process.
  """
  def stop_transport(transport_id) do
    Supervisor.terminate_child(__MODULE__, transport_id)
    Supervisor.delete_child(__MODULE__, transport_id)
  end
end