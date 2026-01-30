defmodule Parrot.Bridge.MediaBridgeIntegrationTest do
  @moduledoc """
  Integration tests for MediaBridge with real MediaSession instances.

  These tests verify that MediaBridge correctly calls the MediaSession
  RTP forwarding API when bridging, holding, and resuming legs.
  """
  use ExUnit.Case, async: false

  alias Parrot.Bridge.MediaBridge
  alias ParrotMedia.MediaSession
  alias ParrotMedia.Test.TestMediaHandler

  @moduletag :integration

  # Standard SDP offer for tests
  @sdp_offer """
  v=0
  o=- 123456 123456 IN IP4 127.0.0.1
  s=Test
  c=IN IP4 127.0.0.1
  t=0 0
  m=audio 20000 RTP/AVP 8
  a=rtpmap:8 PCMA/8000
  """

  defp start_media_session(id) do
    {:ok, pid} = MediaSession.start_link(
      id: id,
      dialog_id: "dialog-#{id}",
      role: :uas,
      media_handler: TestMediaHandler,
      handler_args: %{},
      audio_source: :silence
    )

    # Process SDP offer to move session to ready state
    {:ok, _answer} = MediaSession.process_offer(pid, @sdp_offer)

    pid
  end

  defp get_forward_state(session) do
    :gen_statem.call(session, :get_state)
  end

  describe "bridge/1 sets up RTP forwarding" do
    test "sets bidirectional forwarding between both sessions" do
      session_a = start_media_session("session-a-#{:rand.uniform(100_000)}")
      session_b = start_media_session("session-b-#{:rand.uniform(100_000)}")

      {:ok, bridge} = MediaBridge.create(session_a, session_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      assert bridged.state == :bridged

      # Verify forwarding is configured on both sessions
      state_a = get_forward_state(session_a)
      state_b = get_forward_state(session_b)

      assert state_a.rtp_forward_config != nil
      assert state_a.rtp_forward_config.target_pid == session_b
      assert state_a.rtp_forward_config.direction == :both

      assert state_b.rtp_forward_config != nil
      assert state_b.rtp_forward_config.target_pid == session_a
      assert state_b.rtp_forward_config.direction == :both

      # Cleanup
      MediaSession.terminate_session(session_a)
      MediaSession.terminate_session(session_b)
    end
  end

  describe "hold/2 pauses forwarding" do
    setup do
      session_a = start_media_session("session-a-hold-#{:rand.uniform(100_000)}")
      session_b = start_media_session("session-b-hold-#{:rand.uniform(100_000)}")
      {:ok, bridge} = MediaBridge.create(session_a, session_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      on_exit(fn ->
        if Process.alive?(session_a), do: MediaSession.terminate_session(session_a)
        if Process.alive?(session_b), do: MediaSession.terminate_session(session_b)
      end)

      {:ok, %{bridge: bridged, session_a: session_a, session_b: session_b}}
    end

    test "hold :leg_a pauses forwarding on session A", %{bridge: bridge, session_a: session_a, session_b: session_b} do
      {:ok, held} = MediaBridge.hold(bridge, :leg_a)

      assert held.state == :held_a

      # A's forwarding should be paused
      state_a = get_forward_state(session_a)
      assert state_a.rtp_forward_paused == true

      # B's forwarding should still be active
      state_b = get_forward_state(session_b)
      assert state_b.rtp_forward_paused == false
    end

    test "hold :leg_b pauses forwarding on session B", %{bridge: bridge, session_a: session_a, session_b: session_b} do
      {:ok, held} = MediaBridge.hold(bridge, :leg_b)

      assert held.state == :held_b

      # A's forwarding should still be active
      state_a = get_forward_state(session_a)
      assert state_a.rtp_forward_paused == false

      # B's forwarding should be paused
      state_b = get_forward_state(session_b)
      assert state_b.rtp_forward_paused == true
    end

    test "hold :both pauses forwarding on both sessions", %{bridge: bridge, session_a: session_a, session_b: session_b} do
      {:ok, held} = MediaBridge.hold(bridge, :both)

      assert held.state == :held_both

      state_a = get_forward_state(session_a)
      state_b = get_forward_state(session_b)

      assert state_a.rtp_forward_paused == true
      assert state_b.rtp_forward_paused == true
    end
  end

  describe "resume/2 resumes forwarding" do
    setup do
      session_a = start_media_session("session-a-resume-#{:rand.uniform(100_000)}")
      session_b = start_media_session("session-b-resume-#{:rand.uniform(100_000)}")
      {:ok, bridge} = MediaBridge.create(session_a, session_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)
      {:ok, held_both} = MediaBridge.hold(bridged, :both)

      on_exit(fn ->
        if Process.alive?(session_a), do: MediaSession.terminate_session(session_a)
        if Process.alive?(session_b), do: MediaSession.terminate_session(session_b)
      end)

      {:ok, %{bridge: held_both, session_a: session_a, session_b: session_b}}
    end

    test "resume :leg_a resumes forwarding on session A", %{bridge: bridge, session_a: session_a, session_b: session_b} do
      {:ok, resumed} = MediaBridge.resume(bridge, :leg_a)

      assert resumed.state == :held_b

      # A's forwarding should be resumed
      state_a = get_forward_state(session_a)
      assert state_a.rtp_forward_paused == false

      # B's forwarding should still be paused
      state_b = get_forward_state(session_b)
      assert state_b.rtp_forward_paused == true
    end

    test "resume :leg_b resumes forwarding on session B", %{bridge: bridge, session_a: session_a, session_b: session_b} do
      {:ok, resumed} = MediaBridge.resume(bridge, :leg_b)

      assert resumed.state == :held_a

      # A's forwarding should still be paused
      state_a = get_forward_state(session_a)
      assert state_a.rtp_forward_paused == true

      # B's forwarding should be resumed
      state_b = get_forward_state(session_b)
      assert state_b.rtp_forward_paused == false
    end

    test "resume :both resumes forwarding on both sessions", %{bridge: bridge, session_a: session_a, session_b: session_b} do
      {:ok, resumed} = MediaBridge.resume(bridge, :both)

      assert resumed.state == :bridged

      state_a = get_forward_state(session_a)
      state_b = get_forward_state(session_b)

      assert state_a.rtp_forward_paused == false
      assert state_b.rtp_forward_paused == false
    end
  end

  describe "destroy/1 clears forwarding" do
    test "clears forwarding configuration on both sessions" do
      session_a = start_media_session("session-a-destroy-#{:rand.uniform(100_000)}")
      session_b = start_media_session("session-b-destroy-#{:rand.uniform(100_000)}")
      {:ok, bridge} = MediaBridge.create(session_a, session_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      # Verify forwarding is set up
      state_a = get_forward_state(session_a)
      assert state_a.rtp_forward_config != nil

      # Destroy the bridge
      :ok = MediaBridge.destroy(bridged)

      # Verify forwarding is cleared
      state_a_after = get_forward_state(session_a)
      state_b_after = get_forward_state(session_b)

      assert state_a_after.rtp_forward_config == nil
      assert state_b_after.rtp_forward_config == nil

      # Cleanup
      MediaSession.terminate_session(session_a)
      MediaSession.terminate_session(session_b)
    end
  end
end
