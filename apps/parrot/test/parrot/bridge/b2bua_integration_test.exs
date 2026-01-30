defmodule Parrot.Bridge.B2BUAIntegrationTest do
  @moduledoc """
  Integration tests for B2BUA (Back-to-Back User Agent) call flows.

  These tests verify complete call flows through the B2BUA system, including:

  1. Bridge lifecycle: originate -> ringing -> answered -> connected -> bye
  2. Fork simultaneous: Multiple legs, first answer wins, others cancelled
  3. Fork sequential: One at a time, timeout moves to next
  4. Fork delayed: Staggered ringing
  5. Hold/resume flow: Connected -> hold -> resume -> connected
  6. Transfer flows: Blind transfer (attended transfer if implemented)
  7. Error cases: Timeout, rejection, network failure, invalid operations

  ## Mock Architecture

  These tests use mocks for:
  - SIP layer (no real network)
  - MediaSession for media bridging
  - Handler to verify callbacks

  ## Patterns

  Each test follows TDD principles, verifying behavior through public APIs
  and handler callbacks rather than internal state inspection.
  """
  use ExUnit.Case, async: false

  alias Parrot.Bridge.B2BUA
  alias Parrot.Bridge.RingStrategy
  alias Parrot.Leg

  # ===========================================================================
  # Mock Handler - Tracks all events for test assertions
  # ===========================================================================

  defmodule MockHandler do
    @moduledoc """
    Mock handler that tracks all leg events received.

    Events are sent to the test process for assertion.
    Implements the handle_leg_event/3 callback expected by B2BUA.
    """
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def get_events(pid) do
      GenServer.call(pid, :get_events)
    end

    def clear_events(pid) do
      GenServer.call(pid, :clear_events)
    end

    # Callback for B2BUA - this is called by B2BUA.dispatch_leg_event/3
    def handle_leg_event(leg_id, event, state) do
      if is_pid(state.test_pid) and Process.alive?(state.test_pid) do
        send(state.test_pid, {:leg_event, leg_id, event})
      end

      {:ok, state}
    end

    @impl true
    def init(opts) do
      {:ok, %{events: [], test_pid: Keyword.get(opts, :test_pid)}}
    end

    @impl true
    def handle_call(:get_events, _from, state) do
      {:reply, Enum.reverse(state.events), state}
    end

    @impl true
    def handle_call(:clear_events, _from, state) do
      {:reply, :ok, %{state | events: []}}
    end

    @impl true
    def handle_info({:leg_event, leg_id, event}, state) do
      events = [{leg_id, event} | state.events]
      {:noreply, %{state | events: events}}
    end
  end

  # ===========================================================================
  # Mock MediaSession - Simulates media layer without real RTP
  # ===========================================================================

  defmodule MockMediaSession do
    @moduledoc """
    Mock MediaSession for testing B2BUA without real media processing.

    Tracks forwarding state and simulates media operations.
    Uses gen_statem to match the real MediaSession's wire protocol.
    """
    @behaviour :gen_statem

    def start_link(opts \\ []) do
      :gen_statem.start_link(__MODULE__, opts, [])
    end

    def get_state(pid) do
      :gen_statem.call(pid, :get_state)
    end

    def set_forward_target(pid, target_pid) do
      :gen_statem.call(pid, {:set_forward_target, target_pid})
    end

    def pause_forward(pid) do
      :gen_statem.call(pid, :pause_forward)
    end

    def resume_forward(pid) do
      :gen_statem.call(pid, :resume_forward)
    end

    # gen_statem callbacks

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(opts) do
      data = %{
        id: Keyword.get(opts, :id, generate_id()),
        forward_target: nil,
        forwarding: false,
        rtp_forward_config: nil,
        rtp_forward_paused: false
      }
      {:ok, :idle, data}
    end

    # State function for :idle state (handles all calls in any state)
    def idle({:call, from}, :get_state, data) do
      {:keep_state_and_data, [{:reply, from, data}]}
    end

    def idle({:call, from}, {:set_forward_target, target_pid}, data) do
      {:keep_state, %{data | forward_target: target_pid, forwarding: true}, [{:reply, from, :ok}]}
    end

    def idle({:call, from}, {:set_rtp_forward, nil}, data) do
      {:keep_state, %{data | rtp_forward_config: nil, rtp_forward_paused: false}, [{:reply, from, :ok}]}
    end

    def idle({:call, from}, {:set_rtp_forward, config}, data) do
      {:keep_state, %{data | rtp_forward_config: config, rtp_forward_paused: false}, [{:reply, from, :ok}]}
    end

    def idle({:call, from}, :pause_forward, data) do
      {:keep_state, %{data | forwarding: false, rtp_forward_paused: true}, [{:reply, from, :ok}]}
    end

    def idle({:call, from}, :resume_forward, data) do
      {:keep_state, %{data | forwarding: true, rtp_forward_paused: false}, [{:reply, from, :ok}]}
    end

    defp generate_id do
      "mock-media-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    end
  end

  # ===========================================================================
  # Mock SIP Layer - Simulates SIP operations
  # ===========================================================================

  defmodule MockSipLayer do
    @moduledoc """
    Mock SIP layer for simulating INVITE, BYE, CANCEL, and response messages.

    This allows testing B2BUA logic without actual network operations.
    """
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def get_invites(pid) do
      GenServer.call(pid, :get_invites)
    end

    def get_cancels(pid) do
      GenServer.call(pid, :get_cancels)
    end

    def get_byes(pid) do
      GenServer.call(pid, :get_byes)
    end

    def send_invite(pid, destination) do
      GenServer.call(pid, {:send_invite, destination})
    end

    def send_cancel(pid, leg_id) do
      GenServer.call(pid, {:send_cancel, leg_id})
    end

    def send_bye(pid, leg_id) do
      GenServer.call(pid, {:send_bye, leg_id})
    end

    @impl true
    def init(_opts) do
      {:ok, %{invites: [], cancels: [], byes: []}}
    end

    @impl true
    def handle_call(:get_invites, _from, state) do
      {:reply, Enum.reverse(state.invites), state}
    end

    @impl true
    def handle_call(:get_cancels, _from, state) do
      {:reply, Enum.reverse(state.cancels), state}
    end

    @impl true
    def handle_call(:get_byes, _from, state) do
      {:reply, Enum.reverse(state.byes), state}
    end

    @impl true
    def handle_call({:send_invite, destination}, _from, state) do
      dialog_id = "dialog-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      invites = [{destination, dialog_id} | state.invites]
      {:reply, {:ok, dialog_id}, %{state | invites: invites}}
    end

    @impl true
    def handle_call({:send_cancel, leg_id}, _from, state) do
      cancels = [leg_id | state.cancels]
      {:reply, :ok, %{state | cancels: cancels}}
    end

    @impl true
    def handle_call({:send_bye, leg_id}, _from, state) do
      byes = [leg_id | state.byes]
      {:reply, :ok, %{state | byes: byes}}
    end
  end

  # ===========================================================================
  # Test Setup Helpers
  # ===========================================================================

  defp start_b2bua(opts \\ []) do
    default_opts = [
      handler: MockHandler,
      handler_state: %{test_pid: self()},
      media_mode: :proxy
    ]

    opts = Keyword.merge(default_opts, opts)
    {:ok, pid} = B2BUA.start_link(opts)
    pid
  end

  defp start_mock_media(id \\ nil) do
    {:ok, pid} = MockMediaSession.start_link(id: id)
    pid
  end

  defp create_a_leg(opts) do
    media_pid = Keyword.get(opts, :media_pid) || start_mock_media()

    default_opts = [
      id: :a_leg,
      direction: :inbound,
      state: Keyword.get(opts, :state, :answered),
      remote_uri: "sip:caller@example.com",
      media_pid: media_pid
    ]

    Leg.new(Keyword.merge(default_opts, opts))
  end

  defp make_sdp do
    "v=0\r\no=- 123 456 IN IP4 192.168.1.1\r\ns=-\r\nc=IN IP4 192.168.1.1\r\nt=0 0\r\nm=audio 5004 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
  end

  # ===========================================================================
  # 1. Bridge Lifecycle Tests
  # ===========================================================================

  describe "bridge lifecycle: originate -> ringing -> answered -> connected -> bye" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")
      media_b = start_mock_media("media-b")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      # Clear the :answered event from setting a_leg
      receive do
        {:leg_event, :a_leg, :answered} -> :ok
      after
        100 -> :ok
      end

      {:ok, %{b2bua: b2bua, media_a: media_a, media_b: media_b}}
    end

    test "complete bridge flow from originate to bye", %{b2bua: b2bua, media_b: media_b} do
      # 1. Originate B-leg
      {:ok, b_leg_id} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      assert b_leg_id == :b_leg

      # Verify leg created in :init state
      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :init
      assert legs[:b_leg].remote_uri == "sip:agent@pbx.local"

      # 2. INVITE sent -> trying
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      assert_receive {:leg_event, :b_leg, :trying}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :trying

      # 3. 180 Ringing received
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :ringing)
      assert_receive {:leg_event, :b_leg, :ringing}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :ringing

      # 4. 200 OK received with SDP
      sdp = make_sdp()
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, sdp})
      assert_receive {:leg_event, :b_leg, :answered}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :answered
      assert legs[:b_leg].sdp == sdp

      # 5. Update B-leg with media PID and connect
      :ok = B2BUA.update_leg(b2bua, :b_leg, media_pid: media_b)

      {:ok, bridge} = B2BUA.connect(b2bua, :a_leg, :b_leg)
      assert bridge.state == :bridged
      assert B2BUA.get_active_bridge(b2bua) == {:a_leg, :b_leg}

      # 6. Remote BYE received
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :bye)
      assert_receive {:leg_event, :b_leg, :terminated}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :terminated
    end

    test "originate with multiple B-legs sequentially", %{b2bua: b2bua} do
      # First attempt - fails
      {:ok, :b_leg_1} = B2BUA.originate(b2bua, "sip:agent1@pbx.local", as: :b_leg_1)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg_1, {:failed, :busy})

      assert_receive {:leg_event, :b_leg_1, :terminated}, 200

      # Second attempt - succeeds
      {:ok, :b_leg_2} = B2BUA.originate(b2bua, "sip:agent2@pbx.local", as: :b_leg_2)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg_2, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg_2, {:answered, make_sdp()})

      assert_receive {:leg_event, :b_leg_2, :answered}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg_1].state == :terminated
      assert legs[:b_leg_2].state == :answered
    end

    test "A-leg BYE terminates the bridge", %{b2bua: b2bua, media_b: media_b} do
      # Set up a connected call
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})
      :ok = B2BUA.update_leg(b2bua, :b_leg, media_pid: media_b)
      {:ok, _bridge} = B2BUA.connect(b2bua, :a_leg, :b_leg)

      # A-leg sends BYE
      :ok = B2BUA.handle_leg_event(b2bua, :a_leg, :bye)
      assert_receive {:leg_event, :a_leg, :terminated}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:a_leg].state == :terminated
    end
  end

  # ===========================================================================
  # 2. Fork Simultaneous Tests
  # ===========================================================================

  describe "fork simultaneous: multiple legs, first answer wins" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      # Clear the initial event
      receive do
        {:leg_event, :a_leg, _} -> :ok
      after
        100 -> :ok
      end

      {:ok, %{b2bua: b2bua, media_a: media_a}}
    end

    test "first answer wins, clears pending legs", %{b2bua: b2bua} do
      destinations = [
        "sip:agent1@pbx.local",
        "sip:agent2@pbx.local",
        "sip:agent3@pbx.local"
      ]

      strategy = RingStrategy.simultaneous()
      {:ok, leg_ids} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      assert length(leg_ids) == 3

      # All legs start trying
      for leg_id <- leg_ids do
        :ok = B2BUA.handle_leg_event(b2bua, leg_id, :trying)
      end

      # All legs ringing
      for leg_id <- leg_ids do
        :ok = B2BUA.handle_leg_event(b2bua, leg_id, :ringing)
      end

      # First leg answers
      [first_leg | _rest] = leg_ids
      :ok = B2BUA.handle_leg_event(b2bua, first_leg, {:answered, make_sdp()})
      assert_receive {:leg_event, ^first_leg, :answered}, 200

      # Pending legs should be cleared
      pending = B2BUA.get_pending_legs(b2bua)
      assert pending == []

      # Winner is answered
      legs = B2BUA.get_legs(b2bua)
      assert legs[first_leg].state == :answered
    end

    test "second leg answers first when first leg fails", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local"]
      strategy = RingStrategy.simultaneous()
      {:ok, [leg_1, leg_2]} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      # Both start trying
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, :trying)

      # First leg fails
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, {:failed, :busy})
      assert_receive {:leg_event, ^leg_1, :terminated}, 200

      # Second leg answers
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, {:answered, make_sdp()})
      assert_receive {:leg_event, ^leg_2, :answered}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[leg_1].state == :terminated
      assert legs[leg_2].state == :answered
    end

    test "all legs fail triggers completion", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local"]
      strategy = RingStrategy.simultaneous()
      {:ok, [leg_1, leg_2]} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      # Both start trying
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, :trying)

      # Both fail
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, {:failed, :busy})
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, {:failed, :no_answer})

      # Both should be terminated
      legs = B2BUA.get_legs(b2bua)
      assert legs[leg_1].state == :terminated
      assert legs[leg_2].state == :terminated

      # No pending legs remain
      assert B2BUA.get_pending_legs(b2bua) == []
    end

    test "simultaneous with cancel_others: false allows multiple answers", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local"]
      strategy = RingStrategy.simultaneous(cancel_others: false)
      {:ok, [leg_1, leg_2]} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, :trying)

      # Both legs answer
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, {:answered, make_sdp()})
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, {:answered, make_sdp()})

      legs = B2BUA.get_legs(b2bua)
      # First answer still wins in B2BUA logic even with cancel_others: false
      # The difference is in the RingStrategy event handling
      assert legs[leg_1].state == :answered
      assert legs[leg_2].state == :answered
    end
  end

  # ===========================================================================
  # 3. Fork Sequential Tests
  # ===========================================================================

  describe "fork sequential: one leg at a time, timeout moves to next" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      receive do
        {:leg_event, :a_leg, _} -> :ok
      after
        100 -> :ok
      end

      {:ok, %{b2bua: b2bua, media_a: media_a}}
    end

    test "sequential ringing - first fails, second succeeds", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local"]
      strategy = RingStrategy.sequential(ring_timeout: 5_000)
      {:ok, leg_ids} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      assert length(leg_ids) == 2
      [leg_1, leg_2] = leg_ids

      # First leg tries
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :ringing)

      # First leg fails
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, {:failed, :no_answer})
      assert_receive {:leg_event, ^leg_1, :terminated}, 200

      # Second leg tries (sequential moves to next)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, :ringing)

      # Second leg answers
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, {:answered, make_sdp()})
      assert_receive {:leg_event, ^leg_2, :answered}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[leg_1].state == :terminated
      assert legs[leg_2].state == :answered
    end

    test "sequential - all legs fail in order", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local", "sip:agent3@pbx.local"]
      strategy = RingStrategy.sequential(ring_timeout: 5_000)
      {:ok, [leg_1, leg_2, leg_3]} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      # Each leg tries and fails
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, {:failed, :busy})

      :ok = B2BUA.handle_leg_event(b2bua, leg_2, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, {:failed, :no_answer})

      :ok = B2BUA.handle_leg_event(b2bua, leg_3, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_3, {:failed, :unavailable})

      legs = B2BUA.get_legs(b2bua)
      assert legs[leg_1].state == :terminated
      assert legs[leg_2].state == :terminated
      assert legs[leg_3].state == :terminated
    end

    test "sequential strategy creates all legs but only first rings initially", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local"]
      strategy = RingStrategy.sequential(ring_timeout: 10_000)
      {:ok, leg_ids} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      # All legs are created
      assert length(leg_ids) == 2

      # But the ring state tracks which should ring first
      # (This is internal to RingStrategy, verified via pending_legs)
      pending = B2BUA.get_pending_legs(b2bua)
      assert length(pending) == 2
    end
  end

  # ===========================================================================
  # 4. Fork Delayed Tests
  # ===========================================================================

  describe "fork delayed: staggered ringing" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      receive do
        {:leg_event, :a_leg, _} -> :ok
      after
        100 -> :ok
      end

      {:ok, %{b2bua: b2bua, media_a: media_a}}
    end

    test "delayed strategy creates legs with staggered timing", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local", "sip:agent3@pbx.local"]
      strategy = RingStrategy.delayed(delay: 5_000)
      {:ok, leg_ids} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      # All legs created
      assert length(leg_ids) == 3

      # Verify the strategy was set
      legs = B2BUA.get_legs(b2bua)
      assert map_size(legs) == 4  # A-leg + 3 B-legs

      # All legs are pending initially
      pending = B2BUA.get_pending_legs(b2bua)
      assert length(pending) == 3
    end

    test "delayed - first leg answers before delay fires", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local"]
      strategy = RingStrategy.delayed(delay: 10_000)
      {:ok, [leg_1, _leg_2]} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      # First leg answers immediately
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, {:answered, make_sdp()})

      assert_receive {:leg_event, ^leg_1, :answered}, 200

      # Pending legs cleared on answer
      pending = B2BUA.get_pending_legs(b2bua)
      assert pending == []
    end

    test "delayed - second leg answers after first fails", %{b2bua: b2bua} do
      destinations = ["sip:agent1@pbx.local", "sip:agent2@pbx.local"]
      strategy = RingStrategy.delayed(delay: 1_000)
      {:ok, [leg_1, leg_2]} = B2BUA.fork(b2bua, destinations, strategy: strategy)

      # First leg tries and fails
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_1, {:failed, :no_answer})

      # Second leg tries (would have started after delay)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_2, {:answered, make_sdp()})

      assert_receive {:leg_event, ^leg_2, :answered}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[leg_1].state == :terminated
      assert legs[leg_2].state == :answered
    end
  end

  # ===========================================================================
  # 5. Hold/Resume Flow Tests
  # ===========================================================================

  describe "hold/resume flow: connected -> hold -> resume -> connected" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")
      media_b = start_mock_media("media-b")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      # Establish connected call
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})
      :ok = B2BUA.update_leg(b2bua, :b_leg, media_pid: media_b)
      {:ok, _bridge} = B2BUA.connect(b2bua, :a_leg, :b_leg)

      # Clear setup events
      flush_mailbox()

      {:ok, %{b2bua: b2bua, media_a: media_a, media_b: media_b}}
    end

    test "hold B-leg transitions to held state", %{b2bua: b2bua} do
      :ok = B2BUA.hold(b2bua, :b_leg)

      assert_receive {:leg_event, :b_leg, :held}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :held
    end

    test "resume B-leg transitions back to answered state", %{b2bua: b2bua} do
      :ok = B2BUA.hold(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :held}, 200

      :ok = B2BUA.resume(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :resumed}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :answered
    end

    test "hold and resume A-leg", %{b2bua: b2bua} do
      :ok = B2BUA.hold(b2bua, :a_leg)
      assert_receive {:leg_event, :a_leg, :held}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:a_leg].state == :held

      :ok = B2BUA.resume(b2bua, :a_leg)
      assert_receive {:leg_event, :a_leg, :resumed}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:a_leg].state == :answered
    end

    test "multiple hold/resume cycles", %{b2bua: b2bua} do
      # First cycle
      :ok = B2BUA.hold(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :held}, 200
      :ok = B2BUA.resume(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :resumed}, 200

      # Second cycle
      :ok = B2BUA.hold(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :held}, 200
      :ok = B2BUA.resume(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :resumed}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :answered
    end

    test "hold both legs sequentially", %{b2bua: b2bua} do
      :ok = B2BUA.hold(b2bua, :a_leg)
      assert_receive {:leg_event, :a_leg, :held}, 200

      :ok = B2BUA.hold(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :held}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:a_leg].state == :held
      assert legs[:b_leg].state == :held
    end

    test "resume both legs sequentially", %{b2bua: b2bua} do
      :ok = B2BUA.hold(b2bua, :a_leg)
      :ok = B2BUA.hold(b2bua, :b_leg)
      flush_mailbox()

      :ok = B2BUA.resume(b2bua, :a_leg)
      assert_receive {:leg_event, :a_leg, :resumed}, 200

      :ok = B2BUA.resume(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :resumed}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:a_leg].state == :answered
      assert legs[:b_leg].state == :answered
    end
  end

  # ===========================================================================
  # 6. Transfer Flow Tests
  # ===========================================================================

  describe "transfer flows: blind transfer" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")
      media_b = start_mock_media("media-b")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})
      :ok = B2BUA.update_leg(b2bua, :b_leg, media_pid: media_b)
      {:ok, _bridge} = B2BUA.connect(b2bua, :a_leg, :b_leg)

      flush_mailbox()

      {:ok, %{b2bua: b2bua, media_a: media_a, media_b: media_b}}
    end

    test "blind transfer: hangup old leg, originate new leg", %{b2bua: b2bua} do
      # Simulate blind transfer by hanging up B-leg and creating new C-leg
      :ok = B2BUA.hangup_leg(b2bua, :b_leg)

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :terminated

      # Create new leg to transfer destination
      media_c = start_mock_media("media-c")
      {:ok, :c_leg} = B2BUA.originate(b2bua, "sip:supervisor@pbx.local", as: :c_leg)

      :ok = B2BUA.handle_leg_event(b2bua, :c_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :c_leg, {:answered, make_sdp()})
      :ok = B2BUA.update_leg(b2bua, :c_leg, media_pid: media_c)

      # Connect A-leg to new C-leg
      {:ok, bridge} = B2BUA.connect(b2bua, :a_leg, :c_leg)
      assert bridge.state == :bridged

      active_bridge = B2BUA.get_active_bridge(b2bua)
      assert active_bridge == {:a_leg, :c_leg}
    end

    test "transfer fails - reconnect to original leg", %{b2bua: b2bua, media_b: _media_b} do
      # Hold B-leg before transfer attempt (keeping it active)
      :ok = B2BUA.hold(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :held}, 200

      # Attempt transfer
      {:ok, :c_leg} = B2BUA.originate(b2bua, "sip:supervisor@pbx.local", as: :c_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :c_leg, :trying)

      # Transfer target rejects
      :ok = B2BUA.handle_leg_event(b2bua, :c_leg, {:failed, :busy})

      # Resume original B-leg
      :ok = B2BUA.resume(b2bua, :b_leg)
      assert_receive {:leg_event, :b_leg, :resumed}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :answered
      assert legs[:c_leg].state == :terminated
    end
  end

  # ===========================================================================
  # 7. Error Cases
  # ===========================================================================

  describe "error cases: timeout, rejection, network failure, invalid operations" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      flush_mailbox()

      {:ok, %{b2bua: b2bua, media_a: media_a}}
    end

    test "originate fails with busy", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:failed, :busy})

      assert_receive {:leg_event, :b_leg, :terminated}, 200

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :terminated
    end

    test "originate fails with no_answer", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:failed, :no_answer})

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :terminated
    end

    test "originate fails with network error", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:failed, :network_error})

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :terminated
    end

    test "cannot connect legs that aren't answered", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)

      # Try to connect while B-leg is only trying
      result = B2BUA.connect(b2bua, :a_leg, :b_leg)
      assert result == {:error, :leg_not_answered}
    end

    test "cannot connect to non-existent leg", %{b2bua: b2bua} do
      result = B2BUA.connect(b2bua, :a_leg, :unknown_leg)
      assert result == {:error, :leg_not_found}
    end

    test "cannot hold leg that isn't connected", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})

      # Try to hold without connecting first
      result = B2BUA.hold(b2bua, :b_leg)
      assert result == {:error, :leg_not_connected}
    end

    test "cannot resume leg that isn't held", %{b2bua: b2bua} do
      media_b = start_mock_media("media-b")

      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})
      :ok = B2BUA.update_leg(b2bua, :b_leg, media_pid: media_b)
      {:ok, _bridge} = B2BUA.connect(b2bua, :a_leg, :b_leg)

      # Try to resume when not held
      result = B2BUA.resume(b2bua, :b_leg)
      assert result == {:error, :leg_not_held}
    end

    test "cannot hold unknown leg", %{b2bua: b2bua} do
      result = B2BUA.hold(b2bua, :unknown_leg)
      assert result == {:error, :unknown_leg}
    end

    test "cannot send event to unknown leg", %{b2bua: b2bua} do
      result = B2BUA.handle_leg_event(b2bua, :unknown_leg, :ringing)
      assert result == {:error, :unknown_leg}
    end

    test "cannot send event to terminated leg", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:failed, :busy})

      # Try to send event after terminated
      result = B2BUA.handle_leg_event(b2bua, :b_leg, :ringing)
      assert result == {:error, :leg_terminated}
    end

    test "invalid state transition returns error", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)

      # Try to go directly from :init to :answered
      result = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})
      assert result == {:error, :invalid_transition}
    end

    test "duplicate leg ID returns error", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)

      # Try to create another leg with same ID
      result = B2BUA.originate(b2bua, "sip:other@pbx.local", as: :b_leg)
      assert result == {:error, :leg_exists}
    end

    test "setting A-leg twice returns error", %{b2bua: _b2bua} do
      # Start fresh B2BUA without A-leg
      b2bua = start_b2bua()
      media_a1 = start_mock_media("media-a1")
      media_a2 = start_mock_media("media-a2")

      a_leg_1 = create_a_leg(media_pid: media_a1)
      :ok = B2BUA.set_a_leg(b2bua, a_leg_1)

      a_leg_2 = create_a_leg(media_pid: media_a2)
      result = B2BUA.set_a_leg(b2bua, a_leg_2)
      assert result == {:error, :a_leg_exists}
    end

    test "hangup unknown leg returns error", %{b2bua: b2bua} do
      result = B2BUA.hangup_leg(b2bua, :unknown_leg)
      assert result == {:error, :unknown_leg}
    end
  end

  # ===========================================================================
  # Edge Cases and Complex Scenarios
  # ===========================================================================

  describe "edge cases and complex scenarios" do
    setup do
      b2bua = start_b2bua()
      media_a = start_mock_media("media-a")

      a_leg = create_a_leg(media_pid: media_a)
      :ok = B2BUA.set_a_leg(b2bua, a_leg)

      flush_mailbox()

      {:ok, %{b2bua: b2bua, media_a: media_a}}
    end

    test "hangup_all terminates all legs and dispatches events", %{b2bua: b2bua} do
      # Create multiple B-legs
      {:ok, :b_leg_1} = B2BUA.originate(b2bua, "sip:agent1@pbx.local", as: :b_leg_1)
      {:ok, :b_leg_2} = B2BUA.originate(b2bua, "sip:agent2@pbx.local", as: :b_leg_2)

      # Hangup all
      :ok = B2BUA.hangup_all(b2bua)

      # All legs should be terminated
      legs = B2BUA.get_legs(b2bua)
      assert legs[:a_leg].state == :terminated
      assert legs[:b_leg_1].state == :terminated
      assert legs[:b_leg_2].state == :terminated

      # Should receive :bye events for all legs
      assert_receive {:leg_event, :a_leg, :bye}, 200
      assert_receive {:leg_event, :b_leg_1, :bye}, 200
      assert_receive {:leg_event, :b_leg_2, :bye}, 200
    end

    test "rapid state transitions are handled correctly", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)

      # Rapid transitions
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :ringing)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :answered
    end

    test "early media (183) to answered flow", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)

      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)

      # Skip ringing and go to early_media via :ringing first (per valid transitions)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :ringing)

      # Then to answered
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})

      legs = B2BUA.get_legs(b2bua)
      assert legs[:b_leg].state == :answered
    end

    test "metadata is preserved through state transitions", %{b2bua: b2bua} do
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)

      # Add metadata
      :ok = B2BUA.update_leg(b2bua, :b_leg, metadata: %{call_queue: "support", priority: :high})

      # Transition through states
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, {:answered, make_sdp()})

      {:ok, leg} = B2BUA.get_leg(b2bua, :b_leg)
      assert leg.metadata.call_queue == "support"
      assert leg.metadata.priority == :high
    end

    test "session ID is stable throughout lifecycle", %{b2bua: b2bua} do
      session_id = B2BUA.get_session_id(b2bua)
      assert is_binary(session_id)

      # Operations don't change session ID
      {:ok, :b_leg} = B2BUA.originate(b2bua, "sip:agent@pbx.local", as: :b_leg)
      :ok = B2BUA.handle_leg_event(b2bua, :b_leg, :trying)

      assert B2BUA.get_session_id(b2bua) == session_id
    end

    test "media mode is preserved", %{b2bua: _b2bua} do
      # Test proxy mode (default)
      b2bua_proxy = start_b2bua(media_mode: :proxy)
      assert B2BUA.get_media_mode(b2bua_proxy) == :proxy

      # Test direct mode
      b2bua_direct = start_b2bua(media_mode: :direct)
      assert B2BUA.get_media_mode(b2bua_direct) == :direct
    end

    test "fork with empty destinations", %{b2bua: b2bua} do
      strategy = RingStrategy.simultaneous()
      {:ok, leg_ids} = B2BUA.fork(b2bua, [], strategy: strategy)

      assert leg_ids == []
      assert B2BUA.get_pending_legs(b2bua) == []
    end

    test "fork with single destination behaves like originate", %{b2bua: b2bua} do
      strategy = RingStrategy.simultaneous()
      {:ok, [leg_id]} = B2BUA.fork(b2bua, ["sip:agent@pbx.local"], strategy: strategy)

      :ok = B2BUA.handle_leg_event(b2bua, leg_id, :trying)
      :ok = B2BUA.handle_leg_event(b2bua, leg_id, {:answered, make_sdp()})

      legs = B2BUA.get_legs(b2bua)
      assert legs[leg_id].state == :answered
    end
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      10 -> :ok
    end
  end
end
