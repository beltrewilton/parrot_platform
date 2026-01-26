defmodule Parrot.Bridge.B2BUA do
  @moduledoc """
  B2BUA (Back-to-Back User Agent) GenServer for managing call bridging sessions.

  The B2BUA manages the lifecycle of bridged calls, coordinating:
  - A-leg (inbound) and B-leg(s) (outbound) management
  - Ring strategies for forking scenarios
  - Media bridging between answered legs
  - Event dispatch to user handlers

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────┐
  │                      User Handler                            │
  │  handle_leg_event/3 - receives all leg state changes         │
  └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
  ┌─────────────────────────────────────────────────────────────┐
  │                  B2BUA GenServer                             │
  │  Manages session, legs, media bridging, event dispatch       │
  └─────────────────────────────────────────────────────────────┘
            │                               │
            ▼                               ▼
  ┌───────────────────┐           ┌───────────────────┐
  │       Leg         │           │    MediaBridge    │
  │  A-leg, B-leg...  │           │  RTP forwarding   │
  └───────────────────┘           └───────────────────┘
  ```

  ## Media Modes

  - `:proxy` - RTP flows through Parrot (default, enables recording/manipulation)
  - `:direct` - RTP flows directly between endpoints (lower latency)

  ## RFC References

  - RFC 3261 Section 16 - B2BUA patterns
  - RFC 5765 - B2BUA requirements
  """

  use GenServer

  require Logger

  alias Parrot.Bridge.MediaBridge
  alias Parrot.Bridge.RingStrategy
  alias Parrot.Leg

  @type session_id :: String.t()
  @type leg_id :: Leg.leg_id()
  @type media_mode :: :proxy | :direct

  @type t :: %__MODULE__{
          session_id: session_id(),
          handler: module(),
          handler_state: term(),
          legs: %{leg_id() => Leg.t()},
          media_mode: media_mode(),
          ring_strategy: RingStrategy.t() | nil,
          ring_state: RingStrategy.state() | nil,
          active_bridge: {leg_id(), leg_id()} | nil,
          media_bridge: MediaBridge.t() | nil,
          pending_legs: [leg_id()],
          created_at: DateTime.t()
        }

  defstruct session_id: nil,
            handler: nil,
            handler_state: nil,
            legs: %{},
            media_mode: :proxy,
            ring_strategy: nil,
            ring_state: nil,
            active_bridge: nil,
            media_bridge: nil,
            pending_legs: [],
            created_at: nil

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Starts a B2BUA GenServer process.

  ## Options

  - `:session_id` - Unique session identifier (auto-generated if not provided)
  - `:handler` - Handler module implementing `handle_leg_event/3` callback
  - `:handler_state` - Initial state for handler callbacks
  - `:media_mode` - `:proxy` (default) or `:direct`

  ## Examples

      {:ok, pid} = B2BUA.start_link(
        handler: MyHandler,
        handler_state: %{},
        media_mode: :proxy
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the B2BUA process gracefully.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @doc """
  Returns the session ID of this B2BUA instance.
  """
  @spec get_session_id(pid()) :: session_id()
  def get_session_id(pid) do
    GenServer.call(pid, :get_session_id)
  end

  @doc """
  Returns the media mode configured for this session.
  """
  @spec get_media_mode(pid()) :: media_mode()
  def get_media_mode(pid) do
    GenServer.call(pid, :get_media_mode)
  end

  @doc """
  Returns all legs in the session as a map of leg_id => Leg struct.
  """
  @spec get_legs(pid()) :: %{leg_id() => Leg.t()}
  def get_legs(pid) do
    GenServer.call(pid, :get_legs)
  end

  @doc """
  Returns a specific leg by ID.

  Returns `{:ok, leg}` if found, or `{:error, :not_found}` if not.
  """
  @spec get_leg(pid(), leg_id()) :: {:ok, Leg.t()} | {:error, :not_found}
  def get_leg(pid, leg_id) do
    GenServer.call(pid, {:get_leg, leg_id})
  end

  @doc """
  Returns the currently active bridge as a tuple of {leg_a, leg_b}, or nil if not bridged.
  """
  @spec get_active_bridge(pid()) :: {leg_id(), leg_id()} | nil
  def get_active_bridge(pid) do
    GenServer.call(pid, :get_active_bridge)
  end

  @doc """
  Returns the list of pending legs (legs in forking/ringing phase).
  """
  @spec get_pending_legs(pid()) :: [leg_id()]
  def get_pending_legs(pid) do
    GenServer.call(pid, :get_pending_legs)
  end

  @doc """
  Sets the A-leg (inbound leg) for the session.

  Returns `:ok` if successful, or `{:error, :a_leg_exists}` if already set.
  """
  @spec set_a_leg(pid(), Leg.t()) :: :ok | {:error, :a_leg_exists}
  def set_a_leg(pid, leg) do
    GenServer.call(pid, {:set_a_leg, leg})
  end

  @doc """
  Creates a new outbound leg to the given destination.

  ## Options

  - `:as` - Custom leg ID (auto-generated if not provided)

  Returns `{:ok, leg_id}` on success, or `{:error, :leg_exists}` if leg ID already exists.
  """
  @spec originate(pid(), String.t(), keyword()) :: {:ok, leg_id()} | {:error, :leg_exists}
  def originate(pid, destination, opts \\ []) do
    GenServer.call(pid, {:originate, destination, opts})
  end

  @doc """
  Creates multiple outbound legs for forking scenarios.

  ## Options

  - `:strategy` - RingStrategy struct (default: simultaneous)

  Returns `{:ok, [leg_ids]}` on success.
  """
  @spec fork(pid(), [String.t()], keyword()) :: {:ok, [leg_id()]}
  def fork(pid, destinations, opts \\ []) do
    GenServer.call(pid, {:fork, destinations, opts})
  end

  @doc """
  Handles a leg event (state change).

  Events include `:trying`, `:ringing`, `{:answered, sdp}`, `{:failed, reason}`, `:bye`, etc.

  Returns `:ok` on success, or an error tuple.
  """
  @spec handle_leg_event(pid(), leg_id(), term()) ::
          :ok | {:error, :unknown_leg | :leg_terminated | :invalid_transition}
  def handle_leg_event(pid, leg_id, event) do
    GenServer.call(pid, {:leg_event, leg_id, event})
  end

  @doc """
  Updates leg fields.

  ## Allowed fields

  - `:metadata` - Custom metadata map (merged with existing)
  - `:dialog_id` - SIP dialog ID
  - `:media_pid` - MediaSession PID
  - `:sdp` - SDP data
  """
  @spec update_leg(pid(), leg_id(), keyword()) :: :ok | {:error, :unknown_leg}
  def update_leg(pid, leg_id, updates) do
    GenServer.call(pid, {:update_leg, leg_id, updates})
  end

  @doc """
  Connects two answered legs, establishing media bridging.

  Returns `{:ok, bridge}` on success, or an error tuple.
  """
  @spec connect(pid(), leg_id(), leg_id()) ::
          {:ok, MediaBridge.t()} | {:error, :leg_not_found | :leg_not_answered}
  def connect(pid, leg_a_id, leg_b_id) do
    GenServer.call(pid, {:connect, leg_a_id, leg_b_id})
  end

  @doc """
  Puts a leg on hold.

  The leg must be connected (part of active bridge).
  """
  @spec hold(pid(), leg_id()) :: :ok | {:error, :unknown_leg | :leg_not_connected}
  def hold(pid, leg_id) do
    GenServer.call(pid, {:hold, leg_id})
  end

  @doc """
  Resumes a held leg.

  The leg must currently be in the `:held` state.
  """
  @spec resume(pid(), leg_id()) :: :ok | {:error, :unknown_leg | :leg_not_held}
  def resume(pid, leg_id) do
    GenServer.call(pid, {:resume, leg_id})
  end

  @doc """
  Hangs up a specific leg.
  """
  @spec hangup_leg(pid(), leg_id()) :: :ok | {:error, :unknown_leg}
  def hangup_leg(pid, leg_id) do
    GenServer.call(pid, {:hangup_leg, leg_id})
  end

  @doc """
  Hangs up all legs in the session.
  """
  @spec hangup_all(pid()) :: :ok
  def hangup_all(pid) do
    GenServer.call(pid, :hangup_all)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id) || generate_session_id()
    handler = Keyword.get(opts, :handler)
    handler_state = Keyword.get(opts, :handler_state, %{})
    media_mode = Keyword.get(opts, :media_mode, :proxy)

    state = %__MODULE__{
      session_id: session_id,
      handler: handler,
      handler_state: handler_state,
      media_mode: media_mode,
      legs: %{},
      pending_legs: [],
      created_at: DateTime.utc_now()
    }

    Logger.debug("[B2BUA] Session #{session_id} started with media_mode=#{media_mode}")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  @impl true
  def handle_call(:get_media_mode, _from, state) do
    {:reply, state.media_mode, state}
  end

  @impl true
  def handle_call(:get_legs, _from, state) do
    {:reply, state.legs, state}
  end

  @impl true
  def handle_call({:get_leg, leg_id}, _from, state) do
    case Map.fetch(state.legs, leg_id) do
      {:ok, leg} -> {:reply, {:ok, leg}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_active_bridge, _from, state) do
    {:reply, state.active_bridge, state}
  end

  @impl true
  def handle_call(:get_pending_legs, _from, state) do
    {:reply, state.pending_legs, state}
  end

  @impl true
  def handle_call({:set_a_leg, leg}, _from, state) do
    if Map.has_key?(state.legs, :a_leg) do
      {:reply, {:error, :a_leg_exists}, state}
    else
      # Ensure the leg has the correct ID
      leg = %{leg | id: :a_leg}
      new_legs = Map.put(state.legs, :a_leg, leg)
      new_state = %{state | legs: new_legs}

      # Dispatch the leg's current state as an event
      dispatch_leg_event(new_state, :a_leg, leg.state)

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:originate, destination, opts}, _from, state) do
    leg_id = Keyword.get(opts, :as) || generate_leg_id()

    if Map.has_key?(state.legs, leg_id) do
      {:reply, {:error, :leg_exists}, state}
    else
      leg =
        Leg.new(
          id: leg_id,
          direction: :outbound,
          state: :init,
          remote_uri: destination
        )

      new_legs = Map.put(state.legs, leg_id, leg)
      new_state = %{state | legs: new_legs}

      Logger.debug("[B2BUA] Originated leg #{inspect(leg_id)} to #{destination}")

      {:reply, {:ok, leg_id}, new_state}
    end
  end

  @impl true
  def handle_call({:fork, destinations, opts}, _from, state) do
    strategy = Keyword.get(opts, :strategy, RingStrategy.simultaneous())

    # Create legs for each destination
    {legs, leg_ids} =
      Enum.map_reduce(destinations, [], fn destination, acc ->
        leg_id = generate_leg_id()

        leg =
          Leg.new(
            id: leg_id,
            direction: :outbound,
            state: :init,
            remote_uri: destination
          )

        {leg, [leg_id | acc]}
      end)

    leg_ids = Enum.reverse(leg_ids)

    # Add all legs to state
    new_legs =
      legs
      |> Enum.zip(leg_ids)
      |> Enum.reduce(state.legs, fn {leg, leg_id}, acc ->
        Map.put(acc, leg_id, leg)
      end)

    # Initialize ring strategy state
    leg_structs = Enum.map(leg_ids, fn id -> %{id: id} end)
    ring_state = RingStrategy.init_state(strategy, leg_structs)

    new_state = %{
      state
      | legs: new_legs,
        pending_legs: leg_ids,
        ring_strategy: strategy,
        ring_state: ring_state
    }

    Logger.debug(
      "[B2BUA] Forked to #{length(destinations)} destinations with strategy=#{strategy.type}"
    )

    {:reply, {:ok, leg_ids}, new_state}
  end

  @impl true
  def handle_call({:leg_event, leg_id, event}, _from, state) do
    case Map.fetch(state.legs, leg_id) do
      :error ->
        {:reply, {:error, :unknown_leg}, state}

      {:ok, %Leg{state: :terminated}} ->
        {:reply, {:error, :leg_terminated}, state}

      {:ok, leg} ->
        case process_leg_event(state, leg, event) do
          {:ok, new_state} ->
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:update_leg, leg_id, updates}, _from, state) do
    case Map.fetch(state.legs, leg_id) do
      :error ->
        {:reply, {:error, :unknown_leg}, state}

      {:ok, leg} ->
        updated_leg = apply_leg_updates(leg, updates)
        new_legs = Map.put(state.legs, leg_id, updated_leg)
        {:reply, :ok, %{state | legs: new_legs}}
    end
  end

  @impl true
  def handle_call({:connect, leg_a_id, leg_b_id}, _from, state) do
    with {:ok, leg_a} <- fetch_leg(state, leg_a_id),
         {:ok, leg_b} <- fetch_leg(state, leg_b_id),
         :ok <- verify_leg_answered(leg_a),
         :ok <- verify_leg_answered(leg_b),
         {:ok, bridge} <- create_media_bridge(leg_a, leg_b) do
      new_state = %{
        state
        | active_bridge: {leg_a_id, leg_b_id},
          media_bridge: bridge
      }

      Logger.debug("[B2BUA] Connected legs #{inspect(leg_a_id)} <-> #{inspect(leg_b_id)}")

      {:reply, {:ok, bridge}, new_state}
    else
      {:error, :not_found} -> {:reply, {:error, :leg_not_found}, state}
      {:error, :leg_not_answered} -> {:reply, {:error, :leg_not_answered}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:hold, leg_id}, _from, state) do
    with {:ok, leg} <- fetch_leg(state, leg_id),
         :ok <- verify_leg_connected(state, leg_id) do
      {:ok, held_leg} = Leg.transition(leg, :held)
      new_legs = Map.put(state.legs, leg_id, held_leg)
      new_state = %{state | legs: new_legs}

      # Update media bridge if exists
      new_state = maybe_hold_media_bridge(new_state, leg_id)

      # Dispatch event to handler
      dispatch_leg_event(new_state, leg_id, :held)

      Logger.debug("[B2BUA] Leg #{inspect(leg_id)} placed on hold")

      {:reply, :ok, new_state}
    else
      {:error, :not_found} -> {:reply, {:error, :unknown_leg}, state}
      {:error, :not_connected} -> {:reply, {:error, :leg_not_connected}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:resume, leg_id}, _from, state) do
    with {:ok, leg} <- fetch_leg(state, leg_id),
         :ok <- verify_leg_held(leg) do
      {:ok, resumed_leg} = Leg.transition(leg, :answered)
      new_legs = Map.put(state.legs, leg_id, resumed_leg)
      new_state = %{state | legs: new_legs}

      # Update media bridge if exists
      new_state = maybe_resume_media_bridge(new_state, leg_id)

      # Dispatch event to handler
      dispatch_leg_event(new_state, leg_id, :resumed)

      Logger.debug("[B2BUA] Leg #{inspect(leg_id)} resumed")

      {:reply, :ok, new_state}
    else
      {:error, :not_found} -> {:reply, {:error, :unknown_leg}, state}
      {:error, :leg_not_held} -> {:reply, {:error, :leg_not_held}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:hangup_leg, leg_id}, _from, state) do
    case Map.fetch(state.legs, leg_id) do
      :error ->
        {:reply, {:error, :unknown_leg}, state}

      {:ok, leg} ->
        terminated_leg = force_terminate_leg(leg)
        new_legs = Map.put(state.legs, leg_id, terminated_leg)

        Logger.debug("[B2BUA] Leg #{inspect(leg_id)} hung up")

        {:reply, :ok, %{state | legs: new_legs}}
    end
  end

  @impl true
  def handle_call(:hangup_all, _from, state) do
    # Terminate all legs and dispatch :bye events
    new_legs =
      Map.new(state.legs, fn {leg_id, leg} ->
        terminated_leg = force_terminate_leg(leg)
        # Dispatch :bye event for each leg
        dispatch_leg_event(state, leg_id, :bye)
        {leg_id, terminated_leg}
      end)

    Logger.debug("[B2BUA] All legs hung up")

    {:reply, :ok, %{state | legs: new_legs, active_bridge: nil, media_bridge: nil}}
  end

  # Catch-all for unexpected handle_call messages
  @impl true
  def handle_call(msg, _from, state) do
    Logger.warning("[B2BUA] Unexpected call: #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  # Catch-all for unexpected handle_cast messages
  @impl true
  def handle_cast(msg, state) do
    Logger.warning("[B2BUA] Unexpected cast: #{inspect(msg)}")
    {:noreply, state}
  end

  # Catch-all for unexpected handle_info messages
  @impl true
  def handle_info(msg, state) do
    Logger.warning("[B2BUA] Unexpected info: #{inspect(msg)}")
    {:noreply, state}
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp generate_session_id do
    "b2bua-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_leg_id do
    "leg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp process_leg_event(state, leg, :trying) do
    transition_leg(state, leg, :trying)
  end

  defp process_leg_event(state, leg, :ringing) do
    with {:ok, new_state} <- transition_leg(state, leg, :ringing) do
      # Update ring strategy state if in forking mode
      new_state = maybe_update_ring_state(new_state, leg.id, {:ringing, leg.id})
      {:ok, new_state}
    end
  end

  defp process_leg_event(state, leg, {:answered, sdp}) do
    with {:ok, new_state} <- transition_leg(state, leg, :answered) do
      # Update leg with SDP
      updated_leg = Leg.set_sdp(new_state.legs[leg.id], sdp)
      new_legs = Map.put(new_state.legs, leg.id, updated_leg)
      new_state = %{new_state | legs: new_legs}

      # Handle forking: first answer wins
      new_state = handle_fork_answer(new_state, leg.id)

      {:ok, new_state}
    end
  end

  defp process_leg_event(state, leg, :bye) do
    transition_leg(state, leg, :terminated)
  end

  defp process_leg_event(state, leg, {:failed, _reason}) do
    with {:ok, new_state} <- transition_leg(state, leg, :terminated) do
      # Update ring strategy state if in forking mode
      new_state = maybe_update_ring_state(new_state, leg.id, {:failed, leg.id, :failed})
      {:ok, new_state}
    end
  end

  defp process_leg_event(_state, _leg, _event) do
    {:error, :invalid_transition}
  end

  defp transition_leg(state, leg, target_state) do
    case Leg.transition(leg, target_state) do
      {:ok, updated_leg} ->
        new_legs = Map.put(state.legs, leg.id, updated_leg)
        new_state = %{state | legs: new_legs}

        # Dispatch event to handler
        dispatch_leg_event(new_state, leg.id, target_state)

        {:ok, new_state}

      {:error, :invalid_transition} ->
        {:error, :invalid_transition}
    end
  end

  defp dispatch_leg_event(state, leg_id, event) do
    if state.handler && function_exported?(state.handler, :handle_leg_event, 3) do
      state.handler.handle_leg_event(leg_id, event, state.handler_state)
    end
  end

  defp apply_leg_updates(leg, updates) do
    Enum.reduce(updates, leg, fn
      {:metadata, metadata}, acc ->
        new_metadata = Map.merge(acc.metadata, metadata)
        %{acc | metadata: new_metadata}

      {:dialog_id, dialog_id}, acc ->
        Leg.set_dialog_id(acc, dialog_id)

      {:media_pid, media_pid}, acc ->
        Leg.set_media_pid(acc, media_pid)

      {:sdp, sdp}, acc ->
        Leg.set_sdp(acc, sdp)

      _, acc ->
        acc
    end)
  end

  defp fetch_leg(state, leg_id) do
    case Map.fetch(state.legs, leg_id) do
      {:ok, leg} -> {:ok, leg}
      :error -> {:error, :not_found}
    end
  end

  defp verify_leg_answered(%Leg{state: :answered}), do: :ok
  defp verify_leg_answered(_leg), do: {:error, :leg_not_answered}

  defp verify_leg_connected(state, leg_id) do
    case state.active_bridge do
      {^leg_id, _} -> :ok
      {_, ^leg_id} -> :ok
      _ -> {:error, :not_connected}
    end
  end

  defp verify_leg_held(%Leg{state: :held}), do: :ok
  defp verify_leg_held(_leg), do: {:error, :leg_not_held}

  defp create_media_bridge(leg_a, leg_b) do
    if leg_a.media_pid && leg_b.media_pid do
      case MediaBridge.create(leg_a.media_pid, leg_b.media_pid) do
        {:ok, bridge} -> MediaBridge.bridge(bridge)
        error -> error
      end
    else
      # Return a placeholder bridge if no media PIDs (for testing)
      {:ok,
       %MediaBridge{
         leg_a_media: leg_a.media_pid,
         leg_b_media: leg_b.media_pid,
         state: :bridged
       }}
    end
  end

  defp maybe_hold_media_bridge(%{media_bridge: nil} = state, _leg_id), do: state

  defp maybe_hold_media_bridge(%{media_bridge: bridge, active_bridge: {leg_a, _leg_b}} = state, leg_id) do
    leg_spec = if leg_id == leg_a, do: :leg_a, else: :leg_b
    {:ok, updated_bridge} = MediaBridge.hold(bridge, leg_spec)
    %{state | media_bridge: updated_bridge}
  end

  defp maybe_resume_media_bridge(%{media_bridge: nil} = state, _leg_id), do: state

  defp maybe_resume_media_bridge(%{media_bridge: bridge, active_bridge: {leg_a, _leg_b}} = state, leg_id) do
    leg_spec = if leg_id == leg_a, do: :leg_a, else: :leg_b
    {:ok, updated_bridge} = MediaBridge.resume(bridge, leg_spec)
    %{state | media_bridge: updated_bridge}
  end

  defp force_terminate_leg(leg) do
    %{leg | state: :terminated}
  end

  defp maybe_update_ring_state(%{ring_state: nil} = state, _leg_id, _event), do: state

  defp maybe_update_ring_state(%{ring_state: ring_state} = state, _leg_id, event) do
    case RingStrategy.handle_event(ring_state, event) do
      {:winner, _winner_id, new_ring_state} ->
        %{state | ring_state: new_ring_state}

      {:continue, new_ring_state} ->
        %{state | ring_state: new_ring_state}

      {:ring_next, _next_leg_id, new_ring_state} ->
        %{state | ring_state: new_ring_state}

      {:all_failed, _reasons} ->
        %{state | ring_state: nil, pending_legs: []}
    end
  end

  defp handle_fork_answer(%{pending_legs: []} = state, _leg_id), do: state

  defp handle_fork_answer(%{pending_legs: pending, ring_state: ring_state} = state, winner_id) when is_list(pending) do
    if winner_id in pending do
      # Update ring state
      new_ring_state =
        if ring_state do
          case RingStrategy.handle_event(ring_state, {:answered, winner_id, %{}}) do
            {:winner, ^winner_id, updated_state} -> updated_state
            _ -> ring_state
          end
        else
          ring_state
        end

      # Clear pending legs (winner selected)
      %{state | pending_legs: [], ring_state: new_ring_state}
    else
      state
    end
  end
end
