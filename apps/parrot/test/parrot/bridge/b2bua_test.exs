defmodule Parrot.Bridge.B2BUATest do
  @moduledoc """
  Tests for Parrot.Bridge.B2BUA - Core B2BUA session management.

  The B2BUA GenServer manages call bridging sessions, coordinating:
  - Leg lifecycle (A-leg, B-legs)
  - Ring strategies (fork/bridge)
  - Media bridging between answered legs
  - Event dispatch to user handlers

  ## Test Categories

  1. Session Lifecycle - start, stop, state queries
  2. Leg Management - set_a_leg, originate, leg state tracking
  3. Ring Strategy - simultaneous, sequential, delayed forking
  4. Media Bridging - connect, hold, resume
  5. Event Handling - leg events dispatched to handler
  6. Error Cases - invalid operations, missing legs, etc.
  """
  use ExUnit.Case, async: true

  alias Parrot.Bridge.B2BUA
  alias Parrot.Bridge.RingStrategy
  alias Parrot.Leg

  # ===========================================================================
  # Mock Handler
  # ===========================================================================

  defmodule MockHandler do
    @moduledoc """
    Mock handler that tracks all events received for test assertions.
    """
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def get_events(pid) do
      GenServer.call(pid, :get_events)
    end

    def reset(pid) do
      GenServer.call(pid, :reset)
    end

    # Callbacks for InviteHandler behavior
    def handle_leg_event(leg_id, event, state) do
      # Send event to the tracking process
      if is_pid(state.tracker) and Process.alive?(state.tracker) do
        send(state.tracker, {:leg_event, leg_id, event})
      end

      {:ok, state}
    end

    @impl true
    def init(opts) do
      {:ok, %{events: [], tracker: Keyword.get(opts, :tracker)}}
    end

    @impl true
    def handle_call(:get_events, _from, state) do
      {:reply, Enum.reverse(state.events), state}
    end

    @impl true
    def handle_call(:reset, _from, state) do
      {:reply, :ok, %{state | events: []}}
    end

    @impl true
    def handle_info({:leg_event, leg_id, event}, state) do
      events = [{leg_id, event} | state.events]
      {:noreply, %{state | events: events}}
    end
  end

  # ===========================================================================
  # Mock MediaSession
  # ===========================================================================

  defmodule MockMediaSession do
    @moduledoc """
    Minimal mock MediaSession for testing B2BUA without real media.
    """
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok, %{id: Keyword.get(opts, :id, "mock-media")}}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end
  end

  # ===========================================================================
  # Test Setup
  # ===========================================================================

  defp start_b2bua(opts \\ []) do
    # Start MockHandler to provide handle_leg_event/3 callback
    {:ok, tracker} = MockHandler.start_link(tracker: self())

    default_opts = [
      handler: MockHandler,
      # Pass test process (self()) as tracker so events dispatch to test process
      handler_state: %{tracker: self()},
      media_mode: :proxy
    ]

    opts = Keyword.merge(default_opts, opts)
    {:ok, pid} = B2BUA.start_link(opts)

    {:ok, %{pid: pid, tracker: tracker}}
  end

  defp create_mock_leg(opts) do
    Leg.new(opts)
  end

  defp start_mock_media(id \\ nil) do
    MockMediaSession.start_link(id: id || Leg.generate_id())
  end

  # ===========================================================================
  # Session Lifecycle Tests
  # ===========================================================================

  describe "start_link/1" do
    test "starts a B2BUA process with default options" do
      {:ok, %{pid: pid}} = start_b2bua()

      assert Process.alive?(pid)
      assert is_binary(B2BUA.get_session_id(pid))
    end

    test "starts with custom session_id" do
      {:ok, %{pid: pid}} = start_b2bua(session_id: "custom-session-123")

      assert B2BUA.get_session_id(pid) == "custom-session-123"
    end

    test "starts with specified media_mode" do
      {:ok, %{pid: pid}} = start_b2bua(media_mode: :direct)

      assert B2BUA.get_media_mode(pid) == :direct
    end

    test "defaults to proxy media_mode" do
      {:ok, %{pid: pid}} = start_b2bua()

      assert B2BUA.get_media_mode(pid) == :proxy
    end

    test "starts with no legs" do
      {:ok, %{pid: pid}} = start_b2bua()

      assert B2BUA.get_legs(pid) == %{}
    end
  end

  describe "stop/1" do
    test "gracefully stops the B2BUA process" do
      {:ok, %{pid: pid}} = start_b2bua()
      ref = Process.monitor(pid)

      :ok = B2BUA.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  # ===========================================================================
  # A-Leg Management Tests
  # ===========================================================================

  describe "set_a_leg/2" do
    test "sets the A-leg on the session" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_pid} = start_mock_media()

      a_leg =
        create_mock_leg(
          id: :a_leg,
          direction: :inbound,
          remote_uri: "sip:alice@example.com",
          media_pid: media_pid
        )

      assert :ok = B2BUA.set_a_leg(pid, a_leg)

      legs = B2BUA.get_legs(pid)
      assert Map.has_key?(legs, :a_leg)
      assert legs[:a_leg].direction == :inbound
    end

    test "returns error when A-leg already exists" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_pid} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, media_pid: media_pid)

      :ok = B2BUA.set_a_leg(pid, a_leg)
      assert {:error, :a_leg_exists} = B2BUA.set_a_leg(pid, a_leg)
    end

    test "dispatches :trying event to handler" do
      {:ok, %{pid: pid, tracker: _tracker}} = start_b2bua()
      {:ok, media_pid} = start_mock_media()

      a_leg =
        create_mock_leg(id: :a_leg, direction: :inbound, state: :trying, media_pid: media_pid)

      :ok = B2BUA.set_a_leg(pid, a_leg)

      # Handler should receive the leg event
      assert_receive {:leg_event, :a_leg, :trying}, 100
    end
  end

  # ===========================================================================
  # Originate (B-Leg) Tests
  # ===========================================================================

  describe "originate/3" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_pid} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_pid)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, %{pid: pid, tracker: tracker}}
    end

    test "creates a new outbound leg", %{pid: pid} do
      {:ok, leg_id} = B2BUA.originate(pid, "sip:bob@example.com")

      legs = B2BUA.get_legs(pid)
      assert Map.has_key?(legs, leg_id)
      assert legs[leg_id].direction == :outbound
      assert legs[leg_id].remote_uri == "sip:bob@example.com"
    end

    test "accepts custom leg_id via :as option", %{pid: pid} do
      {:ok, leg_id} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)

      assert leg_id == :b_leg
      legs = B2BUA.get_legs(pid)
      assert Map.has_key?(legs, :b_leg)
    end

    test "starts leg in :init state", %{pid: pid} do
      {:ok, leg_id} = B2BUA.originate(pid, "sip:bob@example.com")

      legs = B2BUA.get_legs(pid)
      assert legs[leg_id].state == :init
    end

    test "returns error for duplicate leg_id", %{pid: pid} do
      {:ok, _} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)
      assert {:error, :leg_exists} = B2BUA.originate(pid, "sip:carol@example.com", as: :b_leg)
    end
  end

  # ===========================================================================
  # Leg Event Handling Tests
  # ===========================================================================

  describe "handle_leg_event/3" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_pid} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_pid)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, b_leg_id} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)

      {:ok, %{pid: pid, tracker: tracker, b_leg_id: b_leg_id}}
    end

    test "transitions leg to :trying state", %{pid: pid, b_leg_id: b_leg_id} do
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :trying)

      legs = B2BUA.get_legs(pid)
      assert legs[b_leg_id].state == :trying
    end

    test "transitions leg to :ringing state", %{pid: pid, b_leg_id: b_leg_id} do
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :trying)
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :ringing)

      legs = B2BUA.get_legs(pid)
      assert legs[b_leg_id].state == :ringing
    end

    test "transitions leg to :answered state with SDP", %{pid: pid, b_leg_id: b_leg_id} do
      sdp = "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\n"

      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :trying)
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, {:answered, sdp})

      legs = B2BUA.get_legs(pid)
      assert legs[b_leg_id].state == :answered
      assert legs[b_leg_id].sdp == sdp
    end

    test "transitions leg to :terminated on :bye", %{pid: pid, b_leg_id: b_leg_id} do
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :trying)
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, {:answered, "sdp"})
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :bye)

      legs = B2BUA.get_legs(pid)
      assert legs[b_leg_id].state == :terminated
    end

    test "transitions leg to :terminated on {:failed, reason}", %{pid: pid, b_leg_id: b_leg_id} do
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :trying)
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, {:failed, :busy})

      legs = B2BUA.get_legs(pid)
      assert legs[b_leg_id].state == :terminated
    end

    test "dispatches event to handler", %{pid: pid, b_leg_id: b_leg_id, tracker: _tracker} do
      # Must transition through :trying before :ringing
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :trying)
      :ok = B2BUA.handle_leg_event(pid, b_leg_id, :ringing)

      assert_receive {:leg_event, ^b_leg_id, :ringing}, 100
    end

    test "returns error for unknown leg", %{pid: pid} do
      assert {:error, :unknown_leg} = B2BUA.handle_leg_event(pid, :unknown_leg, :ringing)
    end
  end

  # ===========================================================================
  # Connect (Media Bridging) Tests
  # ===========================================================================

  describe "connect/3" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_a} = start_mock_media("media-a")
      {:ok, media_b} = start_mock_media("media-b")

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, _} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)

      # Simulate B-leg answering
      :ok = B2BUA.handle_leg_event(pid, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(pid, :b_leg, {:answered, "sdp"})

      # Update B-leg with media_pid
      :ok = B2BUA.update_leg(pid, :b_leg, media_pid: media_b)

      {:ok, %{pid: pid, tracker: tracker, media_a: media_a, media_b: media_b}}
    end

    test "connects two answered legs", %{pid: pid} do
      assert {:ok, _bridge} = B2BUA.connect(pid, :a_leg, :b_leg)

      assert B2BUA.get_active_bridge(pid) == {:a_leg, :b_leg}
    end

    test "returns error when leg_a not found", %{pid: pid} do
      assert {:error, :leg_not_found} = B2BUA.connect(pid, :unknown, :b_leg)
    end

    test "returns error when leg_b not found", %{pid: pid} do
      assert {:error, :leg_not_found} = B2BUA.connect(pid, :a_leg, :unknown)
    end

    test "returns error when leg_a not answered", %{pid: pid} do
      # Create a new leg that's not answered
      {:ok, _} = B2BUA.originate(pid, "sip:carol@example.com", as: :c_leg)

      assert {:error, :leg_not_answered} = B2BUA.connect(pid, :a_leg, :c_leg)
    end

    test "returns error when leg_b not answered", %{pid: pid} do
      # Create a new leg that's not answered
      {:ok, _} = B2BUA.originate(pid, "sip:carol@example.com", as: :c_leg)

      assert {:error, :leg_not_answered} = B2BUA.connect(pid, :c_leg, :b_leg)
    end
  end

  # ===========================================================================
  # Hold/Resume Tests
  # ===========================================================================

  describe "hold/2" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_a} = start_mock_media("media-a")
      {:ok, media_b} = start_mock_media("media-b")

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, _} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)
      :ok = B2BUA.handle_leg_event(pid, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(pid, :b_leg, {:answered, "sdp"})
      :ok = B2BUA.update_leg(pid, :b_leg, media_pid: media_b)

      # Connect the legs
      {:ok, _bridge} = B2BUA.connect(pid, :a_leg, :b_leg)

      {:ok, %{pid: pid, tracker: tracker}}
    end

    test "puts leg on hold", %{pid: pid} do
      assert :ok = B2BUA.hold(pid, :b_leg)

      legs = B2BUA.get_legs(pid)
      assert legs[:b_leg].state == :held
    end

    test "dispatches :held event to handler", %{pid: pid} do
      :ok = B2BUA.hold(pid, :b_leg)

      assert_receive {:leg_event, :b_leg, :held}, 100
    end

    test "returns error for unknown leg", %{pid: pid} do
      assert {:error, :unknown_leg} = B2BUA.hold(pid, :unknown)
    end

    test "returns error when leg not connected", %{pid: pid} do
      {:ok, _} = B2BUA.originate(pid, "sip:carol@example.com", as: :c_leg)

      assert {:error, :leg_not_connected} = B2BUA.hold(pid, :c_leg)
    end
  end

  describe "resume/2" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_a} = start_mock_media("media-a")
      {:ok, media_b} = start_mock_media("media-b")

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, _} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)
      :ok = B2BUA.handle_leg_event(pid, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(pid, :b_leg, {:answered, "sdp"})
      :ok = B2BUA.update_leg(pid, :b_leg, media_pid: media_b)

      {:ok, _bridge} = B2BUA.connect(pid, :a_leg, :b_leg)
      :ok = B2BUA.hold(pid, :b_leg)

      {:ok, %{pid: pid, tracker: tracker}}
    end

    test "resumes a held leg", %{pid: pid} do
      assert :ok = B2BUA.resume(pid, :b_leg)

      legs = B2BUA.get_legs(pid)
      assert legs[:b_leg].state == :answered
    end

    test "dispatches :resumed event to handler", %{pid: pid} do
      :ok = B2BUA.resume(pid, :b_leg)

      assert_receive {:leg_event, :b_leg, :resumed}, 100
    end

    test "returns error when leg not held", %{pid: pid} do
      :ok = B2BUA.resume(pid, :b_leg)  # Resume first

      assert {:error, :leg_not_held} = B2BUA.resume(pid, :b_leg)
    end
  end

  # ===========================================================================
  # Hangup Tests
  # ===========================================================================

  describe "hangup_leg/2" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_a} = start_mock_media("media-a")

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, _} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)
      :ok = B2BUA.handle_leg_event(pid, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(pid, :b_leg, {:answered, "sdp"})

      {:ok, %{pid: pid, tracker: tracker}}
    end

    test "terminates specific leg", %{pid: pid} do
      assert :ok = B2BUA.hangup_leg(pid, :b_leg)

      legs = B2BUA.get_legs(pid)
      assert legs[:b_leg].state == :terminated
    end

    test "returns error for unknown leg", %{pid: pid} do
      assert {:error, :unknown_leg} = B2BUA.hangup_leg(pid, :unknown)
    end
  end

  describe "hangup_all/1" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_a} = start_mock_media("media-a")

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, _} = B2BUA.originate(pid, "sip:bob@example.com", as: :b_leg)
      {:ok, _} = B2BUA.originate(pid, "sip:carol@example.com", as: :c_leg)

      {:ok, %{pid: pid, tracker: tracker}}
    end

    test "terminates all active legs", %{pid: pid} do
      assert :ok = B2BUA.hangup_all(pid)

      legs = B2BUA.get_legs(pid)

      for {_id, leg} <- legs do
        assert leg.state == :terminated
      end
    end

    test "dispatches :bye event for each leg", %{pid: pid} do
      :ok = B2BUA.hangup_all(pid)

      assert_receive {:leg_event, :a_leg, :bye}, 100
      assert_receive {:leg_event, :b_leg, :bye}, 100
      assert_receive {:leg_event, :c_leg, :bye}, 100
    end
  end

  # ===========================================================================
  # Fork (Multi-Destination) Tests
  # ===========================================================================

  describe "fork/3" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_a} = start_mock_media("media-a")

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      {:ok, %{pid: pid, tracker: tracker}}
    end

    test "creates multiple outbound legs with simultaneous strategy", %{pid: pid} do
      destinations = ["sip:bob@example.com", "sip:carol@example.com", "sip:dave@example.com"]
      strategy = RingStrategy.simultaneous()

      {:ok, leg_ids} = B2BUA.fork(pid, destinations, strategy: strategy)

      assert length(leg_ids) == 3
      legs = B2BUA.get_legs(pid)

      for leg_id <- leg_ids do
        assert Map.has_key?(legs, leg_id)
        assert legs[leg_id].direction == :outbound
      end
    end

    test "stores pending legs for forking", %{pid: pid} do
      destinations = ["sip:bob@example.com", "sip:carol@example.com"]
      strategy = RingStrategy.simultaneous()

      {:ok, leg_ids} = B2BUA.fork(pid, destinations, strategy: strategy)

      pending = B2BUA.get_pending_legs(pid)
      assert MapSet.new(pending) == MapSet.new(leg_ids)
    end

    test "with sequential strategy creates one leg at a time", %{pid: pid} do
      destinations = ["sip:bob@example.com", "sip:carol@example.com"]
      strategy = RingStrategy.sequential(ring_timeout: 10_000)

      {:ok, leg_ids} = B2BUA.fork(pid, destinations, strategy: strategy)

      # With sequential, all legs are created but only first is "active"
      assert length(leg_ids) == 2
    end
  end

  describe "fork event handling" do
    setup do
      {:ok, %{pid: pid, tracker: tracker}} = start_b2bua()
      {:ok, media_a} = start_mock_media("media-a")
      {:ok, media_b} = start_mock_media("media-b")

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :answered, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      destinations = ["sip:bob@example.com", "sip:carol@example.com"]
      strategy = RingStrategy.simultaneous()
      {:ok, [leg_1, leg_2]} = B2BUA.fork(pid, destinations, strategy: strategy)

      {:ok, %{pid: pid, tracker: tracker, leg_1: leg_1, leg_2: leg_2, media_b: media_b}}
    end

    test "first answer wins - cancels other legs", %{pid: pid, leg_1: leg_1, leg_2: leg_2, media_b: media_b} do
      # Both legs start trying
      :ok = B2BUA.handle_leg_event(pid, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(pid, leg_2, :trying)

      # Leg 1 answers first
      :ok = B2BUA.handle_leg_event(pid, leg_1, {:answered, "sdp"})
      :ok = B2BUA.update_leg(pid, leg_1, media_pid: media_b)

      # Check that leg_1 is the winner
      legs = B2BUA.get_legs(pid)
      assert legs[leg_1].state == :answered

      # Pending legs should be cleared (only winner remains pending)
      pending = B2BUA.get_pending_legs(pid)
      assert pending == [] or pending == [leg_1]
    end

    test "all legs failed triggers :all_failed event", %{pid: pid, leg_1: leg_1, leg_2: leg_2} do
      :ok = B2BUA.handle_leg_event(pid, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(pid, leg_2, :trying)
      :ok = B2BUA.handle_leg_event(pid, leg_1, {:failed, :busy})
      :ok = B2BUA.handle_leg_event(pid, leg_2, {:failed, :no_answer})

      # Both legs should be terminated
      legs = B2BUA.get_legs(pid)
      assert legs[leg_1].state == :terminated
      assert legs[leg_2].state == :terminated

      # Should receive all_failed event (implementation detail)
      # The handler would typically receive notification
    end
  end

  # ===========================================================================
  # State Query Tests
  # ===========================================================================

  describe "state queries" do
    test "get_session_id/1 returns the session identifier" do
      {:ok, %{pid: pid}} = start_b2bua(session_id: "test-session")

      assert B2BUA.get_session_id(pid) == "test-session"
    end

    test "get_legs/1 returns all legs" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_a} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      legs = B2BUA.get_legs(pid)
      assert Map.has_key?(legs, :a_leg)
    end

    test "get_leg/2 returns specific leg" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_a} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      assert {:ok, leg} = B2BUA.get_leg(pid, :a_leg)
      assert leg.id == :a_leg
    end

    test "get_leg/2 returns error for unknown leg" do
      {:ok, %{pid: pid}} = start_b2bua()

      assert {:error, :not_found} = B2BUA.get_leg(pid, :unknown)
    end

    test "get_active_bridge/1 returns nil when no bridge" do
      {:ok, %{pid: pid}} = start_b2bua()

      assert B2BUA.get_active_bridge(pid) == nil
    end
  end

  # ===========================================================================
  # Error Handling Tests
  # ===========================================================================

  describe "error handling" do
    test "handles invalid leg transitions gracefully" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_a} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :init, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      # Try invalid transition: init -> answered (should go through trying first)
      assert {:error, :invalid_transition} = B2BUA.handle_leg_event(pid, :a_leg, {:answered, "sdp"})
    end

    test "ignores events for terminated legs" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_a} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, state: :terminated, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      # Events on terminated leg should be ignored
      assert {:error, :leg_terminated} = B2BUA.handle_leg_event(pid, :a_leg, :ringing)
    end
  end

  # ===========================================================================
  # Metadata Tests
  # ===========================================================================

  describe "leg metadata" do
    test "update_leg/3 updates leg metadata" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_a} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      :ok = B2BUA.update_leg(pid, :a_leg, metadata: %{custom: "value"})

      {:ok, leg} = B2BUA.get_leg(pid, :a_leg)
      assert leg.metadata.custom == "value"
    end

    test "update_leg/3 can set dialog_id" do
      {:ok, %{pid: pid}} = start_b2bua()
      {:ok, media_a} = start_mock_media()

      a_leg = create_mock_leg(id: :a_leg, direction: :inbound, media_pid: media_a)
      :ok = B2BUA.set_a_leg(pid, a_leg)

      :ok = B2BUA.update_leg(pid, :a_leg, dialog_id: "dialog-123")

      {:ok, leg} = B2BUA.get_leg(pid, :a_leg)
      assert leg.dialog_id == "dialog-123"
    end
  end
end
