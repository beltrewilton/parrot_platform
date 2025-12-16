defmodule ParrotSip.UAC do
  @moduledoc """
  User Agent Client - handles outgoing INVITE requests.

  Follows RFC 3261 INVITE client transaction semantics with Dialog integration.
  """

  @behaviour :gen_statem
  require Logger

  alias ParrotSip.{Message, Dialog, DialogStatem, TimerHelpers}
  alias ParrotSip.Transaction.Client
  alias ParrotSip.Headers.{Via, From, To, CSeq}

  defstruct [
    :id,
    :dialog_id,
    :dialog,
    :dialog_ref,
    :dest_uri,
    :local_sdp,
    :remote_sdp,
    :owner,
    :notify_fun,
    :invite,
    :transaction,
    :timers,
    :metadata,
    :local_host,
    :local_port,
    :transport,
    # CSeq tracking per RFC 3261 Section 12.2.1.1
    local_seq: 1
  ]

  # Public API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @spec cancel(pid()) :: :ok
  def cancel(uac) do
    :gen_statem.call(uac, :cancel)
  end

  @spec hangup(pid()) :: :ok
  def hangup(uac) do
    :gen_statem.call(uac, :hangup)
  end

  @spec send_reinvite(pid(), String.t()) :: :ok
  def send_reinvite(uac, sdp) do
    :gen_statem.cast(uac, {:send_reinvite, sdp})
  end

  # gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init(opts) do
    dest_uri = Keyword.fetch!(opts, :dest_uri)
    sdp = Keyword.fetch!(opts, :sdp)
    owner = Keyword.fetch!(opts, :owner)
    notify_fun = Keyword.fetch!(opts, :notify_fun)

    from_uri = Keyword.get(opts, :from_uri)
    headers = Keyword.get(opts, :headers, %{})
    local_host = Keyword.get(opts, :local_host, "127.0.0.1")
    local_port = Keyword.get(opts, :local_port, 5060)
    transport = Keyword.get(opts, :transport, :udp)

    data = %__MODULE__{
      id: generate_id(),
      dest_uri: dest_uri,
      local_sdp: sdp,
      owner: owner,
      notify_fun: notify_fun,
      timers: %{},
      metadata: Keyword.get(opts, :metadata, %{}),
      local_host: local_host,
      local_port: local_port,
      transport: transport
    }

    invite = build_invite(dest_uri, sdp, from_uri, headers, data)
    # Track CSeq from INVITE per RFC 3261 Section 12.2.1.1
    data = %{data | invite: invite, local_seq: invite.cseq.number}

    notify(data, {:uac_created, self()})

    {:ok, :initiating, data}
  end

  # State: initiating

  def initiating(:enter, _old_state, data) do
    send(self(), :send_invite)
    {:keep_state, data}
  end

  def initiating(:info, :send_invite, data) do
    uac_pid = self()

    # Extract destination from dest_uri (Request-URI)
    # For now, use dest_uri as-is - Transaction layer will parse it
    destination = data.dest_uri

    transaction =
      Client.request(data.invite, destination, fn result ->
        send(uac_pid, {:tx_response, result})
      end)

    timer_ref = :erlang.start_timer(32_000, self(), :timer_b)
    data = %{data |
      transaction: transaction,
      timers: Map.put(data.timers, :timer_b, timer_ref)
    }

    {:next_state, :calling, data}
  end

  # State: calling

  def calling(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def calling(:info, {:tx_response, {:response, %{status_code: 100}}}, data) do
    data = TimerHelpers.cancel_timer(data, :timer_b)
    {:keep_state, data}
  end

  def calling(:info, {:tx_response, {:response, %{status_code: code} = resp}}, data)
      when code >= 180 and code < 200 do
    data = TimerHelpers.cancel_timer(data, :timer_b)
    notify(data, {:uac_ringing, self(), code, resp})

    remote_tag = resp.to.parameters["tag"]
    dialog_id = build_dialog_id(data.invite, remote_tag)
    data = %{data | dialog_id: dialog_id}

    {:next_state, :ringing, data}
  end

  def calling(:info, {:tx_response, {:response, %{status_code: code} = resp}}, data)
      when code >= 200 and code < 300 do
    data = TimerHelpers.cancel_timer(data, :timer_b)
    send_ack(data.invite, resp, data)

    remote_tag = resp.to.parameters["tag"]
    dialog_id = build_dialog_id(data.invite, remote_tag)
    data = %{data | dialog_id: dialog_id, remote_sdp: resp.body}

    notify(data, {:uac_answered, self(), resp.body})

    {:next_state, :answered, data}
  end

  def calling(:info, {:tx_response, {:response, %{status_code: code} = resp}}, data)
      when code >= 300 do
    data = TimerHelpers.cancel_timer(data, :timer_b)
    send_ack(data.invite, resp, data)

    notify(data, {:uac_rejected, self(), code, resp})

    {:next_state, :terminated, data}
  end

  def calling({:call, from}, :cancel, data) do
    Client.cancel(data.transaction)
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def calling(:info, {:timeout, _ref, :timer_b}, data) do
    Logger.warning("UAC Timer B timeout - no response")
    notify(data, {:uac_timeout, self()})
    {:next_state, :terminated, data}
  end

  # State: ringing

  def ringing(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def ringing(:info, {:tx_response, {:response, %{status_code: code} = resp}}, data)
      when code >= 180 and code < 200 do
    notify(data, {:uac_progress, self(), code, resp})
    {:keep_state, data}
  end

  def ringing(:info, {:tx_response, {:response, %{status_code: code} = resp}}, data)
      when code >= 200 and code < 300 do
    send_ack(data.invite, resp, data)

    data = %{data | remote_sdp: resp.body}
    notify(data, {:uac_answered, self(), resp.body})

    {:next_state, :answered, data}
  end

  def ringing(:info, {:tx_response, {:response, %{status_code: code} = resp}}, data)
      when code >= 300 do
    send_ack(data.invite, resp, data)
    notify(data, {:uac_rejected, self(), code, resp})
    {:next_state, :terminated, data}
  end

  def ringing({:call, from}, :cancel, data) do
    Client.cancel(data.transaction)
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  # State: answered
  # Replaced polling loop with immediate lookup + bounded retry per Phase 2.1

  def answered(:enter, _old_state, data) do
    # Try immediate dialog lookup - common case should succeed immediately
    case Registry.lookup(ParrotSip.Registry, data.dialog_id) do
      [{dialog_pid, _}] ->
        :ok = DialogStatem.set_owner(dialog_pid, data.dialog_id)
        ref = Process.monitor(dialog_pid)
        data = %{data | dialog: dialog_pid, dialog_ref: ref}
        notify(data, {:uac_established, self()})
        {:next_state, :established, data}

      [] ->
        # Dialog not found yet - single short retry for race condition
        {:keep_state, data, [{:state_timeout, 50, :retry_dialog_lookup}]}
    end
  end

  def answered(:state_timeout, :retry_dialog_lookup, data) do
    # Final retry attempt - if still not found, fail gracefully
    case Registry.lookup(ParrotSip.Registry, data.dialog_id) do
      [{dialog_pid, _}] ->
        :ok = DialogStatem.set_owner(dialog_pid, data.dialog_id)
        ref = Process.monitor(dialog_pid)
        data = %{data | dialog: dialog_pid, dialog_ref: ref}
        notify(data, {:uac_established, self()})
        {:next_state, :established, data}

      [] ->
        Logger.warning("UAC dialog not found after retry: #{data.dialog_id}")
        notify(data, {:uac_error, self(), :dialog_not_found})
        {:next_state, :terminated, data}
    end
  end

  # Test helper - inject mock dialog for unit tests
  def answered(:info, {:test_dialog_found, dialog_pid}, data) do
    ref = Process.monitor(dialog_pid)
    data = %{data | dialog: dialog_pid, dialog_ref: ref}

    notify(data, {:uac_established, self()})
    {:next_state, :established, data}
  end

  # State: established

  def established(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def established(:info, {:dialog_event, {:bye_received, bye}}, data) do
    response = Message.reply(bye, 200, "OK")
    send_response(response)

    notify(data, {:uac_bye, self(), bye})

    {:next_state, :terminating, data}
  end

  def established({:call, from}, :hangup, data) do
    # Increment CSeq per RFC 3261 Section 12.2.1.1
    next_seq = data.local_seq + 1
    bye = build_bye(data, next_seq)
    Client.request(bye, fn _result -> :ok end)

    {:next_state, :terminating, %{data | local_seq: next_seq}, [{:reply, from, :ok}]}
  end

  def established(:cast, {:send_reinvite, sdp}, data) do
    # Increment CSeq per RFC 3261 Section 12.2.1.1
    next_seq = data.local_seq + 1
    reinvite = build_reinvite(data, sdp, next_seq)
    Client.request(reinvite, fn _result -> :ok end)
    {:keep_state, %{data | local_seq: next_seq}}
  end

  def established(:info, {:dialog_event, {:reinvite, invite}}, data) do
    notify(data, {:uac_reinvite, self(), invite})
    {:keep_state, data}
  end

  # State: terminating

  def terminating(:enter, _old_state, data) do
    timer_ref = :erlang.start_timer(5_000, self(), :cleanup)
    data = put_in(data.timers[:cleanup], timer_ref)
    {:keep_state, data}
  end

  def terminating(:info, {:dialog_event, :bye_200}, data) do
    data = TimerHelpers.cancel_timer(data, :cleanup)
    notify(data, {:uac_terminated, self()})
    {:next_state, :terminated, data}
  end

  def terminating(:info, {:timeout, _ref, :cleanup}, data) do
    Logger.warning("UAC forced cleanup timeout")
    notify(data, {:uac_terminated, self()})
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
    Logger.error("UAC dialog crashed: #{inspect(reason)}")
    notify(data, {:uac_error, self(), {:dialog_crashed, reason}})
    {:next_state, :terminated, data}
  end

  # Private helpers

  defp notify(%{owner: owner, notify_fun: fun}, event) do
    fun.(event, owner)
  end

  defp build_dialog_id(invite, remote_tag) do
    call_id = invite.call_id
    local_tag = invite.from.parameters["tag"]
    Dialog.generate_id(:uac, call_id, local_tag, remote_tag)
  end

  defp build_invite(dest_uri, sdp, from_uri, _headers, data) do
    call_id = "#{generate_id()}@#{data.local_host}"
    from_tag = generate_tag()
    via = Via.new(data.local_host, data.transport, data.local_port)

    %Message{
      type: :request,
      method: :invite,
      request_uri: dest_uri,
      from: From.new(from_uri || "sip:user@#{data.local_host}", nil, %{"tag" => from_tag}),
      to: To.new(dest_uri),
      call_id: call_id,
      cseq: CSeq.new(1, :invite),
      via: [via],
      body: sdp,
      max_forwards: 70
    }
  end

  # Build BYE with proper CSeq tracking per RFC 3261 Section 12.2.1.1
  defp build_bye(data, cseq_number) do
    via = Via.new(data.local_host, data.transport, data.local_port)

    %Message{
      type: :request,
      method: :bye,
      request_uri: data.dest_uri,
      from: data.invite.from,
      to: data.invite.to,
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
      request_uri: data.dest_uri,
      from: data.invite.from,
      to: data.invite.to,
      call_id: data.invite.call_id,
      cseq: CSeq.new(cseq_number, :invite),
      via: [via],
      body: sdp,
      max_forwards: 70
    }
  end

  defp send_ack(invite, response, data) do
    via = Via.new(data.local_host, data.transport, data.local_port)

    ack = %Message{
      type: :request,
      method: :ack,
      request_uri: invite.request_uri,
      from: invite.from,
      to: %{response.to | parameters: Map.put(response.to.parameters, "tag", response.to.parameters["tag"])},
      call_id: invite.call_id,
      cseq: CSeq.new(invite.cseq.number, :ack),
      via: [via],
      max_forwards: 70
    }

    Client.request(ack, fn _result -> :ok end)
  end

  defp send_response(response) do
    # In real implementation, would use Server.response/2
    # For now, simplified
    Logger.debug("Sending response: #{inspect(response)}")
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp generate_tag, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
