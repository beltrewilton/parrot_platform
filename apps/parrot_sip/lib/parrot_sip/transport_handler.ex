defmodule ParrotSip.TransportHandler do
  @moduledoc """
  Handles message-based communication between ParrotSip and transport layer.

  This GenServer acts as a bridge between the SIP protocol layer and the 
  transport layer (UDP/TCP/TLS). It receives raw packets from transport,
  parses them into SIP messages, and routes them to the appropriate 
  transaction/dialog handlers.

  For outgoing messages, it receives SIP messages from the protocol layer,
  serializes them, and sends them to the transport layer.

  ## Message Flow

  ### Incoming (Transport → SIP):
  1. Receives `{:packet_received, raw_data, source, metadata}` from transport
  2. Parses raw data into SIP message
  3. Routes to transaction layer

  ### Outgoing (SIP → Transport):  
  1. Receives `{:send_sip_message, message, destination}` from SIP layer
  2. Serializes SIP message
  3. Sends `{:send_packet, raw_data, destination}` to transport
  """

  use GenServer
  require Logger

  alias ParrotSip.Parser
  alias ParrotSip.Serializer
  alias ParrotSip.Source

  defstruct [
    # Deprecated - kept for backward compatibility
    :transport_ref,
    :name,
    handlers: [],
    # New: Map of transport refs by {transport, local_ip, local_port}
    transports: %{}
  ]

  @type t :: %__MODULE__{
          # Deprecated
          transport_ref: pid() | atom() | nil,
          name: atom() | nil,
          handlers: list(pid()),
          # %{{:udp, {127,0,0,1}, 5060} => pid(), ...}
          transports: map()
        }

  # API

  @doc """
  Starts the transport handler.

  Options:
  - `:name` - Optional name to register the process
  - `:transport_ref` - Reference to the transport process (pid or registered name)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Sends a SIP message through the transport layer.

  The message will be serialized and sent as raw data to the transport.
  """
  def send_message(handler, message, destination) do
    GenServer.cast(handler, {:send_sip_message, message, destination})
  end

  @doc """
  Sends a SIP response through the transport layer.

  Similar to send_message but extracts destination from the message source.
  """
  def send_response(handler, response, source) do
    GenServer.cast(handler, {:send_sip_response, response, source})
  end

  @doc """
  Sends a SIP request through the transport layer.
  """
  def send_request(handler, request, destination) do
    GenServer.cast(handler, {:send_sip_request, request, destination})
  end

  @doc """
  Registers a handler to receive parsed SIP messages.

  ## Options
  - `timeout` - GenServer call timeout in milliseconds (default: 5000)
  """
  def register_handler(transport_handler, handler_pid, timeout \\ 5000) do
    GenServer.call(transport_handler, {:register_handler, handler_pid}, timeout)
  end

  @doc """
  Sets or updates the transport reference.

  ## Options
  - `timeout` - GenServer call timeout in milliseconds (default: 5000)

  DEPRECATED: Use register_transport/5 for multi-transport support
  """
  def set_transport(handler, transport_ref, timeout \\ 5000) do
    GenServer.call(handler, {:set_transport, transport_ref}, timeout)
  end

  @doc """
  Registers a transport listener for a specific transport/address combination.

  This allows TransportHandler to manage multiple listeners (e.g., UDP:5060, TCP:5060, TLS:5061).
  Responses will be sent back through the same transport/address where the request was received.

  ## Parameters
  - `handler` - TransportHandler process
  - `transport_ref` - PID or name of the transport listener
  - `transport_type` - :udp | :tcp | :tls | :websocket
  - `local_ip` - Local IP address tuple, e.g., {127, 0, 0, 1}
  - `local_port` - Local port number

  ## Examples
      register_transport(handler, udp_listener, :udp, {0, 0, 0, 0}, 5060)
      register_transport(handler, tcp_listener, :tcp, {0, 0, 0, 0}, 5060)
      register_transport(handler, tls_listener, :tls, {0, 0, 0, 0}, 5061)
  """
  def register_transport(
        handler,
        transport_ref,
        transport_type,
        local_ip,
        local_port,
        timeout \\ 5000
      ) do
    GenServer.call(
      handler,
      {:register_transport, transport_ref, transport_type, local_ip, local_port},
      timeout
    )
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    transport_ref = Keyword.get(opts, :transport_ref)
    name = Keyword.get(opts, :name)

    # If we have a transport ref, register with it
    if transport_ref do
      register_with_transport(transport_ref, self())
    end

    # Register in the SIP registry if we have a name
    if name do
      Registry.register(ParrotSip.Registry, {__MODULE__, name}, self())
    end

    state = %__MODULE__{
      transport_ref: transport_ref,
      name: name,
      handlers: [],
      transports: %{}
    }

    # Logger.info("TransportHandler started#{if name, do: " as #{name}", else: ""}")
    # Startup log disabled for cleaner test output

    {:ok, state}
  end

  @impl true
  def handle_call({:register_handler, handler_pid}, _from, state) do
    new_handlers = Enum.uniq([handler_pid | state.handlers])
    {:reply, :ok, %{state | handlers: new_handlers}}
  end

  def handle_call({:set_transport, transport_ref}, _from, state) do
    # Register with the new transport (deprecated single-transport mode)
    register_with_transport(transport_ref, self())
    {:reply, :ok, %{state | transport_ref: transport_ref}}
  end

  def handle_call(
        {:register_transport, transport_ref, transport_type, local_ip, local_port},
        _from,
        state
      ) do
    # Register a new transport listener
    key = {transport_type, local_ip, local_port}
    new_transports = Map.put(state.transports, key, transport_ref)

    Logger.debug(
      "[TransportHandler] Registered transport #{transport_type}://#{inspect(local_ip)}:#{local_port}"
    )

    {:reply, :ok, %{state | transports: new_transports}}
  end

  @impl true
  def handle_cast({:send_sip_message, message, destination}, state) do
    send_to_transport(message, destination, state.transport_ref, nil)
    {:noreply, state}
  end

  def handle_cast({:send_sip_response, response, source}, state) do
    # Extract destination, transport info, and connection PID from source
    {destination, transport_ref, connection_pid} =
      case source do
        %Source{
          remote: remote,
          transport: transport_type,
          local: {local_ip, local_port},
          connection: conn
        } ->
          # Look up the correct transport based on where the request came from
          key = {transport_type, local_ip, local_port}
          transport = Map.get(state.transports, key) || state.transport_ref
          {remote, transport, conn}

        {host, port} ->
          # Fallback to old single-transport mode
          {{host, port}, state.transport_ref, nil}

        _ ->
          Logger.error("Invalid source for response: #{inspect(source)}")
          {nil, nil, nil}
      end

    if destination && transport_ref do
      send_to_transport(response, destination, transport_ref, connection_pid)
    end

    {:noreply, state}
  end

  # Send request with source info - look up correct transport
  def handle_cast(
        {:send_sip_request,
         %{source: %Source{transport: transport_type, local: {local_ip, local_port}}} = request,
         destination},
        state
      ) do
    key = {transport_type, local_ip, local_port}
    transport_ref = Map.get(state.transports, key) || state.transport_ref
    send_to_transport(request, destination, transport_ref, nil)
    {:noreply, state}
  end

  # Send request without source info - use default transport
  def handle_cast({:send_sip_request, request, destination}, state) do
    send_to_transport(request, destination, state.transport_ref, nil)
    {:noreply, state}
  end

  @impl true
  def handle_info({:packet_received, raw_data, {remote_ip, remote_port}, metadata}, state) do
    # Parse the raw SIP message
    case Parser.parse(raw_data) do
      {:ok, sip_message} ->
        # Add source information to the message
        local_ip = Map.get(metadata, :local_ip, {0, 0, 0, 0})
        local_port = Map.get(metadata, :local_port, 5060)

        source = %Source{
          transport: Map.get(metadata, :transport, :udp),
          remote: {remote_ip, remote_port},
          local: {local_ip, local_port}
        }

        message_with_source = Map.put(sip_message, :source, source)

        Logger.debug(
          "Parsed SIP #{message_with_source.type} #{if message_with_source.type == :request, do: message_with_source.method, else: "#{message_with_source.status_code} #{message_with_source.reason_phrase}"}"
        )

        # Route to transaction layer
        route_message(message_with_source, state)

      {:error, reason} ->
        Logger.warning(
          "Failed to parse SIP message from #{format_ip(remote_ip)}:#{remote_port}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  # Handle transport process down
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{transport_ref: pid} = state) do
    Logger.error("Transport process down: #{inspect(reason)}")
    {:noreply, %{state | transport_ref: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp register_with_transport(transport_ref, handler_pid) do
    case resolve_transport(transport_ref) do
      {:ok, pid} ->
        # Monitor the transport process
        Process.monitor(pid)

        # Register as a handler with the transport (using gen_statem call)
        :gen_statem.call(pid, {:register_handler, handler_pid}, 5000)

      {:error, reason} ->
        Logger.error("Failed to register with transport: #{reason}")
    end
  end

  defp send_to_transport(_message, nil, _transport_ref, _connection_pid) do
    Logger.debug("[TransportHandler] Skipping send (no destination) in test environment")
    :ok
  end

  defp send_to_transport(message, destination, transport_ref, connection_pid) do
    raw_data = Serializer.encode(message)

    # For TCP/TLS with a connection PID, send directly to the connection
    if connection_pid && is_pid(connection_pid) do
      ParrotTransport.Connection.send_data(connection_pid, raw_data)
    else
      # For UDP or when no connection PID, send via listener
      {dest_ip, dest_port} =
        case destination do
          {ip, port} when is_tuple(ip) ->
            {ip, port}

          {host, port} when is_binary(host) ->
            case resolve_host(host) do
              {:ok, ip} -> {ip, port}
              _ -> {host, port}
            end

          _ ->
            destination
        end

      case resolve_transport(transport_ref) do
        {:ok, pid} ->
          :gen_statem.cast(pid, {:send_data, raw_data, dest_ip, dest_port})

        {:error, reason} ->
          Logger.error("Failed to send to transport: #{reason}")
      end
    end
  end

  # Route SIP requests to transaction layer (RFC 3261 Section 17.2.3)
  defp route_message(%{type: :request, method: method} = message, state) do
    # Always route to handlers for visibility
    route_to_handlers(message, state)

    # Also try to route to transaction layer
    case ParrotSip.TransactionStatem.server_process(message, %{}) do
      :ok ->
        Logger.debug("Request forwarded to existing transaction: #{method}")

      {:ok, _pid} ->
        Logger.debug("New transaction created for request: #{method}")

      {:error, reason} ->
        Logger.debug("Transaction layer routing failed: #{inspect(reason)}")
    end

    :ok
  end

  # Route SIP responses to client transactions (RFC 3261 Section 17.1.3)
  defp route_message(%{type: :response, status_code: status} = message, state) do
    # For now, just route to handlers since we don't have client transaction lookup by response
    Logger.debug("Response received: #{status} - routing to handlers")
    route_to_handlers(message, state)
  end

  # Route to registered message handlers (for application-layer processing)
  defp route_to_handlers(message, state) do
    Logger.debug("Routing message to #{length(state.handlers)} registered handlers")
    Enum.each(state.handlers, &send(&1, {:sip_message, message}))
    :ok
  end

  defp resolve_transport(ref) when is_pid(ref), do: {:ok, ref}

  defp resolve_transport(ref) when is_atom(ref) do
    case Process.whereis(ref) do
      nil -> {:error, :transport_not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_transport(_), do: {:error, :invalid_transport_ref}

  defp resolve_host(host) when is_binary(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      error -> error
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(ip), do: inspect(ip)
end
