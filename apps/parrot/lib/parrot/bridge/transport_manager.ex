defmodule Parrot.Bridge.TransportManager do
  @moduledoc """
  Manages SIP transport listeners for the Parrot DSL framework.

  This module starts and manages transport listeners (UDP, TCP, TLS) and
  wires them to the Bridge.Handler for processing incoming SIP messages.

  ## Architecture

  The TransportManager follows the SipStackHelper pattern:
  1. Starts transport listeners based on configuration
  2. Creates a bridge process to receive incoming packets
  3. Registers transports with ParrotSip.TransportHandler for response routing
  4. Routes incoming requests to TransactionStatem with the Bridge.Handler
  """

  use GenServer
  require Logger

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}
  alias ParrotSip.TransportHandler

  defstruct [
    :router,
    :sip_handler,
    transports: [],
    listeners: %{}
  ]

  @type transport_config :: {:udp | :tcp | :tls, keyword()}
  @type t :: %__MODULE__{
          router: module(),
          sip_handler: ParrotSip.Handler.t(),
          transports: [transport_config()],
          listeners: map()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the transport manager.

  ## Options

  * `:router` - Required. The router module for call routing.
  * `:transports` - Required. List of transport configurations.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the child specification for supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    router = Keyword.fetch!(opts, :router)
    transports = Keyword.get(opts, :transports, [])

    # Create the SIP handler that will be used for all transports
    sip_handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: router})

    state = %__MODULE__{
      router: router,
      sip_handler: sip_handler,
      transports: transports,
      listeners: %{}
    }

    # Start transports
    case start_transports(state) do
      {:ok, new_state} ->
        Logger.info("[TransportManager] Started with #{length(transports)} transport(s)")
        {:ok, new_state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:incoming_packet, %IncomingPacket{} = packet}, state) do
    # Parse and process SIP message
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

        # Route to appropriate transaction layer handler
        case message_with_source.type do
          :request ->
            # Process requests through server transaction layer with our handler
            TransactionStatem.server_process(message_with_source, state.sip_handler)

          :response ->
            # Process responses through client transaction layer
            via = List.first(message_with_source.via)
            TransactionStatem.client_response(via, packet.data)
        end

      {:error, reason} ->
        Logger.error("[TransportManager] Failed to parse SIP message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[TransportManager] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp start_transports(state) do
    Enum.reduce_while(state.transports, {:ok, state}, fn transport_config, {:ok, acc_state} ->
      case start_transport(transport_config, acc_state) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_transport({:udp, opts}, state) do
    port = Keyword.get(opts, :port, 5060)
    ip = Keyword.get(opts, :ip, {0, 0, 0, 0})
    sip_trace = System.get_env("SIP_TRACE", "false") == "true"

    config = %ListenerConfig{
      transport: :udp,
      ip: ip,
      port: port,
      trace: sip_trace
    }

    case ParrotTransport.start_listener(config) do
      {:ok, listener} ->
        # Register ourselves to receive packets
        ParrotTransport.register_handler(listener, self())

        # Get actual bound address
        {:ok, {actual_ip, actual_port}} = ParrotTransport.get_local_address(listener)

        # Register with global TransportHandler for response routing
        :ok =
          TransportHandler.register_transport(
            ParrotSip.TransportHandler,
            listener,
            :udp,
            actual_ip,
            actual_port
          )

        Logger.info("[TransportManager] Started UDP transport on #{format_ip(actual_ip)}:#{actual_port}")

        new_listeners = Map.put(state.listeners, {:udp, actual_ip, actual_port}, listener)
        {:ok, %{state | listeners: new_listeners}}

      {:error, reason} = error ->
        Logger.error("[TransportManager] Failed to start UDP transport: #{inspect(reason)}")
        error
    end
  end

  defp start_transport({:tcp, opts}, state) do
    port = Keyword.get(opts, :port, 5060)
    ip = Keyword.get(opts, :ip, {0, 0, 0, 0})
    sip_trace = System.get_env("SIP_TRACE", "false") == "true"

    config = %ListenerConfig{
      transport: :tcp,
      ip: ip,
      port: port,
      trace: sip_trace
    }

    case ParrotTransport.start_tcp_listener(config, self()) do
      {:ok, listener} ->
        {:ok, {actual_ip, actual_port}} = ParrotTransport.TcpListener.get_local_address(listener)

        :ok =
          TransportHandler.register_transport(
            ParrotSip.TransportHandler,
            listener,
            :tcp,
            actual_ip,
            actual_port
          )

        Logger.info("[TransportManager] Started TCP transport on #{format_ip(actual_ip)}:#{actual_port}")

        new_listeners = Map.put(state.listeners, {:tcp, actual_ip, actual_port}, listener)
        {:ok, %{state | listeners: new_listeners}}

      {:error, reason} = error ->
        Logger.error("[TransportManager] Failed to start TCP transport: #{inspect(reason)}")
        error
    end
  end

  defp start_transport({:tls, opts}, state) do
    port = Keyword.get(opts, :port, 5061)
    ip = Keyword.get(opts, :ip, {0, 0, 0, 0})
    certfile = Keyword.fetch!(opts, :certfile)
    keyfile = Keyword.fetch!(opts, :keyfile)
    cacertfile = Keyword.get(opts, :cacertfile)
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

    case ParrotTransport.start_tls_listener(config, self()) do
      {:ok, listener} ->
        {:ok, {actual_ip, actual_port}} = ParrotTransport.TlsListener.get_local_address(listener)

        :ok =
          TransportHandler.register_transport(
            ParrotSip.TransportHandler,
            listener,
            :tls,
            actual_ip,
            actual_port
          )

        Logger.info("[TransportManager] Started TLS transport on #{format_ip(actual_ip)}:#{actual_port}")

        new_listeners = Map.put(state.listeners, {:tls, actual_ip, actual_port}, listener)
        {:ok, %{state | listeners: new_listeners}}

      {:error, reason} = error ->
        Logger.error("[TransportManager] Failed to start TLS transport: #{inspect(reason)}")
        error
    end
  end

  defp start_transport({transport, _opts}, _state) do
    {:error, {:unsupported_transport, transport}}
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(ip), do: inspect(ip)
end
