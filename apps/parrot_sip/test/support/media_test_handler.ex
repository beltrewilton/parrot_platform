defmodule SippTest.MediaTestHandler do
  @moduledoc """
  A SIP handler for testing media flows with SIPp.

  This handler integrates ParrotSip and ParrotMedia to create complete
  SIP+media sessions during SIPp integration tests. It automatically:

  - Creates MediaSession on INVITE
  - Processes SDP offers/answers
  - Starts media streams
  - Tracks SIP method statistics

  ## Usage

      # Create handler
      handler = MediaTestHandler.new(
        audio_source: :silence,
        audio_sink: :none
      )

      # Start SIP stack
      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      # Run SIPp scenario...

      # Check statistics
      stats = MediaTestHandler.get_stats(handler)
      assert stats.invites > 0
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
  def transp_request(_msg, _args) do
    :process_transaction
  end

  @impl ParrotSip.Handler
  def transaction(_trans, _sip_msg, _args) do
    :process_uas
  end

  @impl ParrotSip.Handler
  def transaction_stop(_trans, _result, _args) do
    :ok
  end

  @impl ParrotSip.Handler
  def uas_request(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] uas_request fallback for method: #{sip_msg.method}")
    update_stats(args, :other)

    response = Message.reply(sip_msg, 501, "Not Implemented")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def uas_cancel(_uas_id, args) do
    Logger.debug("[MediaTestHandler] uas_cancel called")
    update_stats(args, :cancels)
    :ok
  end

  @impl ParrotSip.Handler
  def process_ack(_sip_msg, args) do
    Logger.debug("[MediaTestHandler] process_ack called")
    update_stats(args, :acks)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_invite(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_invite called")
    update_stats(args, :invites)

    config = get_config(args)
    call_id = sip_msg.call_id

    # Create media session for this call
    media_opts = [
      id: "media_#{call_id}",
      dialog_id: call_id,
      role: :uas,
      media_handler: __MODULE__,
      handler_args: %{
        test_pid: config[:test_pid]
      },
      audio_source: config[:audio_source] || :silence,
      audio_sink: config[:audio_sink] || :none,
      audio_file: config[:audio_file],
      supported_codecs: config[:supported_codecs] || [:pcma]
    ]

    case MediaSession.start_link(media_opts) do
      {:ok, media_pid} ->
        Logger.debug("[MediaTestHandler] MediaSession started: #{inspect(media_pid)}")

        # Store media session PID
        update_media_session(args, call_id, media_pid)

        # Process SDP offer if present
        case sip_msg.body do
          "" ->
            # No SDP in INVITE, send 200 without SDP
            response = Message.reply(sip_msg, 200, "OK")
            Server.response(response, uas)
            :ok

          sdp_offer ->
            # Process offer and generate answer
            case MediaSession.process_offer(media_pid, sdp_offer) do
              {:ok, sdp_answer} ->
                Logger.debug("[MediaTestHandler] SDP negotiation successful")

                # Start media immediately
                :ok = MediaSession.start_media(media_pid)

                # Send 200 OK with SDP answer
                response = Message.reply(sip_msg, 200, "OK")
                response = %{response | body: sdp_answer}
                Server.response(response, uas)
                :ok

              {:error, reason} ->
                Logger.error("[MediaTestHandler] SDP negotiation failed: #{inspect(reason)}")
                response = Message.reply(sip_msg, 488, "Not Acceptable Here")
                Server.response(response, uas)
                :ok
            end
        end

      {:error, reason} ->
        Logger.error("[MediaTestHandler] Failed to start MediaSession: #{inspect(reason)}")
        response = Message.reply(sip_msg, 500, "Internal Server Error")
        Server.response(response, uas)
        :ok
    end
  end

  @impl ParrotSip.Handler
  def handle_bye(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_bye called")
    update_stats(args, :byes)

    # Stop media session if exists
    call_id = sip_msg.call_id

    case get_media_session(args, call_id) do
      nil ->
        Logger.debug("[MediaTestHandler] No media session found for call_id: #{call_id}")

      media_pid ->
        Logger.debug("[MediaTestHandler] Stopping media session: #{inspect(media_pid)}")
        # MediaSession will stop automatically when we stop monitoring it
        GenServer.stop(media_pid, :normal)
        remove_media_session(args, call_id)
    end

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_options(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_options called")
    update_stats(args, :options)

    response = Message.reply(sip_msg, 200, "OK")

    response = %{
      response
      | allow: ["INVITE", "ACK", "CANCEL", "OPTIONS", "BYE"],
        accept: "application/sdp",
        supported: ["replaces"]
    }

    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_cancel(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_cancel called")
    update_stats(args, :cancels)

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_register(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_register called")
    update_stats(args, :registers)

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_subscribe(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_subscribe called")
    update_stats(args, :subscribes)

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_notify(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_notify called")
    update_stats(args, :notifies)

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_message(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_message called")
    update_stats(args, :messages)

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  @impl ParrotSip.Handler
  def handle_info(uas, sip_msg, args) do
    Logger.debug("[MediaTestHandler] handle_info called")
    update_stats(args, :infos)

    response = Message.reply(sip_msg, 200, "OK")
    Server.response(response, uas)
    :ok
  end

  # ============================================================================
  # ParrotMedia.Handler Callbacks
  # ============================================================================

  @impl ParrotMedia.Handler
  def init(args) do
    Logger.debug("[MediaTestHandler] MediaHandler init called with args: #{inspect(args)}")
    {:ok, args}
  end

  @impl ParrotMedia.Handler
  def handle_session_start(_session_id, _opts, state) do
    Logger.debug("[MediaTestHandler] handle_session_start called")
    {:ok, state}
  end

  @impl ParrotMedia.Handler
  def handle_offer(_sdp, _direction, state) do
    Logger.debug("[MediaTestHandler] handle_offer called")
    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_answer(_sdp, _direction, state) do
    Logger.debug("[MediaTestHandler] handle_answer called")
    {:ok, state}
  end

  @impl ParrotMedia.Handler
  def handle_stream_start(_session_id, _direction, state) do
    Logger.debug("[MediaTestHandler] handle_stream_start called")
    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_stream_stop(_session_id, _reason, state) do
    Logger.debug("[MediaTestHandler] handle_stream_stop called")
    {:ok, state}
  end

  # Note: handle_dtmf is not part of ParrotMedia.Handler behaviour
  def handle_dtmf(digit, state) do
    Logger.debug("[MediaTestHandler] handle_dtmf called: #{digit}")
    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_play_complete(_file, state) do
    Logger.debug("[MediaTestHandler] handle_play_complete called")
    {:noreply, state}
  end

  # Note: handle_record_complete is not part of ParrotMedia.Handler behaviour
  def handle_record_complete(_file, state) do
    Logger.debug("[MediaTestHandler] handle_record_complete called")
    {:noreply, state}
  end

  # Note: handle_error is not part of ParrotMedia.Handler behaviour
  def handle_error(error, state) do
    Logger.error("[MediaTestHandler] handle_error called: #{inspect(error)}")
    {:noreply, state}
  end

  @impl ParrotMedia.Handler
  def handle_codec_negotiation(offered, supported, state) do
    Logger.debug(
      "[MediaTestHandler] handle_codec_negotiation called - offered: #{inspect(offered)}, supported: #{inspect(supported)}"
    )

    # Pick the first common codec
    codec = Enum.find(supported, fn c -> c in offered end) || hd(supported)
    Logger.debug("[MediaTestHandler] Selected codec: #{codec}")
    {:ok, codec, state}
  end

  @impl ParrotMedia.Handler
  def handle_negotiation_complete(_answer, _offer, codec, state) do
    Logger.debug("[MediaTestHandler] handle_negotiation_complete - codec: #{codec}")
    {:ok, state}
  end

  @impl ParrotMedia.Handler
  def handle_info(msg, state) do
    Logger.debug("[MediaTestHandler] MediaHandler handle_info: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates a new MediaTestHandler wrapped in ParrotSip.Handler struct.

  ## Options

    * `:test_pid` - PID to send notifications to (optional)
    * `:audio_source` - Audio source: :file | :device | :silence (default: :silence)
    * `:audio_sink` - Audio sink: :none | :device | :file (default: :none)
    * `:audio_file` - Path to audio file when audio_source is :file
    * `:supported_codecs` - List of supported codecs (default: [:pcma])

  ## Returns

    * `ParrotSip.Handler.t()` - Handler struct ready to use
  """
  def new(opts \\ []) do
    # Start Agent for stats tracking
    {:ok, stats_pid} =
      Agent.start_link(fn ->
        %{
          invites: 0,
          acks: 0,
          byes: 0,
          cancels: 0,
          options: 0,
          registers: 0,
          subscribes: 0,
          notifies: 0,
          messages: 0,
          infos: 0,
          other: 0
        }
      end)

    # Start Agent for media sessions tracking
    {:ok, media_sessions_pid} = Agent.start_link(fn -> %{} end)

    args = %{
      stats_pid: stats_pid,
      media_sessions_pid: media_sessions_pid,
      config: Enum.into(opts, %{})
    }

    ParrotSip.Handler.new(__MODULE__, args)
  end

  @doc """
  Gets current statistics from the handler.
  """
  def get_stats(%ParrotSip.Handler{args: %{stats_pid: pid}}) do
    Agent.get(pid, & &1)
  end

  @doc """
  Resets statistics counters to zero.
  """
  def reset_stats(%ParrotSip.Handler{args: %{stats_pid: pid}}) do
    Agent.update(pid, fn _ ->
      %{
        invites: 0,
        acks: 0,
        byes: 0,
        cancels: 0,
        options: 0,
        registers: 0,
        subscribes: 0,
        notifies: 0,
        messages: 0,
        infos: 0,
        other: 0
      }
    end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_config(%{config: config}), do: config
  defp get_config(_), do: %{}

  defp update_stats(%{stats_pid: pid}, key) when is_pid(pid) do
    Agent.update(pid, fn stats -> Map.update(stats, key, 1, &(&1 + 1)) end)
  end

  defp update_stats(_, _), do: :ok

  defp update_media_session(%{media_sessions_pid: pid}, call_id, media_pid) when is_pid(pid) do
    Agent.update(pid, fn sessions -> Map.put(sessions, call_id, media_pid) end)
  end

  defp update_media_session(_, _, _), do: :ok

  defp get_media_session(%{media_sessions_pid: pid}, call_id) when is_pid(pid) do
    Agent.get(pid, fn sessions -> Map.get(sessions, call_id) end)
  end

  defp get_media_session(_, _), do: nil

  defp remove_media_session(%{media_sessions_pid: pid}, call_id) when is_pid(pid) do
    Agent.update(pid, fn sessions -> Map.delete(sessions, call_id) end)
  end

  defp remove_media_session(_, _), do: :ok
end
