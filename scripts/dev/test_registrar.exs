# Registrar test server demonstrating Parrot.RegistrationHandler behaviour
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_registrar.exs
#
# Features:
# - Digest authentication with hardcoded users
# - ETS-based binding storage
# - Shows 401 challenge -> credentials -> 200 OK flow
#
# Test users:
#   alice / secret123
#   bob   / secret456

require Logger

# ============================================================================
# ETS Table Owner - Prevents ETS table from being garbage collected
# ============================================================================

defmodule DevRegistrar.TableOwner do
  @moduledoc false
  use GenServer

  def start_link(table_name) do
    GenServer.start_link(__MODULE__, table_name, name: __MODULE__)
  end

  @impl true
  def init(table_name) do
    :ets.new(table_name, [:named_table, :public, :set])
    {:ok, table_name}
  end
end

# ============================================================================
# Registration Handler - Implements Parrot.RegistrationHandler callbacks
# ============================================================================

defmodule DevRegistrar.Handler do
  @moduledoc """
  Registration handler with digest authentication.

  Hardcoded users for testing:
    - alice / secret123
    - bob   / secret456
  """
  use Parrot.RegistrationHandler

  require Logger

  @users %{
    "alice" => "secret123",
    "bob" => "secret456"
  }

  @impl Parrot.RegistrationHandler
  def get_password(username) do
    Logger.info("[DevRegistrar] Looking up password for user: #{username}")

    case Map.get(@users, username) do
      nil ->
        Logger.warning("[DevRegistrar] Unknown user: #{username}")
        :error

      password ->
        Logger.debug("[DevRegistrar] Found password for user: #{username}")
        {:ok, password}
    end
  end

  @impl Parrot.RegistrationHandler
  def authenticate(credentials) do
    Logger.info("[DevRegistrar] Authenticating user: #{inspect(credentials.username)}")
    # Additional authentication logic could go here
    # For now, we accept all users that passed digest validation
    :ok
  end

  @impl Parrot.RegistrationHandler
  def store_binding(aor, contact, expires) do
    if expires > 0 do
      Logger.info("[DevRegistrar] Storing binding: #{aor} -> #{contact} (expires: #{expires}s)")

      binding = %{
        contact: contact,
        expires: expires,
        registered_at: System.system_time(:second)
      }

      :ets.insert(:dev_registrations, {aor, binding})
    else
      Logger.info("[DevRegistrar] Removing binding: #{aor} -> #{contact}")
      :ets.delete(:dev_registrations, aor)
    end

    :ok
  end

  @impl Parrot.RegistrationHandler
  def get_bindings(aor) do
    case :ets.lookup(:dev_registrations, aor) do
      [{^aor, binding}] ->
        Logger.debug("[DevRegistrar] Found binding for #{aor}: #{inspect(binding)}")
        [binding]

      [] ->
        Logger.debug("[DevRegistrar] No bindings found for #{aor}")
        []
    end
  end

  @impl Parrot.RegistrationHandler
  def handle_registration_expired(aor, contact) do
    Logger.info("[DevRegistrar] Registration expired: #{aor} -> #{contact}")
    :ets.delete(:dev_registrations, aor)
    :ok
  end
end

# ============================================================================
# Router - Routes REGISTER requests to our handler
# ============================================================================

defmodule DevRegistrar.Router do
  @moduledoc false
  use Parrot.Router

  register(DevRegistrar.Handler)
end

# ============================================================================
# Startup
# ============================================================================

IO.puts("""
================================================================================
Parrot Registrar Test Server
================================================================================

Starting registrar with digest authentication...

Test Users:
  - alice / secret123
  - bob   / secret456

""")

# Start the ETS table owner
case DevRegistrar.TableOwner.start_link(:dev_registrations) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Create the handler and start the SIP stack
handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: DevRegistrar.Router})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)

    IO.puts("""
    Server listening on port #{port}

    --------------------------------------------------------------------------------
    Testing with pjsua:
    --------------------------------------------------------------------------------

    1. Register alice:
       pjsua --id sip:alice@127.0.0.1 --registrar sip:127.0.0.1:#{port} \\
             --realm "*" --username alice --password secret123

    2. Register bob:
       pjsua --id sip:bob@127.0.0.1 --registrar sip:127.0.0.1:#{port} \\
             --realm "*" --username bob --password secret456

    --------------------------------------------------------------------------------
    Testing with SIPp:
    --------------------------------------------------------------------------------

    sipp -sf test/sipp/scenarios/register_auth.xml 127.0.0.1:#{port} \\
         -m 1 -l 1 -trace_msg

    --------------------------------------------------------------------------------
    Expected Flow:
    --------------------------------------------------------------------------------

    1. Client sends REGISTER (no credentials)
    2. Server responds 401 Unauthorized with WWW-Authenticate challenge
    3. Client sends REGISTER with Authorization header (digest credentials)
    4. Server validates credentials and responds 200 OK

    Press Ctrl+C to stop
    """)

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
