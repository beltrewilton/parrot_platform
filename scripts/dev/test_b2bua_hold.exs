# B2BUA hold/resume test using Parrot DSL
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_b2bua_hold.exs
#
# This test demonstrates B2BUA hold/resume functionality:
# 1. Establish a bridged call (A-leg <-> B-leg)
# 2. Put B-leg on hold
# 3. Resume B-leg
# 4. Clean up on hangup
#
# Test with pjsua:
#   pjsua --null-audio --no-tcp "sip:hold@127.0.0.1:5080;transport=udp"

require Logger

defmodule TestB2BUAHoldHandler do
  use Parrot.InviteHandler

  require Logger

  alias Parrot.Bridge.B2BUA
  alias Parrot.Leg

  @b_leg_dest "sip:echo@127.0.0.1:5090"

  @impl true
  def handle_invite(call) do
    Logger.info("[B2BUA-Hold] INVITE received from #{call.from}")

    # Start B2BUA session
    {:ok, b2bua_pid} = B2BUA.start_link(
      handler: __MODULE__,
      handler_state: %{call_server: self()},
      media_mode: :proxy
    )

    # Create and set A-leg
    a_leg = Leg.new(
      id: :a_leg,
      direction: :inbound,
      remote_uri: call.from,
      state: :init
    )
    :ok = B2BUA.set_a_leg(b2bua_pid, a_leg)

    # Store B2BUA pid and mark phase
    call = call
    |> Parrot.Call.assign(:b2bua_pid, b2bua_pid)
    |> Parrot.Call.assign(:phase, :answering)

    # Answer A-leg
    Logger.info("[B2BUA-Hold] Answering A-leg...")
    call = call |> answer()

    # Create B-leg
    Logger.info("[B2BUA-Hold] Originating B-leg to #{@b_leg_dest}...")
    {:ok, _b_leg_id} = B2BUA.originate(b2bua_pid, @b_leg_dest, as: :b_leg)

    # Simulate B-leg flow
    :ok = B2BUA.handle_leg_event(b2bua_pid, :b_leg, :trying)
    :ok = B2BUA.handle_leg_event(b2bua_pid, :b_leg, :ringing)
    :ok = B2BUA.handle_leg_event(b2bua_pid, :b_leg, {:answered, "fake-sdp"})

    # Connect legs
    Logger.info("[B2BUA-Hold] Connecting A-leg <-> B-leg...")
    {:ok, _bridge} = B2BUA.connect(b2bua_pid, :a_leg, :b_leg)
    Logger.info("[B2BUA-Hold] Bridge established!")

    # Play initial message
    call |> play("priv/audio/parrot-welcome.wav")
  end

  @impl true
  def handle_play_complete(_file, call) do
    b2bua_pid = call.assigns[:b2bua_pid]
    phase = call.assigns[:phase] || :answering

    Logger.info("[B2BUA-Hold] Play complete, phase: #{phase}")

    case phase do
      :answering ->
        # First playback done - now demonstrate hold
        Logger.info("[B2BUA-Hold] Putting B-leg on hold...")

        case B2BUA.hold(b2bua_pid, :b_leg) do
          :ok ->
            Logger.info("[B2BUA-Hold] B-leg is now on hold")

            # Show state
            {:ok, b_leg} = B2BUA.get_leg(b2bua_pid, :b_leg)
            Logger.info("[B2BUA-Hold] B-leg state: #{b_leg.state}")

            # Play hold music placeholder
            call = call
            |> Parrot.Call.assign(:phase, :on_hold)
            |> play("priv/audio/parrot-welcome.wav")

            {:noreply, call}

          {:error, reason} ->
            Logger.error("[B2BUA-Hold] Hold failed: #{inspect(reason)}")
            {:noreply, call}
        end

      :on_hold ->
        # After hold music - resume
        Logger.info("[B2BUA-Hold] Resuming B-leg...")

        case B2BUA.resume(b2bua_pid, :b_leg) do
          :ok ->
            Logger.info("[B2BUA-Hold] B-leg resumed!")

            {:ok, b_leg} = B2BUA.get_leg(b2bua_pid, :b_leg)
            Logger.info("[B2BUA-Hold] B-leg state: #{b_leg.state}")

            # Final message then hangup
            call = call
            |> Parrot.Call.assign(:phase, :resumed)
            |> play("priv/audio/parrot-welcome.wav")

            {:noreply, call}

          {:error, reason} ->
            Logger.error("[B2BUA-Hold] Resume failed: #{inspect(reason)}")
            {:noreply, call}
        end

      :resumed ->
        # All done - show final state and hangup
        Logger.info("[B2BUA-Hold] Demo complete!")

        legs = B2BUA.get_legs(b2bua_pid)
        Logger.info("[B2BUA-Hold] Final leg states:")
        for {id, leg} <- legs do
          Logger.info("[B2BUA-Hold]   #{id}: #{leg.state}")
        end

        active = B2BUA.get_active_bridge(b2bua_pid)
        Logger.info("[B2BUA-Hold] Active bridge: #{inspect(active)}")

        Logger.info("[B2BUA-Hold] Hanging up...")
        {:noreply, call |> hangup()}

      _ ->
        {:noreply, call}
    end
  end

  @impl true
  def handle_leg_event(call, leg_id, event) do
    Logger.info("[B2BUA-Hold] Leg event: #{inspect(leg_id)} -> #{inspect(event)}")
    {:ok, call}
  end

  @impl true
  def handle_hangup(call) do
    Logger.info("[B2BUA-Hold] Call ended")

    b2bua_pid = call.assigns[:b2bua_pid]

    if b2bua_pid && Process.alive?(b2bua_pid) do
      B2BUA.hangup_all(b2bua_pid)
      B2BUA.stop(b2bua_pid)
    end

    {:noreply, call}
  end
end

defmodule TestB2BUAHoldRouter do
  use Parrot.Router

  invite("hold", TestB2BUAHoldHandler)
  invite("*", TestB2BUAHoldHandler)
end

IO.puts("""
========================================
B2BUA Hold/Resume Test Server
========================================

Starting server on port 5080...

Test with pjsua:
  pjsua --null-audio --no-tcp "sip:hold@127.0.0.1:5080;transport=udp"

This test demonstrates:
  1. Establish bridge (A-leg <-> B-leg)
  2. Put B-leg on hold
  3. Resume B-leg
  4. Hangup

NOTE: B-leg state changes are simulated.
Real hold/resume requires SIP re-INVITE with SDP changes.

Press Ctrl+C to stop
""")

handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: TestB2BUAHoldRouter})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)
    IO.puts("Server listening on port #{port}\n")
    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
