defmodule ParrotSip.CDR do
  @moduledoc """
  Call Detail Record struct for Parrot Platform.
  Generated automatically for every INVITE dialog upon termination.
  Delivered to registered handlers for storage/processing.

  ## Handler Registration

  Handlers implementing the `ParrotSip.CDR.Handler` behaviour can be registered
  to receive CDRs when calls complete:

      # Register a handler
      :ok = ParrotSip.CDR.register_handler(MyApp.CDR.LoggerHandler, [])
      :ok = ParrotSip.CDR.register_handler(MyApp.CDR.DatabaseHandler, repo: MyApp.Repo)

      # List registered handlers
      [{MyApp.CDR.LoggerHandler, state1}, {MyApp.CDR.DatabaseHandler, state2}] =
        ParrotSip.CDR.list_handlers()

      # Unregister a handler
      :ok = ParrotSip.CDR.unregister_handler(MyApp.CDR.LoggerHandler)

  Handler registration calls the handler's `init/1` callback to initialize state.
  If `init/1` fails, registration returns `{:error, :init_failed, reason}`.
  """

  use Agent

  alias ParrotSip.CDR.{TerminationCause, MediaInfo}
  alias ParrotSip.CDR.Handler

  # Agent name for handler registry
  @registry_name __MODULE__.Registry

  @typedoc "Call disposition indicating the outcome of the call attempt"
  @type disposition ::
          :answered
          | :busy
          | :no_answer
          | :timeout
          | :cancelled
          | :declined
          | :not_found
          | :forbidden
          | :server_error
          | :failed
          | :redirected
          | :abandoned

  @typedoc "Call direction from the perspective of this endpoint"
  @type direction :: :inbound | :outbound

  @typedoc "Transport protocol used for SIP signaling"
  @type transport :: :udp | :tcp | :tls | :ws | :wss

  @typedoc "Call Detail Record struct"
  @type t :: %__MODULE__{
          id: String.t(),
          correlation_id: String.t(),
          call_id: String.t(),
          caller_uri: String.t(),
          caller_display_name: String.t() | nil,
          caller_tag: String.t(),
          callee_uri: String.t(),
          callee_display_name: String.t() | nil,
          callee_tag: String.t() | nil,
          disposition: disposition(),
          termination_cause: TerminationCause.t(),
          invite_received_at: DateTime.t(),
          answered_at: DateTime.t() | nil,
          ended_at: DateTime.t(),
          ring_duration_ms: non_neg_integer(),
          talk_duration_ms: non_neg_integer(),
          direction: direction(),
          transport: transport(),
          dialog_id: String.t(),
          media_info: MediaInfo.t() | nil,
          custom_fields: map()
        }

  defstruct [
    :id,
    :correlation_id,
    :call_id,
    :caller_uri,
    :caller_display_name,
    :caller_tag,
    :callee_uri,
    :callee_display_name,
    :callee_tag,
    :disposition,
    :termination_cause,
    :invite_received_at,
    :answered_at,
    :ended_at,
    :ring_duration_ms,
    :talk_duration_ms,
    :direction,
    :transport,
    :dialog_id,
    :media_info,
    custom_fields: %{}
  ]

  # Valid keys for query filters
  @valid_filter_keys [
    :start_time,
    :end_time,
    :caller_uri,
    :callee_uri,
    :disposition,
    :call_id,
    :direction
  ]

  # ===========================================================================
  # Query Helper API
  # ===========================================================================

  @doc """
  Build a query filter map from options.

  Handlers can use this to build filters for their storage backend.

  ## Options

  - `:start_time` - Filter CDRs after this DateTime
  - `:end_time` - Filter CDRs before this DateTime
  - `:caller_uri` - Filter by caller URI (exact match or pattern)
  - `:callee_uri` - Filter by callee URI (exact match or pattern)
  - `:disposition` - Filter by disposition atom or list of atoms
  - `:call_id` - Filter by specific call_id
  - `:direction` - Filter by :inbound or :outbound

  ## Examples

      iex> filter = ParrotSip.CDR.build_query_filter(
      ...>   start_time: ~U[2024-01-01 00:00:00Z],
      ...>   end_time: ~U[2024-01-02 00:00:00Z],
      ...>   disposition: [:answered, :busy]
      ...> )
      %{start_time: ~U[2024-01-01 00:00:00Z], end_time: ~U[2024-01-02 00:00:00Z], disposition: [:answered, :busy]}

      iex> ParrotSip.CDR.build_query_filter(invalid_key: "ignored")
      %{}

  """
  @spec build_query_filter(keyword()) :: map()
  def build_query_filter(opts) when is_list(opts) do
    opts
    |> Enum.filter(fn {key, _} -> key in @valid_filter_keys end)
    |> Map.new()
  end

  # ===========================================================================
  # Handler Registration API
  # ===========================================================================

  @doc """
  Starts the CDR handler registry agent.

  This is typically started as part of the application supervision tree.
  The registry stores registered handlers with their initialized state.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Returns the child specification for supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc """
  Registers a CDR handler module with initialization arguments.

  Calls the handler's `init/1` callback with the provided args. If `init/1`
  returns `{:ok, state}`, the handler is registered with that state.
  If the handler module doesn't implement `init/1`, the default implementation
  from `ParrotSip.CDR.Handler` is used which passes args through as state.

  ## Parameters

  - `handler_module` - Module implementing `ParrotSip.CDR.Handler` behaviour
  - `args` - Arguments passed to handler's `init/1` callback

  ## Return Values

  - `:ok` - Handler registered successfully
  - `{:error, :init_failed, reason}` - Handler's `init/1` returned an error
  - `{:error, :already_registered}` - Handler is already registered

  ## Examples

      iex> ParrotSip.CDR.register_handler(MyApp.CDR.LoggerHandler, [])
      :ok

      iex> ParrotSip.CDR.register_handler(MyApp.CDR.DatabaseHandler, repo: MyApp.Repo)
      :ok

  """
  @spec register_handler(module(), term()) :: :ok | {:error, term()}
  def register_handler(handler_module, args) do
    ensure_registry_started()

    # Check if already registered
    if handler_registered?(handler_module) do
      {:error, :already_registered}
    else
      # Initialize the handler - use handler's init/1 if defined, otherwise default
      init_result =
        if function_exported?(handler_module, :init, 1) do
          handler_module.init(args)
        else
          Handler.init(args)
        end

      case init_result do
        {:ok, state} ->
          Agent.update(@registry_name, fn handlers ->
            Map.put(handlers, handler_module, state)
          end)

          :ok

        {:error, reason} ->
          {:error, :init_failed, reason}
      end
    end
  end

  @doc """
  Unregisters a CDR handler module.

  Removes the handler from the registry. This operation is idempotent -
  unregistering a handler that isn't registered returns `:ok`.

  ## Parameters

  - `handler_module` - Module to unregister

  ## Return Values

  - `:ok` - Handler unregistered (or was not registered)

  ## Examples

      iex> ParrotSip.CDR.unregister_handler(MyApp.CDR.LoggerHandler)
      :ok

  """
  @spec unregister_handler(module()) :: :ok
  def unregister_handler(handler_module) do
    ensure_registry_started()

    Agent.update(@registry_name, fn handlers ->
      Map.delete(handlers, handler_module)
    end)

    :ok
  end

  @doc """
  Lists all registered CDR handlers with their current state.

  Returns a list of `{module, state}` tuples for all registered handlers.
  The state is the value returned by the handler's `init/1` callback
  at registration time.

  ## Return Values

  - List of `{handler_module, state}` tuples

  ## Examples

      iex> ParrotSip.CDR.list_handlers()
      [{MyApp.CDR.LoggerHandler, %{}}, {MyApp.CDR.DatabaseHandler, %{repo: MyApp.Repo}}]

  """
  @spec list_handlers() :: [{module(), term()}]
  def list_handlers do
    ensure_registry_started()

    Agent.get(@registry_name, fn handlers ->
      Map.to_list(handlers)
    end)
  end

  @doc """
  Clears all registered handlers.

  This is primarily useful for testing to reset state between tests.
  """
  @spec clear_handlers() :: :ok
  def clear_handlers do
    ensure_registry_started()
    Agent.update(@registry_name, fn _handlers -> %{} end)
    :ok
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  # Checks if a handler is already registered
  defp handler_registered?(handler_module) do
    Agent.get(@registry_name, fn handlers ->
      Map.has_key?(handlers, handler_module)
    end)
  end

  # Ensures the registry agent is started
  # If not started, starts it (useful for testing without supervision tree)
  defp ensure_registry_started do
    case Process.whereis(@registry_name) do
      nil ->
        # Start the registry if not already running
        {:ok, _pid} = start_link()
        :ok

      _pid ->
        :ok
    end
  end
end
