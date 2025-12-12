defmodule ParrotSip.Examples.SimpleB2BUA do
  @moduledoc """
  Example: Simple B2BUA (Back-to-Back User Agent) using ParrotSip.

  This demonstrates how to:
  - Accept incoming calls (UAS)
  - Route and forward calls (UAC)
  - Bridge two call legs together
  - Handle SDP manipulation
  - Forward events between legs

  ## Architecture

      Caller (Alice) → UAS (A-leg) → B2BUA → UAC (B-leg) → Callee (Bob)

  ## Usage

      # Start the B2BUA
      {:ok, b2bua} = SimpleB2BUA.start_link(
        routing_table: %{
          "sip:bob@example.com" => "sip:bob@internal.example.com:5061"
        }
      )

      # Get handler to wire into SIP stack
      handler = SimpleB2BUA.get_handler(b2bua)

      # Incoming calls will be automatically:
      # 1. Accepted (UAS created)
      # 2. Routed based on routing table
      # 3. Forwarded (UAC created)
      # 4. Bridged together

      # List active sessions
      sessions = SimpleB2BUA.list_sessions(b2bua)
  """

  use GenServer
  require Logger

  alias ParrotSip.{UAS, UAC, Handler, Message}

  defstruct [
    :routing_table,
    :sessions  # Map of session_id => %{a_leg: uas_pid, b_leg: uac_pid, state: atom}
  ]

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all active sessions"
  def list_sessions(b2bua) do
    GenServer.call(b2bua, :list_sessions)
  end

  @doc "Hangup a session (both legs)"
  def hangup_session(b2bua, session_id) do
    GenServer.call(b2bua, {:hangup_session, session_id})
  end

  @doc "Get SIP handler for this B2BUA"
  def get_handler(b2bua) do
    Handler.new(__MODULE__, %{b2bua_pid: b2bua})
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    routing_table = Keyword.get(opts, :routing_table, %{})

    state = %__MODULE__{
      routing_table: routing_table,
      sessions: %{}
    }

    Logger.info("SimpleB2BUA started with #{map_size(routing_table)} routes")

    {:ok, state}
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions = Enum.map(state.sessions, fn {session_id, session} ->
      %{
        session_id: session_id,
        state: session.state,
        a_leg_uri: session.a_leg_uri,
        b_leg_uri: session.b_leg_uri
      }
    end)

    {:reply, sessions, state}
  end

  def handle_call({:hangup_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        # Hangup both legs
        if session.a_leg, do: UAS.hangup(session.a_leg)
        if session.b_leg, do: UAC.hangup(session.b_leg)

        {:reply, :ok, state}
    end
  end

  # Handler Behaviour Implementation

  @impl Handler
  def handle_invite(uas, invite, %{b2bua_pid: b2bua_pid}) do
    GenServer.call(b2bua_pid, {:incoming_invite, uas, invite})
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
    session_id = invite.call_id
    from_uri = invite.from.uri
    to_uri = invite.to.uri

    Logger.info("B2BUA: Incoming call #{from_uri} → #{to_uri} (session: #{session_id})")

    # Lookup routing
    case Map.get(state.routing_table, to_uri) do
      nil ->
        # No route found - reject
        Logger.warning("B2BUA: No route for #{to_uri}")
        response = Message.reply(invite, 404, "Not Found")
        ParrotSip.Transaction.Server.response(response, uas)
        {:reply, :ok, state}

      dest_uri ->
        # Create A-leg (UAS)
        {:ok, a_leg} = UAS.Supervisor.start_child(
          invite: invite,
          owner: self(),
          notify_fun: &handle_a_leg_event/2,
          uas: uas,
          metadata: %{session_id: session_id}
        )

        # Ring the A-leg immediately
        :ok = UAS.ring(a_leg)

        session = %{
          a_leg: a_leg,
          b_leg: nil,
          state: :routing,
          a_leg_uri: from_uri,
          b_leg_uri: dest_uri,
          a_leg_sdp: invite.body,
          b_leg_sdp: nil
        }

        state = put_in(state.sessions[session_id], session)

        # Create B-leg (UAC)
        # In real B2BUA, would modify SDP here
        modified_sdp = modify_sdp(invite.body, :a_to_b)

        {:ok, b_leg} = UAC.Supervisor.start_child(
          dest_uri: dest_uri,
          sdp: modified_sdp,
          owner: self(),
          notify_fun: &handle_b_leg_event/2,
          metadata: %{session_id: session_id}
        )

        state = put_in(state.sessions[session_id].b_leg, b_leg)
        state = put_in(state.sessions[session_id].state, :connecting)

        Logger.info("B2BUA: Created session #{session_id}: A-leg=#{inspect(a_leg)}, B-leg=#{inspect(b_leg)}")

        {:reply, :ok, state}
    end
  end

  # A-leg (UAS) Event Handling

  defp handle_a_leg_event({:uas_created, _uas}, _owner), do: :ok
  defp handle_a_leg_event({:uas_ringing, _uas}, _owner), do: :ok
  defp handle_a_leg_event({:uas_answered, _uas}, _owner), do: :ok

  defp handle_a_leg_event({:uas_established, uas}, owner) do
    send(owner, {:a_leg_established, uas})
  end

  defp handle_a_leg_event({:uas_bye, uas, _bye_msg}, owner) do
    send(owner, {:a_leg_bye, uas})
  end

  defp handle_a_leg_event({:uas_terminated, uas}, owner) do
    send(owner, {:a_leg_terminated, uas})
  end

  defp handle_a_leg_event({:uas_cancelled, uas}, owner) do
    send(owner, {:a_leg_cancelled, uas})
  end

  defp handle_a_leg_event(_event, _owner), do: :ok

  # B-leg (UAC) Event Handling

  defp handle_b_leg_event({:uac_created, _uac}, _owner), do: :ok

  defp handle_b_leg_event({:uac_ringing, _uac, _code, _resp}, _owner) do
    # B-leg is ringing - A-leg already ringing
    :ok
  end

  defp handle_b_leg_event({:uac_answered, uac, sdp}, owner) do
    send(owner, {:b_leg_answered, uac, sdp})
  end

  defp handle_b_leg_event({:uac_established, uac}, owner) do
    send(owner, {:b_leg_established, uac})
  end

  defp handle_b_leg_event({:uac_rejected, uac, code, _resp}, owner) do
    send(owner, {:b_leg_rejected, uac, code})
  end

  defp handle_b_leg_event({:uac_bye, uac, _bye_msg}, owner) do
    send(owner, {:b_leg_bye, uac})
  end

  defp handle_b_leg_event({:uac_terminated, uac}, owner) do
    send(owner, {:b_leg_terminated, uac})
  end

  defp handle_b_leg_event(_event, _owner), do: :ok

  # Process Session Events

  @impl true
  def handle_info({:b_leg_answered, uac, b_sdp}, state) do
    # B-leg answered - answer A-leg with B's SDP
    case find_session_by_b_leg(state.sessions, uac) do
      nil ->
        {:noreply, state}

      {session_id, session} ->
        # Modify SDP from B to A
        modified_sdp = modify_sdp(b_sdp, :b_to_a)

        # Answer A-leg
        :ok = UAS.answer(session.a_leg, sdp: modified_sdp)

        Logger.info("B2BUA: B-leg answered, answering A-leg (session: #{session_id})")

        state = put_in(state.sessions[session_id].b_leg_sdp, b_sdp)
        state = put_in(state.sessions[session_id].state, :answered)

        {:noreply, state}
    end
  end

  def handle_info({:a_leg_established, uas}, state) do
    case find_session_by_a_leg(state.sessions, uas) do
      nil ->
        {:noreply, state}

      {session_id, _session} ->
        Logger.info("B2BUA: A-leg established (session: #{session_id})")
        state = put_in(state.sessions[session_id].state, :a_established)
        state = check_both_established(state, session_id)
        {:noreply, state}
    end
  end

  def handle_info({:b_leg_established, uac}, state) do
    case find_session_by_b_leg(state.sessions, uac) do
      nil ->
        {:noreply, state}

      {session_id, _session} ->
        Logger.info("B2BUA: B-leg established (session: #{session_id})")
        state = put_in(state.sessions[session_id].state, :b_established)
        state = check_both_established(state, session_id)
        {:noreply, state}
    end
  end

  def handle_info({:a_leg_bye, uas}, state) do
    # A-leg hung up - hangup B-leg
    case find_session_by_a_leg(state.sessions, uas) do
      nil ->
        {:noreply, state}

      {session_id, session} ->
        Logger.info("B2BUA: A-leg BYE, hanging up B-leg (session: #{session_id})")

        if session.b_leg do
          :ok = UAC.hangup(session.b_leg)
        end

        {:noreply, state}
    end
  end

  def handle_info({:b_leg_bye, uac}, state) do
    # B-leg hung up - hangup A-leg
    case find_session_by_b_leg(state.sessions, uac) do
      nil ->
        {:noreply, state}

      {session_id, session} ->
        Logger.info("B2BUA: B-leg BYE, hanging up A-leg (session: #{session_id})")

        if session.a_leg do
          :ok = UAS.hangup(session.a_leg)
        end

        {:noreply, state}
    end
  end

  def handle_info({:a_leg_terminated, uas}, state) do
    case find_session_by_a_leg(state.sessions, uas) do
      nil ->
        {:noreply, state}

      {session_id, _session} ->
        Logger.info("B2BUA: A-leg terminated (session: #{session_id})")
        state = update_in(state.sessions, &Map.delete(&1, session_id))
        {:noreply, state}
    end
  end

  def handle_info({:b_leg_terminated, uac}, state) do
    case find_session_by_b_leg(state.sessions, uac) do
      nil ->
        {:noreply, state}

      {session_id, _session} ->
        Logger.info("B2BUA: B-leg terminated (session: #{session_id})")
        {:noreply, state}
    end
  end

  def handle_info({:b_leg_rejected, uac, code}, state) do
    # B-leg rejected - reject A-leg with same code
    case find_session_by_b_leg(state.sessions, uac) do
      nil ->
        {:noreply, state}

      {session_id, session} ->
        Logger.info("B2BUA: B-leg rejected (#{code}), rejecting A-leg (session: #{session_id})")

        :ok = UAS.reject(session.a_leg, code)

        state = update_in(state.sessions, &Map.delete(&1, session_id))
        {:noreply, state}
    end
  end

  def handle_info({:a_leg_cancelled, uas}, state) do
    # A-leg cancelled - cancel B-leg
    case find_session_by_a_leg(state.sessions, uas) do
      nil ->
        {:noreply, state}

      {session_id, session} ->
        Logger.info("B2BUA: A-leg cancelled, cancelling B-leg (session: #{session_id})")

        if session.b_leg do
          :ok = UAC.cancel(session.b_leg)
        end

        state = update_in(state.sessions, &Map.delete(&1, session_id))
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Helpers

  defp find_session_by_a_leg(sessions, uas) do
    Enum.find(sessions, fn {_id, session} -> session.a_leg == uas end)
  end

  defp find_session_by_b_leg(sessions, uac) do
    Enum.find(sessions, fn {_id, session} -> session.b_leg == uac end)
  end

  defp check_both_established(state, session_id) do
    session = state.sessions[session_id]

    if session.state in [:a_established, :b_established] do
      # Check if both are ready
      # In real implementation, would check actual states
      Logger.info("B2BUA: Call fully established (session: #{session_id})")
      put_in(state.sessions[session_id].state, :established)
    else
      state
    end
  end

  defp modify_sdp(sdp, :a_to_b) do
    # In real B2BUA, would:
    # - Parse SDP
    # - Change connection IP to B2BUA's media proxy
    # - Negotiate codecs
    # - Modify media port
    # For now, pass through
    sdp
  end

  defp modify_sdp(sdp, :b_to_a) do
    # In real B2BUA, would:
    # - Parse SDP
    # - Change connection IP to B2BUA's media proxy
    # - Map to A-leg's codecs
    # For now, pass through
    sdp
  end
end
