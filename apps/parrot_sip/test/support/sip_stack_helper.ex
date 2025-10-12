defmodule SippTest.SipStackHelper do
  @moduledoc """
  Helper module for wiring ParrotTransport + ParrotSip for integration tests.

  Follows the integration pattern from CORRECT_INTEGRATION.md to properly
  connect the transport and SIP layers.

  ## Usage

      # Start a complete SIP stack on UDP
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Get the actual port
      port = stack.port

      # Stop when done
      :ok = SipStackHelper.stop(stack)
  """

  use GenServer
  require Logger

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}
  alias ParrotSip.TransportHandler

  defstruct [
    :transport_listener,
    :transport_handler,
    :sip_handler,
    :port,
    :transport_type
  ]

  @type t :: %__MODULE__{
          transport_listener: pid(),
          transport_handler: pid(),
          sip_handler: ParrotSip.Handler.t(),
          port: integer(),
          transport_type: :udp | :tcp | :tls | :websocket
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a UDP SIP stack for testing.

  ## Parameters

    * `handler` - ParrotSip.Handler struct (created with TestHandler.new())
    * `opts` - Options:
      - `:port` - Port to listen on (default: 0 for random)
      - `:ip` - IP to bind to (default: {127, 0, 0, 1})

  ## Returns

    * `{:ok, stack}` - Stack struct with listener, handler, and port info
    * `{:error, reason}` - Startup failed

  ## Examples

      handler = SippTest.TestHandler.new()
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)
      # stack.port contains the actual bound port
  """
  def start_udp(handler, opts \\ []) do
    port = Keyword.get(opts, :port, 0)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    with {:ok, bridge} <- start_bridge(handler),
         {:ok, listener, actual_ip, actual_port} <- start_udp_listener(bridge, ip, port) do
      # Register this transport with the global TransportHandler using ACTUAL bound address
      :ok =
        TransportHandler.register_transport(
          ParrotSip.TransportHandler,
          listener,
          :udp,
          actual_ip,
          actual_port
        )

      stack = %__MODULE__{
        transport_listener: listener,
        transport_handler: bridge,
        sip_handler: handler,
        port: actual_port,
        transport_type: :udp
      }

      {:ok, stack}
    end
  end

  @doc """
  Starts a TCP SIP stack for testing.

  ## Parameters

    * `handler` - ParrotSip.Handler struct
    * `opts` - Options (same as start_udp/2)

  ## Returns

    * `{:ok, stack}` - Stack struct
    * `{:error, reason}` - Startup failed
  """
  def start_tcp(handler, opts \\ []) do
    port = Keyword.get(opts, :port, 0)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})

    with {:ok, bridge} <- start_bridge(handler),
         {:ok, listener, actual_ip, actual_port} <- start_tcp_listener(bridge, ip, port) do
      # Register this transport with the global TransportHandler using ACTUAL bound address
      :ok =
        TransportHandler.register_transport(
          ParrotSip.TransportHandler,
          listener,
          :tcp,
          actual_ip,
          actual_port
        )

      stack = %__MODULE__{
        transport_listener: listener,
        transport_handler: bridge,
        sip_handler: handler,
        port: actual_port,
        transport_type: :tcp
      }

      {:ok, stack}
    end
  end

  @doc """
  Starts a TLS SIP stack for testing.

  ## Parameters

    * `handler` - ParrotSip.Handler struct
    * `opts` - Options:
      - `:port` - Port to listen on (default: 0)
      - `:ip` - IP to bind to (default: {127, 0, 0, 1})
      - `:certfile` - TLS certificate path (required)
      - `:keyfile` - TLS key path (required)
      - `:cacertfile` - CA certificate path (optional)

  ## Returns

    * `{:ok, stack}` - Stack struct
    * `{:error, reason}` - Startup failed
  """
  def start_tls(handler, opts \\ []) do
    port = Keyword.get(opts, :port, 0)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    certfile = Keyword.fetch!(opts, :certfile)
    keyfile = Keyword.fetch!(opts, :keyfile)
    cacertfile = Keyword.get(opts, :cacertfile)

    with {:ok, bridge} <- start_bridge(handler),
         {:ok, listener, actual_ip, actual_port} <-
           start_tls_listener(bridge, ip, port, certfile, keyfile, cacertfile) do
      # Register this transport with the global TransportHandler using ACTUAL bound address
      :ok =
        TransportHandler.register_transport(
          ParrotSip.TransportHandler,
          listener,
          :tls,
          actual_ip,
          actual_port
        )

      stack = %__MODULE__{
        transport_listener: listener,
        transport_handler: bridge,
        sip_handler: handler,
        port: actual_port,
        transport_type: :tls
      }

      {:ok, stack}
    end
  end

  @doc """
  Stops the SIP stack and cleans up resources.

  ## Parameters

    * `stack` - Stack struct returned by start_udp/2, start_tcp/2, etc.

  ## Returns

    * `:ok`
  """
  def stop(%__MODULE__{} = stack) do
    # Stop transport listener
    case stack.transport_type do
      :udp -> ParrotTransport.stop_listener(stack.transport_listener)
      :tcp -> ParrotTransport.TcpListener.stop(stack.transport_listener)
      :tls -> ParrotTransport.TlsListener.stop(stack.transport_listener)
      :websocket -> ParrotTransport.WebsocketListener.stop(stack.transport_listener)
    end

    # Stop bridge process
    GenServer.stop(stack.transport_handler)

    :ok
  end

  # ============================================================================
  # GenServer Implementation (Bridge Process)
  # ============================================================================

  def start_bridge(sip_handler) do
    GenServer.start_link(__MODULE__, sip_handler)
  end

  @impl true
  def init(sip_handler) do
    # Use the TransportHandler that was started by ParrotSip.Application
    transport_handler = Process.whereis(ParrotSip.TransportHandler)

    unless transport_handler do
      raise "ParrotSip.TransportHandler not found - make sure ParrotSip application is started"
    end

    # Store both handler and transport_handler
    {:ok, %{sip_handler: sip_handler, transport_handler: transport_handler}}
  end

  @impl true
  def handle_info({:incoming_packet, %IncomingPacket{} = packet}, state) do
    # Parse and process SIP message directly
    alias ParrotSip.{Parser, Source, TransactionStatem}

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

        # Process through transaction layer with our handler
        TransactionStatem.server_process(message_with_source, state.sip_handler)

      {:error, reason} ->
        Logger.error("[SipStackHelper] Failed to parse SIP message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[SipStackHelper] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_udp_listener(bridge_pid, ip, port) do
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
        ParrotTransport.register_handler(listener, bridge_pid)
        {:ok, {actual_ip, actual_port}} = ParrotTransport.get_local_address(listener)
        {:ok, listener, actual_ip, actual_port}

      error ->
        error
    end
  end

  defp start_tcp_listener(bridge_pid, ip, port) do
    sip_trace = System.get_env("SIP_TRACE", "false") == "true"

    config = %ListenerConfig{
      transport: :tcp,
      ip: ip,
      port: port,
      trace: sip_trace
    }

    case ParrotTransport.start_tcp_listener(config, bridge_pid) do
      {:ok, listener} ->
        {:ok, {actual_ip, actual_port}} = ParrotTransport.TcpListener.get_local_address(listener)
        {:ok, listener, actual_ip, actual_port}

      error ->
        error
    end
  end

  defp start_tls_listener(bridge_pid, ip, port, certfile, keyfile, cacertfile) do
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

    case ParrotTransport.start_tls_listener(config, bridge_pid) do
      {:ok, listener} ->
        {:ok, {actual_ip, actual_port}} = ParrotTransport.TlsListener.get_local_address(listener)
        {:ok, listener, actual_ip, actual_port}

      error ->
        error
    end
  end
end
