defmodule ParrotMedia.MOS do
  @moduledoc """
  Public API for MOS (Mean Opinion Score) quality monitoring.

  MOS provides real-time call quality metrics based on the ITU-T G.107 E-model.
  Scores range from 1.0 (bad quality) to 5.0 (excellent quality).

  ## Quick Start

  MOS scoring starts automatically when a MediaSession starts media, if enabled
  in configuration. You can query scores and register handlers at any time.

  ### Query Current Quality

      {:ok, score} = ParrotMedia.MOS.current_score("call-123")
      IO.puts("MOS: \#{score.value} (\#{score.quality_level})")

  ### Get Call Summary

      {:ok, summary} = ParrotMedia.MOS.call_summary("call-123")
      IO.puts("Average MOS: \#{summary.avg_mos}")

  ## Receiving Quality Events

  ### Option 1: Register Process

      ParrotMedia.MOS.register_handler("call-123", self())

      receive do
        {:mos_score, %{session_id: id, score: score}} ->
          Logger.info("[\#{id}] MOS: \#{score.value}")

        {:mos_threshold_crossed, %{session_id: id, threshold: t, direction: dir}} ->
          Logger.warning("[\#{id}] Crossed \#{t} going \#{dir}")

        {:mos_summary, %{session_id: id, summary: summary}} ->
          Logger.info("[\#{id}] Call ended - Avg: \#{summary.avg_mos}")
      end

  ### Option 2: Handler Behaviour

      defmodule MyHandler do
        @behaviour ParrotMedia.MOS.Handler

        @impl true
        def init(_opts), do: {:ok, %{}}

        @impl true
        def handle_mos_score(session_id, score, state) do
          Logger.info("[\#{session_id}] MOS: \#{score.value}")
          {:ok, state}
        end

        # Other callbacks...
      end

      ParrotMedia.MOS.register_handler("call-123", {MyHandler, %{}})

  ### Option 3: Telemetry

      :telemetry.attach("mos-handler", [:parrot_media, :mos, :score], fn _, m, meta, _ ->
        Logger.info("[\#{meta.session_id}] MOS: \#{m.mos_score}")
      end, nil)

  ## Configuration

      config :parrot_media, :mos,
        enabled: true,
        interval_ms: 5_000,
        min_packets_per_interval: 10,
        default_delay_ms: 50.0,
        thresholds: [
          %{name: :excellent, value: 4.0, hysteresis: 0.1},
          %{name: :good, value: 3.5, hysteresis: 0.1},
          %{name: :fair, value: 3.0, hysteresis: 0.1}
        ]

  ## Quality Levels

  | Level     | MOS Range | Description                     |
  |-----------|-----------|--------------------------------|
  | Excellent | >= 4.0    | Toll quality, no issues         |
  | Good      | 3.5 - 4.0 | Minor impairments, acceptable  |
  | Fair      | 3.0 - 3.5 | Noticeable impairments         |
  | Poor      | < 3.0     | Significant quality problems   |

  ## Related Modules

  - `ParrotMedia.MOS.Score` - Individual score measurement
  - `ParrotMedia.MOS.CallSummary` - Aggregate call statistics
  - `ParrotMedia.MOS.Event` - Threshold crossing events
  - `ParrotMedia.MOS.Handler` - Callback behaviour
  - `ParrotMedia.MOS.Config` - Configuration management
  - `ParrotMedia.MOS.Calculator` - Internal score calculation
  """

  alias ParrotMedia.MOS.Calculator
  alias ParrotMedia.MOS.Config
  alias ParrotMedia.MOS.Handler

  @doc """
  Returns whether MOS monitoring is globally enabled.

  This checks the application configuration. MOS is enabled by default.

  ## Examples

      iex> ParrotMedia.MOS.enabled?()
      true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Config.enabled?()
  end

  @doc """
  Gets the current MOS score for a session.

  Returns the most recently calculated score, or nil if no scores have
  been calculated yet (call is still starting).

  ## Parameters

  - `session_id` - The media session identifier

  ## Returns

  - `{:ok, score}` - The current Score struct
  - `{:ok, nil}` - Calculator exists but no scores yet
  - `{:error, :not_found}` - No calculator for this session

  ## Examples

      iex> ParrotMedia.MOS.current_score("call-123")
      {:ok, %ParrotMedia.MOS.Score{value: 4.2, quality_level: :excellent, ...}}

      iex> ParrotMedia.MOS.current_score("nonexistent")
      {:error, :not_found}
  """
  @spec current_score(String.t()) :: {:ok, ParrotMedia.MOS.Score.t() | nil} | {:error, :not_found}
  def current_score(session_id) when is_binary(session_id) do
    case lookup_calculator(session_id) do
      {:ok, pid} ->
        score = Calculator.current_score(pid)
        {:ok, score}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the call quality summary for a session.

  Returns aggregate statistics including min/max/avg MOS, packet counts,
  and quality events. This can be called during an active call to get
  a snapshot, or after the call ends.

  ## Parameters

  - `session_id` - The media session identifier

  ## Returns

  - `{:ok, summary}` - The CallSummary struct
  - `{:error, :not_found}` - No calculator for this session

  ## Examples

      iex> ParrotMedia.MOS.call_summary("call-123")
      {:ok, %ParrotMedia.MOS.CallSummary{avg_mos: 4.1, min_mos: 3.8, max_mos: 4.4, ...}}
  """
  @spec call_summary(String.t()) ::
          {:ok, ParrotMedia.MOS.CallSummary.t()} | {:error, :not_found}
  def call_summary(session_id) when is_binary(session_id) do
    case lookup_calculator(session_id) do
      {:ok, pid} ->
        summary = Calculator.call_summary(pid)
        {:ok, summary}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Registers a handler to receive MOS events for a session.

  Two types of handlers are supported:

  1. **Process (pid)** - Receives messages directly:
     - `{:mos_score, %{session_id: _, score: _}}`
     - `{:mos_threshold_crossed, %{session_id: _, threshold: _, direction: _}}`
     - `{:mos_summary, %{session_id: _, summary: _}}`

  2. **Handler module** - Receives callbacks via the `ParrotMedia.MOS.Handler`
     behaviour. Pass a tuple of `{module, opts}`.

  ## Parameters

  - `session_id` - The media session identifier
  - `handler` - Either a pid or `{handler_module, opts}` tuple

  ## Returns

  - `:ok` - Handler registered successfully
  - `{:error, :not_found}` - No calculator for this session

  ## Examples

      # Register current process
      ParrotMedia.MOS.register_handler("call-123", self())

      # Register handler module
      ParrotMedia.MOS.register_handler("call-123", {MyHandler, %{notify: true}})
  """
  @spec register_handler(String.t(), pid() | {module(), term()}) :: :ok | {:error, :not_found}
  def register_handler(session_id, handler_pid)
      when is_binary(session_id) and is_pid(handler_pid) do
    case lookup_calculator(session_id) do
      {:ok, pid} ->
        Calculator.register_handler(pid, handler_pid)

      :error ->
        {:error, :not_found}
    end
  end

  def register_handler(session_id, {handler_module, opts})
      when is_binary(session_id) and is_atom(handler_module) do
    case lookup_calculator(session_id) do
      {:ok, calc_pid} ->
        # Start a handler adapter process that wraps the behaviour module
        {:ok, adapter_pid} = start_handler_adapter(session_id, handler_module, opts)
        Calculator.register_handler(calc_pid, adapter_pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the full MOS configuration.

  ## Examples

      iex> ParrotMedia.MOS.config()
      %{enabled: true, interval_ms: 5000, ...}
  """
  @spec config() :: map()
  def config do
    Config.get()
  end

  @doc """
  Returns a specific MOS configuration key.

  ## Parameters

  - `key` - The configuration key (atom)

  ## Returns

  The configuration value, or nil if not found.

  ## Examples

      iex> ParrotMedia.MOS.config(:interval_ms)
      5000

      iex> ParrotMedia.MOS.config(:enabled)
      true
  """
  @spec config(atom()) :: term()
  def config(key) when is_atom(key) do
    Config.get(key)
  end

  @doc """
  Returns configured quality thresholds as Threshold structs.

  ## Examples

      iex> ParrotMedia.MOS.thresholds()
      [%Threshold{name: :excellent, value: 4.0, ...}, ...]
  """
  @spec thresholds() :: [ParrotMedia.MOS.Threshold.t()]
  def thresholds do
    Config.thresholds()
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp lookup_calculator(session_id) do
    case Registry.lookup(ParrotMedia.MOS.Registry, session_id) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :error

      [] ->
        :error
    end
  end

  # Starts a handler adapter that wraps a Handler behaviour module.
  # The adapter receives messages from the Calculator and invokes
  # the appropriate handler callbacks.
  defp start_handler_adapter(session_id, handler_module, opts) do
    Task.start(fn ->
      handler_adapter_loop(session_id, handler_module, opts)
    end)
  end

  defp handler_adapter_loop(session_id, handler_module, opts) do
    # Initialize the handler
    case Handler.invoke_init(handler_module, opts) do
      {:ok, state} ->
        # Send init confirmation (for testing)
        if pid = opts[:test_pid] do
          send(pid, {:handler_init, opts})
        end

        # Run the message loop
        handler_message_loop(session_id, handler_module, state)

      {:error, reason} ->
        require Logger

        Logger.error(
          "Failed to initialize MOS handler #{inspect(handler_module)}: #{inspect(reason)}"
        )
    end
  end

  defp handler_message_loop(session_id, handler_module, state) do
    receive do
      {:mos_score, %{session_id: ^session_id, score: score}} ->
        case Handler.invoke_score(handler_module, session_id, score, state) do
          {:ok, new_state} ->
            handler_message_loop(session_id, handler_module, new_state)

          {:error, _reason} ->
            handler_message_loop(session_id, handler_module, state)
        end

      {:mos_threshold_crossed,
       %{session_id: ^session_id, threshold: threshold, direction: direction, mos: mos}} ->
        # Create an Event struct for the handler
        {:ok, event} =
          ParrotMedia.MOS.Event.threshold_crossed(
            session_id: session_id,
            mos: mos,
            threshold: threshold,
            direction: direction
          )

        case Handler.invoke_threshold_crossed(handler_module, session_id, event, state) do
          {:ok, new_state} ->
            handler_message_loop(session_id, handler_module, new_state)

          {:error, _reason} ->
            handler_message_loop(session_id, handler_module, state)
        end

      {:mos_summary, %{session_id: ^session_id, summary: summary}} ->
        # Final callback, then exit
        Handler.invoke_summary(handler_module, session_id, summary, state)
        :ok

      _other ->
        handler_message_loop(session_id, handler_module, state)
    after
      # Timeout after 5 minutes of inactivity
      300_000 ->
        :ok
    end
  end
end
