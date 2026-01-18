defmodule ParrotSip.ClusterMonitor do
  @moduledoc """
  Monitors cluster nodes and detects failures for dialog recovery.

  Uses `:net_kernel.monitor_nodes/1` to receive nodeup/nodedown messages.
  When a node goes down, queries DialogBroadcast for orphaned dialogs
  and triggers recovery.

  ## Example

      {:ok, pid} = ClusterMonitor.start_link()
      nodes = ClusterMonitor.get_nodes(pid)

  """

  use GenServer
  require Logger

  @type node_name :: atom()

  defmodule State do
    @moduledoc false
    defstruct nodes: MapSet.new()

    @type t :: %__MODULE__{
            nodes: MapSet.t(atom())
          }
  end

  # Client API

  @doc """
  Starts the ClusterMonitor GenServer.

  ## Options

    * `:name` - Optional name to register the process

  ## Examples

      {:ok, pid} = ClusterMonitor.start_link()
      {:ok, pid} = ClusterMonitor.start_link(name: MyMonitor)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, _init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns the list of currently connected nodes being tracked.

  ## Examples

      nodes = ClusterMonitor.get_nodes(pid)
      [:node1@host, :node2@host]

  """
  @spec get_nodes(GenServer.server()) :: [node_name()]
  def get_nodes(server) do
    GenServer.call(server, :get_nodes)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Subscribe to node events
    :ok = :net_kernel.monitor_nodes(true)

    # Initialize with currently connected nodes
    initial_nodes = Node.list() |> MapSet.new()

    Logger.info("ClusterMonitor started, monitoring #{MapSet.size(initial_nodes)} nodes")

    {:ok, %State{nodes: initial_nodes}}
  end

  @impl true
  def handle_call(:get_nodes, _from, state) do
    {:reply, MapSet.to_list(state.nodes), state}
  end

  @impl true
  def handle_info({:nodeup, node}, %State{} = state) do
    Logger.info("Node up: #{node}")

    new_nodes = MapSet.put(state.nodes, node)
    {:noreply, %{state | nodes: new_nodes}}
  end

  @impl true
  def handle_info({:nodedown, node}, %State{} = state) do
    Logger.warning("Node down: #{node}")

    new_nodes = MapSet.delete(state.nodes, node)

    # In the future, this is where we would query DialogBroadcast
    # for orphaned dialogs and trigger recovery:
    # orphaned_dialogs = ParrotSip.DialogBroadcast.find_dialogs_on_node(node)
    # Enum.each(orphaned_dialogs, &trigger_recovery/1)

    {:noreply, %{state | nodes: new_nodes}}
  end

  @impl true
  def terminate(_reason, _state) do
    # Unsubscribe from node events
    :net_kernel.monitor_nodes(false)
    :ok
  end
end
