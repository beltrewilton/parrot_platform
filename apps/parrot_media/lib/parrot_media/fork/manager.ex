defmodule ParrotMedia.Fork.Manager do
  @moduledoc """
  GenServer for managing active media forks within a MediaSession.

  Fork.Manager handles the lifecycle of media forks - creating, tracking,
  and removing forks that stream audio to external services. It maintains
  the state of all active forks and sends notifications to the parent process
  (typically Call.Server) when fork events occur.

  ## Responsibilities

  - Add new forks with configuration (WebSocket or RTP destination)
  - Track fork state (pending, connecting, active, stopped, error)
  - Remove forks and clean up resources
  - Notify parent of fork events (added, removed, connected, error)
  - Handle fork sink crashes gracefully

  ## Usage

      # Start manager for a media session
      {:ok, manager} = Fork.Manager.start_link(
        session_id: "session-123",
        parent_pid: self()
      )

      # Add a WebSocket fork
      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "wss://ai-service.com/audio"},
        direction: :both
      }
      {:ok, fork_id} = Fork.Manager.add_fork(manager, config)

      # List active forks
      forks = Fork.Manager.list_forks(manager)

      # Remove a fork
      :ok = Fork.Manager.remove_fork(manager, "fork-1")

  ## Event Notifications

  When a parent_pid is provided, the manager sends events:

  - `{:fork_event, session_id, {:fork_added, fork_id}}` - Fork added to manager
  - `{:fork_event, session_id, {:fork_removed, fork_id}}` - Fork removed
  - `{:fork_event, session_id, {:fork_connected, fork_id}}` - Sink connected
  - `{:fork_event, session_id, {:fork_error, fork_id, reason}}` - Error occurred
  """

  use GenServer

  require Logger

  alias ParrotMedia.Fork.Types.{ForkConfig, ForkState}

  defmodule State do
    @moduledoc false
    defstruct [
      :session_id,
      :parent_pid,
      :pipeline_pid,
      forks: %{}
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            parent_pid: pid() | nil,
            pipeline_pid: pid() | nil,
            forks: %{String.t() => ForkState.t()}
          }
  end

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts a Fork.Manager linked to the calling process.

  ## Options

  - `:session_id` - Required. Unique identifier for the media session.
  - `:parent_pid` - Optional. PID to receive fork event notifications.
  - `:pipeline_pid` - Optional. PID of Membrane pipeline for dynamic element creation.

  ## Returns

  - `{:ok, pid}` - Manager started successfully
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Adds a new fork with the given configuration.

  If the config has no id, one will be generated.

  ## Parameters

  - `manager` - The manager PID or name
  - `config` - ForkConfig struct with destination and direction

  ## Returns

  - `{:ok, fork_id}` - Fork added successfully
  - `{:error, :already_exists}` - Fork with this ID already exists
  - `{:error, reason}` - Failed to add fork
  """
  @spec add_fork(GenServer.server(), ForkConfig.t()) ::
          {:ok, String.t()} | {:error, term()}
  def add_fork(manager, %ForkConfig{} = config) do
    GenServer.call(manager, {:add_fork, config})
  end

  @doc """
  Removes a fork by its ID.

  ## Parameters

  - `manager` - The manager PID or name
  - `fork_id` - The fork identifier to remove

  ## Returns

  - `:ok` - Fork removed successfully
  - `{:error, :not_found}` - No fork with this ID exists
  """
  @spec remove_fork(GenServer.server(), String.t()) ::
          :ok | {:error, :not_found}
  def remove_fork(manager, fork_id) do
    GenServer.call(manager, {:remove_fork, fork_id})
  end

  @doc """
  Lists all active forks.

  ## Returns

  A list of `ForkState` structs for all active forks.
  """
  @spec list_forks(GenServer.server()) :: [ForkState.t()]
  def list_forks(manager) do
    GenServer.call(manager, :list_forks)
  end

  @doc """
  Gets the state of a specific fork.

  ## Returns

  - `{:ok, ForkState.t()}` - Fork state
  - `{:error, :not_found}` - No fork with this ID
  """
  @spec get_fork(GenServer.server(), String.t()) ::
          {:ok, ForkState.t()} | {:error, :not_found}
  def get_fork(manager, fork_id) do
    GenServer.call(manager, {:get_fork, fork_id})
  end

  @doc """
  Updates the status of a fork.

  Used internally to update fork status when connection events occur.
  """
  @spec update_fork_status(GenServer.server(), String.t(), atom()) :: :ok | {:error, :not_found}
  def update_fork_status(manager, fork_id, status) do
    GenServer.call(manager, {:update_status, fork_id, status})
  end

  @doc """
  Sets the pipeline PID for dynamic element management.
  """
  @spec set_pipeline(GenServer.server(), pid()) :: :ok
  def set_pipeline(manager, pipeline_pid) do
    GenServer.cast(manager, {:set_pipeline, pipeline_pid})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    parent_pid = Keyword.get(opts, :parent_pid)
    pipeline_pid = Keyword.get(opts, :pipeline_pid)

    Logger.debug("Fork.Manager [#{session_id}]: Starting")

    state = %State{
      session_id: session_id,
      parent_pid: parent_pid,
      pipeline_pid: pipeline_pid
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add_fork, config}, _from, state) do
    # Generate ID if not provided
    fork_id = config.id || generate_fork_id()
    config = %{config | id: fork_id}

    if Map.has_key?(state.forks, fork_id) do
      {:reply, {:error, :already_exists}, state}
    else
      # Create initial fork state
      fork_state = %ForkState{
        config: %{config | started_at: DateTime.utc_now()},
        status: :pending
      }

      new_forks = Map.put(state.forks, fork_id, fork_state)
      new_state = %{state | forks: new_forks}

      # Notify parent
      notify_parent(state, {:fork_added, fork_id})

      Logger.info("Fork.Manager [#{state.session_id}]: Added fork #{fork_id}")

      {:reply, {:ok, fork_id}, new_state}
    end
  end

  def handle_call({:remove_fork, fork_id}, _from, state) do
    case Map.fetch(state.forks, fork_id) do
      {:ok, fork_state} ->
        # Clean up connection if active
        cleanup_fork(fork_state)

        new_forks = Map.delete(state.forks, fork_id)
        new_state = %{state | forks: new_forks}

        # Notify parent
        notify_parent(state, {:fork_removed, fork_id})

        Logger.info("Fork.Manager [#{state.session_id}]: Removed fork #{fork_id}")

        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_forks, _from, state) do
    forks = Map.values(state.forks)
    {:reply, forks, state}
  end

  def handle_call({:get_fork, fork_id}, _from, state) do
    case Map.fetch(state.forks, fork_id) do
      {:ok, fork_state} -> {:reply, {:ok, fork_state}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update_status, fork_id, new_status}, _from, state) do
    case Map.fetch(state.forks, fork_id) do
      {:ok, fork_state} ->
        updated_state = %{fork_state | status: new_status}
        new_forks = Map.put(state.forks, fork_id, updated_state)
        new_state = %{state | forks: new_forks}

        # Notify parent of status change
        case new_status do
          :active ->
            notify_parent(state, {:fork_connected, fork_id})

          :error ->
            notify_parent(state, {:fork_error, fork_id, :connection_failed})

          _ ->
            :ok
        end

        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:set_pipeline, pipeline_pid}, state) do
    {:noreply, %{state | pipeline_pid: pipeline_pid}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Handle death of a fork connection
    case find_fork_by_pid(state.forks, pid) do
      {fork_id, fork_state} ->
        Logger.warning(
          "Fork.Manager [#{state.session_id}]: Fork #{fork_id} connection died: #{inspect(reason)}"
        )

        updated_state = %{fork_state | status: :error, connection_pid: nil}
        new_forks = Map.put(state.forks, fork_id, updated_state)
        new_state = %{state | forks: new_forks}

        notify_parent(state, {:fork_error, fork_id, {:connection_died, reason}})

        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Fork.Manager [#{state.session_id}]: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("Fork.Manager [#{state.session_id}]: Terminating: #{inspect(reason)}")

    # Clean up all forks
    Enum.each(state.forks, fn {fork_id, fork_state} ->
      Logger.debug("Fork.Manager [#{state.session_id}]: Cleaning up fork #{fork_id}")
      cleanup_fork(fork_state)
    end)

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_fork_id do
    "fork-" <> :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp notify_parent(%State{parent_pid: nil}, _event), do: :ok

  defp notify_parent(%State{parent_pid: parent, session_id: session_id}, event) do
    send(parent, {:fork_event, session_id, event})
  end

  defp cleanup_fork(%ForkState{connection_pid: nil}), do: :ok

  defp cleanup_fork(%ForkState{connection_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      # Send close signal - the connection process will handle cleanup
      send(pid, :close)
      # Give it a moment to close gracefully
      Process.sleep(50)

      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end
  end

  defp find_fork_by_pid(forks, pid) do
    Enum.find_value(forks, fn {fork_id, fork_state} ->
      if fork_state.connection_pid == pid do
        {fork_id, fork_state}
      end
    end)
  end
end
