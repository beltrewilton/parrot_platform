defmodule ParrotExampleUas do
  @moduledoc """
  Example UAS (User Agent Server) application that receives SIP calls.
  
  This application demonstrates:
  - Receiving inbound SIP calls
  - Playing audio files to callers
  - Proper SIP dialog management
  - Clean separation between SIP and media handling
  
  ## Architecture
  
  This UAS uses two separate handler modules:
  
  1. **IncomingCallHandler** (ParrotExampleUas.IncomingCallHandler) - Handles incoming SIP calls
     - Processes INVITE requests and generates SDP answers
     - Handles ACK to start media playback
     - Processes BYE to end calls
     - Responds to OPTIONS, CANCEL, and other SIP methods
  
  2. **MediaHandler** (ParrotExampleUas.MediaHandler) - Handles media session callbacks
     - Plays welcome audio file when receiving control messages
     - Manages audio streaming lifecycle
     - Handles codec negotiation
  
  The IncomingCallHandler is called by HandlerAdapter.Core, which bridges between
  the low-level transport layer and our high-level handler logic.
  
  ## Usage
  
      # Start the UAS on default port 5060
      ParrotExampleUas.start()
      
      # Start on custom port
      ParrotExampleUas.start(port: 5061)
      
      # Stop the UAS
      ParrotExampleUas.stop()
  """
  
  use GenServer
  require Logger
  
  # No alias - use full module name to ensure proper loading
  
  @server_name {:via, Registry, {Parrot.Registry, __MODULE__}}
  
  defmodule State do
    @moduledoc false
    defstruct [
      :transport_ref,
      :port,
      active_calls: %{}
    ]
  end
  
  # Client API
  
  @doc """
  Starts the UAS application.
  
  Options:
    - `:port` - Port to listen on (default: 5060)
  """
  def start(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: @server_name) do
      {:ok, pid} ->
        Logger.info("ParrotExampleUas started successfully")
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        Logger.info("ParrotExampleUas already running")
        {:ok, pid}
      error ->
        error
    end
  end
  
  @doc """
  Stops the UAS application.
  """
  def stop do
    GenServer.stop(@server_name)
  end
  
  @doc """
  Gets the current status of the UAS.
  """
  def status do
    GenServer.call(@server_name, :status)
  end
  
  # Server Callbacks
  
  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 5060)
    
    Logger.info("Starting ParrotExampleUas on port #{port}")
    Logger.info("Connect your SIP client to sip:service@<your-ip>:#{port}")
    
    # Start the SIP transport with our IncomingCallHandler
    # Use full module name to ensure proper module resolution
    handler = Parrot.Sip.Handler.new(
      Parrot.Sip.HandlerAdapter.Core,
      {ParrotExampleUas.IncomingCallHandler, %{parent: self()}},
      log_level: :info,
      sip_trace: true
    )
    
    case Parrot.Sip.Transport.StateMachine.start_udp(%{
      handler: handler,
      listen_port: port
    }) do
      :ok ->
        state = %State{
          transport_ref: make_ref(),
          port: port
        }
        {:ok, state}
        
      {:error, reason} ->
        {:stop, {:transport_error, reason}}
    end
  end
  
  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      listening_port: state.port,
      active_calls: map_size(state.active_calls)
    }
    {:reply, status, state}
  end
  
  @impl true
  def handle_info({:call_started, call_id, media_session_id}, state) do
    Logger.info("Call started: #{call_id} with media session: #{media_session_id}")
    new_calls = Map.put(state.active_calls, call_id, media_session_id)
    {:noreply, %{state | active_calls: new_calls}}
  end
  
  @impl true
  def handle_info({:call_ended, call_id}, state) do
    Logger.info("Call ended: #{call_id}")
    new_calls = Map.delete(state.active_calls, call_id)
    {:noreply, %{state | active_calls: new_calls}}
  end
  
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
