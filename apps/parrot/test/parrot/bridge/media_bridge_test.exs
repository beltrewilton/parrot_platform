defmodule Parrot.Bridge.MediaBridgeTest do
  @moduledoc """
  Tests for Parrot.Bridge.MediaBridge - RTP forwarding between B2BUA legs.

  Since MediaSession's set_rtp_forward functionality (T08) isn't implemented yet,
  these tests use mocks/stubs for MediaSession interactions.
  """
  use ExUnit.Case, async: true

  alias Parrot.Bridge.MediaBridge

  # Mock MediaSession module for testing
  # In production, this would be ParrotMedia.MediaSession
  defmodule MockMediaSession do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok, %{
        id: Keyword.get(opts, :id, "mock-session"),
        forward_target: nil,
        paused: false
      }}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end

    @impl true
    def handle_call({:set_rtp_forward, target_pid}, _from, state) do
      {:reply, :ok, %{state | forward_target: target_pid}}
    end

    @impl true
    def handle_call(:pause_forward, _from, state) do
      {:reply, :ok, %{state | paused: true}}
    end

    @impl true
    def handle_call(:resume_forward, _from, state) do
      {:reply, :ok, %{state | paused: false}}
    end

    @impl true
    def handle_call(:stop_forward, _from, state) do
      {:reply, :ok, %{state | forward_target: nil, paused: false}}
    end
  end

  describe "create/2" do
    test "creates a MediaBridge with two media PIDs" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")

      assert {:ok, bridge} = MediaBridge.create(media_a, media_b)

      assert bridge.leg_a_media == media_a
      assert bridge.leg_b_media == media_b
      assert bridge.state == :idle
    end

    test "returns error when leg_a_media is not a valid PID" do
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")

      assert {:error, :invalid_leg_a_media} = MediaBridge.create(:not_a_pid, media_b)
    end

    test "returns error when leg_b_media is not a valid PID" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")

      assert {:error, :invalid_leg_b_media} = MediaBridge.create(media_a, :not_a_pid)
    end

    test "returns error when leg_a_media process is not alive" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      GenServer.stop(media_a)

      assert {:error, :leg_a_not_alive} = MediaBridge.create(media_a, media_b)
    end

    test "returns error when leg_b_media process is not alive" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      GenServer.stop(media_b)

      assert {:error, :leg_b_not_alive} = MediaBridge.create(media_a, media_b)
    end
  end

  describe "bridge/1" do
    test "transitions from idle to bridged state" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)

      assert {:ok, bridged} = MediaBridge.bridge(bridge)

      assert bridged.state == :bridged
    end

    test "returns error when already bridged" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      assert {:error, :already_bridged} = MediaBridge.bridge(bridged)
    end

    test "returns error when in held state" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)
      {:ok, held} = MediaBridge.hold(bridged, :leg_a)

      assert {:error, :in_held_state} = MediaBridge.bridge(held)
    end
  end

  describe "hold/2" do
    setup do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      {:ok, %{bridged: bridged, media_a: media_a, media_b: media_b}}
    end

    test "hold :leg_a transitions to held_a state", %{bridged: bridged} do
      assert {:ok, held} = MediaBridge.hold(bridged, :leg_a)
      assert held.state == :held_a
    end

    test "hold :leg_b transitions to held_b state", %{bridged: bridged} do
      assert {:ok, held} = MediaBridge.hold(bridged, :leg_b)
      assert held.state == :held_b
    end

    test "hold :both transitions to held_both state", %{bridged: bridged} do
      assert {:ok, held} = MediaBridge.hold(bridged, :both)
      assert held.state == :held_both
    end

    test "hold :leg_a from held_b transitions to held_both", %{bridged: bridged} do
      {:ok, held_b} = MediaBridge.hold(bridged, :leg_b)
      assert {:ok, held_both} = MediaBridge.hold(held_b, :leg_a)
      assert held_both.state == :held_both
    end

    test "hold :leg_b from held_a transitions to held_both", %{bridged: bridged} do
      {:ok, held_a} = MediaBridge.hold(bridged, :leg_a)
      assert {:ok, held_both} = MediaBridge.hold(held_a, :leg_b)
      assert held_both.state == :held_both
    end

    test "returns error when not bridged" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)

      assert {:error, :not_bridged} = MediaBridge.hold(bridge, :leg_a)
    end

    test "returns error with invalid leg specifier", %{bridged: bridged} do
      assert {:error, :invalid_leg} = MediaBridge.hold(bridged, :invalid)
    end

    test "hold :leg_a when already held_a is idempotent", %{bridged: bridged} do
      {:ok, held_a} = MediaBridge.hold(bridged, :leg_a)
      assert {:ok, still_held_a} = MediaBridge.hold(held_a, :leg_a)
      assert still_held_a.state == :held_a
    end
  end

  describe "resume/2" do
    setup do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      {:ok, %{bridged: bridged, media_a: media_a, media_b: media_b}}
    end

    test "resume :leg_a from held_a returns to bridged", %{bridged: bridged} do
      {:ok, held_a} = MediaBridge.hold(bridged, :leg_a)
      assert {:ok, resumed} = MediaBridge.resume(held_a, :leg_a)
      assert resumed.state == :bridged
    end

    test "resume :leg_b from held_b returns to bridged", %{bridged: bridged} do
      {:ok, held_b} = MediaBridge.hold(bridged, :leg_b)
      assert {:ok, resumed} = MediaBridge.resume(held_b, :leg_b)
      assert resumed.state == :bridged
    end

    test "resume :both from held_both returns to bridged", %{bridged: bridged} do
      {:ok, held_both} = MediaBridge.hold(bridged, :both)
      assert {:ok, resumed} = MediaBridge.resume(held_both, :both)
      assert resumed.state == :bridged
    end

    test "resume :leg_a from held_both transitions to held_b", %{bridged: bridged} do
      {:ok, held_both} = MediaBridge.hold(bridged, :both)
      assert {:ok, partial} = MediaBridge.resume(held_both, :leg_a)
      assert partial.state == :held_b
    end

    test "resume :leg_b from held_both transitions to held_a", %{bridged: bridged} do
      {:ok, held_both} = MediaBridge.hold(bridged, :both)
      assert {:ok, partial} = MediaBridge.resume(held_both, :leg_b)
      assert partial.state == :held_a
    end

    test "returns error when not in held state", %{bridged: bridged} do
      assert {:error, :not_held} = MediaBridge.resume(bridged, :leg_a)
    end

    test "returns error with invalid leg specifier", %{bridged: bridged} do
      {:ok, held} = MediaBridge.hold(bridged, :leg_a)
      assert {:error, :invalid_leg} = MediaBridge.resume(held, :invalid)
    end

    test "resume :leg_b from held_a has no effect (idempotent)", %{bridged: bridged} do
      {:ok, held_a} = MediaBridge.hold(bridged, :leg_a)
      assert {:ok, still_held_a} = MediaBridge.resume(held_a, :leg_b)
      assert still_held_a.state == :held_a
    end
  end

  describe "destroy/1" do
    test "cleans up bridge from idle state" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)

      assert :ok = MediaBridge.destroy(bridge)
    end

    test "cleans up bridge from bridged state" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      assert :ok = MediaBridge.destroy(bridged)
    end

    test "cleans up bridge from held state" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)
      {:ok, held} = MediaBridge.hold(bridged, :both)

      assert :ok = MediaBridge.destroy(held)
    end
  end

  describe "state machine consistency" do
    test "full lifecycle: create -> bridge -> hold -> resume -> destroy" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")

      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      assert bridge.state == :idle

      {:ok, bridged} = MediaBridge.bridge(bridge)
      assert bridged.state == :bridged

      {:ok, held_a} = MediaBridge.hold(bridged, :leg_a)
      assert held_a.state == :held_a

      {:ok, held_both} = MediaBridge.hold(held_a, :leg_b)
      assert held_both.state == :held_both

      {:ok, held_b} = MediaBridge.resume(held_both, :leg_a)
      assert held_b.state == :held_b

      {:ok, resumed} = MediaBridge.resume(held_b, :leg_b)
      assert resumed.state == :bridged

      assert :ok = MediaBridge.destroy(resumed)
    end

    test "struct immutability - original struct unchanged after operations" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")

      {:ok, original} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(original)

      assert original.state == :idle
      assert bridged.state == :bridged
    end
  end

  describe "get_state/1" do
    test "returns current state of the bridge" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)

      assert MediaBridge.get_state(bridge) == :idle

      {:ok, bridged} = MediaBridge.bridge(bridge)
      assert MediaBridge.get_state(bridged) == :bridged

      {:ok, held} = MediaBridge.hold(bridged, :leg_a)
      assert MediaBridge.get_state(held) == :held_a
    end
  end

  describe "bridged?/1" do
    test "returns true when state is :bridged" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      assert MediaBridge.bridged?(bridged) == true
    end

    test "returns false when state is :idle" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)

      assert MediaBridge.bridged?(bridge) == false
    end

    test "returns false when in held state" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)
      {:ok, held} = MediaBridge.hold(bridged, :leg_a)

      assert MediaBridge.bridged?(held) == false
    end
  end

  describe "held?/1" do
    test "returns true when in any held state" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      {:ok, held_a} = MediaBridge.hold(bridged, :leg_a)
      assert MediaBridge.held?(held_a) == true

      {:ok, held_b} = MediaBridge.hold(bridged, :leg_b)
      assert MediaBridge.held?(held_b) == true

      {:ok, held_both} = MediaBridge.hold(bridged, :both)
      assert MediaBridge.held?(held_both) == true
    end

    test "returns false when not held" do
      {:ok, media_a} = MockMediaSession.start_link(id: "leg-a")
      {:ok, media_b} = MockMediaSession.start_link(id: "leg-b")
      {:ok, bridge} = MediaBridge.create(media_a, media_b)
      {:ok, bridged} = MediaBridge.bridge(bridge)

      assert MediaBridge.held?(bridge) == false
      assert MediaBridge.held?(bridged) == false
    end
  end
end
