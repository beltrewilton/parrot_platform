# Simple B2BUA bridge test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_b2bua_simple.exs
#
# This test demonstrates a simple B2BUA bridge scenario:
# 1. Receive incoming INVITE from A-leg (caller)
# 2. Answer the A-leg
# 3. Originate to B-leg destination
# 4. When B-leg answers, connect the two legs
# 5. Handle hangup from either side
#
# Test with pjsua:
#   pjsua --null-audio --no-tcp "sip:bridge@127.0.0.1:5080;transport=udp"
#
# The B-leg destination is hardcoded to sip:echo@127.0.0.1:5090
# You can run a second pjsua instance as the B-leg:
#   pjsua --null-audio --no-tcp --local-port=5090

require Logger

defmodule TestB2BUAHandler do
  use Parrot.InviteHandler

  require Logger

  alias Parrot.Bridge.B2BUA
  alias Parrot.Leg

  @b_leg_dest "sip:echo@127.0.0.1:5090"

  @impl true
  def handle_invite(call) do
    Logger.info("[B2BUA] INVITE received from #{call.from} to #{call.to}")
    Logger.info("[B2BUA] Will bridge to #{@b_leg_dest}")

    # Start a B2BUA session for this call
    {:ok, b2bua_pid} = B2BUA.start_link(
      handler: __MODULE__,
      handler_state: %{call_server: self()},
      media_mode: :proxy
    )

    Logger.info("[B2BUA] Started B2BUA session: #{inspect(b2bua_pid)}")

    # Create the A-leg from the incoming call
    a_leg = Leg.new(
      id: :a_leg,
      direction: :inbound,
      remote_uri: call.from,
      local_uri: call.to,
      state: :init
    )

    # Set the A-leg on the B2BUA
    :ok = B2BUA.set_a_leg(b2bua_pid, a_leg)
    Logger.info("[B2BUA] A-leg set: #{inspect(a_leg.id)}")

    # Store B2BUA pid in call assigns for later use
    call = call |> Parrot.Call.assign(:b2bua_pid, b2bua_pid)

    # Answer the A-leg first (SIP 200 OK)
    Logger.info("[B2BUA] Answering A-leg...")
    call = call |> answer()

    # Synchronize B2BUA A-leg state to :answered
    # The DSL answer() sends SIP 200 OK, but we need to explicitly update
    # the B2BUA's A-leg state. The Leg state machine requires: init -> trying -> answered
    :ok = B2BUA.handle_leg_event(b2bua_pid, :a_leg, :trying)
    :ok = B2BUA.handle_leg_event(b2bua_pid, :a_leg, {:answered, nil})
    Logger.info("[B2BUA] A-leg state synchronized to :answered")

    # Now originate to B-leg
    # NOTE: This currently only creates the leg struct in B2BUA state.
    # The actual SIP INVITE to the B-leg requires UA.Client integration
    # which is not yet implemented.
    Logger.info("[B2BUA] Originating to B-leg: #{@b_leg_dest}")
    {:ok, b_leg_id} = B2BUA.originate(b2bua_pid, @b_leg_dest, as: :b_leg)
    Logger.info("[B2BUA] B-leg created: #{inspect(b_leg_id)}")

    # Simulate trying event (in real implementation, this comes from SIP layer)
    :ok = B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)

    # For now, play a message to the caller while we "wait" for B-leg
    # In a real implementation, we'd wait for actual SIP responses
    call = call |> play("priv/audio/parrot-welcome.wav")

    # Store leg info
    call
    |> Parrot.Call.assign(:b_leg_id, b_leg_id)
    |> Parrot.Call.assign(:b_leg_dest, @b_leg_dest)
  end

  @impl true
  def handle_play_complete(_file, call) do
    Logger.info("[B2BUA] Playback complete")

    b2bua_pid = call.assigns[:b2bua_pid]

    if b2bua_pid do
      # Simulate B-leg answering (in real impl, comes from SIP 200 OK)
      Logger.info("[B2BUA] Simulating B-leg answer...")
      :ok = B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "fake-sdp"})

      # Now connect the legs
      Logger.info("[B2BUA] Connecting A-leg and B-leg...")
      case B2BUA.connect(b2bua_pid, :a_leg, :b_leg) do
        {:ok, _bridge} ->
          Logger.info("[B2BUA] Legs connected! Bridge is active.")
        {:error, reason} ->
          Logger.error("[B2BUA] Failed to connect legs: #{inspect(reason)}")
      end

      # Show current state
      legs = B2BUA.get_legs(b2bua_pid)
      Logger.info("[B2BUA] Current legs: #{inspect(Map.keys(legs))}")

      for {id, leg} <- legs do
        Logger.info("[B2BUA]   #{id}: state=#{leg.state}, direction=#{leg.direction}")
      end

      active = B2BUA.get_active_bridge(b2bua_pid)
      Logger.info("[B2BUA] Active bridge: #{inspect(active)}")
    end

    {:noreply, call}
  end

  @impl true
  def handle_leg_event(call, leg_id, event) do
    Logger.info("[B2BUA] Leg event: #{inspect(leg_id)} -> #{inspect(event)}")
    {:ok, call}
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[B2BUA] Call ended - cleaning up")

    b2bua_pid = call.assigns[:b2bua_pid]

    if b2bua_pid && Process.alive?(b2bua_pid) do
      Logger.info("[B2BUA] Hanging up all legs...")
      B2BUA.hangup_all(b2bua_pid)
      B2BUA.stop(b2bua_pid)
    end

    {:noreply, call}
  end
end

defmodule TestB2BUARouter do
  use Parrot.Router

  invite("bridge", TestB2BUAHandler)
  invite("*", TestB2BUAHandler)
end

IO.puts("""
========================================
B2BUA Simple Bridge Test Server
========================================

Starting server on port 5080...

Test with pjsua:
  pjsua --null-audio --no-tcp "sip:bridge@127.0.0.1:5080;transport=udp"

NOTE: This test demonstrates the B2BUA state management.
The actual outbound SIP INVITE to B-leg is not yet implemented
(requires UA.Client integration).

Press Ctrl+C to stop
""")

# Start Parrot.Registry for Call.Server lookup/registration
# This is required for handle_hangup callbacks to work properly
case Registry.start_link(keys: :unique, name: Parrot.Registry) do
  {:ok, _} ->
    IO.puts("Started Parrot.Registry")

  {:error, {:already_started, _}} ->
    IO.puts("Parrot.Registry already running")
end

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestB2BUARouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}\n")
    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
