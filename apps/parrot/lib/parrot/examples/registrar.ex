defmodule Parrot.Examples.Registrar do
  @moduledoc """
  A simple SIP registrar using the Parrot DSL layer.

  Uses `Parrot.RegistrationHandler` behaviour for registration logic and
  `Parrot.Router` for routing REGISTER requests. Stores registrations
  in ETS.

  ## Running the Example

      mix run test_registrar.exs

  ## Testing

      gophone register -username=alice sip:127.0.0.1:15062

  ## What It Does

  1. Accepts REGISTER requests (routed through Parrot.Router)
  2. Stores registrations in memory (ETS)
  3. Returns 200 OK with Contact headers
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
