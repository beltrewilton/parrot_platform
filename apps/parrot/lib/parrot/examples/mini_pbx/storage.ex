defmodule Parrot.Examples.MiniPBX.Storage do
  @moduledoc """
  Mnesia-based storage for the Mini PBX example.

  Provides persistent, distributed storage for:
  - Registrations (AOR -> Contact mappings)
  - Voicemail messages
  - Call logs (optional)

  ## Why Mnesia?

  Mnesia is Erlang's built-in distributed database, making it ideal for telecom:
  - **Persistence** - Survives node restarts (with disc_copies)
  - **Distribution** - Replicates across cluster nodes
  - **Transactions** - ACID guarantees for concurrent access
  - **Real-time** - Low latency for telecom workloads

  ## Example

      # Start storage (creates tables if needed)
      {:ok, _pid} = Storage.start_link()

      # Register an extension
      :ok = Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)

      # Lookup extension
      {:ok, contact} = Storage.lookup_extension("1001")

  ## Storage Mode

  By default, tables use `ram_copies` (in-memory, lost on restart).
  For persistence, configure with `disc_copies`:

      Storage.start_link(storage_mode: :disc_copies)

  Note: disc_copies requires Mnesia schema to be created on disk first:

      :mnesia.create_schema([node()])
  """

  use GenServer
  require Logger

  alias Parrot.Examples.MiniPBX.Config

  # Mnesia table names
  @registrations_table :mini_pbx_registrations
  @voicemail_table :mini_pbx_voicemail
  @presence_table :mini_pbx_presence
  @subscriptions_table :mini_pbx_subscriptions

  # Record definitions for Mnesia tables
  # Registration: {aor, contact, expires, registered_at}
  # Voicemail: {id, extension, from, file_path, timestamp, read}
  # Presence: {presentity, status, note, updated_at}
  # Subscription: {id, watcher, presentity, dialog_id, expires, created_at}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the storage GenServer and initializes Mnesia tables.

  ## Options

  - `:storage_mode` - `:ram_copies` (default) or `:disc_copies` for persistence
  - `:nodes` - List of nodes for distributed tables (default: [node()])
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the storage GenServer.
  """
  def stop do
    GenServer.stop(__MODULE__)
  end

  # ----------------------------------------------------------------------------
  # Registration API
  # ----------------------------------------------------------------------------

  @doc """
  Registers a contact for an Address of Record (AOR).

  ## Parameters

  - `aor` - Address of Record (e.g., "sip:1001@pbx.local")
  - `contact` - Contact URI (e.g., "sip:1001@192.168.1.100:5060")
  - `expires` - Registration expiry in seconds

  ## Example

      :ok = Storage.register("sip:1001@pbx.local", "sip:1001@192.168.1.100:5060", 3600)
  """
  @spec register(String.t(), String.t(), non_neg_integer()) :: :ok
  def register(aor, contact, expires) do
    GenServer.call(__MODULE__, {:register, aor, contact, expires})
  end

  @doc """
  Removes a registration for a specific contact.
  """
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(aor, contact) do
    GenServer.call(__MODULE__, {:unregister, aor, contact})
  end

  @doc """
  Gets all registrations for an AOR.

  Returns a list of registration maps with contact, expires, and registered_at.
  """
  @spec get_registrations(String.t()) :: {:ok, list()}
  def get_registrations(aor) do
    GenServer.call(__MODULE__, {:get_registrations, aor})
  end

  @doc """
  Looks up a registered contact by extension number.

  ## Example

      {:ok, "sip:1001@192.168.1.100:5060"} = Storage.lookup_extension("1001")
  """
  @spec lookup_extension(String.t()) :: {:ok, String.t()} | {:error, :not_registered}
  def lookup_extension(extension) do
    aor = Config.extension_aor(extension)

    case get_registrations(aor) do
      {:ok, [first | _]} -> {:ok, first.contact}
      {:ok, []} -> {:error, :not_registered}
    end
  end

  # ----------------------------------------------------------------------------
  # Voicemail API
  # ----------------------------------------------------------------------------

  @doc """
  Stores a voicemail message for an extension.
  """
  @spec store_voicemail(String.t(), String.t(), String.t()) :: :ok
  def store_voicemail(extension, from, file_path) do
    GenServer.call(__MODULE__, {:store_voicemail, extension, from, file_path})
  end

  @doc """
  Gets all voicemail messages for an extension.
  """
  @spec get_voicemails(String.t()) :: {:ok, list()}
  def get_voicemails(extension) do
    GenServer.call(__MODULE__, {:get_voicemails, extension})
  end

  @doc """
  Marks a voicemail message as read.
  """
  @spec mark_voicemail_read(String.t(), String.t()) :: :ok
  def mark_voicemail_read(extension, message_id) do
    GenServer.call(__MODULE__, {:mark_voicemail_read, extension, message_id})
  end

  @doc """
  Deletes a voicemail message.
  """
  @spec delete_voicemail(String.t(), String.t()) :: :ok
  def delete_voicemail(extension, message_id) do
    GenServer.call(__MODULE__, {:delete_voicemail, extension, message_id})
  end

  # ----------------------------------------------------------------------------
  # Presence API
  # ----------------------------------------------------------------------------

  @doc """
  Gets the presence state for a presentity.

  Returns `:available`, `:busy`, `:dnd`, or `:offline`.
  """
  @spec get_presence_state(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_presence_state(presentity) do
    GenServer.call(__MODULE__, {:get_presence_state, presentity})
  end

  @doc """
  Sets the presence state for a presentity.
  """
  @spec set_presence_state(String.t(), atom()) :: :ok
  def set_presence_state(presentity, status) do
    GenServer.call(__MODULE__, {:set_presence_state, presentity, status})
  end

  # ----------------------------------------------------------------------------
  # Subscription API
  # ----------------------------------------------------------------------------

  @doc """
  Stores a presence subscription.

  ## Subscription Map Fields

  - `:watcher` - The SIP URI of the subscriber
  - `:presentity` - The SIP URI being watched
  - `:dialog_id` - The dialog ID for this subscription
  - `:expires` - Expiration time in seconds
  """
  @spec save_subscription(map()) :: :ok
  def save_subscription(subscription) do
    GenServer.call(__MODULE__, {:save_subscription, subscription})
  end

  @doc """
  Gets all subscriptions for a presentity.
  """
  @spec get_subscriptions(String.t()) :: [map()]
  def get_subscriptions(presentity) do
    GenServer.call(__MODULE__, {:get_subscriptions, presentity})
  end

  @doc """
  Removes a subscription.
  """
  @spec remove_subscription(String.t(), String.t()) :: :ok
  def remove_subscription(watcher, presentity) do
    GenServer.call(__MODULE__, {:remove_subscription, watcher, presentity})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    storage_mode = Keyword.get(opts, :storage_mode, :ram_copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    # Ensure Mnesia is started
    ensure_mnesia_started()

    # Create tables (idempotent - handles existing tables)
    create_tables(storage_mode, nodes)

    # Wait for tables to be ready
    :mnesia.wait_for_tables(
      [@registrations_table, @voicemail_table, @presence_table, @subscriptions_table],
      5000
    )

    Logger.debug("[MiniPBX.Storage] Started with Mnesia (#{storage_mode})")
    {:ok, %{storage_mode: storage_mode}}
  end

  @impl true
  def terminate(_reason, _state) do
    # Note: We don't delete Mnesia tables on terminate to preserve data
    # For test isolation, use clear_all/0 in test setup
    :ok
  end

  # ----------------------------------------------------------------------------
  # Registration Handlers
  # ----------------------------------------------------------------------------

  @impl true
  def handle_call({:register, aor, contact, expires}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        # Remove existing registration for this aor+contact combo
        existing = :mnesia.match_object({@registrations_table, aor, contact, :_, :_})

        for record <- existing do
          :mnesia.delete_object(record)
        end

        # Insert new registration
        :mnesia.write(
          {@registrations_table, aor, contact, expires, DateTime.utc_now()}
        )
      end)

    case result do
      {:atomic, _} ->
        {:reply, :ok, state}

      {:aborted, reason} ->
        Logger.error("[MiniPBX.Storage] Registration failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unregister, aor, contact}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        existing = :mnesia.match_object({@registrations_table, aor, contact, :_, :_})

        for record <- existing do
          :mnesia.delete_object(record)
        end
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_registrations, aor}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@registrations_table, aor, :_, :_, :_})
      end)

    case result do
      {:atomic, records} ->
        registrations =
          records
          |> Enum.map(fn {@registrations_table, _aor, contact, expires, registered_at} ->
            %{contact: contact, expires: expires, registered_at: registered_at}
          end)

        {:reply, {:ok, registrations}, state}

      {:aborted, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # ----------------------------------------------------------------------------
  # Voicemail Handlers
  # ----------------------------------------------------------------------------

  @impl true
  def handle_call({:store_voicemail, extension, from, file_path}, _from, state) do
    message_id = generate_message_id()
    timestamp = DateTime.utc_now()

    result =
      :mnesia.transaction(fn ->
        :mnesia.write(
          {@voicemail_table, message_id, extension, from, file_path, timestamp, false}
        )
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_voicemails, extension}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@voicemail_table, :_, extension, :_, :_, :_, :_})
      end)

    case result do
      {:atomic, records} ->
        messages =
          records
          |> Enum.map(fn {@voicemail_table, id, _ext, from, file_path, timestamp, read} ->
            %{id: id, from: from, file_path: file_path, timestamp: timestamp, read: read}
          end)
          |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

        {:reply, {:ok, messages}, state}

      {:aborted, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mark_voicemail_read, extension, message_id}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.match_object({@voicemail_table, message_id, extension, :_, :_, :_, :_}) do
          [{@voicemail_table, id, ext, from, file_path, timestamp, _read}] ->
            :mnesia.delete_object({@voicemail_table, id, ext, from, file_path, timestamp, false})
            :mnesia.write({@voicemail_table, id, ext, from, file_path, timestamp, true})

          [] ->
            :ok
        end
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_voicemail, extension, message_id}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.match_object({@voicemail_table, message_id, extension, :_, :_, :_, :_}) do
          [record] -> :mnesia.delete_object(record)
          [] -> :ok
        end
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ----------------------------------------------------------------------------
  # Presence Handlers
  # ----------------------------------------------------------------------------

  @impl true
  def handle_call({:get_presence_state, presentity}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        :mnesia.read({@presence_table, presentity})
      end)

    case result do
      {:atomic, [{@presence_table, ^presentity, status, _note, _updated_at}]} ->
        {:reply, {:ok, status}, state}

      {:atomic, []} ->
        {:reply, {:error, :not_found}, state}

      {:aborted, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_presence_state, presentity, status}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        :mnesia.write({@presence_table, presentity, status, nil, DateTime.utc_now()})
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # ----------------------------------------------------------------------------
  # Subscription Handlers
  # ----------------------------------------------------------------------------

  @impl true
  def handle_call({:save_subscription, subscription}, _from, state) do
    id = generate_subscription_id()
    watcher = subscription[:watcher]
    presentity = subscription[:presentity]
    dialog_id = subscription[:dialog_id]
    expires = subscription[:expires]

    result =
      :mnesia.transaction(fn ->
        # Remove any existing subscription for this watcher/presentity pair
        existing = :mnesia.match_object({@subscriptions_table, :_, watcher, presentity, :_, :_, :_})

        for record <- existing do
          :mnesia.delete_object(record)
        end

        # Insert new subscription
        :mnesia.write(
          {@subscriptions_table, id, watcher, presentity, dialog_id, expires, DateTime.utc_now()}
        )
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_subscriptions, presentity}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@subscriptions_table, :_, :_, presentity, :_, :_, :_})
      end)

    case result do
      {:atomic, records} ->
        subscriptions =
          Enum.map(records, fn {@subscriptions_table, _id, watcher, _pres, dialog_id, expires, _created} ->
            %{watcher: watcher, dialog_id: dialog_id, expires: expires}
          end)

        {:reply, subscriptions, state}

      {:aborted, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_subscription, watcher, presentity}, _from, state) do
    result =
      :mnesia.transaction(fn ->
        existing = :mnesia.match_object({@subscriptions_table, :_, watcher, presentity, :_, :_, :_})

        for record <- existing do
          :mnesia.delete_object(record)
        end
      end)

    case result do
      {:atomic, _} -> {:reply, :ok, state}
      {:aborted, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("[MiniPBX.Storage] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Table Management (for testing)
  # ============================================================================

  @doc """
  Clears all data from storage tables. Useful for test isolation.
  """
  def clear_all do
    :mnesia.clear_table(@registrations_table)
    :mnesia.clear_table(@voicemail_table)
    :mnesia.clear_table(@presence_table)
    :mnesia.clear_table(@subscriptions_table)
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp ensure_mnesia_started do
    case :mnesia.system_info(:is_running) do
      :yes -> :ok
      :no -> :mnesia.start()
      :starting -> wait_for_mnesia()
      :stopping -> wait_for_mnesia_stopped_then_start()
    end
  end

  defp wait_for_mnesia do
    Process.sleep(100)
    ensure_mnesia_started()
  end

  defp wait_for_mnesia_stopped_then_start do
    Process.sleep(100)
    ensure_mnesia_started()
  end

  defp create_tables(storage_mode, nodes) do
    # Create registrations table
    # Schema: {aor, contact, expires, registered_at}
    create_table(@registrations_table, [
      {:attributes, [:aor, :contact, :expires, :registered_at]},
      {:type, :bag},
      {storage_mode, nodes},
      {:index, [:contact]}
    ])

    # Create voicemail table
    # Schema: {id, extension, from, file_path, timestamp, read}
    create_table(@voicemail_table, [
      {:attributes, [:id, :extension, :from, :file_path, :timestamp, :read]},
      {:type, :set},
      {storage_mode, nodes},
      {:index, [:extension]}
    ])

    # Create presence table
    # Schema: {presentity, status, note, updated_at}
    create_table(@presence_table, [
      {:attributes, [:presentity, :status, :note, :updated_at]},
      {:type, :set},
      {storage_mode, nodes}
    ])

    # Create subscriptions table
    # Schema: {id, watcher, presentity, dialog_id, expires, created_at}
    create_table(@subscriptions_table, [
      {:attributes, [:id, :watcher, :presentity, :dialog_id, :expires, :created_at]},
      {:type, :set},
      {storage_mode, nodes},
      {:index, [:presentity, :watcher]}
    ])
  end

  defp create_table(name, opts) do
    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} ->
        Logger.debug("[MiniPBX.Storage] Created Mnesia table: #{name}")
        :ok

      {:aborted, {:already_exists, ^name}} ->
        Logger.debug("[MiniPBX.Storage] Mnesia table already exists: #{name}")
        :ok

      {:aborted, reason} ->
        Logger.error("[MiniPBX.Storage] Failed to create table #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp generate_message_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_subscription_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
