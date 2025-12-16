defmodule ParrotSip.UAS do
  @moduledoc """
  User Agent Server - handles incoming INVITE requests.

  Follows RFC 3261 INVITE server transaction semantics with Dialog integration.
  """

  @behaviour :gen_statem
  require Logger

  alias ParrotSip.{Message, Dialog, DialogStatem, TimerHelpers}
  alias ParrotSip.Transaction.{Server, Client}
  alias ParrotSip.Headers.{Via, CSeq}

  defstruct [
    :id,
    :dialog_id,
    :dialog,
    :dialog_ref,
    :invite,
    :owner,
    :notify_fun,
    :uas,
    :timers,
    :metadata,
    :local_host,
    :local_port,
    :transport,
    # CSeq tracking per RFC 3261 Section 12.2.1.1
    # For UAS, starts at 0 (no requests sent yet)
    local_seq: 0
  ]

  # Public API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @spec ring(pid(), keyword()) :: :ok
  def ring(uas, opts \\ []) do
    :gen_statem.call(uas, {:ring, opts})
  end

  @spec answer(pid(), keyword()) :: :ok
  def answer(uas, opts) do
    :gen_statem.call(uas, {:answer, opts})
  end

  @spec reject(pid(), pos_integer(), keyword()) :: :ok
  def reject(uas, status_code, opts \\ []) when status_code >= 300 do
    :gen_statem.call(uas, {:reject, status_code, opts})
  end

  @spec hangup(pid()) :: :ok
  def hangup(uas) do
    :gen_statem.call(uas, :hangup)
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init(opts) do
    invite = Keyword.fetch!(opts, :invite)
    owner = Keyword.fetch!(opts, :owner)
    notify_fun = Keyword.fetch!(opts, :notify_fun)
    uas = Keyword.fetch!(opts, :uas)

    local_host = Keyword.get(opts, :local_host, "127.0.0.1")
    local_port = Keyword.get(opts, :local_port, 5060)
    transport = Keyword.get(opts, :transport, :udp)

    data = %__MODULE__{
      id: generate_id(),
      invite: invite,
      owner: owner,
      notify_fun: notify_fun,
      uas: uas,
      timers: %{},
      metadata: Keyword.get(opts, :metadata, %{}),
      local_host: local_host,
      local_port: local_port,
      transport: transport
    }

    timer_ref = :erlang.start_timer(10_000, self(), :handler_decision)
    data = put_in(data.timers[:handler_decision], timer_ref)

    notify(data, {:uas_created, self()})

    {:ok, :incoming, data}
  end

  # State: incoming

  def incoming(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def incoming({:call, from}, {:ring, opts}, data) do
    status = Keyword.get(opts, :status, 180)
    response = Message.reply(data.invite, status, status_text(status))
    Server.response(response, data.uas)

    data = TimerHelpers.cancel_timer(data, :handler_decision)
    notify(data, {:uas_ringing, self()})

    {:next_state, :ringing, data, [{:reply, from, :ok}]}
  end

  def incoming({:call, from}, {:answer, opts}, data) do
    sdp = Keyword.fetch!(opts, :sdp)
    response = Message.reply(data.invite, 200, "OK")
    response = %{response | body: sdp}
    Server.response(response, data.uas)

    data = TimerHelpers.cancel_timer(data, :handler_decision)
    dialog_id = build_dialog_id(data.invite)
    data = %{data | dialog_id: dialog_id}

    notify(data, {:uas_answered, self()})

    {:next_state, :answering, data, [{:reply, from, :ok}]}
  end

  def incoming({:call, from}, {:reject, status_code, opts}, data) do
    reason = Keyword.get(opts, :reason, status_text(status_code))
    response = Message.reply(data.invite, status_code, reason)
    Server.response(response, data.uas)

    data = TimerHelpers.cancel_timer(data, :handler_decision)
    notify(data, {:uas_terminated, self()})

    {:next_state, :terminated, data, [{:reply, from, :ok}]}
  end

  def incoming(:info, {:timeout, _ref, :handler_decision}, data) do
    response = Message.reply(data.invite, 408, "Request Timeout")
    Server.response(response, data.uas)

    notify(data, {:uas_timeout, self()})

    {:next_state, :terminated, data}
  end

  def incoming(:cast, :cancel_received, data) do
    response_487 = Message.reply(data.invite, 487, "Request Terminated")
    Server.response(response_487, data.uas)

    data = TimerHelpers.cancel_timer(data, :handler_decision)
    notify(data, {:uas_cancelled, self()})

    {:next_state, :terminated, data}
  end

  # State: ringing

  def ringing(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def ringing({:call, from}, {:answer, opts}, data) do
    sdp = Keyword.fetch!(opts, :sdp)
    response = Message.reply(data.invite, 200, "OK")
    response = %{response | body: sdp}
    Server.response(response, data.uas)

    dialog_id = build_dialog_id(data.invite)
    data = %{data | dialog_id: dialog_id}

    notify(data, {:uas_answered, self()})

    {:next_state, :answering, data, [{:reply, from, :ok}]}
  end

  def ringing({:call, from}, {:reject, status_code, opts}, data) do
    reason = Keyword.get(opts, :reason, status_text(status_code))
    response = Message.reply(data.invite, status_code, reason)
    Server.response(response, data.uas)

    notify(data, {:uas_terminated, self()})

    {:next_state, :terminated, data, [{:reply, from, :ok}]}
  end

  def ringing({:call, from}, {:ring, opts}, data) do
    status = Keyword.get(opts, :status, 180)
    response = Message.reply(data.invite, status, status_text(status))
    Server.response(response, data.uas)

    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def ringing(:cast, :cancel_received, data) do
    response_487 = Message.reply(data.invite, 487, "Request Terminated")
    Server.response(response_487, data.uas)

    notify(data, {:uas_cancelled, self()})

    {:next_state, :terminated, data}
  end

  # State: answering
  # Replaced polling loop with immediate lookup + bounded retry per Phase 2.1

  def answering(:enter, _old_state, data) do
    # Try immediate dialog lookup - common case should succeed immediately
    case Registry.lookup(ParrotSip.Registry, data.dialog_id) do
      [{dialog_pid, _}] ->
        :ok = DialogStatem.set_owner(dialog_pid, data.dialog_id)
        ref = Process.monitor(dialog_pid)
        {:keep_state, %{data | dialog: dialog_pid, dialog_ref: ref}}

      [] ->
        # Dialog not found yet - single short retry for race condition
        {:keep_state, data, [{:state_timeout, 50, :retry_dialog_lookup}]}
    end
  end

  def answering(:state_timeout, :retry_dialog_lookup, data) do
    # Final retry attempt - if still not found, fail gracefully
    case Registry.lookup(ParrotSip.Registry, data.dialog_id) do
      [{dialog_pid, _}] ->
        :ok = DialogStatem.set_owner(dialog_pid, data.dialog_id)
        ref = Process.monitor(dialog_pid)
        {:keep_state, %{data | dialog: dialog_pid, dialog_ref: ref}}

      [] ->
        Logger.warning("UAS dialog not found after retry: #{data.dialog_id}")
        notify(data, {:uas_error, self(), :dialog_not_found})
        {:next_state, :terminated, data}
    end
  end

  def answering(:info, {:dialog_event, :ack_received}, data) do
    notify(data, {:uas_established, self()})
    {:next_state, :established, data}
  end

  def answering(:info, {:dialog_event, :timer_h_timeout}, data) do
    Logger.warning("UAS Timer H timeout - no ACK received")
    notify(data, {:uas_timeout, self()})
    {:next_state, :terminated, data}
  end

  def answering(:info, {:dialog_event, {:retransmit_invite}}, data) do
    response = Message.reply(data.invite, 200, "OK")
    Server.response(response, data.uas)
    {:keep_state, data}
  end

  # State: established

  def established(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def established(:info, {:dialog_event, {:bye_received, bye_msg}}, data) do
    response = Message.reply(bye_msg, 200, "OK")
    Server.response(response, data.uas)

    notify(data, {:uas_bye, self(), bye_msg})

    {:next_state, :terminating, data}
  end

  def established({:call, from}, :hangup, data) do
    # Increment CSeq per RFC 3261 Section 12.2.1.1
    next_seq = data.local_seq + 1
    bye = build_bye(data, next_seq)
    Client.request(bye, fn _result -> :ok end)

    {:next_state, :terminating, %{data | local_seq: next_seq}, [{:reply, from, :ok}]}
  end

  def established(:info, {:dialog_event, {:reinvite, invite}}, data) do
    notify(data, {:uas_reinvite, self(), invite})
    {:keep_state, data}
  end

  def established(:cast, {:send_reinvite, sdp}, data) do
    # Increment CSeq per RFC 3261 Section 12.2.1.1
    next_seq = data.local_seq + 1
    reinvite = build_reinvite(data, sdp, next_seq)
    Client.request(reinvite, fn _result -> :ok end)
    {:keep_state, %{data | local_seq: next_seq}}
  end

  # State: terminating

  def terminating(:enter, _old_state, data) do
    timer_ref = :erlang.start_timer(5_000, self(), :cleanup)
    data = put_in(data.timers[:cleanup], timer_ref)
    {:keep_state, data}
  end

  def terminating(:info, {:dialog_event, :bye_200}, data) do
    data = TimerHelpers.cancel_timer(data, :cleanup)
    notify(data, {:uas_terminated, self()})
    {:next_state, :terminated, data}
  end

  def terminating(:info, {:timeout, _ref, :cleanup}, data) do
    Logger.warning("UAS forced cleanup timeout")
    notify(data, {:uas_terminated, self()})
    {:next_state, :terminated, data}
  end

  # State: terminated

  def terminated(:enter, _old_state, data) do
    TimerHelpers.cancel_all_timers(data)
    Process.send_after(self(), :stop, 1_000)
    {:keep_state, data}
  end

  def terminated(:info, :stop, _data) do
    :stop
  end

  # Handle DOWN messages for dialog crash

  @impl :gen_statem
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, %{dialog_ref: ref} = data) do
    Logger.error("UAS dialog crashed: #{inspect(reason)}")
    notify(data, {:uas_error, self(), {:dialog_crashed, reason}})
    {:next_state, :terminated, data}
  end

  # Private helpers

  defp notify(%{owner: owner, notify_fun: fun}, event) do
    fun.(event, owner)
  end

  defp build_dialog_id(invite) do
    call_id = invite.call_id
    local_tag = invite.to.parameters["tag"] || generate_tag()
    remote_tag = invite.from.parameters["tag"]
    Dialog.generate_id(:uas, call_id, local_tag, remote_tag)
  end

  # Build BYE with proper CSeq tracking per RFC 3261 Section 12.2.1.1
  defp build_bye(data, cseq_number) do
    via = Via.new(data.local_host, data.transport, data.local_port)

    %Message{
      type: :request,
      method: :bye,
      request_uri: data.invite.from.uri,
      from: data.invite.to,
      to: data.invite.from,
      call_id: data.invite.call_id,
      cseq: CSeq.new(cseq_number, :bye),
      via: [via],
      max_forwards: 70
    }
  end

  # Build re-INVITE with proper CSeq tracking per RFC 3261 Section 12.2.1.1
  defp build_reinvite(data, sdp, cseq_number) do
    via = Via.new(data.local_host, data.transport, data.local_port)

    %Message{
      type: :request,
      method: :invite,
      request_uri: data.invite.from.uri,
      from: data.invite.to,
      to: data.invite.from,
      call_id: data.invite.call_id,
      cseq: CSeq.new(cseq_number, :invite),
      via: [via],
      body: sdp,
      max_forwards: 70
    }
  end

  defp status_text(180), do: "Ringing"
  defp status_text(181), do: "Call Is Being Forwarded"
  defp status_text(182), do: "Queued"
  defp status_text(183), do: "Session Progress"
  defp status_text(486), do: "Busy Here"
  defp status_text(480), do: "Temporarily Unavailable"
  defp status_text(404), do: "Not Found"
  defp status_text(603), do: "Decline"
  defp status_text(_), do: "Unknown"

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp generate_tag, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
