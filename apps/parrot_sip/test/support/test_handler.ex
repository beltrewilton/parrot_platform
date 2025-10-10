defmodule SippTest.TestHandler do
  @moduledoc """
  A configurable SIP handler for SIPp integration testing.

  Implements the ParrotSip.Handler behavior and provides flexible
  response configuration and statistics tracking for test scenarios.

  ## Usage

      # Basic handler with auto-responses
      handler = TestHandler.new()

      # Handler with custom responses
      handler = TestHandler.new(
        invite_response: {180, "Ringing"},
        options_response: {200, "OK"}
      )

      # Get statistics
      stats = TestHandler.get_stats(handler_pid)
      assert stats.invites == 10
  """

  @behaviour ParrotSip.Handler

  require Logger
  alias ParrotSip.{Message, UAS}

  # ============================================================================
  # Required ParrotSip.Handler Callbacks
  # ============================================================================

  @impl true
  def transp_request(_msg, _args) do
    # Almost always return :process_transaction to route through normal flow
    :process_transaction
  end

  @impl true
  def transaction(_trans, _sip_msg, _args) do
    # Almost always return :process_uas for server side
    :process_uas
  end

  @impl true
  def transaction_stop(_trans, _result, _args) do
    # Called when transaction terminates - usually nothing to do
    :ok
  end

  @impl true
  def uas_request(uas, sip_msg, args) do
    # THIS IS WHERE THE MAIN LOGIC GOES
    # The Handler behavior will automatically dispatch to method-specific
    # callbacks (handle_invite/3, handle_bye/3, etc.) if they're defined
    # This is the fallback for methods without specific handlers

    Logger.debug("[TestHandler] uas_request fallback for method: #{sip_msg.method}")
    update_stats(args, :other)

    response = Message.reply(sip_msg, 501, "Not Implemented")
    UAS.response(response, uas)
    :ok
  end

  @impl true
  def uas_cancel(_uas_id, args) do
    Logger.debug("[TestHandler] uas_cancel called")
    update_stats(args, :cancels)
    :ok
  end

  @impl true
  def process_ack(_sip_msg, args) do
    Logger.debug("[TestHandler] process_ack called")
    update_stats(args, :acks)
    :ok
  end

  # ============================================================================
  # Optional Method-Specific Callbacks (automatically dispatched by ParrotSip.Handler)
  # ============================================================================

  @impl true
  def handle_invite(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_invite called")
    update_stats(args, :invites)

    config = get_config(args)
    {status, reason} = config[:invite_response] || {200, "OK"}

    # Build SDP if needed for 200 OK
    body = if status == 200 do
      config[:sdp_body] || """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Parrot SIP Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 10000 RTP/AVP 0 8 101
      a=rtpmap:0 PCMU/8000
      a=rtpmap:8 PCMA/8000
      a=rtpmap:101 telephone-event/8000
      a=fmtp:101 0-16
      a=sendrecv
      """
    else
      ""
    end

    response = Message.reply(sip_msg, status, reason)
    response = %{response | body: body}

    # Add Contact header if configured
    response = if config[:contact_uri] do
      %{response | contact: config[:contact_uri]}
    else
      response
    end

    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_options(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_options called")
    update_stats(args, :options)

    config = get_config(args)
    {status, reason} = config[:options_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    response = %{response |
      allow: ["INVITE", "ACK", "CANCEL", "OPTIONS", "BYE"],
      accept: "application/sdp",
      supported: ["replaces"]
    }

    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_bye(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_bye called")
    update_stats(args, :byes)

    config = get_config(args)
    {status, reason} = config[:bye_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_cancel(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_cancel called")
    update_stats(args, :cancels)

    config = get_config(args)
    {status, reason} = config[:cancel_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_register(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_register called")
    update_stats(args, :registers)

    config = get_config(args)
    {status, reason} = config[:register_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_subscribe(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_subscribe called")
    update_stats(args, :subscribes)

    config = get_config(args)
    {status, reason} = config[:subscribe_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_notify(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_notify called")
    update_stats(args, :notifies)

    config = get_config(args)
    {status, reason} = config[:notify_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_message(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_message called")
    update_stats(args, :messages)

    config = get_config(args)
    {status, reason} = config[:message_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    UAS.response(response, uas)
    :ok
  end

  @impl true
  def handle_info(uas, sip_msg, args) do
    Logger.debug("[TestHandler] handle_info called")
    update_stats(args, :infos)

    config = get_config(args)
    {status, reason} = config[:info_response] || {200, "OK"}

    response = Message.reply(sip_msg, status, reason)
    UAS.response(response, uas)
    :ok
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates a new TestHandler wrapped in ParrotSip.Handler struct.

  ## Options

    * `:invite_response` - Response for INVITE: {code, reason} (default: {200, "OK"})
    * `:options_response` - Response for OPTIONS: {code, reason} (default: {200, "OK"})
    * `:bye_response` - Response for BYE: {code, reason} (default: {200, "OK"})
    * `:cancel_response` - Response for CANCEL: {code, reason} (default: {200, "OK"})
    * `:register_response` - Response for REGISTER: {code, reason} (default: {200, "OK"})
    * `:subscribe_response` - Response for SUBSCRIBE: {code, reason} (default: {200, "OK"})
    * `:notify_response` - Response for NOTIFY: {code, reason} (default: {200, "OK"})
    * `:message_response` - Response for MESSAGE: {code, reason} (default: {200, "OK"})
    * `:info_response` - Response for INFO: {code, reason} (default: {200, "OK"})
    * `:sdp_body` - SDP body to include in 200 OK for INVITE (default: generated)
    * `:contact_uri` - Contact URI to include in responses (default: nil)

  ## Returns

    * `ParrotSip.Handler.t()` - Handler struct ready to use

  ## Examples

      handler = TestHandler.new()
      handler = TestHandler.new(invite_response: {180, "Ringing"})
  """
  def new(opts \\ []) do
    # Start a stats tracking process
    stats_pid = spawn(fn -> stats_loop(%{
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
    }) end)

    args = %{
      stats_pid: stats_pid,
      config: Enum.into(opts, %{})
    }

    ParrotSip.Handler.new(__MODULE__, args)
  end

  @doc """
  Gets current statistics from the handler.

  ## Parameters

    * `handler` - The ParrotSip.Handler struct returned by new/1

  ## Returns

    * Map with counts of each request type received
  """
  def get_stats(%ParrotSip.Handler{args: %{stats_pid: pid}}) do
    send(pid, {:get_stats, self()})
    receive do
      {:stats, stats} -> stats
    after
      5000 -> {:error, :timeout}
    end
  end

  @doc """
  Resets statistics counters to zero.
  """
  def reset_stats(%ParrotSip.Handler{args: %{stats_pid: pid}}) do
    send(pid, :reset_stats)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_config(%{config: config}), do: config
  defp get_config(_), do: %{}

  defp update_stats(%{stats_pid: pid}, key) when is_pid(pid) do
    send(pid, {:update_stat, key})
  end
  defp update_stats(_, _), do: :ok

  defp stats_loop(stats) do
    receive do
      {:get_stats, from} ->
        send(from, {:stats, stats})
        stats_loop(stats)

      :reset_stats ->
        stats_loop(%{
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
        })

      {:update_stat, key} ->
        new_stats = Map.update(stats, key, 1, &(&1 + 1))
        stats_loop(new_stats)
    end
  end

end
