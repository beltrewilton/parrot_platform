defmodule Parrot.Bridge.RingStrategyTest do
  @moduledoc """
  Tests for Parrot.Bridge.RingStrategy module.

  Tests ring strategies for B2BUA fork operations:
  - :simultaneous - Ring all legs at once, first to answer wins
  - :sequential - Ring one at a time with configurable timeout
  - :delayed - Ring legs with staggered delays

  Following TDD principles - tests written before implementation.
  """
  use ExUnit.Case, async: true

  alias Parrot.Bridge.RingStrategy

  # Helper to create test leg structs
  defp create_leg(id, opts \\ []) do
    %{
      id: id,
      state: Keyword.get(opts, :state, :init),
      destination: Keyword.get(opts, :destination, "sip:#{id}@example.com"),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  # ==========================================================================
  # Strategy Configuration Tests
  # ==========================================================================

  describe "simultaneous/1" do
    test "creates simultaneous strategy with defaults" do
      strategy = RingStrategy.simultaneous()

      assert strategy.type == :simultaneous
      assert strategy.timeout == 30_000
    end

    test "creates simultaneous strategy with custom timeout" do
      strategy = RingStrategy.simultaneous(timeout: 45_000)

      assert strategy.type == :simultaneous
      assert strategy.timeout == 45_000
    end

    test "creates simultaneous strategy with cancel_others option" do
      strategy = RingStrategy.simultaneous(cancel_others: true)

      assert strategy.type == :simultaneous
      assert strategy.cancel_others == true
    end
  end

  describe "sequential/1" do
    test "creates sequential strategy with defaults" do
      strategy = RingStrategy.sequential()

      assert strategy.type == :sequential
      assert strategy.timeout == 30_000
      assert strategy.ring_timeout == 15_000
    end

    test "creates sequential strategy with custom ring_timeout" do
      strategy = RingStrategy.sequential(ring_timeout: 20_000)

      assert strategy.type == :sequential
      assert strategy.ring_timeout == 20_000
    end

    test "creates sequential strategy with custom per-leg and total timeout" do
      strategy = RingStrategy.sequential(ring_timeout: 10_000, timeout: 60_000)

      assert strategy.type == :sequential
      assert strategy.ring_timeout == 10_000
      assert strategy.timeout == 60_000
    end
  end

  describe "delayed/1" do
    test "creates delayed strategy with required delay" do
      strategy = RingStrategy.delayed(delay: 5_000)

      assert strategy.type == :delayed
      assert strategy.delay == 5_000
      assert strategy.timeout == 30_000
    end

    test "creates delayed strategy with custom timeout" do
      strategy = RingStrategy.delayed(delay: 3_000, timeout: 45_000)

      assert strategy.type == :delayed
      assert strategy.delay == 3_000
      assert strategy.timeout == 45_000
    end

    test "validates delay is required" do
      assert_raise ArgumentError, ~r/delay is required/, fn ->
        RingStrategy.delayed([])
      end
    end

    test "validates delay is positive" do
      assert_raise ArgumentError, ~r/delay must be positive/, fn ->
        RingStrategy.delayed(delay: 0)
      end
    end
  end

  # ==========================================================================
  # execute/2 Tests - Determine which legs to ring
  # ==========================================================================

  describe "execute/2 with :simultaneous" do
    test "returns all legs to ring immediately" do
      strategy = RingStrategy.simultaneous()

      legs = [
        create_leg(:leg_1),
        create_leg(:leg_2),
        create_leg(:leg_3)
      ]

      assert {:ok, result} = RingStrategy.execute(strategy, legs)
      assert result.ring_now == [:leg_1, :leg_2, :leg_3]
      assert result.ring_later == []
      assert result.timers == []
    end

    test "returns empty list when no legs provided" do
      strategy = RingStrategy.simultaneous()

      assert {:ok, result} = RingStrategy.execute(strategy, [])
      assert result.ring_now == []
      assert result.ring_later == []
    end

    test "returns single leg when only one provided" do
      strategy = RingStrategy.simultaneous()
      legs = [create_leg(:only_leg)]

      assert {:ok, result} = RingStrategy.execute(strategy, legs)
      assert result.ring_now == [:only_leg]
    end
  end

  describe "execute/2 with :sequential" do
    test "returns only first leg to ring" do
      strategy = RingStrategy.sequential()

      legs = [
        create_leg(:leg_1),
        create_leg(:leg_2),
        create_leg(:leg_3)
      ]

      assert {:ok, result} = RingStrategy.execute(strategy, legs)
      assert result.ring_now == [:leg_1]
      assert result.ring_later == [:leg_2, :leg_3]
    end

    test "returns empty lists when no legs provided" do
      strategy = RingStrategy.sequential()

      assert {:ok, result} = RingStrategy.execute(strategy, [])
      assert result.ring_now == []
      assert result.ring_later == []
    end

    test "returns single leg without ring_later when only one provided" do
      strategy = RingStrategy.sequential()
      legs = [create_leg(:only_leg)]

      assert {:ok, result} = RingStrategy.execute(strategy, legs)
      assert result.ring_now == [:only_leg]
      assert result.ring_later == []
    end
  end

  describe "execute/2 with :delayed" do
    test "returns first leg immediately and schedules others" do
      strategy = RingStrategy.delayed(delay: 5_000)

      legs = [
        create_leg(:leg_1),
        create_leg(:leg_2),
        create_leg(:leg_3)
      ]

      assert {:ok, result} = RingStrategy.execute(strategy, legs)
      assert result.ring_now == [:leg_1]

      # Other legs should have timer instructions
      assert length(result.timers) == 2
      assert {:ring_leg, :leg_2, 5_000} in result.timers
      assert {:ring_leg, :leg_3, 10_000} in result.timers
    end

    test "returns single leg without timers when only one provided" do
      strategy = RingStrategy.delayed(delay: 5_000)
      legs = [create_leg(:only_leg)]

      assert {:ok, result} = RingStrategy.execute(strategy, legs)
      assert result.ring_now == [:only_leg]
      assert result.timers == []
    end

    test "calculates staggered delays correctly" do
      strategy = RingStrategy.delayed(delay: 2_000)

      legs = [
        create_leg(:leg_1),
        create_leg(:leg_2),
        create_leg(:leg_3),
        create_leg(:leg_4)
      ]

      assert {:ok, result} = RingStrategy.execute(strategy, legs)
      assert result.ring_now == [:leg_1]

      timers = result.timers
      assert {:ring_leg, :leg_2, 2_000} in timers
      assert {:ring_leg, :leg_3, 4_000} in timers
      assert {:ring_leg, :leg_4, 6_000} in timers
    end
  end

  # ==========================================================================
  # handle_event/3 Tests - Process leg events during ringing
  # ==========================================================================

  describe "handle_event/3 with :simultaneous strategy" do
    setup do
      state = %{
        strategy: RingStrategy.simultaneous(),
        ringing: [:leg_1, :leg_2, :leg_3],
        pending: [],
        winner: nil,
        failed: []
      }

      %{state: state}
    end

    test "selects winner when leg answers", %{state: state} do
      event = {:answered, :leg_2, %{sdp: "v=0..."}}

      assert {:winner, :leg_2, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.winner == :leg_2
    end

    test "continues when leg starts ringing", %{state: state} do
      event = {:ringing, :leg_1}

      assert {:continue, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.ringing == [:leg_1, :leg_2, :leg_3]
    end

    test "continues when single leg fails but others remain", %{state: state} do
      event = {:failed, :leg_1, :rejected}

      assert {:continue, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.ringing == [:leg_2, :leg_3]
      assert updated_state.failed == [{:leg_1, :rejected}]
    end

    test "returns all_failed when last leg fails", %{state: state} do
      # Simulate all but one leg already failed
      state = %{state | ringing: [:leg_3], failed: [{:leg_1, :rejected}, {:leg_2, :timeout}]}
      event = {:failed, :leg_3, :busy}

      assert {:all_failed, reasons} = RingStrategy.handle_event(state, event)
      assert {:leg_1, :rejected} in reasons
      assert {:leg_2, :timeout} in reasons
      assert {:leg_3, :busy} in reasons
    end

    test "ignores events for unknown legs", %{state: state} do
      event = {:answered, :unknown_leg, %{}}

      assert {:continue, ^state} = RingStrategy.handle_event(state, event)
    end
  end

  describe "handle_event/3 with :sequential strategy" do
    setup do
      state = %{
        strategy: RingStrategy.sequential(ring_timeout: 15_000),
        ringing: [:leg_1],
        pending: [:leg_2, :leg_3],
        winner: nil,
        failed: []
      }

      %{state: state}
    end

    test "selects winner when current leg answers", %{state: state} do
      event = {:answered, :leg_1, %{sdp: "v=0..."}}

      assert {:winner, :leg_1, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.winner == :leg_1
    end

    test "advances to next leg when current leg fails", %{state: state} do
      event = {:failed, :leg_1, :busy}

      assert {:ring_next, :leg_2, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.ringing == [:leg_2]
      assert updated_state.pending == [:leg_3]
      assert updated_state.failed == [{:leg_1, :busy}]
    end

    test "returns all_failed when last leg fails", %{state: state} do
      state = %{state | ringing: [:leg_3], pending: [], failed: [{:leg_1, :busy}, {:leg_2, :timeout}]}
      event = {:failed, :leg_3, :rejected}

      assert {:all_failed, reasons} = RingStrategy.handle_event(state, event)
      assert length(reasons) == 3
    end

    test "handles ring_timeout event by advancing to next leg", %{state: state} do
      event = {:ring_timeout, :leg_1}

      assert {:ring_next, :leg_2, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.failed == [{:leg_1, :ring_timeout}]
    end
  end

  describe "handle_event/3 with :delayed strategy" do
    setup do
      state = %{
        strategy: RingStrategy.delayed(delay: 5_000),
        ringing: [:leg_1],
        pending: [:leg_2, :leg_3],
        winner: nil,
        failed: []
      }

      %{state: state}
    end

    test "selects winner when any ringing leg answers", %{state: state} do
      event = {:answered, :leg_1, %{sdp: "v=0..."}}

      assert {:winner, :leg_1, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.winner == :leg_1
    end

    test "adds leg to ringing when timer fires", %{state: state} do
      event = {:ring_timer, :leg_2}

      assert {:continue, updated_state} = RingStrategy.handle_event(state, event)
      assert :leg_2 in updated_state.ringing
      refute :leg_2 in updated_state.pending
    end

    test "continues when one leg fails but others ringing or pending", %{state: state} do
      # First add leg_2 to ringing
      state = %{state | ringing: [:leg_1, :leg_2], pending: [:leg_3]}
      event = {:failed, :leg_1, :rejected}

      assert {:continue, updated_state} = RingStrategy.handle_event(state, event)
      assert updated_state.ringing == [:leg_2]
      assert updated_state.pending == [:leg_3]
    end

    test "returns all_failed when all legs fail", %{state: state} do
      state = %{state | ringing: [:leg_3], pending: [], failed: [{:leg_1, :busy}, {:leg_2, :timeout}]}
      event = {:failed, :leg_3, :rejected}

      assert {:all_failed, reasons} = RingStrategy.handle_event(state, event)
      assert length(reasons) == 3
    end
  end

  # ==========================================================================
  # init_state/2 Tests - Initialize strategy state
  # ==========================================================================

  describe "init_state/2" do
    test "initializes state for simultaneous strategy" do
      strategy = RingStrategy.simultaneous()
      legs = [create_leg(:leg_1), create_leg(:leg_2)]

      state = RingStrategy.init_state(strategy, legs)

      assert state.strategy == strategy
      assert state.ringing == [:leg_1, :leg_2]
      assert state.pending == []
      assert state.winner == nil
      assert state.failed == []
    end

    test "initializes state for sequential strategy" do
      strategy = RingStrategy.sequential()
      legs = [create_leg(:leg_1), create_leg(:leg_2), create_leg(:leg_3)]

      state = RingStrategy.init_state(strategy, legs)

      assert state.strategy == strategy
      assert state.ringing == [:leg_1]
      assert state.pending == [:leg_2, :leg_3]
    end

    test "initializes state for delayed strategy" do
      strategy = RingStrategy.delayed(delay: 5_000)
      legs = [create_leg(:leg_1), create_leg(:leg_2)]

      state = RingStrategy.init_state(strategy, legs)

      assert state.strategy == strategy
      assert state.ringing == [:leg_1]
      assert state.pending == [:leg_2]
    end
  end

  # ==========================================================================
  # cancel_pending/1 Tests - Get legs to cancel after winner
  # ==========================================================================

  describe "cancel_pending/1" do
    test "returns all non-winning ringing legs for simultaneous" do
      state = %{
        strategy: RingStrategy.simultaneous(),
        ringing: [:leg_1, :leg_2, :leg_3],
        pending: [],
        winner: :leg_2,
        failed: []
      }

      assert [:leg_1, :leg_3] = RingStrategy.cancel_pending(state) |> Enum.sort()
    end

    test "returns pending and other ringing legs for sequential" do
      state = %{
        strategy: RingStrategy.sequential(),
        ringing: [:leg_2],
        pending: [:leg_3, :leg_4],
        winner: :leg_2,
        failed: []
      }

      # Should cancel pending legs (leg_3, leg_4)
      # Winner is leg_2, so it shouldn't be cancelled
      to_cancel = RingStrategy.cancel_pending(state)
      assert :leg_3 in to_cancel
      assert :leg_4 in to_cancel
      refute :leg_2 in to_cancel
    end

    test "returns all pending and other ringing for delayed" do
      state = %{
        strategy: RingStrategy.delayed(delay: 5_000),
        ringing: [:leg_1, :leg_2],
        pending: [:leg_3],
        winner: :leg_1,
        failed: []
      }

      to_cancel = RingStrategy.cancel_pending(state)
      assert :leg_2 in to_cancel
      assert :leg_3 in to_cancel
      refute :leg_1 in to_cancel
    end
  end
end
