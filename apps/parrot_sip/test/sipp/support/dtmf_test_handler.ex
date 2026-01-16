defmodule SippTest.DTMFTestHandler do
  @moduledoc """
  A specialized SIP/Media handler for testing RFC 4733 DTMF detection.

  This handler extends MediaTestHandler to track DTMF digits and report
  them to the test process for verification. Used with uac_rtp_dtmf.xml
  scenario to verify end-to-end DTMF detection through the pipeline.

  ## Usage

      # Create handler with test process for notifications
      handler = DTMFTestHandler.new(
        test_pid: self(),
        expected_digits: "1234#"
      )

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp scenario with RFC 4733 DTMF...

      # Verify DTMF was received
      assert_receive {:dtmf_collected, "1234#"}, 10_000

  ## Notifications sent to test_pid

    * `{:dtmf_received, digit}` - Each DTMF digit as it's detected
    * `{:dtmf_collected, digits}` - Full sequence when expected digits received
    * `{:dtmf_timeout, partial}` - If collection times out
  """

  @behaviour ParrotSip.Handler
  @behaviour ParrotMedia.Handler

  require Logger
  alias ParrotSip.Message
  alias ParrotSip.Transaction.Server
  alias ParrotMedia.MediaSession

  # ============================================================================
  # ParrotSip.Handler Callbacks
  # ============================================================================

  @impl ParrotSip.Handler
  def transp_request(_msg, _args), do: :process_transaction

  @impl ParrotSip.Handler
  def transaction(_trans, _sip_msg, _args), do: :process_uas

  @impl ParrotSip.Handler
  def transaction_stop(_trans, _result, _args), do: :ok

  @impl ParrotSip.Handler
  def uas_request(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 501, "Not Implemented")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def uas_cancel(_uas_id, _args), do: :ok

  @impl ParrotSip.Handler
  def process_ack(_sip_msg, _args), do: :ok

  @impl ParrotSip.Handler
  def handle_invite(uas, sip_msg, args) do
    Logger.info("[DTMFTestHandler] handle_invite called")
    config = get_config(args)
    call_id = sip_msg.call_id

    # Create media session with DTMF collection enabled
    media_opts = [
      id: "dtmf_#{call_id}",
      dialog_id: call_id,
      role: :uas,
      media_handler: __MODULE__,
      handler_args: %{
        test_pid: config[:test_pid],
        expected_digits: config[:expected_digits],
        collected_digits: "",
        call_id: call_id
      },
      audio_source: :silence,
      audio_sink: :none,
      supported_codecs: [:pcma]
    ]

    case MediaSession.start_link(media_opts) do
      {:ok, media_pid} ->
        Logger.info("[DTMFTestHandler] MediaSession started: #{inspect(media_pid)}")
        update_media_session(args, call_id, media_pid)

        case sip_msg.body do
          "" ->
            response = Message.reply(sip_msg, 200, "OK")
            Server.response(response, uas)
            :ok

          sdp_offer ->
            case MediaSession.process_offer(media_pid, sdp_offer) do
              {:ok, sdp_answer} ->
                :ok = MediaSession.start_media(media_pid)

                # Start DTMF collection immediately
                send(media_pid, {:collect_dtmf, max: 20, terminators: [], timeout: 30_000})

                response = Message.reply(sip_msg, 200, "OK")
                # Set body with SDP answer and Content-Type header
                content_type = ParrotSip.Headers.ContentType.new("application", "sdp")
                # Build proper Contact header with our local address
                {local_ip, local_port} = sip_msg.source.local
                local_ip_str = local_ip |> Tuple.to_list() |> Enum.join(".")
                contact_uri = %ParrotSip.Uri{scheme: "sip", host: local_ip_str, port: local_port, parameters: %{}, headers: %{}}
                contact = %ParrotSip.Headers.Contact{uri: contact_uri, parameters: %{}}
                response = %{response | body: sdp_answer, content_type: content_type, contact: contact}
                Server.response(response, uas)
                :ok

              {:error, reason} ->
                Logger.error("[DTMFTestHandler] SDP negotiation failed: #{inspect(reason)}")
                response = Message.reply(sip_msg, 488, "Not Acceptable Here")
                Server.response(response, uas)
                :ok
            end
        end

      {:error, reason} ->
        Logger.error("[DTMFTestHandler] Failed to start MediaSession: #{inspect(reason)}")
        response = Message.reply(sip_msg, 500, "Internal Server Error")
        Server.response(response, uas)
        :ok
    end
  end

  @impl ParrotSip.Handler
  def handle_bye(uas, sip_msg, args) do
    Logger.info("[DTMFTestHandler] handle_bye called")
    call_id = sip_msg.call_id

    case get_media_session(args, call_id) do
      nil -> :ok
      media_pid -> GenServer.stop(media_pid, :normal)
    end

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_options(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_cancel(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_register(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_subscribe(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_notify(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_message(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_info(uas, sip_msg, _args) do
    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  # ============================================================================
  # ParrotMedia.Handler Callbacks
  # ============================================================================

  @impl ParrotMedia.Handler
  def init(args) do
    Logger.info("[DTMFTestHandler] MediaHandler init: #{inspect(args)}")
    {:ok, args}
  end

  @impl ParrotMedia.Handler
  def handle_session_start(_session_id, _opts, state) do
    Logger.info("[DTMFTestHandler] handle_session_start")
    {:ok, state}
  end

  @impl ParrotMedia.Handler
  def handle_offer(_sdp, _direction, state) do
    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_answer(_sdp, _direction, state) do
    {:ok, state}
  end

  @impl ParrotMedia.Handler
  def handle_stream_start(_session_id, _direction, state) do
    Logger.info("[DTMFTestHandler] handle_stream_start - ready for DTMF")
    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_stream_stop(_session_id, _reason, state) do
    {:ok, state}
  end

  @impl ParrotMedia.Handler
  def handle_play_complete(_file, state) do
    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_codec_negotiation(offered, supported, state) do
    codec = Enum.find(supported, fn c -> c in offered end) || hd(supported)
    {:ok, codec, state}
  end

  @impl ParrotMedia.Handler
  def handle_negotiation_complete(_answer, _offer, _codec, state) do
    {:ok, state}
  end

  @impl ParrotMedia.Handler
  def handle_info({:media_event, _session_id, {:dtmf_collected, digits}}, state) do
    Logger.info("[DTMFTestHandler] DTMF collection complete: #{digits}")

    if state[:test_pid] do
      send(state[:test_pid], {:dtmf_collected, digits})
    end

    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_info({:media_event, _session_id, {:dtmf_timeout, digits}}, state) do
    Logger.info("[DTMFTestHandler] DTMF timeout with digits: #{digits}")

    if state[:test_pid] do
      send(state[:test_pid], {:dtmf_timeout, digits})
    end

    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_info(msg, state) do
    Logger.debug("[DTMFTestHandler] handle_info: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates a new DTMFTestHandler wrapped in ParrotSip.Handler struct.

  ## Options

    * `:test_pid` - PID to send DTMF notifications to (required for verification)
    * `:expected_digits` - Expected DTMF sequence (for logging/verification)

  ## Returns

    * `ParrotSip.Handler.t()` - Handler struct ready to use
  """
  def new(opts \\ []) do
    {:ok, media_sessions_pid} = Agent.start_link(fn -> %{} end)

    args = %{
      media_sessions_pid: media_sessions_pid,
      config: Enum.into(opts, %{})
    }

    ParrotSip.Handler.new(__MODULE__, args)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_config(%{config: config}), do: config
  defp get_config(_), do: %{}

  defp update_media_session(%{media_sessions_pid: pid}, call_id, media_pid) when is_pid(pid) do
    Agent.update(pid, fn sessions -> Map.put(sessions, call_id, media_pid) end)
  end

  defp update_media_session(_, _, _), do: :ok

  defp get_media_session(%{media_sessions_pid: pid}, call_id) when is_pid(pid) do
    Agent.get(pid, fn sessions -> Map.get(sessions, call_id) end)
  end

  defp get_media_session(_, _), do: nil
end
