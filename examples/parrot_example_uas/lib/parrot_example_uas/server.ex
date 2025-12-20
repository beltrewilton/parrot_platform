defmodule ParrotExampleUas.Server do
  @moduledoc """
  Example UAS server that answers incoming SIP calls and plays audio.

  This demonstrates how to integrate ParrotSip.UA with ParrotMedia.MediaSession
  for a complete SIP UAS with media handling.
  """

  use GenServer
  require Logger

  alias ParrotSip.UA

  defstruct [:ua, :stack, :port, :audio_file, :calls]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_calls do
    GenServer.call(__MODULE__, :get_calls)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 5060)
    audio_file = Keyword.get(opts, :audio_file)

    Logger.info("ParrotExampleUas.Server starting on port #{port}")

    # Start the UA with our handler module
    {:ok, ua} = UA.start_link(ParrotExampleUas.Handler, {self(), audio_file}, port: port)
    Logger.info("UA started: #{inspect(ua)}")

    # Get the handler struct for transport routing
    handler = UA.get_handler(ua)

    # Start UDP transport and wire it to the UA
    {:ok, stack} = start_transport(handler, port)
    Logger.info("Transport started on port #{port}")

    state = %__MODULE__{
      ua: ua,
      stack: stack,
      port: port,
      audio_file: audio_file,
      calls: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_calls, _from, state) do
    {:reply, state.calls, state}
  end

  @impl true
  def handle_cast({:call_started, entity, media_session}, state) do
    call_info = %{
      entity: entity,
      media_session: media_session,
      started_at: DateTime.utc_now()
    }

    calls = Map.put(state.calls, entity.id, call_info)
    {:noreply, %{state | calls: calls}}
  end

  @impl true
  def handle_cast({:call_ended, entity_id}, state) do
    calls = Map.delete(state.calls, entity_id)
    {:noreply, %{state | calls: calls}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ParrotExampleUas.Server received: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("ParrotExampleUas.Server terminating")

    # Stop transport
    if state.stack do
      stop_transport(state.stack)
    end

    # Stop UA
    if state.ua && Process.alive?(state.ua) do
      GenServer.stop(state.ua)
    end

    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp start_transport(handler, port) do
    alias ParrotTransport.Types.ListenerConfig
    alias ParrotSip.TransportHandler

    # Create bridge process for transport -> SIP routing
    {:ok, bridge} = start_bridge(handler)

    # Start UDP listener
    config = %ListenerConfig{
      transport: :udp,
      ip: {0, 0, 0, 0},
      port: port,
      trace: false
    }

    case ParrotTransport.start_listener(config) do
      {:ok, listener} ->
        ParrotTransport.register_handler(listener, bridge)
        {:ok, {actual_ip, actual_port}} = ParrotTransport.get_local_address(listener)

        # Register with transport handler
        :ok = TransportHandler.register_transport(
          ParrotSip.TransportHandler,
          listener,
          :udp,
          actual_ip,
          actual_port
        )

        {:ok, %{listener: listener, bridge: bridge, port: actual_port}}

      error ->
        error
    end
  end

  defp start_bridge(sip_handler) do
    Task.start_link(fn -> bridge_loop(sip_handler) end)
  end

  defp bridge_loop(sip_handler) do
    receive do
      {:incoming_packet, packet} ->
        handle_incoming_packet(packet, sip_handler)
        bridge_loop(sip_handler)

      _ ->
        bridge_loop(sip_handler)
    end
  end

  defp handle_incoming_packet(packet, sip_handler) do
    alias ParrotSip.{Parser, Source, TransactionStatem}

    case Parser.parse(packet.data) do
      {:ok, sip_message} ->
        source = %Source{
          transport: packet.source.transport,
          remote: packet.source.remote_addr,
          local: packet.source.local_addr,
          connection: packet.source.connection
        }

        message_with_source = Map.put(sip_message, :source, source)

        case message_with_source.type do
          :request ->
            TransactionStatem.server_process(message_with_source, sip_handler)
          :response ->
            via = List.first(message_with_source.via)
            TransactionStatem.client_response(via, packet.data)
        end

      {:error, reason} ->
        Logger.error("Failed to parse SIP message: #{inspect(reason)}")
    end
  end

  defp stop_transport(%{listener: listener, bridge: bridge}) do
    ParrotTransport.stop_listener(listener)
    Process.exit(bridge, :normal)
    :ok
  end
end
