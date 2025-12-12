defmodule ParrotSip.Examples.SimplePhone do
  @moduledoc """
  Example: Simple SIP phone using ParrotSip.

  This demonstrates how to:
  - Answer incoming calls (UAS)
  - Make outgoing calls (UAC)
  - Handle call events
  - Manage active calls

  ## Usage

      # Start the phone
      {:ok, phone} = SimplePhone.start_link(local_uri: "sip:alice@example.com")

      # Make a call
      {:ok, call_id} = SimplePhone.dial(phone, "sip:bob@example.com", sdp: my_sdp)

      # Answer incoming calls automatically
      # (Configured in init/1)

      # Hangup a call
      :ok = SimplePhone.hangup(phone, call_id)

      # List active calls
      calls = SimplePhone.list_calls(phone)
  """

  use GenServer
  require Logger

  alias ParrotSip.{UAS, UAC, Handler, Message}

  defstruct [
    :local_uri,
    :active_calls,  # Map of call_id => %{type: :incoming/:outgoing, pid: uas_pid/uac_pid, state: atom}
    :handler
  ]

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Make an outbound call"
  def dial(phone, dest_uri, opts) do
    GenServer.call(phone, {:dial, dest_uri, opts})
  end

  @doc "Hangup a call"
  def hangup(phone, call_id) do
    GenServer.call(phone, {:hangup, call_id})
  end

  @doc "List all active calls"
  def list_calls(phone) do
    GenServer.call(phone, :list_calls)
  end

  @doc "Get SIP handler for this phone (to wire into ParrotSip stack)"
  def get_handler(phone) do
    Handler.new(__MODULE__, %{phone_pid: phone})
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    local_uri = Keyword.fetch!(opts, :local_uri)

    state = %__MODULE__{
      local_uri: local_uri,
      active_calls: %{},
      handler: nil
    }

    Logger.info("SimplePhone started: #{local_uri}")

    {:ok, state}
  end

  @impl true
  def handle_call({:dial, dest_uri, opts}, _from, state) do
    sdp = Keyword.fetch!(opts, :sdp)
    call_id = generate_call_id()

    {:ok, uac} = UAC.Supervisor.start_child(
      dest_uri: dest_uri,
      sdp: sdp,
      from_uri: state.local_uri,
      owner: self(),
      notify_fun: &handle_uac_event/2,
      metadata: %{call_id: call_id}
    )

    call = %{
      type: :outgoing,
      pid: uac,
      state: :calling,
      remote_uri: dest_uri,
      local_sdp: sdp,
      remote_sdp: nil
    }

    state = put_in(state.active_calls[call_id], call)

    Logger.info("Dialing #{dest_uri} (call_id: #{call_id})")

    {:reply, {:ok, call_id}, state}
  end

  def handle_call({:hangup, call_id}, _from, state) do
    case Map.get(state.active_calls, call_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{type: :incoming, pid: uas} ->
        :ok = UAS.hangup(uas)
        {:reply, :ok, state}

      %{type: :outgoing, pid: uac} ->
        :ok = UAC.hangup(uac)
        {:reply, :ok, state}
    end
  end

  def handle_call(:list_calls, _from, state) do
    calls = Enum.map(state.active_calls, fn {call_id, call} ->
      %{
        call_id: call_id,
        type: call.type,
        state: call.state,
        remote_uri: call.remote_uri
      }
    end)

    {:reply, calls, state}
  end

  # Handler Behaviour Implementation (for incoming calls)

  @impl Handler
  def handle_invite(uas, invite, %{phone_pid: phone_pid}) do
    GenServer.call(phone_pid, {:incoming_invite, uas, invite})
  end

  @impl Handler
  def handle_bye(_uas, _bye, _args), do: :ok

  @impl Handler
  def handle_cancel(_uas, _cancel, _args), do: :ok

  @impl Handler
  def transp_request(_msg, _args), do: :process_transaction

  @impl Handler
  def transaction(_trans, _msg, _args), do: :process_uas

  @impl Handler
  def transaction_stop(_trans, _result, _args), do: :ok

  @impl Handler
  def uas_request(_uas, _msg, _args), do: :ok

  @impl Handler
  def uas_cancel(_uas, _args), do: :ok

  @impl Handler
  def process_ack(_msg, _args), do: :ok

  # Internal - Handle Incoming INVITE

  def handle_call({:incoming_invite, uas, invite}, _from, state) do
    call_id = invite.call_id

    Logger.info("Incoming call from #{invite.from.uri} (call_id: #{call_id})")

    # Create UAS entity
    {:ok, uas_pid} = UAS.Supervisor.start_child(
      invite: invite,
      owner: self(),
      notify_fun: &handle_uas_event/2,
      uas: uas,
      metadata: %{call_id: call_id}
    )

    call = %{
      type: :incoming,
      pid: uas_pid,
      state: :incoming,
      remote_uri: invite.from.uri,
      local_sdp: nil,
      remote_sdp: invite.body
    }

    state = put_in(state.active_calls[call_id], call)

    # Auto-answer policy: ring for 2 seconds, then answer
    Process.send_after(self(), {:auto_ring, call_id}, 100)
    Process.send_after(self(), {:auto_answer, call_id}, 2_000)

    {:reply, :ok, state}
  end

  # Internal - Auto-ring and Auto-answer

  @impl true
  def handle_info({:auto_ring, call_id}, state) do
    case Map.get(state.active_calls, call_id) do
      %{pid: uas, state: :incoming} ->
        :ok = UAS.ring(uas)
        Logger.info("Ringing call #{call_id}")
        {:noreply, put_in(state.active_calls[call_id].state, :ringing)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:auto_answer, call_id}, state) do
    case Map.get(state.active_calls, call_id) do
      %{pid: uas, state: :ringing, remote_sdp: remote_sdp} ->
        # Generate answer SDP (in real app, would negotiate codecs)
        answer_sdp = build_answer_sdp(remote_sdp)
        :ok = UAS.answer(uas, sdp: answer_sdp)
        Logger.info("Answered call #{call_id}")
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # UAS Event Handling

  defp handle_uas_event({:uas_created, _uas}, _owner), do: :ok

  defp handle_uas_event({:uas_ringing, _uas}, _owner), do: :ok

  defp handle_uas_event({:uas_answered, _uas}, _owner), do: :ok

  defp handle_uas_event({:uas_established, uas}, owner) do
    send(owner, {:call_established, uas, :incoming})
  end

  defp handle_uas_event({:uas_bye, uas, _bye_msg}, owner) do
    send(owner, {:call_ended, uas, :incoming, :remote_hangup})
  end

  defp handle_uas_event({:uas_terminated, uas}, owner) do
    send(owner, {:call_terminated, uas, :incoming})
  end

  defp handle_uas_event({:uas_timeout, uas}, owner) do
    send(owner, {:call_timeout, uas, :incoming})
  end

  defp handle_uas_event({:uas_cancelled, uas}, owner) do
    send(owner, {:call_cancelled, uas, :incoming})
  end

  defp handle_uas_event(_event, _owner), do: :ok

  # UAC Event Handling

  defp handle_uac_event({:uac_created, _uac}, _owner), do: :ok

  defp handle_uac_event({:uac_ringing, uac, _code, _resp}, owner) do
    send(owner, {:call_ringing, uac, :outgoing})
  end

  defp handle_uac_event({:uac_answered, uac, _sdp}, owner) do
    send(owner, {:call_answered, uac, :outgoing})
  end

  defp handle_uac_event({:uac_established, uac}, owner) do
    send(owner, {:call_established, uac, :outgoing})
  end

  defp handle_uac_event({:uac_rejected, uac, code, _resp}, owner) do
    send(owner, {:call_rejected, uac, :outgoing, code})
  end

  defp handle_uac_event({:uac_bye, uac, _bye_msg}, owner) do
    send(owner, {:call_ended, uac, :outgoing, :remote_hangup})
  end

  defp handle_uac_event({:uac_terminated, uac}, owner) do
    send(owner, {:call_terminated, uac, :outgoing})
  end

  defp handle_uac_event({:uac_timeout, uac}, owner) do
    send(owner, {:call_timeout, uac, :outgoing})
  end

  defp handle_uac_event(_event, _owner), do: :ok

  # Process Call Events

  def handle_info({:call_established, pid, type}, state) do
    call = find_call_by_pid(state.active_calls, pid)
    Logger.info("Call established: #{inspect(call)}")

    state = if call do
      put_in(state.active_calls[call.call_id].state, :established)
    else
      state
    end

    {:noreply, state}
  end

  def handle_info({:call_ended, pid, _type, reason}, state) do
    case find_call_by_pid(state.active_calls, pid) do
      nil ->
        {:noreply, state}

      call ->
        Logger.info("Call ended (#{reason}): #{call.call_id}")
        state = update_in(state.active_calls, &Map.delete(&1, call.call_id))
        {:noreply, state}
    end
  end

  def handle_info({:call_terminated, pid, _type}, state) do
    case find_call_by_pid(state.active_calls, pid) do
      nil ->
        {:noreply, state}

      call ->
        Logger.info("Call terminated: #{call.call_id}")
        state = update_in(state.active_calls, &Map.delete(&1, call.call_id))
        {:noreply, state}
    end
  end

  def handle_info({:call_rejected, pid, _type, code}, state) do
    case find_call_by_pid(state.active_calls, pid) do
      nil ->
        {:noreply, state}

      call ->
        Logger.info("Call rejected (#{code}): #{call.call_id}")
        state = update_in(state.active_calls, &Map.delete(&1, call.call_id))
        {:noreply, state}
    end
  end

  def handle_info({:call_ringing, pid, _type}, state) do
    case find_call_by_pid(state.active_calls, pid) do
      nil ->
        {:noreply, state}

      call ->
        Logger.info("Call ringing: #{call.call_id}")
        state = put_in(state.active_calls[call.call_id].state, :ringing)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Helpers

  defp find_call_by_pid(calls, pid) do
    Enum.find_value(calls, fn {call_id, call} ->
      if call.pid == pid, do: Map.put(call, :call_id, call_id), else: nil
    end)
  end

  defp generate_call_id do
    "call-#{System.unique_integer([:positive])}"
  end

  defp build_answer_sdp(_offer_sdp) do
    # In real implementation, would parse offer and generate proper answer
    # For now, return basic SDP
    """
    v=0
    o=- #{System.unique_integer([:positive])} #{System.unique_integer([:positive])} IN IP4 127.0.0.1
    s=-
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 8000 RTP/AVP 0
    a=rtpmap:0 PCMU/8000
    """
  end
end
