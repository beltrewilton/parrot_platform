defmodule ParrotExampleUac.Client do
  @moduledoc """
  Example UAC client that makes outbound SIP calls.

  This demonstrates how to integrate ParrotSip.UA with ParrotMedia.MediaSession
  for a complete SIP UAC with media handling.
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

  @doc """
  Make an outbound call to the given SIP URI.

  ## Examples

      ParrotExampleUac.Client.dial("sip:test@192.168.1.100:5060")
  """
  def dial(uri) do
    GenServer.call(__MODULE__, {:dial, uri})
  end

  @doc """
  Hang up an active call.
  """
  def hangup(call_id) do
    GenServer.call(__MODULE__, {:hangup, call_id})
  end

  @doc """
  List active calls.
  """
  def calls do
    GenServer.call(__MODULE__, :get_calls)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 5070)
    audio_file = Keyword.get(opts, :audio_file)

    Logger.info("ParrotExampleUac.Client starting on port #{port}")

    # Start the UA with our handler module
    {:ok, ua} = UA.start_link(ParrotExampleUac.Handler, {self(), audio_file}, port: port)
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
  def handle_call({:dial, uri}, _from, state) do
    Logger.info("Dialing: #{uri}")

    # Generate SDP offer for audio
    local_port = Enum.random(20000..30000)
    sdp = generate_sdp(local_port)

    case UA.dial(state.ua, uri, sdp: sdp) do
      {:ok, entity} ->
        call_info = %{
          entity: entity,
          local_port: local_port,
          started_at: DateTime.utc_now()
        }

        calls = Map.put(state.calls, entity.id, call_info)
        {:reply, {:ok, entity.id}, %{state | calls: calls}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:hangup, call_id}, _from, state) do
    case Map.get(state.calls, call_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      call_info ->
        UA.hangup(state.ua, call_info.entity)
        calls = Map.delete(state.calls, call_id)
        {:reply, :ok, %{state | calls: calls}}
    end
  end

  def handle_call(:get_calls, _from, state) do
    {:reply, state.calls, state}
  end

  @impl true
  def handle_cast({:call_answered, entity, remote_sdp}, state) do
    Logger.info("Call answered: #{entity.id}")

    case Map.get(state.calls, entity.id) do
      nil ->
        {:noreply, state}

      call_info ->
        # Start media session now that call is answered
        case start_media_session(call_info, remote_sdp, state) do
          {:ok, media_session} ->
            call_info = Map.put(call_info, :media_session, media_session)
            calls = Map.put(state.calls, entity.id, call_info)
            {:noreply, %{state | calls: calls}}

          {:error, reason} ->
            Logger.error("Failed to start media: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:call_ended, entity_id}, state) do
    case Map.get(state.calls, entity_id) do
      nil ->
        {:noreply, state}

      call_info ->
        if call_info[:media_session] do
          ParrotMedia.MediaSession.terminate_session(call_info.media_session)
        end

        calls = Map.delete(state.calls, entity_id)
        {:noreply, %{state | calls: calls}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ParrotExampleUac.Client received: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("ParrotExampleUac.Client terminating")

    if state.stack do
      stop_transport(state.stack)
    end

    if state.ua && Process.alive?(state.ua) do
      GenServer.stop(state.ua)
    end

    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp generate_sdp(local_port) do
    """
    v=0
    o=- #{System.unique_integer([:positive])} #{System.unique_integer([:positive])} IN IP4 127.0.0.1
    s=ParrotExampleUac
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio #{local_port} RTP/AVP 8 0
    a=rtpmap:8 PCMA/8000
    a=rtpmap:0 PCMU/8000
    a=sendrecv
    """
  end

  defp start_media_session(call_info, remote_sdp, state) do
    session_id = "media_#{call_info.entity.id}"

    {:ok, media_session} = ParrotMedia.MediaSession.start_link(
      id: session_id,
      dialog_id: call_info.entity.call_id,
      role: :uac,
      media_handler: ParrotExampleUac.MediaHandler,
      handler_args: %{entity_id: call_info.entity.id},
      supported_codecs: [:pcma, :pcmu],
      audio_file: state.audio_file
    )

    # Process the remote SDP answer
    case ParrotMedia.MediaSession.process_answer(media_session, remote_sdp) do
      {:ok, _} ->
        # Start media
        ParrotMedia.MediaSession.start_media(media_session)
        {:ok, media_session}

      error ->
        ParrotMedia.MediaSession.terminate_session(media_session)
        error
    end
  end

  defp start_transport(handler, port) do
    alias ParrotTransport.Types.ListenerConfig
    alias ParrotSip.TransportHandler

    {:ok, bridge} = start_bridge(handler)

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
