defmodule ParrotSip.Stack do
  @moduledoc """
  A complete SIP stack that encapsulates transport and SIP protocol layers.

  This module provides a simple, high-level API for running a SIP stack without
  manually wiring transport listeners, bridge processes, and handler registration.

  ## The Bridge Pattern

  Stack implements the complete "bridge pattern" needed for SIP:
  1. **Request Routing**: Parses incoming packets and routes requests to `TransactionStatem.server_process/2`
  2. **Response Routing**: Delegates to `TransportHandler` for response routing
  3. **Transport Management**: Automatically starts/stops transport listeners
  4. **Handler Dispatch**: Routes all requests to your configured handler

  ## Usage

      # Start a UDP SIP stack
      {:ok, stack} = ParrotSip.Stack.start_link(
        handler: my_handler,
        transport: :udp,
        port: 5060
      )

      # Get the actual bound port
      port = ParrotSip.Stack.get_port(stack)

      # Stop when done
      ParrotSip.Stack.stop(stack)

  ## Options

    * `:handler` - (required) ParrotSip.Handler struct for processing requests
    * `:transport` - (required) Transport type - `:udp`, `:tcp`, or `:tls`
    * `:port` - Port to bind (default: 0 for random port)
    * `:ip` - IP address to bind (default: {127, 0, 0, 1})
    * `:certfile` - Path to TLS certificate (required for `:tls`)
    * `:keyfile` - Path to TLS key (required for `:tls`)
    * `:cacertfile` - Path to CA certificate (optional for `:tls`)

  ## Examples

      # UDP stack on random port
      handler = MyHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp)

      # TCP stack on specific port
      {:ok, stack} = Stack.start_link(
        handler: handler,
        transport: :tcp,
        port: 5060,
        ip: {0, 0, 0, 0}
      )

      # TLS stack with certificates
      {:ok, stack} = Stack.start_link(
        handler: handler,
        transport: :tls,
        port: 5061,
        certfile: "path/to/cert.pem",
        keyfile: "path/to/key.pem"
      )

  ## Comparison with Manual Wiring

  Without Stack (manual wiring - ~50 lines):
  ```elixir
  {:ok, bridge} = GenServer.start_link(MyBridge, handler)
  {:ok, listener} = ParrotTransport.start_listener(config)
  ParrotTransport.register_handler(listener, bridge)
  {:ok, {ip, port}} = ParrotTransport.get_local_address(listener)
  TransportHandler.register_transport(ParrotSip.TransportHandler, listener, :udp, ip, port)
  # Plus bridge process implementation...
  ```

  With Stack (one line):
  ```elixir
  {:ok, stack} = Stack.start_link(handler: handler, transport: :udp)
  ```
  """

  use GenServer
  require Logger

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}
  alias ParrotSip.{Parser, Source, TransactionStatem, TransportHandler}

  defstruct [
    :transport_listener,
    :sip_handler,
    :port,
    :ip,
    :transport_type
  ]

  @type t :: %__MODULE__{
          transport_listener: pid(),
          sip_handler: ParrotSip.Handler.t(),
          port: integer(),
          ip: :inet.ip_address(),
          transport_type: :udp | :tcp | :tls | :websocket
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a SIP stack.

  ## Options

    * `:handler` - (required) ParrotSip.Handler struct
    * `:transport` - (required) Transport type - `:udp`, `:tcp`, or `:tls`
    * `:port` - Port to bind (default: 0 for random port)
    * `:ip` - IP address to bind (default: {127, 0, 0, 1})
    * `:certfile` - Path to TLS certificate (required for `:tls`)
    * `:keyfile` - Path to TLS key (required for `:tls`)
    * `:cacertfile` - Path to CA certificate (optional for `:tls`)

  ## Returns

    * `{:ok, pid}` - Stack process PID
    * `{:error, reason}` - Startup failed

  ## Examples

      handler = MyHandler.new()
      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 5060)
  """
  def start_link(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        {:ok, pid}

      :ignore ->
        # Convert :ignore to {:error, reason} by checking what the error was
        handler = Keyword.get(opts, :handler)
        transport = Keyword.get(opts, :transport)

        cond do
          is_nil(handler) -> {:error, :missing_handler}
          is_nil(transport) -> {:error, :missing_transport}
          transport == :websocket -> {:error, :websocket_not_yet_supported}
          transport not in [:udp, :tcp, :tls] -> {:error, {:invalid_transport, transport}}
          true -> {:error, :unknown}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the actual bound port for the stack.

  Useful when starting with `port: 0` to get a random port.

  ## Examples

      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp, port: 0)
      port = Stack.get_port(stack)
      # port might be 35847 (random)
  """
  def get_port(stack) do
    GenServer.call(stack, :get_port)
  end

  @doc """
  Gets the actual bound IP address for the stack.

  ## Examples

      {:ok, stack} = Stack.start_link(handler: handler, transport: :udp)
      ip = Stack.get_ip(stack)
      # ip is {127, 0, 0, 1}
  """
  def get_ip(stack) do
    GenServer.call(stack, :get_ip)
  end

  @doc """
  Stops the SIP stack and cleans up all resources.

  This will:
  1. Stop the transport listener
  2. Clean up any connections
  3. Terminate the stack process

  ## Examples

      Stack.stop(stack)
      # :ok
  """
  def stop(stack) do
    GenServer.stop(stack)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    # Validate required options
    with {:ok, handler} <- Keyword.fetch(opts, :handler),
         {:ok, transport_type} <- Keyword.fetch(opts, :transport) do
      port = Keyword.get(opts, :port, 0)
      ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

      do_init(handler, transport_type, port, ip, opts)
    else
      :error ->
        # Missing required option - return :ignore so start_link can convert to error
        :ignore
    end
  end

  defp do_init(handler, transport_type, port, ip, opts) do
    # Start the appropriate transport listener
    result =
      case transport_type do
        :udp ->
          start_udp_listener(ip, port)

        :tcp ->
          start_tcp_listener(ip, port)

        :tls ->
          certfile = Keyword.fetch!(opts, :certfile)
          keyfile = Keyword.fetch!(opts, :keyfile)
          cacertfile = Keyword.get(opts, :cacertfile)
          start_tls_listener(ip, port, certfile, keyfile, cacertfile)

        :websocket ->
          {:error, :websocket_not_yet_supported}

        _ ->
          {:error, {:invalid_transport, transport_type}}
      end

    case result do
      {:ok, listener, actual_ip, actual_port} ->
        # Register transport with global TransportHandler for response routing
        :ok =
          TransportHandler.register_transport(
            ParrotSip.TransportHandler,
            listener,
            transport_type,
            actual_ip,
            actual_port
          )

        state = %__MODULE__{
          transport_listener: listener,
          sip_handler: handler,
          port: actual_port,
          ip: actual_ip,
          transport_type: transport_type
        }

        {:ok, state}

      {:error, _reason} ->
        # Return :ignore to prevent GenServer from starting and allow caller to get error
        :ignore
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call(:get_ip, _from, state) do
    {:reply, state.ip, state}
  end

  @impl true
  def handle_info({:incoming_packet, %IncomingPacket{} = packet}, state) do
    # This is the REQUEST BRIDGE: Parse incoming packets and route to transaction layer
    case Parser.parse(packet.data) do
      {:ok, sip_message} ->
        # Add source information
        source = %Source{
          transport: packet.source.transport,
          remote: packet.source.remote_addr,
          local: packet.source.local_addr,
          connection: packet.source.connection
        }

        message_with_source = Map.put(sip_message, :source, source)

        # Route to appropriate transaction layer handler
        case message_with_source.type do
          :request ->
            # Process requests through server transaction layer with OUR handler
            TransactionStatem.server_process(message_with_source, state.sip_handler)

          :response ->
            # Process responses through client transaction layer
            # Extract Via header and pass raw binary message
            via = List.first(message_with_source.via)
            TransactionStatem.client_response(via, packet.data)
        end

      {:error, reason} ->
        Logger.error("[Stack] Failed to parse SIP message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[Stack] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up transport listener on termination
    case state.transport_type do
      :udp -> ParrotTransport.stop_listener(state.transport_listener)
      :tcp -> ParrotTransport.TcpListener.stop(state.transport_listener)
      :tls -> ParrotTransport.TlsListener.stop(state.transport_listener)
      :websocket -> ParrotTransport.WebsocketListener.stop(state.transport_listener)
      _ -> :ok
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_udp_listener(ip, port) do
    # Check for SIP_TRACE environment variable
    sip_trace = System.get_env("SIP_TRACE", "false") == "true"

    config = %ListenerConfig{
      transport: :udp,
      ip: ip,
      port: port,
      trace: sip_trace
    }

    case ParrotTransport.start_listener(config) do
      {:ok, listener} ->
        # Register ourselves as the handler for incoming packets
        ParrotTransport.register_handler(listener, self())
        {:ok, {actual_ip, actual_port}} = ParrotTransport.get_local_address(listener)
        {:ok, listener, actual_ip, actual_port}

      error ->
        error
    end
  end

  defp start_tcp_listener(ip, port) do
    sip_trace = System.get_env("SIP_TRACE", "false") == "true"

    config = %ListenerConfig{
      transport: :tcp,
      ip: ip,
      port: port,
      trace: sip_trace
    }

    # TCP listeners need handler passed at creation time
    case ParrotTransport.start_tcp_listener(config, self()) do
      {:ok, listener} ->
        {:ok, {actual_ip, actual_port}} = ParrotTransport.TcpListener.get_local_address(listener)
        {:ok, listener, actual_ip, actual_port}

      error ->
        error
    end
  end

  defp start_tls_listener(ip, port, certfile, keyfile, cacertfile) do
    sip_trace = System.get_env("SIP_TRACE", "false") == "true"

    config = %ListenerConfig{
      transport: :tls,
      ip: ip,
      port: port,
      certfile: certfile,
      keyfile: keyfile,
      cacertfile: cacertfile,
      trace: sip_trace
    }

    # TLS listeners need handler passed at creation time
    case ParrotTransport.start_tls_listener(config, self()) do
      {:ok, listener} ->
        {:ok, {actual_ip, actual_port}} = ParrotTransport.TlsListener.get_local_address(listener)
        {:ok, listener, actual_ip, actual_port}

      error ->
        error
    end
  end
end
