defmodule ParrotSip.TimerHelpers do
  @moduledoc """
  Shared timer management utilities for gen_statem processes.

  Provides functions for managing timers in state machine data structures
  that store timers in a map with timer names as keys and timer references as values.

  ## Example Usage

      defmodule MyStatem do
        defstruct [:timers, :other_data]

        def some_state(:enter, _old_state, data) do
          ref = :erlang.start_timer(1000, self(), :timeout)
          data = TimerHelpers.store_timer(data, :my_timer, ref)
          {:keep_state, data}
        end

        def some_state(:info, {:timeout, _ref, :timeout}, data) do
          data = TimerHelpers.cancel_timer(data, :my_timer)
          {:next_state, :next_state, data}
        end

        def cleanup_state(:enter, _old_state, data) do
          data = TimerHelpers.cancel_all_timers(data)
          {:keep_state, data}
        end
      end
  """

  @doc """
  Stores a timer reference in the data structure.

  Expects data to have a `:timers` field that is a map.

  ## Examples

      iex> data = %{timers: %{}}
      iex> ref = :erlang.start_timer(1000, self(), :test)
      iex> data = TimerHelpers.store_timer(data, :my_timer, ref)
      iex> is_reference(data.timers[:my_timer])
      true
  """
  @spec store_timer(map(), atom(), reference()) :: map()
  def store_timer(%{timers: _timers} = data, timer_name, timer_ref) when is_atom(timer_name) do
    put_in(data.timers[timer_name], timer_ref)
  end

  @doc """
  Cancels a timer by name and removes it from the data structure.

  If the timer doesn't exist, returns the data unchanged.
  If the timer exists, cancels it and sets its value to nil in the map.

  ## Examples

      iex> ref = :erlang.start_timer(1000, self(), :test)
      iex> data = %{timers: %{my_timer: ref}}
      iex> data = TimerHelpers.cancel_timer(data, :my_timer)
      iex> is_nil(data.timers[:my_timer])
      true
  """
  @spec cancel_timer(map(), atom()) :: map()
  def cancel_timer(%{timers: timers} = data, timer_name) when is_atom(timer_name) do
    case timers[timer_name] do
      nil ->
        data

      ref when is_reference(ref) ->
        :erlang.cancel_timer(ref)
        put_in(data.timers[timer_name], nil)
    end
  end

  @doc """
  Cancels all timers in the data structure.

  Iterates through all timer entries and cancels each one.

  ## Examples

      iex> ref1 = :erlang.start_timer(1000, self(), :test1)
      iex> ref2 = :erlang.start_timer(2000, self(), :test2)
      iex> data = %{timers: %{timer1: ref1, timer2: ref2}}
      iex> data = TimerHelpers.cancel_all_timers(data)
      iex> data.timers[:timer1]
      nil
      iex> data.timers[:timer2]
      nil
  """
  @spec cancel_all_timers(map()) :: map()
  def cancel_all_timers(%{timers: timers} = data) do
    timers
    |> Map.keys()
    |> Enum.reduce(data, fn key, acc -> cancel_timer(acc, key) end)
  end
end
