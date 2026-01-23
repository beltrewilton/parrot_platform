defmodule Parrot.Examples.Registrar do
  @moduledoc """
  A simple SIP registrar using the Parrot DSL layer.

  This example demonstrates how to build a SIP registrar server using the
  `Parrot.RegistrationHandler` behaviour for registration logic and
  `Parrot.Router` for request routing. Registrations are stored in ETS.

  ## Architecture Overview

  ```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │                         Parrot.Examples.Registrar                       │
  │                                                                         │
  │  ┌─────────────────┐   ┌────────────────┐   ┌─────────────────────────┐│
  │  │   TableOwner    │   │     Router     │   │        Handler          ││
  │  │   (GenServer)   │   │  (register/1)  │   │ (RegistrationHandler)   ││
  │  │                 │   │                │   │                         ││
  │  │  Owns ETS table │   │ Routes REGISTER│   │ - get_password/1        ││
  │  │  to prevent GC  │   │ to Handler     │   │ - authenticate/1        ││
  │  │                 │   │                │   │ - store_binding/3       ││
  │  │                 │   │                │   │ - get_bindings/1        ││
  │  │                 │   │                │   │ - handle_reg_expired/2  ││
  │  └─────────────────┘   └────────────────┘   └─────────────────────────┘│
  │                                 │                       │              │
  │                                 ▼                       ▼              │
  │                        ┌─────────────────┐    ┌─────────────────────┐  │
  │                        │ Parrot.Router   │    │     ETS Table       │  │
  │                        │  `register/1`   │    │ :named, :public     │  │
  │                        │    macro        │    │                     │  │
  │                        └─────────────────┘    └─────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────────┘
  ```

  ## ETS Storage Pattern

  Registrations are stored in an ETS table owned by a dedicated `TableOwner`
  GenServer. This pattern prevents the table from being garbage collected when
  the creating process exits.

  **Table Configuration:**
  - Name: `Parrot.Examples.Registrar` (same as module name)
  - Type: `:set` (one binding per AOR)
  - Access: `:public` (readable/writable by any process)
  - Owned by: `TableOwner` GenServer

  **Schema:**
  ```elixir
  {aor, %{contact: contact_uri, expires: seconds, registered_at: unix_timestamp}}
  ```

  For production, consider:
  - Using `:bag` for multiple contacts per AOR
  - Adding TTL tracking with `ExpiryManager`
  - Persistence to database (Mnesia, Postgres, Redis)

  ## Handler Callbacks

  The `Handler` module implements `Parrot.RegistrationHandler` with these callbacks:

  | Callback | Purpose | This Example |
  |----------|---------|--------------|
  | `get_password/1` | Lookup user's password for digest auth | Returns `""` (no auth) |
  | `authenticate/1` | Validate credentials after digest check | Returns `:ok` (accept all) |
  | `store_binding/3` | Store or update a registration binding | Inserts into ETS |
  | `get_bindings/1` | Retrieve current bindings for an AOR | Lookups from ETS |
  | `handle_registration_expired/2` | Called when registration expires | Deletes from ETS |

  ## Router Configuration

  The `Router` module uses `Parrot.Router` with the `register/1` macro:

  ```elixir
  defmodule Router do
    use Parrot.Router
    register(Parrot.Examples.Registrar.Handler)
  end
  ```

  This routes all REGISTER requests to the specified handler. For combined
  registration and presence, add:

  ```elixir
  defmodule Router do
    use Parrot.Router
    register(MyRegistrationHandler)
    presence(MyPresenceHandler)
  end
  ```

  ## Running the Example

  ```bash
  # Using the dev script
  mix run scripts/dev/test_registrar.exs

  # Or start programmatically
  iex> {:ok, stack} = Parrot.Examples.Registrar.start(port: 5080)
  ```

  ## Testing with pjsua

  ```bash
  pjsua --null-audio --no-tcp --local-port=5090 \\
    --id="sip:alice@127.0.0.1" \\
    --registrar="sip:127.0.0.1:15062" \\
    --realm="*" --username="alice" --password="any"
  ```

  ## Inspecting Registrations

  ```elixir
  # List all registrations
  Parrot.Examples.Registrar.list_registrations()

  # Lookup specific AOR
  Parrot.Examples.Registrar.lookup("sip:alice@127.0.0.1")
  ```

  ## Extending for Production

  ### Adding Digest Authentication

  ```elixir
  defmodule MyHandler do
    use Parrot.RegistrationHandler

    @impl true
    def get_password(username) do
      case MyUserDB.get_password(username) do
        nil -> :error
        password -> {:ok, password}
      end
    end

    @impl true
    def authenticate(%{username: username}) do
      if MyUserDB.is_active?(username), do: :ok, else: :error
    end
  end
  ```

  ### Integrating with Presence

  ```elixir
  @impl true
  def store_binding(aor, contact, expires) do
    # Store the binding
    :ets.insert(:registrations, {aor, contact, expires})

    # Update presence state
    if expires > 0 do
      Parrot.Presence.notify(aor, %{status: :open, note: "Available"})
    else
      Parrot.Presence.notify(aor, %{status: :closed, note: "Offline"})
    end

    :ok
  end
  ```

  ### Database Persistence

  ```elixir
  @impl true
  def store_binding(aor, contact, expires) do
    Repo.insert_or_update!(%Registration{
      aor: aor,
      contact: contact,
      expires: expires,
      expires_at: DateTime.add(DateTime.utc_now(), expires)
    })
    :ok
  end
  ```

  ## SIP Flow

  ```
  Client                        Registrar
    |                               |
    |------ REGISTER (no auth) ---->|
    |                               |
    |<---- 401 Unauthorized --------|  (WWW-Authenticate challenge)
    |                               |
    |-- REGISTER (with auth) ------>|
    |                               |  get_password() -> validate digest
    |                               |  authenticate() -> accept user
    |                               |  store_binding() -> save to ETS
    |<-------- 200 OK --------------|  (Contact: with expires)
    |                               |
  ```

  ## RFC References

  - RFC 3261 Section 10: Registrations
  - RFC 3261 Section 22: Authentication (Digest)
  - RFC 3665 Section 2: Registration Flows
  """

  require Logger

  # ============================================================================
  # ETS Table Owner - Holds the ETS table to prevent it from being garbage collected
  # ============================================================================

  defmodule TableOwner do
    @moduledoc false
    use GenServer

    def start_link(table_name) do
      GenServer.start_link(__MODULE__, table_name, name: __MODULE__)
    end

    @impl true
    def init(table_name) do
      # Create ETS table owned by this GenServer
      :ets.new(table_name, [:named_table, :public, :set])
      {:ok, table_name}
    end
  end

  # ============================================================================
  # Registration Handler - Implements Parrot.RegistrationHandler callbacks
  # ============================================================================

  defmodule Handler do
    @moduledoc """
    Registration handler that stores bindings in ETS.
    """
    use Parrot.RegistrationHandler

    require Logger

    @impl Parrot.RegistrationHandler
    def get_password(_username) do
      # No authentication required for this simple registrar
      # Return a dummy password that will always validate
      {:ok, ""}
    end

    @impl Parrot.RegistrationHandler
    def authenticate(_credentials) do
      # Accept all registrations without authentication
      :ok
    end

    @impl Parrot.RegistrationHandler
    def store_binding(aor, contact, expires) do
      Logger.info(
        "[Registrar.Handler] Storing binding #{aor} -> #{contact} (expires: #{expires}s)"
      )

      binding = %{
        contact: contact,
        expires: expires,
        registered_at: System.system_time(:second)
      }

      :ets.insert(Parrot.Examples.Registrar, {aor, binding})
      :ok
    end

    @impl Parrot.RegistrationHandler
    def get_bindings(aor) do
      # Return richer binding data per RFC 3261 Section 10.3
      # The response MUST include Contact headers with expires parameter
      # Optional q-value for Contact priority (RFC 3261 Section 10.2.1.2)
      case :ets.lookup(Parrot.Examples.Registrar, aor) do
        [{^aor, binding}] ->
          # Return binding as-is (may include optional :q field if stored)
          [binding]

        [] ->
          []
      end
    end

    @impl Parrot.RegistrationHandler
    def handle_registration_expired(aor, contact) do
      Logger.info("[Registrar.Handler] Registration expired: #{aor} -> #{contact}")
      :ets.delete(Parrot.Examples.Registrar, aor)
      :ok
    end
  end

  # ============================================================================
  # Router - Routes REGISTER requests to our handler
  # ============================================================================

  defmodule Router do
    @moduledoc """
    Router that handles REGISTER requests.
    """
    use Parrot.Router

    register(Parrot.Examples.Registrar.Handler)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the Registrar server.

  ## Options
    - `:port` - UDP port to listen on (default: 15062)
    - `:auth` - Whether to require authentication (default: false)

  ## Returns

    - `{:ok, stack}` - Stack struct with listener, handler, and port info
    - `{:error, reason}` - Startup failed

  ## Examples

      {:ok, stack} = Registrar.start(port: 0)
      # stack.port contains the actual bound port
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 15062)
    _auth = Keyword.get(opts, :auth, false)

    # Start the TableOwner GenServer to own the ETS table
    # This ensures the table persists as long as the registrar is running
    case TableOwner.start_link(__MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Create a ParrotSip.Handler that uses Bridge.Handler with our router
    handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: Router})

    # Start the SIP stack
    case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: port) do
      {:ok, stack} ->
        actual_port = ParrotSip.Stack.get_port(stack)
        Logger.info("[Registrar] Started on port #{actual_port}")
        {:ok, stack}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List all current registrations"
  def list_registrations do
    :ets.tab2list(__MODULE__)
  end

  @doc "Lookup a specific registration"
  def lookup(aor) do
    case :ets.lookup(__MODULE__, aor) do
      [{^aor, binding}] -> {:ok, binding}
      [] -> :not_found
    end
  end
end
