defmodule Parrot.Bridge.RingStrategy do
  @moduledoc """
  Ring strategies for B2BUA fork operations.

  Manages how multiple destination legs are rung during call bridging.
  Strategies determine when each leg starts ringing and how to handle
  leg events (answered, failed, timeout).

  ## Strategies

  - `:simultaneous` - Ring all legs at once, first to answer wins
  - `:sequential` - Ring one leg at a time with configurable timeout per leg
  - `:delayed` - Ring legs with staggered delays (first immediately, others after N ms)

  ## Usage

      # Create strategy
      strategy = RingStrategy.simultaneous(timeout: 30_000)

      # Get initial execution plan
      {:ok, result} = RingStrategy.execute(strategy, legs)
      # result.ring_now - legs to ring immediately
      # result.ring_later - legs to ring later (sequential/delayed)
      # result.timers - timer instructions for delayed ringing

      # Initialize state for event handling
      state = RingStrategy.init_state(strategy, legs)

      # Process events during ringing phase
      case RingStrategy.handle_event(state, {:answered, :leg_1, %{}}) do
        {:winner, leg_id, state} -> # We have a winner
        {:continue, state} -> # Keep waiting
        {:ring_next, leg_id, state} -> # Ring the next leg (sequential)
        {:all_failed, reasons} -> # All legs failed
      end

  ## RFC 3261 Reference

  Section 13.2.1 - Creating the Initial INVITE:
  Forking proxies may deliver the request to multiple destinations.
  The first 2xx response received terminates the fork.
  """

  @type leg_id :: atom() | binary()

  @type t :: %__MODULE__{
          type: :simultaneous | :sequential | :delayed,
          timeout: pos_integer(),
          ring_timeout: pos_integer() | nil,
          delay: pos_integer() | nil,
          cancel_others: boolean()
        }

  @type execute_result :: %{
          ring_now: [leg_id()],
          ring_later: [leg_id()],
          timers: [{:ring_leg, leg_id(), pos_integer()}]
        }

  @type state :: %{
          strategy: t(),
          ringing: [leg_id()],
          pending: [leg_id()],
          winner: leg_id() | nil,
          failed: [{leg_id(), term()}]
        }

  @type leg_event ::
          {:answered, leg_id(), map()}
          | {:ringing, leg_id()}
          | {:failed, leg_id(), term()}
          | {:ring_timeout, leg_id()}
          | {:ring_timer, leg_id()}

  @type handle_result ::
          {:winner, leg_id(), state()}
          | {:continue, state()}
          | {:ring_next, leg_id(), state()}
          | {:all_failed, [{leg_id(), term()}]}

  defstruct type: :simultaneous,
            timeout: 30_000,
            ring_timeout: nil,
            delay: nil,
            cancel_others: true

  @default_timeout 30_000
  @default_ring_timeout 15_000

  # ===========================================================================
  # Strategy Constructors
  # ===========================================================================

  @doc """
  Creates a simultaneous ring strategy.

  All legs ring at once. First leg to answer wins.
  Other legs are cancelled when winner is selected.

  ## Options

  - `:timeout` - Overall timeout in milliseconds (default: 30_000)
  - `:cancel_others` - Whether to cancel other legs when one answers (default: true)

  ## Examples

      RingStrategy.simultaneous()
      RingStrategy.simultaneous(timeout: 45_000)
      RingStrategy.simultaneous(cancel_others: false)

  """
  @spec simultaneous(keyword()) :: t()
  def simultaneous(opts \\ []) do
    %__MODULE__{
      type: :simultaneous,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      cancel_others: Keyword.get(opts, :cancel_others, true)
    }
  end

  @doc """
  Creates a sequential ring strategy.

  Legs are rung one at a time. If a leg fails or times out,
  the next leg is tried.

  ## Options

  - `:timeout` - Overall timeout in milliseconds (default: 30_000)
  - `:ring_timeout` - Timeout per leg in milliseconds (default: 15_000)

  ## Examples

      RingStrategy.sequential()
      RingStrategy.sequential(ring_timeout: 20_000)
      RingStrategy.sequential(ring_timeout: 10_000, timeout: 60_000)

  """
  @spec sequential(keyword()) :: t()
  def sequential(opts \\ []) do
    %__MODULE__{
      type: :sequential,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      ring_timeout: Keyword.get(opts, :ring_timeout, @default_ring_timeout)
    }
  end

  @doc """
  Creates a delayed ring strategy.

  First leg rings immediately. Additional legs are added with
  staggered delays.

  ## Options

  - `:delay` - Required. Delay between adding legs in milliseconds
  - `:timeout` - Overall timeout in milliseconds (default: 30_000)

  ## Examples

      RingStrategy.delayed(delay: 5_000)
      RingStrategy.delayed(delay: 3_000, timeout: 45_000)

  ## Raises

  - `ArgumentError` if `:delay` is not provided or not positive

  """
  @spec delayed(keyword()) :: t()
  def delayed(opts) do
    delay = Keyword.get(opts, :delay)

    validate_delay!(delay)

    %__MODULE__{
      type: :delayed,
      delay: delay,
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }
  end

  defp validate_delay!(nil), do: raise(ArgumentError, "delay is required for delayed strategy")
  defp validate_delay!(d) when d <= 0, do: raise(ArgumentError, "delay must be positive")
  defp validate_delay!(_d), do: :ok

  # ===========================================================================
  # execute/2 - Determine which legs to ring
  # ===========================================================================

  @doc """
  Execute strategy to determine which legs to ring.

  Returns a result struct with:
  - `ring_now` - List of leg IDs to ring immediately
  - `ring_later` - List of leg IDs to ring later
  - `timers` - List of timer instructions `{:ring_leg, leg_id, delay_ms}`

  ## Examples

      strategy = RingStrategy.simultaneous()
      legs = [%{id: :leg_1}, %{id: :leg_2}]
      {:ok, result} = RingStrategy.execute(strategy, legs)
      # result.ring_now == [:leg_1, :leg_2]

  """
  @spec execute(t(), [map()]) :: {:ok, execute_result()}
  def execute(%__MODULE__{type: :simultaneous}, legs) do
    leg_ids = extract_leg_ids(legs)

    result = %{
      ring_now: leg_ids,
      ring_later: [],
      timers: []
    }

    {:ok, result}
  end

  def execute(%__MODULE__{type: :sequential}, legs) do
    case extract_leg_ids(legs) do
      [] ->
        {:ok, %{ring_now: [], ring_later: [], timers: []}}

      [first | rest] ->
        {:ok, %{ring_now: [first], ring_later: rest, timers: []}}
    end
  end

  def execute(%__MODULE__{type: :delayed, delay: delay}, legs) do
    case extract_leg_ids(legs) do
      [] ->
        {:ok, %{ring_now: [], ring_later: [], timers: []}}

      [first | rest] ->
        timers = build_delayed_timers(rest, delay)
        {:ok, %{ring_now: [first], ring_later: [], timers: timers}}
    end
  end

  defp extract_leg_ids(legs) do
    Enum.map(legs, & &1.id)
  end

  defp build_delayed_timers(leg_ids, delay) do
    leg_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {leg_id, index} ->
      {:ring_leg, leg_id, delay * index}
    end)
  end

  # ===========================================================================
  # init_state/2 - Initialize state for event handling
  # ===========================================================================

  @doc """
  Initialize state for handling leg events.

  Creates a state map based on the strategy and initial leg list.

  ## Examples

      strategy = RingStrategy.simultaneous()
      legs = [%{id: :leg_1}, %{id: :leg_2}]
      state = RingStrategy.init_state(strategy, legs)

  """
  @spec init_state(t(), [map()]) :: state()
  def init_state(%__MODULE__{type: :simultaneous} = strategy, legs) do
    leg_ids = extract_leg_ids(legs)

    %{
      strategy: strategy,
      ringing: leg_ids,
      pending: [],
      winner: nil,
      failed: []
    }
  end

  def init_state(%__MODULE__{type: :sequential} = strategy, legs) do
    case extract_leg_ids(legs) do
      [] ->
        %{strategy: strategy, ringing: [], pending: [], winner: nil, failed: []}

      [first | rest] ->
        %{strategy: strategy, ringing: [first], pending: rest, winner: nil, failed: []}
    end
  end

  def init_state(%__MODULE__{type: :delayed} = strategy, legs) do
    case extract_leg_ids(legs) do
      [] ->
        %{strategy: strategy, ringing: [], pending: [], winner: nil, failed: []}

      [first | rest] ->
        %{strategy: strategy, ringing: [first], pending: rest, winner: nil, failed: []}
    end
  end

  # ===========================================================================
  # handle_event/2 - Process leg events during ringing
  # ===========================================================================

  @doc """
  Handle a leg event during the ringing phase.

  Returns one of:
  - `{:winner, leg_id, state}` - A leg answered and is the winner
  - `{:continue, state}` - Continue waiting for events
  - `{:ring_next, leg_id, state}` - Ring the next leg (sequential strategy)
  - `{:all_failed, reasons}` - All legs have failed

  ## Events

  - `{:answered, leg_id, response}` - Leg answered the call
  - `{:ringing, leg_id}` - Leg started ringing
  - `{:failed, leg_id, reason}` - Leg failed
  - `{:ring_timeout, leg_id}` - Per-leg ring timeout (sequential)
  - `{:ring_timer, leg_id}` - Timer fired to add leg (delayed)

  """
  @spec handle_event(state(), leg_event()) :: handle_result()
  def handle_event(state, event)

  # Answered events - winner selection
  def handle_event(%{ringing: ringing} = state, {:answered, leg_id, _response}) do
    if leg_id in ringing do
      updated_state = %{state | winner: leg_id}
      {:winner, leg_id, updated_state}
    else
      {:continue, state}
    end
  end

  # Ringing events - just continue
  def handle_event(state, {:ringing, _leg_id}) do
    {:continue, state}
  end

  # Failed events - strategy-specific handling
  def handle_event(%{strategy: %{type: :simultaneous}} = state, {:failed, leg_id, reason}) do
    handle_simultaneous_failure(state, leg_id, reason)
  end

  def handle_event(%{strategy: %{type: :sequential}} = state, {:failed, leg_id, reason}) do
    handle_sequential_failure(state, leg_id, reason)
  end

  def handle_event(%{strategy: %{type: :delayed}} = state, {:failed, leg_id, reason}) do
    handle_delayed_failure(state, leg_id, reason)
  end

  # Ring timeout - sequential specific
  def handle_event(%{strategy: %{type: :sequential}} = state, {:ring_timeout, leg_id}) do
    handle_sequential_failure(state, leg_id, :ring_timeout)
  end

  # Ring timer - delayed specific, adds leg to ringing
  def handle_event(%{strategy: %{type: :delayed}} = state, {:ring_timer, leg_id}) do
    %{ringing: ringing, pending: pending} = state

    updated_state = %{
      state
      | ringing: ringing ++ [leg_id],
        pending: List.delete(pending, leg_id)
    }

    {:continue, updated_state}
  end

  # ===========================================================================
  # Strategy-specific failure handlers
  # ===========================================================================

  defp handle_simultaneous_failure(state, leg_id, reason) do
    %{ringing: ringing, failed: failed} = state

    if leg_id in ringing do
      updated_ringing = List.delete(ringing, leg_id)
      updated_failed = failed ++ [{leg_id, reason}]

      if updated_ringing == [] do
        {:all_failed, updated_failed}
      else
        {:continue, %{state | ringing: updated_ringing, failed: updated_failed}}
      end
    else
      {:continue, state}
    end
  end

  defp handle_sequential_failure(state, leg_id, reason) do
    %{ringing: ringing, pending: pending, failed: failed} = state

    if leg_id in ringing do
      # Note: We don't use updated_ringing because sequential always moves to the next leg
      _updated_ringing = List.delete(ringing, leg_id)
      updated_failed = failed ++ [{leg_id, reason}]

      case pending do
        [] ->
          # No more legs to try
          {:all_failed, updated_failed}

        [next_leg | rest_pending] ->
          updated_state = %{
            state
            | ringing: [next_leg],
              pending: rest_pending,
              failed: updated_failed
          }

          {:ring_next, next_leg, updated_state}
      end
    else
      {:continue, state}
    end
  end

  defp handle_delayed_failure(state, leg_id, reason) do
    %{ringing: ringing, pending: pending, failed: failed} = state

    if leg_id in ringing do
      updated_ringing = List.delete(ringing, leg_id)
      updated_failed = failed ++ [{leg_id, reason}]

      if updated_ringing == [] and pending == [] do
        {:all_failed, updated_failed}
      else
        {:continue, %{state | ringing: updated_ringing, failed: updated_failed}}
      end
    else
      {:continue, state}
    end
  end

  # ===========================================================================
  # cancel_pending/1 - Get legs to cancel after winner selected
  # ===========================================================================

  @doc """
  Returns list of legs to cancel after a winner is selected.

  Excludes the winning leg from the cancel list.

  ## Examples

      state = %{ringing: [:leg_1, :leg_2, :leg_3], pending: [], winner: :leg_2, ...}
      RingStrategy.cancel_pending(state)
      # => [:leg_1, :leg_3]

  """
  @spec cancel_pending(state()) :: [leg_id()]
  def cancel_pending(%{ringing: ringing, pending: pending, winner: winner}) do
    all_legs = ringing ++ pending

    Enum.reject(all_legs, &(&1 == winner))
  end
end
