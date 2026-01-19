defmodule Parrot.Call.Server do
  @moduledoc """
  GenServer that manages the lifecycle of a single call.

  The Call.Server is responsible for:
  - Initializing the call and invoking `handle_invite/1`
  - Dispatching events to the appropriate handler callbacks
  - Managing call state transitions
  - Executing pipeline actions after each callback

  ## Usage

  The server is typically started by the Parrot routing layer when an INVITE
  is received and routed to a handler module.

      {:ok, pid} = Parrot.Call.Server.start_link(
        handler: MyApp.IvrHandler,
        invite: %{
          from: "sip:alice@example.com",
          to: "sip:100@pbx.local",
          call_id: "abc123@host"
        }
      )

  ## Event Dispatch

  External components (media, SIP layer) dispatch events to the server:

      Parrot.Call.Server.dispatch(pid, {:play_complete, "welcome.wav"})
      Parrot.Call.Server.dispatch(pid, {:dtmf, "1234"})
      Parrot.Call.Server.dispatch(pid, :hangup)

  ## Callback Routing

  Events are routed to the handler's callbacks:

  | Event                                   | Callback                        |
  |-----------------------------------------|---------------------------------|
  | `{:play_complete, filename}`            | `handle_play_complete/2`        |
  | `{:dtmf, digits_or_timeout}`            | `handle_dtmf/2`                 |
  | `{:bridge_complete, result}`            | `handle_bridge_complete/2`      |
  | `{:fork_complete, result}`              | `handle_fork_complete/2`        |
  | `{:record_complete, filename, duration}`| `handle_record_complete/3`      |
  | `:hangup`                               | `handle_hangup/1`               |
  """

  use GenServer
  require Logger

  alias Parrot.Call
  alias Parrot.Bridge.ActionExecutor

  defstruct [:call, :handler, :context]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a Call.Server process.

  ## Options

  * `:handler` - (required) Module implementing `Parrot.InviteHandler`
  * `:invite` - (required) Map with invite data (`:from`, `:to`, `:call_id`, etc.)
  * `:context` - (optional) Map with SIP context (`:uas`, `:sip_msg`, `:media_pid`, `:dialog_id`)
  * `:name` - (optional) Name for process registration

  ## Examples

      {:ok, pid} = Parrot.Call.Server.start_link(
        handler: MyApp.Handler,
        invite: %{from: "sip:a@b.com", to: "sip:c@d.com"}
      )

      # With SIP context for ActionExecutor integration
      {:ok, pid} = Parrot.Call.Server.start_link(
        handler: MyApp.Handler,
        invite: %{from: "sip:a@b.com", to: "sip:c@d.com"},
        context: %{uas: uas, sip_msg: sip_msg, media_pid: nil}
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    handler = Keyword.fetch!(opts, :handler)
    invite = Keyword.fetch!(opts, :invite)
    context = Keyword.get(opts, :context)
    name = Keyword.get(opts, :name)

    gen_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, {handler, invite, context}, gen_opts)
  end

  @doc """
  Dispatches an event to the call server synchronously.

  Returns `:ok` after the event has been processed and state updated.

  ## Events

  * `{:play_complete, filename}` - Audio playback finished
  * `{:dtmf, digits | :timeout}` - DTMF digits collected or timeout
  * `{:bridge_complete, :answered | {:failed, reason}}` - Bridge result
  * `{:fork_complete, {:answered, info} | :no_answer}` - Fork result
  * `{:record_complete, filename, duration_ms}` - Recording finished
  * `:hangup` - Call ended

  ## Examples

      :ok = Parrot.Call.Server.dispatch(pid, {:play_complete, "welcome.wav"})
  """
  @spec dispatch(GenServer.server(), term()) :: :ok
  def dispatch(server, event) do
    GenServer.call(server, {:dispatch, event})
  end

  @doc """
  Dispatches an event to the call server asynchronously.

  Returns `:ok` immediately without waiting for processing.

  ## Examples

      :ok = Parrot.Call.Server.cast_dispatch(pid, {:dtmf, "1"})
  """
  @spec cast_dispatch(GenServer.server(), term()) :: :ok
  def cast_dispatch(server, event) do
    GenServer.cast(server, {:dispatch, event})
  end

  @doc """
  Gets the current call struct.

  ## Examples

      call = Parrot.Call.Server.get_call(pid)
      call.state
      #=> :answered
  """
  @spec get_call(GenServer.server()) :: Call.t()
  def get_call(server) do
    GenServer.call(server, :get_call)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init({handler, invite, context}) do
    # Extract context fields
    uas = context && Map.get(context, :uas)
    sip_msg = context && Map.get(context, :sip_msg)
    media_pid = context && Map.get(context, :media_pid)
    dialog_id = context && Map.get(context, :dialog_id)

    # Create the initial Call struct from invite data
    call =
      Call.new(
        id: Map.get(invite, :id),
        handler: handler,
        from: Map.get(invite, :from),
        to: Map.get(invite, :to),
        call_id: Map.get(invite, :call_id),
        method: Map.get(invite, :method, "INVITE"),
        assigns: Map.get(invite, :assigns, %{}),
        uas: uas,
        sip_msg: sip_msg,
        media_pid: media_pid,
        dialog_id: dialog_id
      )

    # Invoke handle_invite/1 with the Call struct
    # Handlers use pipeline operations (answer, play, etc.) on the struct
    result = handler.handle_invite(call)

    # Process the result and execute operations
    call = process_callback_result(call, result)
    call = execute_operations_if_context(call, context)

    Logger.debug("Call.Server started: id=#{call.id} handler=#{inspect(handler)}")

    {:ok, %__MODULE__{call: call, handler: handler, context: context}}
  end

  @impl true
  def handle_call({:dispatch, event}, _from, state) do
    state = dispatch_event(event, state)
    {:reply, :ok, state}
  end

  def handle_call(:get_call, _from, state) do
    {:reply, state.call, state}
  end

  @impl true
  def handle_cast({:dispatch, event}, state) do
    state = dispatch_event(event, state)
    {:noreply, state}
  end

  # ===========================================================================
  # Media Event Handling (from MediaSession)
  # ===========================================================================

  # Handle {:media_event, session_id, event} messages from MediaSession.
  # These provide an alternative path for media events to reach Call.Server
  # without going through the explicit dispatch/2 API.

  @impl true
  def handle_info({:media_event, _session_id, {:play_complete, filename}}, state) do
    state = dispatch_event({:play_complete, filename}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _session_id, {:dtmf_collected, digits}}, state) do
    state = dispatch_event({:dtmf, digits}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _session_id, {:dtmf_timeout, _partial}}, state) do
    state = dispatch_event({:dtmf, :timeout}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _session_id, {:record_complete, filename, duration_ms}}, state) do
    state = dispatch_event({:record_complete, filename, duration_ms}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _session_id, {:prompt_complete, filename, digits}}, state) do
    state = dispatch_event({:prompt_complete, filename, digits}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _session_id, {:conference_join, room}}, state) do
    state = dispatch_event({:conference_join, room}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _session_id, {:conference_leave, room, reason}}, state) do
    state = dispatch_event({:conference_leave, room, reason}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:media_event, _session_id, {:fork_media_connected, url}}, state) do
    state = dispatch_event({:fork_media_connected, url}, state)
    {:noreply, state}
  end

  # Handle media started event (FR-010, US4)
  @impl true
  def handle_info({:media_event, _session_id, :media_started}, state) do
    state = dispatch_event(:media_started, state)
    {:noreply, state}
  end

  # Handle media stopped event (FR-011, US4)
  @impl true
  def handle_info({:media_event, _session_id, {:media_stopped, reason}}, state) do
    state = dispatch_event({:media_stopped, reason}, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Call.Server received unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ===========================================================================
  # Event Dispatch
  # ===========================================================================

  defp dispatch_event({:play_complete, filename}, state) do
    invoke_callback(:handle_play_complete, [filename], state)
  end

  defp dispatch_event({:dtmf, digits_or_timeout}, state) do
    invoke_callback(:handle_dtmf, [digits_or_timeout], state)
  end

  defp dispatch_event({:bridge_complete, result}, state) do
    invoke_callback(:handle_bridge_complete, [result], state)
  end

  defp dispatch_event({:fork_complete, result}, state) do
    invoke_callback(:handle_fork_complete, [result], state)
  end

  defp dispatch_event({:record_complete, filename, duration_ms}, state) do
    invoke_callback(:handle_record_complete, [filename, duration_ms], state)
  end

  defp dispatch_event({:prompt_complete, filename, digits}, state) do
    invoke_callback(:handle_prompt_complete, [filename, digits], state)
  end

  defp dispatch_event({:conference_join, room}, state) do
    invoke_callback(:handle_conference_join, [room], state)
  end

  defp dispatch_event({:conference_leave, room, reason}, state) do
    invoke_callback(:handle_conference_leave, [room, reason], state)
  end

  defp dispatch_event({:fork_media_connected, url}, state) do
    invoke_callback(:handle_fork_media_connected, [url], state)
  end

  defp dispatch_event(:hangup, state) do
    state = invoke_callback(:handle_hangup, [], state)

    # Ensure state is terminated after hangup
    call = %{state.call | state: :terminated}
    %{state | call: call}
  end

  # Handle media started event (FR-010, US4)
  defp dispatch_event(:media_started, state) do
    invoke_callback(:handle_media_started, [], state)
  end

  # Handle media stopped event (FR-011, US4)
  defp dispatch_event({:media_stopped, reason}, state) do
    invoke_callback(:handle_media_stopped, [reason], state)
  end

  defp dispatch_event(unknown, state) do
    Logger.warning("Call.Server received unknown event: #{inspect(unknown)}")
    state
  end

  # ===========================================================================
  # Callback Invocation
  # ===========================================================================

  defp invoke_callback(callback, args, state) do
    %{call: call, handler: handler, context: context} = state

    # Invoke the callback with args + Call struct
    # Handlers use pipeline operations on the struct
    result = apply(handler, callback, args ++ [call])

    # Process the result
    call = process_callback_result(call, result)

    # Execute operations via ActionExecutor if context is available
    call = execute_operations_if_context(call, context)

    %{state | call: call}
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  # Execute operations via ActionExecutor if context is available
  # Returns the call with operations cleared after execution
  # When no context, just clear operations (no SIP/media actions can be performed)
  defp execute_operations_if_context(call, nil), do: %{call | __operations__: []}

  defp execute_operations_if_context(%Call{} = call, context) when is_map(context) do
    operations = Call.get_operations(call)

    if operations == [] do
      # No operations to execute, but still clear any leftover operations list
      %{call | __operations__: []}
    else
      # Build executor context from call and provided context
      executor_context = %{
        uas: call.__uas__ || Map.get(context, :uas),
        sip_msg: call.__sip_msg__ || Map.get(context, :sip_msg),
        media_pid: call.__media_pid__ || Map.get(context, :media_pid),
        sdp_answer: Map.get(context, :sdp_answer),
        response_fn: Map.get(context, :response_fn)
      }

      case ActionExecutor.execute(operations, call, executor_context) do
        {:ok, updated_call} ->
          # Preserve context fields and clear operations
          %{
            updated_call
            | __uas__: call.__uas__,
              __sip_msg__: call.__sip_msg__,
              __media_pid__: call.__media_pid__,
              __dialog_id__: call.__dialog_id__,
              __operations__: []
          }

        {:error, reason} ->
          Logger.error("ActionExecutor failed: #{inspect(reason)}")
          # Clear operations even on failure to prevent re-execution
          %{call | __operations__: []}
      end
    end
  end

  # Process the result from a callback
  # Handles Call structs, {:noreply, call}, and legacy map returns
  defp process_callback_result(_call, {:noreply, %Call{} = result_call}) do
    process_operations(result_call)
  end

  defp process_callback_result(_call, %Call{} = result_call) do
    process_operations(result_call)
  end

  defp process_callback_result(%Call{} = call, {:noreply, result_map}) when is_map(result_map) do
    update_call_from_result(call, result_map)
  end

  defp process_callback_result(%Call{} = call, result_map) when is_map(result_map) do
    update_call_from_result(call, result_map)
  end

  # Process pipeline operations from the Call struct
  # Updates state based on operations but does NOT clear them
  # Clearing happens in execute_operations_if_context after ActionExecutor runs
  defp process_operations(%Call{} = call) do
    operations = call.__operations__

    # Apply operations to determine state transitions
    # Return the updated call with new state
    # Note: Operations are NOT cleared here - they're cleared after ActionExecutor runs
    Enum.reduce(operations, call, fn
      {:answer, _opts}, acc -> %{acc | state: :answered}
      {:reject, _code}, acc -> %{acc | state: :terminated}
      {:reject, _code, _opts}, acc -> %{acc | state: :terminated}
      {:hangup, _opts}, acc -> %{acc | state: :terminated}
      _op, acc -> acc
    end)
  end

  # Update the Call struct from the callback result map
  # Extracts assigns, action markers, and determines state transitions
  defp update_call_from_result(%Call{} = call, result_map) do
    # Update assigns from result
    assigns = Map.get(result_map, :assigns, call.assigns)

    # Determine new state based on action markers
    state = determine_state(call.state, result_map)

    # Merge the action markers back onto the call struct
    # These are used by the action executor to know what to do
    call
    |> struct!(assigns: assigns, state: state)
    |> merge_action_markers(result_map)
  end

  # Merge action markers (keys used by InviteHandler) from result into call
  defp merge_action_markers(call, result_map) do
    action_keys = [
      :__answered__,
      :__answer_opts__,
      :__rejected__,
      :__hangup__,
      :__play__,
      :__play_opts__,
      :__record__,
      :__record_opts__,
      :__stop_record__,
      :__collect_dtmf__,
      :__bridge__,
      :__bridge_opts__,
      :__fork__,
      :__fork_opts__
    ]

    Enum.reduce(action_keys, call, fn key, acc ->
      case Map.get(result_map, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # Determine state transitions based on action markers
  defp determine_state(current_state, result_map) do
    cond do
      Map.get(result_map, :__hangup__) == true ->
        :terminated

      Map.get(result_map, :__rejected__) != nil ->
        :terminated

      Map.get(result_map, :__answered__) == true and current_state in [:incoming, :ringing] ->
        :answered

      true ->
        current_state
    end
  end
end
