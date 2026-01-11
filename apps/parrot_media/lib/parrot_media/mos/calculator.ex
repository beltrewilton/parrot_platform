defmodule ParrotMedia.MOS.Calculator do
  @moduledoc """
  GenServer that orchestrates MOS (Mean Opinion Score) calculation for a media session.

  The Calculator is the central component of the MOS monitoring system, responsible for:
  - Receiving metrics from the Observer
  - Managing calculation intervals
  - Using the E-Model to compute scores
  - Detecting threshold crossings with hysteresis
  - Notifying registered handlers of quality events

  ## Lifecycle

  1. Started with `start_link/1` for a specific session
  2. Transitions from `:awaiting_media` to `:active` on first metrics
  3. Runs interval timer to calculate MOS scores periodically
  4. Terminates gracefully with `stop/1`, generating a call summary

  ## State Machine

  - `:awaiting_media` - Initial state, waiting for first metrics
  - `:active` - Actively collecting metrics and calculating scores
  - `:terminated` - Final state after shutdown

  ## Usage

      {:ok, pid} = Calculator.start_link(
        session_id: "call-123",
        codec: :g711,
        config: Config.new(interval_ms: 5000)
      )

      Calculator.register_handler(pid, self())

      # Metrics arrive from Observer
      Calculator.add_metrics(pid, %{packets_received: 50, packets_expected: 50, jitter_ms: 10.0, delay_ms: 50.0})

      # Query current score
      score = Calculator.current_score(pid)

      # Stop and get summary
      summary = Calculator.stop(pid)
  """

  use GenServer

  alias ParrotMedia.MOS.Config
  alias ParrotMedia.MOS.EModel
  alias ParrotMedia.MOS.Interval
  alias ParrotMedia.MOS.Score
  alias ParrotMedia.MOS.Threshold

  @type state :: %{
          session_id: String.t(),
          call_id: String.t() | nil,
          direction: :inbound | :outbound | nil,
          codec: atom(),
          config: Config.t(),
          status: :awaiting_media | :active | :terminated,
          start_time: DateTime.t(),
          media_started_at: DateTime.t() | nil,
          current_interval: Interval.t() | nil,
          scores: [Score.t()],
          last_mos: float() | nil,
          quality_events: [map()],
          handlers: [pid()],
          interval_timer: reference() | nil
        }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a Calculator GenServer for a media session.

  ## Options

  - `:session_id` - Required. Unique identifier for the media session.
  - `:codec` - Codec type for E-Model calculation (default: :g711)
  - `:call_id` - Optional call identifier
  - `:direction` - Optional call direction (:inbound or :outbound)
  - `:config` - Optional Config struct to override defaults

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, :missing_session_id}` if session_id is not provided

  ## Examples

      {:ok, pid} = Calculator.start_link(session_id: "session-123", codec: :opus)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, atom()}
  def start_link(opts) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, session_id} when is_binary(session_id) ->
        GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))

      {:ok, nil} ->
        {:error, :missing_session_id}

      :error ->
        {:error, :missing_session_id}
    end
  end

  @doc """
  Stops the Calculator gracefully and returns the call summary.

  ## Returns

  A map containing call quality summary:
  - `:session_id` - Session identifier
  - `:status` - :complete or :insufficient_data
  - `:intervals_calculated` - Number of intervals with valid scores
  - `:avg_mos` - Average MOS score (nil if insufficient data)
  - `:min_mos` - Minimum MOS score (nil if insufficient data)
  - `:max_mos` - Maximum MOS score (nil if insufficient data)
  - `:quality_events` - List of threshold crossing events

  ## Examples

      summary = Calculator.stop(pid)
      # %{session_id: "session-123", status: :complete, avg_mos: 4.2, ...}
  """
  @spec stop(pid() | {:via, module(), any()}) :: :ok | map()
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc """
  Adds metrics from the Observer to the current calculation interval.

  This is an asynchronous operation (cast) to avoid blocking the Observer.

  ## Parameters

  - `pid` - Calculator process
  - `metrics` - Map with optional keys:
    - `:packets_received` - Number of packets received
    - `:packets_expected` - Number of packets expected
    - `:jitter_ms` - Interarrival jitter in milliseconds
    - `:delay_ms` - One-way delay estimate in milliseconds

  ## Examples

      :ok = Calculator.add_metrics(pid, %{packets_received: 50, packets_expected: 50, jitter_ms: 10.0})
  """
  @spec add_metrics(pid(), map()) :: :ok
  def add_metrics(pid, metrics) when is_map(metrics) do
    GenServer.cast(pid, {:add_metrics, metrics})
  end

  @doc """
  Registers a process to receive MOS events.

  Registered handlers receive messages:
  - `{:mos_score, %{session_id: _, score: %Score{}}}` - On each interval completion
  - `{:mos_threshold_crossed, %{session_id: _, threshold: _, direction: _}}` - On threshold crossings
  - `{:mos_summary, %{session_id: _, summary: _}}` - On calculator termination

  ## Examples

      :ok = Calculator.register_handler(pid, self())
  """
  @spec register_handler(pid(), pid()) :: :ok
  def register_handler(pid, handler_pid) when is_pid(handler_pid) do
    GenServer.call(pid, {:register_handler, handler_pid})
  end

  @doc """
  Returns the most recent MOS score, or nil if no scores have been calculated.

  ## Examples

      score = Calculator.current_score(pid)
      # %Score{value: 4.2, ...}
  """
  @spec current_score(pid()) :: Score.t() | nil
  def current_score(pid) do
    GenServer.call(pid, :current_score)
  end

  @doc """
  Returns a summary of the call quality without stopping the calculator.

  ## Examples

      summary = Calculator.call_summary(pid)
      # %{session_id: "session-123", status: :complete, avg_mos: 4.2, ...}
  """
  @spec call_summary(pid()) :: map()
  def call_summary(pid) do
    GenServer.call(pid, :call_summary)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    codec = Keyword.get(opts, :codec) || :g711
    call_id = Keyword.get(opts, :call_id)
    direction = Keyword.get(opts, :direction)
    config = Keyword.get(opts, :config) || Config.new([])

    state = %{
      session_id: session_id,
      call_id: call_id,
      direction: direction,
      codec: codec,
      config: config,
      status: :awaiting_media,
      start_time: DateTime.utc_now(),
      media_started_at: nil,
      current_interval: nil,
      scores: [],
      last_mos: nil,
      quality_events: [],
      handlers: [],
      interval_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:stop, _from, %{status: :awaiting_media} = state) do
    # No metrics received - just return :ok
    if state.interval_timer do
      Process.cancel_timer(state.interval_timer)
    end

    {:stop, :normal, :ok, %{state | status: :terminated}}
  end

  def handle_call(:stop, _from, state) do
    summary = generate_summary(state)

    # Notify handlers of summary
    notify_handlers(state.handlers, {:mos_summary, %{session_id: state.session_id, summary: summary}})

    # Cancel interval timer if running
    if state.interval_timer do
      Process.cancel_timer(state.interval_timer)
    end

    {:stop, :normal, summary, %{state | status: :terminated}}
  end

  def handle_call({:register_handler, handler_pid}, _from, state) do
    handlers = [handler_pid | state.handlers]
    {:reply, :ok, %{state | handlers: handlers}}
  end

  def handle_call(:current_score, _from, state) do
    score = List.first(state.scores)
    {:reply, score, state}
  end

  def handle_call(:call_summary, _from, state) do
    summary = generate_summary(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_cast({:add_metrics, metrics}, %{status: :awaiting_media} = state) do
    # Transition to :active state on first metrics
    interval = Interval.new() |> Interval.add_metrics(metrics)

    # Start the interval timer
    timer_ref = schedule_interval_tick(state.config.interval_ms)

    new_state = %{
      state
      | status: :active,
        media_started_at: DateTime.utc_now(),
        current_interval: interval,
        interval_timer: timer_ref
    }

    {:noreply, new_state}
  end

  def handle_cast({:add_metrics, metrics}, %{status: :active} = state) do
    # Accumulate metrics in current interval
    updated_interval = Interval.add_metrics(state.current_interval, metrics)
    {:noreply, %{state | current_interval: updated_interval}}
  end

  def handle_cast({:add_metrics, _metrics}, state) do
    # Ignore metrics in other states
    {:noreply, state}
  end

  @impl true
  def handle_info(:interval_tick, %{status: :active} = state) do
    # Complete current interval and calculate score
    state = complete_interval(state)

    # Start new interval and schedule next tick
    new_interval = Interval.new()
    timer_ref = schedule_interval_tick(state.config.interval_ms)

    {:noreply, %{state | current_interval: new_interval, interval_timer: timer_ref}}
  end

  def handle_info(:interval_tick, state) do
    # Ignore tick in non-active states
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp via_tuple(session_id) do
    {:via, Registry, {ParrotMedia.MOS.Registry, session_id}}
  end

  defp schedule_interval_tick(interval_ms) do
    Process.send_after(self(), :interval_tick, interval_ms)
  end

  defp complete_interval(state) do
    completed = Interval.complete(state.current_interval)

    # Check if we have sufficient data
    if Interval.sufficient_data?(completed, min_packets: state.config.min_packets_per_interval) do
      # Calculate MOS score
      score = calculate_score(completed, state.codec, state.config)

      # Check for threshold crossings
      {quality_events, new_events} = check_thresholds(state, score.value)

      # Notify handlers
      notify_handlers(state.handlers, {:mos_score, %{session_id: state.session_id, score: score}})

      # Notify of threshold crossings
      Enum.each(new_events, fn event ->
        notify_handlers(state.handlers, {:mos_threshold_crossed, %{
          session_id: state.session_id,
          threshold: event.threshold_name,
          direction: event.direction
        }})
      end)

      %{
        state
        | scores: [score | state.scores],
          last_mos: score.value,
          quality_events: quality_events
      }
    else
      # Insufficient data - don't add a score
      state
    end
  end

  defp calculate_score(interval, codec, config) do
    # Use default delay if none measured
    delay_ms =
      if interval.delay_ms == 0.0 do
        config.default_delay_ms
      else
        interval.delay_ms
      end

    # Calculate R-factor and MOS using E-Model
    r_factor = EModel.calculate_r_factor(
      interval.packet_loss_percent,
      interval.jitter_ms,
      delay_ms,
      codec
    )

    mos_value = EModel.r_to_mos(r_factor)

    {:ok, score} = Score.new(
      value: mos_value,
      timestamp: DateTime.utc_now(),
      packet_loss_percent: interval.packet_loss_percent,
      jitter_ms: interval.jitter_ms,
      delay_ms: delay_ms,
      r_factor: r_factor
    )

    score
  end

  defp check_thresholds(state, current_mos) do
    previous_mos = state.last_mos

    # If no previous MOS, no crossings to detect
    if previous_mos == nil do
      {state.quality_events, []}
    else
      # Check each threshold for crossing
      new_events =
        state.config.thresholds
        |> Enum.map(fn threshold ->
          case Threshold.crossed?(threshold, previous_mos, current_mos) do
            {true, direction} ->
              %{
                timestamp: DateTime.utc_now(),
                event_type: :threshold_crossed,
                mos_score: current_mos,
                threshold_name: threshold.name,
                direction: direction
              }

            false ->
              nil
          end
        end)
        |> Enum.filter(&(&1 != nil))

      {state.quality_events ++ new_events, new_events}
    end
  end

  defp notify_handlers(handlers, message) do
    Enum.each(handlers, fn handler_pid ->
      # Use send/2 which won't crash on dead processes
      try do
        send(handler_pid, message)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  end

  defp generate_summary(state) do
    scores = state.scores

    if length(scores) == 0 do
      %{
        session_id: state.session_id,
        status: :insufficient_data,
        intervals_calculated: 0,
        avg_mos: nil,
        min_mos: nil,
        max_mos: nil,
        quality_events: state.quality_events
      }
    else
      mos_values = Enum.map(scores, & &1.value)
      avg = Enum.sum(mos_values) / length(mos_values)
      min = Enum.min(mos_values)
      max = Enum.max(mos_values)

      %{
        session_id: state.session_id,
        status: :complete,
        intervals_calculated: length(scores),
        avg_mos: avg,
        min_mos: min,
        max_mos: max,
        quality_events: state.quality_events
      }
    end
  end
end
