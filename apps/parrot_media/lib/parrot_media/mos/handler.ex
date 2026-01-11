defmodule ParrotMedia.MOS.Handler do
  @moduledoc """
  Behaviour for receiving MOS (Mean Opinion Score) quality events.

  Implement this behaviour to receive callbacks when MOS scores are calculated,
  quality thresholds are crossed, or calls end with a summary.

  ## Callbacks

  All callbacks except `init/1` are optional and have default implementations
  that simply return `{:ok, state}` unchanged.

  - `init/1` - Initialize handler state from options
  - `handle_mos_score/3` - Called when a new MOS score is calculated
  - `handle_threshold_crossed/3` - Called when quality crosses a threshold
  - `handle_call_summary/3` - Called when a call ends with quality summary

  ## Example

      defmodule MyQualityHandler do
        @behaviour ParrotMedia.MOS.Handler

        @impl true
        def init(_opts), do: {:ok, %{}}

        @impl true
        def handle_mos_score(session_id, score, state) do
          Logger.info("[" <> session_id <> "] MOS: " <> to_string(score.value))
          {:ok, state}
        end

        @impl true
        def handle_threshold_crossed(session_id, event, state) do
          Logger.warning("[" <> session_id <> "] Threshold crossed: " <> inspect(event))
          {:ok, state}
        end

        @impl true
        def handle_call_summary(session_id, summary, state) do
          Logger.info("[" <> session_id <> "] Call ended - Avg MOS: " <> to_string(summary.avg_mos))
          {:ok, state}
        end
      end

  ## Error Isolation

  When using the `invoke_*` helper functions, handler errors are caught and
  isolated to prevent one failing handler from affecting others. Errors are
  returned as `{:error, {:handler_error, reason}}` tuples.

  ## Registration

  Register handlers with a MOS Calculator using:

      ParrotMedia.MOS.register_handler(session_id, {MyQualityHandler, opts})

  Or register the current process to receive messages:

      ParrotMedia.MOS.register_handler(session_id, self())
  """

  alias ParrotMedia.MOS.CallSummary
  alias ParrotMedia.MOS.Event
  alias ParrotMedia.MOS.Score

  @type state :: term()

  @doc """
  Initialize handler state.

  Called when the handler is registered. Returns `{:ok, state}` where
  state will be passed to subsequent callbacks.

  ## Parameters

  - `opts` - Options passed during handler registration

  ## Returns

  - `{:ok, state}` - Initial handler state
  """
  @callback init(opts :: term()) :: {:ok, state()}

  @doc """
  Handle a new MOS score calculation.

  Called each time a MOS score is calculated for an interval.

  ## Parameters

  - `session_id` - The media session identifier
  - `score` - The calculated `ParrotMedia.MOS.Score` struct
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Updated handler state
  """
  @callback handle_mos_score(session_id :: String.t(), score :: Score.t(), state()) ::
              {:ok, state()}

  @doc """
  Handle a threshold crossing event.

  Called when the MOS score crosses a configured quality threshold.

  ## Parameters

  - `session_id` - The media session identifier
  - `event` - The `ParrotMedia.MOS.Event` struct with crossing details
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Updated handler state
  """
  @callback handle_threshold_crossed(session_id :: String.t(), event :: Event.t(), state()) ::
              {:ok, state()}

  @doc """
  Handle a call summary.

  Called when a media session ends with a quality summary.

  ## Parameters

  - `session_id` - The media session identifier
  - `summary` - The `ParrotMedia.MOS.CallSummary` struct
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Updated handler state
  """
  @callback handle_call_summary(session_id :: String.t(), summary :: CallSummary.t(), state()) ::
              {:ok, state()}

  # Optional callbacks - handlers can choose which to implement
  @optional_callbacks handle_mos_score: 3, handle_threshold_crossed: 3, handle_call_summary: 3

  # ===========================================================================
  # Default Implementations
  # ===========================================================================

  @doc """
  Default implementation for handle_mos_score/3.

  Simply returns the state unchanged.
  """
  @spec handle_mos_score(String.t(), Score.t(), state()) :: {:ok, state()}
  def handle_mos_score(_session_id, _score, state), do: {:ok, state}

  @doc """
  Default implementation for handle_threshold_crossed/3.

  Simply returns the state unchanged.
  """
  @spec handle_threshold_crossed(String.t(), Event.t(), state()) :: {:ok, state()}
  def handle_threshold_crossed(_session_id, _event, state), do: {:ok, state}

  @doc """
  Default implementation for handle_call_summary/3.

  Simply returns the state unchanged.
  """
  @spec handle_call_summary(String.t(), CallSummary.t(), state()) :: {:ok, state()}
  def handle_call_summary(_session_id, _summary, state), do: {:ok, state}

  # ===========================================================================
  # Safe Invocation Functions
  # ===========================================================================

  @doc """
  Safely invoke a handler's init callback.

  Catches any errors and returns an error tuple instead of crashing.

  ## Parameters

  - `handler` - The handler module implementing the behaviour
  - `opts` - Options to pass to init

  ## Returns

  - `{:ok, state}` - Successful initialization with initial state
  - `{:error, {:handler_error, reason}}` - Handler raised an error
  """
  @spec invoke_init(module(), term()) :: {:ok, state()} | {:error, {:handler_error, term()}}
  def invoke_init(handler, opts) do
    handler.init(opts)
  rescue
    error -> {:error, {:handler_error, error}}
  catch
    kind, reason -> {:error, {:handler_error, {kind, reason}}}
  end

  @doc """
  Safely invoke a handler's handle_mos_score callback.

  Catches any errors and returns an error tuple instead of crashing.

  ## Parameters

  - `handler` - The handler module implementing the behaviour
  - `session_id` - Media session identifier
  - `score` - The MOS score
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Successful invocation with updated state
  - `{:error, {:handler_error, reason}}` - Handler raised an error
  """
  @spec invoke_score(module(), String.t(), Score.t(), state()) ::
          {:ok, state()} | {:error, {:handler_error, term()}}
  def invoke_score(handler, session_id, score, state) do
    handler.handle_mos_score(session_id, score, state)
  rescue
    error -> {:error, {:handler_error, error}}
  catch
    kind, reason -> {:error, {:handler_error, {kind, reason}}}
  end

  @doc """
  Safely invoke a handler's handle_threshold_crossed callback.

  Catches any errors and returns an error tuple instead of crashing.

  ## Parameters

  - `handler` - The handler module implementing the behaviour
  - `session_id` - Media session identifier
  - `event` - The threshold crossing event
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Successful invocation with updated state
  - `{:error, {:handler_error, reason}}` - Handler raised an error
  """
  @spec invoke_threshold_crossed(module(), String.t(), Event.t(), state()) ::
          {:ok, state()} | {:error, {:handler_error, term()}}
  def invoke_threshold_crossed(handler, session_id, event, state) do
    handler.handle_threshold_crossed(session_id, event, state)
  rescue
    error -> {:error, {:handler_error, error}}
  catch
    kind, reason -> {:error, {:handler_error, {kind, reason}}}
  end

  @doc """
  Safely invoke a handler's handle_call_summary callback.

  Catches any errors and returns an error tuple instead of crashing.

  ## Parameters

  - `handler` - The handler module implementing the behaviour
  - `session_id` - Media session identifier
  - `summary` - The call summary
  - `state` - Current handler state

  ## Returns

  - `{:ok, new_state}` - Successful invocation with updated state
  - `{:error, {:handler_error, reason}}` - Handler raised an error
  """
  @spec invoke_summary(module(), String.t(), CallSummary.t(), state()) ::
          {:ok, state()} | {:error, {:handler_error, term()}}
  def invoke_summary(handler, session_id, summary, state) do
    handler.handle_call_summary(session_id, summary, state)
  rescue
    error -> {:error, {:handler_error, error}}
  catch
    kind, reason -> {:error, {:handler_error, {kind, reason}}}
  end
end
