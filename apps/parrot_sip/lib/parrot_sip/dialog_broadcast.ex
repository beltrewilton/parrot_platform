defmodule ParrotSip.DialogBroadcast do
  @moduledoc """
  GenServer for broadcasting dialog state changes across cluster nodes.

  This module provides PubSub-based dialog state replication for cluster-wide
  session continuity. When a dialog is created, updated, or deleted on one node,
  the change is broadcast to all other nodes in the cluster.

  ## Architecture

  - Uses Phoenix.PubSub for inter-node communication
  - Stores dialog state in a local ETS table for fast lookups
  - Tags all broadcasts with the originating node to prevent echo loops
  - Ignores broadcasts from self to avoid duplicate processing

  ## Topic

  All dialog events are broadcast on the `parrot:dialogs` PubSub topic.

  ## Message Types

  - `{:dialog_created, dialog_id, dialog_state, origin_node}` - New dialog
  - `{:dialog_updated, dialog_id, changes, origin_node}` - State change
  - `{:dialog_deleted, dialog_id, origin_node}` - Dialog terminated

  ## Usage

      # Start in supervision tree with PubSub
      {:ok, _} = DialogBroadcast.start_link(pubsub: ParrotSip.PubSub)

      # Create a new dialog (broadcasts to cluster)
      :ok = DialogBroadcast.broadcast_create(pid, dialog_id, dialog_state)

      # Update dialog state
      :ok = DialogBroadcast.broadcast_update(pid, dialog_id, %{state: :confirmed})

      # Delete a dialog
      :ok = DialogBroadcast.broadcast_delete(pid, dialog_id)

      # Get dialog from local ETS
      {:ok, state} = DialogBroadcast.get(pid, dialog_id)

      # Get all dialogs
      all_dialogs = DialogBroadcast.get_all(pid)

  ## Cluster Considerations

  - Each node maintains its own ETS table with replicated state
  - Broadcasts use Phoenix.PubSub which handles inter-node messaging
  - The origin node is included in all broadcasts to track source
  """

  use GenServer

  require Logger

  @topic "parrot:dialogs"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the DialogBroadcast GenServer.

  ## Options

  - `:name` - GenServer name (required for named process)
  - `:pubsub` - Phoenix.PubSub server name (required)

  ## Examples

      {:ok, pid} = DialogBroadcast.start_link(pubsub: ParrotSip.PubSub)
      {:ok, pid} = DialogBroadcast.start_link(name: :dialog_broadcast, pubsub: ParrotSip.PubSub)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, init_opts, name: name)
    else
      GenServer.start_link(__MODULE__, init_opts)
    end
  end

  @doc """
  Broadcasts a new dialog creation to the cluster and stores it locally.

  ## Parameters

  - `server` - The DialogBroadcast server
  - `dialog_id` - Unique identifier for the dialog
  - `dialog_state` - Map containing the dialog state

  ## Returns

  - `:ok` - Always succeeds

  ## Examples

      :ok = DialogBroadcast.broadcast_create(pid, "call-123", %{state: :early})
  """
  @spec broadcast_create(GenServer.server(), String.t(), map()) :: :ok
  def broadcast_create(server, dialog_id, dialog_state) do
    GenServer.call(server, {:broadcast_create, dialog_id, dialog_state})
  end

  @doc """
  Broadcasts a dialog state update to the cluster and applies it locally.

  ## Parameters

  - `server` - The DialogBroadcast server
  - `dialog_id` - The dialog to update
  - `changes` - Map of fields to update

  ## Returns

  - `:ok` - Update successful
  - `{:error, :not_found}` - Dialog does not exist locally

  ## Examples

      :ok = DialogBroadcast.broadcast_update(pid, "call-123", %{state: :confirmed})
  """
  @spec broadcast_update(GenServer.server(), String.t(), map()) :: :ok | {:error, :not_found}
  def broadcast_update(server, dialog_id, changes) do
    GenServer.call(server, {:broadcast_update, dialog_id, changes})
  end

  @doc """
  Broadcasts a dialog deletion to the cluster and removes it locally.

  ## Parameters

  - `server` - The DialogBroadcast server
  - `dialog_id` - The dialog to delete

  ## Returns

  - `:ok` - Always succeeds (idempotent)

  ## Examples

      :ok = DialogBroadcast.broadcast_delete(pid, "call-123")
  """
  @spec broadcast_delete(GenServer.server(), String.t()) :: :ok
  def broadcast_delete(server, dialog_id) do
    GenServer.call(server, {:broadcast_delete, dialog_id})
  end

  @doc """
  Gets a dialog from the local ETS table.

  ## Parameters

  - `server` - The DialogBroadcast server
  - `dialog_id` - The dialog to retrieve

  ## Returns

  - `{:ok, dialog_state}` - Dialog found
  - `{:error, :not_found}` - Dialog not in local ETS

  ## Examples

      {:ok, state} = DialogBroadcast.get(pid, "call-123")
      {:error, :not_found} = DialogBroadcast.get(pid, "nonexistent")
  """
  @spec get(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(server, dialog_id) do
    GenServer.call(server, {:get, dialog_id})
  end

  @doc """
  Gets all dialogs from the local ETS table.

  ## Returns

  A map of dialog_id => dialog_state for all dialogs.

  ## Examples

      %{"call-1" => %{...}, "call-2" => %{...}} = DialogBroadcast.get_all(pid)
  """
  @spec get_all(GenServer.server()) :: %{String.t() => map()}
  def get_all(server) do
    GenServer.call(server, :get_all)
  end

  @doc """
  Gets the ETS table name for this DialogBroadcast instance.

  Primarily used for testing and debugging.
  """
  @spec table_name(GenServer.server()) :: atom()
  def table_name(server) do
    GenServer.call(server, :table_name)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)

    # Create a unique ETS table for this instance
    table = :ets.new(:dialog_broadcast_table, [:set, :protected])

    # Subscribe to the dialogs topic
    Phoenix.PubSub.subscribe(pubsub, @topic)

    state = %{
      pubsub: pubsub,
      table: table,
      node: node()
    }

    Logger.debug("[DialogBroadcast] Started on node #{node()}, subscribed to #{@topic}")

    {:ok, state}
  end

  @impl true
  def handle_call({:broadcast_create, dialog_id, dialog_state}, _from, state) do
    # Store locally in ETS
    :ets.insert(state.table, {dialog_id, dialog_state})

    # Broadcast to cluster with origin node
    Phoenix.PubSub.broadcast(
      state.pubsub,
      @topic,
      {:dialog_created, dialog_id, dialog_state, state.node}
    )

    Logger.debug("[DialogBroadcast] Created dialog #{dialog_id}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:broadcast_update, dialog_id, changes}, _from, state) do
    case :ets.lookup(state.table, dialog_id) do
      [{^dialog_id, existing_state}] ->
        # Merge changes into existing state
        updated_state = Map.merge(existing_state, changes)
        :ets.insert(state.table, {dialog_id, updated_state})

        # Broadcast to cluster
        Phoenix.PubSub.broadcast(
          state.pubsub,
          @topic,
          {:dialog_updated, dialog_id, changes, state.node}
        )

        Logger.debug("[DialogBroadcast] Updated dialog #{dialog_id}: #{inspect(changes)}")

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:broadcast_delete, dialog_id}, _from, state) do
    # Delete from local ETS
    :ets.delete(state.table, dialog_id)

    # Broadcast to cluster
    Phoenix.PubSub.broadcast(
      state.pubsub,
      @topic,
      {:dialog_deleted, dialog_id, state.node}
    )

    Logger.debug("[DialogBroadcast] Deleted dialog #{dialog_id}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, dialog_id}, _from, state) do
    case :ets.lookup(state.table, dialog_id) do
      [{^dialog_id, dialog_state}] ->
        {:reply, {:ok, dialog_state}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_all, _from, state) do
    dialogs =
      state.table
      |> :ets.tab2list()
      |> Map.new()

    {:reply, dialogs, state}
  end

  @impl true
  def handle_call(:table_name, _from, state) do
    {:reply, state.table, state}
  end

  # Handle incoming broadcasts from PubSub
  @impl true
  def handle_info({:dialog_created, dialog_id, dialog_state, origin_node}, state) do
    # Ignore broadcasts from ourselves
    if origin_node != state.node do
      :ets.insert(state.table, {dialog_id, dialog_state})
      Logger.debug("[DialogBroadcast] Received create from #{origin_node}: #{dialog_id}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:dialog_updated, dialog_id, changes, origin_node}, state) do
    # Ignore broadcasts from ourselves
    if origin_node != state.node do
      case :ets.lookup(state.table, dialog_id) do
        [{^dialog_id, existing_state}] ->
          updated_state = Map.merge(existing_state, changes)
          :ets.insert(state.table, {dialog_id, updated_state})
          Logger.debug("[DialogBroadcast] Received update from #{origin_node}: #{dialog_id}")

        [] ->
          # Dialog doesn't exist locally - this could happen if we missed the create
          Logger.warning(
            "[DialogBroadcast] Received update for unknown dialog #{dialog_id} from #{origin_node}"
          )
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:dialog_deleted, dialog_id, origin_node}, state) do
    # Ignore broadcasts from ourselves
    if origin_node != state.node do
      :ets.delete(state.table, dialog_id)
      Logger.debug("[DialogBroadcast] Received delete from #{origin_node}: #{dialog_id}")
    end

    {:noreply, state}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("[DialogBroadcast] Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
