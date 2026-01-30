# B2BUA fork test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_b2bua_fork.exs
#
# This test demonstrates B2BUA forking to multiple destinations:
# 1. Receive incoming INVITE from A-leg (caller)
# 2. Answer the A-leg
# 3. Fork to multiple B-leg destinations simultaneously
# 4. First to answer wins, others are cancelled
# 5. Connect winner to A-leg
#
# Test with pjsua:
#   pjsua --null-audio --no-tcp "sip:fork@127.0.0.1:5080;transport=udp"

require Logger

defmodule TestB2BUAForkHandler do
  use Parrot.InviteHandler

  require Logger

  alias Parrot.Bridge.B2BUA
  alias Parrot.Bridge.RingStrategy
  alias Parrot.Leg

  @destinations [
    "sip:agent1@127.0.0.1:5091",
    "sip:agent2@127.0.0.1:5092",
    "sip:agent3@127.0.0.1:5093"
  ]

  @impl true
  def handle_invite(call) do
    Logger.info("[B2BUA-Fork] INVITE received from #{call.from}")
    Logger.info("[B2BUA-Fork] Will fork to: #{inspect(@destinations)}")

    # Start B2BUA session
    {:ok, b2bua_pid} = B2BUA.start_link(
      handler: __MODULE__,
      handler_state: %{call_server: self()},
      media_mode: :proxy
    )

    Logger.info("[B2BUA-Fork] Started B2BUA session: #{inspect(b2bua_pid)}")

    # Create and set A-leg
    a_leg = Leg.new(
      id: :a_leg,
      direction: :inbound,
      remote_uri: call.from,
      local_uri: call.to,
      state: :init
    )
    :ok = B2BUA.set_a_leg(b2bua_pid, a_leg)

    # Store B2BUA pid
    call = call |> Parrot.Call.assign(:b2bua_pid, b2bua_pid)

    # Answer A-leg (SIP 200 OK)
    Logger.info("[B2BUA-Fork] Answering A-leg...")
    call = call |> answer()

    # Synchronize B2BUA A-leg state to :answered
    # The DSL answer() sends SIP 200 OK, but we need to explicitly update
    # the B2BUA's A-leg state. The Leg state machine requires: init -> trying -> answered
    :ok = B2BUA.handle_leg_event(b2bua_pid, :a_leg, :trying)
    :ok = B2BUA.handle_leg_event(b2bua_pid, :a_leg, {:answered, nil})
    Logger.info("[B2BUA-Fork] A-leg state synchronized to :answered")

    # Create simultaneous ring strategy
    strategy = RingStrategy.simultaneous(timeout: 30_000)
    Logger.info("[B2BUA-Fork] Using strategy: #{inspect(strategy)}")

    # Fork to all destinations
    Logger.info("[B2BUA-Fork] Forking to #{length(@destinations)} destinations...")
    {:ok, leg_ids} = B2BUA.fork(b2bua_pid, @destinations, strategy: strategy)
    Logger.info("[B2BUA-Fork] Created legs: #{inspect(leg_ids)}")

    # Simulate all legs trying
    for leg_id <- leg_ids do
      :ok = B2BUA.handle_leg_event(b2bua_pid, leg_id, :trying)
      Logger.info("[B2BUA-Fork] #{leg_id} -> :trying")
    end

    # Play ringback to caller
    call = call |> play("priv/audio/parrot-welcome.wav")

    call
    |> Parrot.Call.assign(:fork_leg_ids, leg_ids)
    |> Parrot.Call.assign(:destinations, @destinations)
  end

  @impl true
  def handle_play_complete(_file, call) do
    Logger.info("[B2BUA-Fork] Ringback complete")

    b2bua_pid = call.assigns[:b2bua_pid]
    leg_ids = call.assigns[:fork_leg_ids] || []

    if b2bua_pid && length(leg_ids) > 0 do
      # Simulate some legs ringing
      [first | rest] = leg_ids

      for leg_id <- rest do
        :ok = B2BUA.handle_leg_event(b2bua_pid, leg_id, :ringing)
        Logger.info("[B2BUA-Fork] #{leg_id} -> :ringing")
      end

      # Simulate first leg answering (winner)
      Logger.info("[B2BUA-Fork] Simulating #{first} answering (winner)...")
      :ok = B2BUA.handle_leg_event(b2bua_pid, first, {:answered, "fake-sdp"})

      # Check pending legs - should be cleared after winner
      pending = B2BUA.get_pending_legs(b2bua_pid)
      Logger.info("[B2BUA-Fork] Pending legs after answer: #{inspect(pending)}")

      # Connect winner to A-leg
      Logger.info("[B2BUA-Fork] Connecting A-leg to winner #{first}...")
      case B2BUA.connect(b2bua_pid, :a_leg, first) do
        {:ok, _bridge} ->
          Logger.info("[B2BUA-Fork] Bridge established with #{first}!")
        {:error, reason} ->
          Logger.error("[B2BUA-Fork] Connect failed: #{inspect(reason)}")
      end

      # Show final state
      legs = B2BUA.get_legs(b2bua_pid)
      Logger.info("[B2BUA-Fork] Final leg states:")
      for {id, leg} <- legs do
        Logger.info("[B2BUA-Fork]   #{id}: #{leg.state}")
      end

      active = B2BUA.get_active_bridge(b2bua_pid)
      Logger.info("[B2BUA-Fork] Active bridge: #{inspect(active)}")
    end

    {:noreply, call}
  end

  @impl true
  def handle_leg_event(call, leg_id, event) do
    Logger.info("[B2BUA-Fork] Leg event: #{inspect(leg_id)} -> #{inspect(event)}")

    case event do
      {:answered, _sdp} ->
        Logger.info("[B2BUA-Fork] Winner: #{leg_id}")
        {:bridge, leg_id, call}

      {:failed, reason} ->
        Logger.warning("[B2BUA-Fork] #{leg_id} failed: #{inspect(reason)}")
        {:ok, call}

      :cancelled ->
        Logger.info("[B2BUA-Fork] #{leg_id} cancelled (another answered)")
        {:ok, call}

      _ ->
        {:ok, call}
    end
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[B2BUA-Fork] Call ended")

    b2bua_pid = call.assigns[:b2bua_pid]

    if b2bua_pid && Process.alive?(b2bua_pid) do
      B2BUA.hangup_all(b2bua_pid)
      B2BUA.stop(b2bua_pid)
    end

    {:noreply, call}
  end
end

defmodule TestB2BUAForkRouter do
  use Parrot.Router

  invite("fork", TestB2BUAForkHandler)
  invite("*", TestB2BUAForkHandler)
end

IO.puts("""
========================================
B2BUA Fork Test Server
========================================

Starting server on port 5080...

Test with pjsua:
  pjsua --null-audio --no-tcp "sip:fork@127.0.0.1:5080;transport=udp"

This test demonstrates forking to multiple destinations:
  #{inspect(["sip:agent1@127.0.0.1:5091", "sip:agent2@127.0.0.1:5092", "sip:agent3@127.0.0.1:5093"])}

NOTE: Actual outbound SIP INVITEs are simulated.
Real B-leg calling requires UA.Client integration.

Press Ctrl+C to stop
""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestB2BUAForkRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}\n")
    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
