# Registration + Presence integration server demonstrating:
# - Parrot.RegistrationHandler for digest authentication
# - Parrot.PresenceHandler for presence state and subscriptions
# - Registration events triggering presence notifications
#
# Run with: SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_registrar_presence.exs
#
# Features:
# - Digest authentication with hardcoded users
# - ETS-based binding and subscription storage
# - When user registers → presence becomes :open ("Available")
# - When user unregisters/expires → presence becomes :closed ("Offline")
# - Subscribers receive NOTIFY on presence changes
#
# Test users:
#   alice / secret123
#   bob   / secret456

require Logger

# ============================================================================
# ETS Table Owner - Prevents ETS tables from being garbage collected
# ============================================================================

defmodule DevRegistrarPresence.TableOwner do
  @moduledoc false
  use GenServer

  def start_link(tables) when is_list(tables) do
    GenServer.start_link(__MODULE__, tables, name: __MODULE__)
  end

  @impl true
  def init(tables) do
    Enum.each(tables, fn {name, type} ->
      :ets.new(name, [:named_table, :public, type])
    end)

    {:ok, tables}
  end
end

# ============================================================================
# Registration Handler - Implements Parrot.RegistrationHandler callbacks
# with presence notification integration
# ============================================================================

defmodule DevRegistrarPresence.RegistrationHandler do
  @moduledoc """
  Registration handler with digest authentication and presence integration.

  When a user registers, their presence state is set to :open (Available).
  When a user unregisters or their registration expires, presence becomes :closed (Offline).

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
    Logger.info("[RegistrationHandler] Looking up password for user: #{username}")

    case Map.get(@users, username) do
      nil ->
        Logger.warning("[RegistrationHandler] Unknown user: #{username}")
        :error

      password ->
        Logger.debug("[RegistrationHandler] Found password for user: #{username}")
        {:ok, password}
    end
  end

  @impl Parrot.RegistrationHandler
  def authenticate(credentials) do
    Logger.info("[RegistrationHandler] Authenticating user: #{inspect(credentials.username)}")
    # Additional authentication logic could go here
    # For now, we accept all users that passed digest validation
    :ok
  end

  @impl Parrot.RegistrationHandler
  def store_binding(aor, contact, expires) do
    if expires > 0 do
      Logger.info(
        "[RegistrationHandler] Storing binding: #{aor} -> #{contact} (expires: #{expires}s)"
      )

      binding = %{
        contact: contact,
        expires: expires,
        registered_at: System.system_time(:second)
      }

      :ets.insert(:dev_registrations, {aor, binding})

      # Update presence state and store it
      :ets.insert(:dev_presence_state, {aor, :open, "Available"})

      # Notify presence subscribers that user is now available
      # Uses fire-and-forget async notification
      Logger.info("[RegistrationHandler] Notifying presence: #{aor} is now Available")
      Parrot.Presence.notify(aor, %{status: :open, note: "Available"})
    else
      Logger.info("[RegistrationHandler] Removing binding: #{aor} -> #{contact}")
      :ets.delete(:dev_registrations, aor)

      # Update presence state
      :ets.insert(:dev_presence_state, {aor, :closed, "Offline"})

      # Notify presence subscribers that user is now offline
      Logger.info("[RegistrationHandler] Notifying presence: #{aor} is now Offline")
      Parrot.Presence.notify(aor, %{status: :closed, note: "Offline"})
    end

    :ok
  end

  @impl Parrot.RegistrationHandler
  def get_bindings(aor) do
    case :ets.lookup(:dev_registrations, aor) do
      [{^aor, binding}] ->
        Logger.debug("[RegistrationHandler] Found binding for #{aor}: #{inspect(binding)}")
        [binding]

      [] ->
        Logger.debug("[RegistrationHandler] No bindings found for #{aor}")
        []
    end
  end

  @impl Parrot.RegistrationHandler
  def handle_registration_expired(aor, contact) do
    Logger.info("[RegistrationHandler] Registration expired: #{aor} -> #{contact}")
    :ets.delete(:dev_registrations, aor)

    # Update presence state
    :ets.insert(:dev_presence_state, {aor, :closed, "Offline"})

    # Notify presence subscribers that user is now offline
    Logger.info("[RegistrationHandler] Notifying presence: #{aor} is now Offline (expired)")
    Parrot.Presence.notify(aor, %{status: :closed, note: "Offline"})

    :ok
  end
end

# ============================================================================
# Presence Handler - Implements Parrot.PresenceHandler callbacks
# ============================================================================

defmodule DevRegistrarPresence.PresenceHandler do
  @moduledoc """
  Presence handler with ETS-based subscription and state storage.

  Supports:
  - SUBSCRIBE requests from watchers
  - PUBLISH requests from presentities
  - NOTIFY delivery to subscribers
  """
  use Parrot.PresenceHandler

  require Logger

  @impl Parrot.PresenceHandler
  def authorize_subscription(watcher, presentity) do
    Logger.info(
      "[PresenceHandler] Authorization request: #{watcher} wants to watch #{presentity}"
    )

    # Allow all subscriptions for this demo
    # In production, you'd check ACLs, buddy lists, etc.
    :allow
  end

  @impl Parrot.PresenceHandler
  def store_subscription(sub) do
    Logger.info(
      "[PresenceHandler] Storing subscription: #{sub.watcher} watching #{sub.presentity}"
    )

    Logger.debug("[PresenceHandler] Subscription details: #{inspect(sub)}")

    # Store subscription in ETS
    # Using :bag table type allows multiple watchers per presentity
    :ets.insert(
      :dev_subscriptions,
      {sub.subscription_id, sub.watcher, sub.presentity, sub.dialog_id, sub.expires}
    )

    :ok
  end

  @impl Parrot.PresenceHandler
  def get_subscriptions(presentity) do
    Logger.debug("[PresenceHandler] Looking up subscriptions for: #{presentity}")

    # Match all subscriptions where the presentity matches
    # ETS pattern: {subscription_id, watcher, presentity, dialog_id, expires}
    subscriptions =
      :ets.match_object(:dev_subscriptions, {:_, :_, presentity, :_, :_})
      |> Enum.map(fn {id, watcher, _presentity, dialog_id, expires} ->
        %{
          subscription_id: id,
          watcher: watcher,
          dialog_id: dialog_id,
          expires: expires
        }
      end)

    Logger.debug(
      "[PresenceHandler] Found #{length(subscriptions)} subscriptions for #{presentity}"
    )

    subscriptions
  end

  @impl Parrot.PresenceHandler
  def get_presence(presentity) do
    Logger.debug("[PresenceHandler] Looking up presence for: #{presentity}")

    case :ets.lookup(:dev_presence_state, presentity) do
      [{^presentity, status, note}] ->
        Logger.debug("[PresenceHandler] Found presence: #{status} - #{note}")
        %{status: status, note: note}

      [] ->
        Logger.debug("[PresenceHandler] No presence found, defaulting to closed/Unknown")
        %{status: :closed, note: "Unknown"}
    end
  end

  @impl Parrot.PresenceHandler
  def handle_publish(presentity, state) do
    Logger.info("[PresenceHandler] PUBLISH from #{presentity}: #{inspect(state)}")

    # Store the published presence state
    status = Map.get(state, :status, :closed)
    note = Map.get(state, :note, "")
    :ets.insert(:dev_presence_state, {presentity, status, note})

    :ok
  end
end

# ============================================================================
# Router - Routes requests to appropriate handlers
# ============================================================================

defmodule DevRegistrarPresence.Router do
  @moduledoc false
  use Parrot.Router

  register(DevRegistrarPresence.RegistrationHandler)
  presence(DevRegistrarPresence.PresenceHandler)
end

# ============================================================================
# Startup
# ============================================================================

IO.puts("""
================================================================================
Parrot Registrar + Presence Test Server
================================================================================

Starting server with:
- Digest authentication
- Registration binding storage (ETS)
- Presence subscription management (ETS)
- Automatic presence updates on register/unregister

Test Users:
  - alice / secret123
  - bob   / secret456

""")

# Start the ETS table owner with all required tables
tables = [
  # Registration bindings: {aor, binding_map}
  {:dev_registrations, :set},
  # Presence subscriptions: {subscription_id, watcher, presentity, dialog_id, expires}
  # Using :bag allows multiple watchers per presentity
  {:dev_subscriptions, :bag},
  # Presence state: {presentity, status, note}
  {:dev_presence_state, :set}
]

case DevRegistrarPresence.TableOwner.start_link(tables) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Start Task.Supervisor for async presence notifications
# This is needed because Parrot.Presence.notify/2 uses Task.Supervisor
case Task.Supervisor.start_link(name: Parrot.TaskSupervisor) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Set the router in application env so Parrot.Presence.notify/2 can find the handler
Application.put_env(:parrot, :router, DevRegistrarPresence.Router)

# Create the handler and start the SIP stack
handler = ParrotSip.Handler.new(Parrot.Bridge.Handler, %{router: DevRegistrarPresence.Router})

case ParrotSip.Stack.start_link(handler: handler, transport: :udp, port: 5080) do
  {:ok, stack} ->
    port = ParrotSip.Stack.get_port(stack)

    IO.puts("""
    Server listening on port #{port}

    ================================================================================
    Testing with pjsua
    ================================================================================

    TERMINAL 1 - Start Alice (will register):
    --------------------------------------------------------------------------------
    pjsua --null-audio --no-tcp --local-port=5090 \\
      --log-file=/tmp/pjsua_alice.log --log-level=5 \\
      --id="sip:alice@127.0.0.1" \\
      --registrar="sip:127.0.0.1:#{port}" \\
      --realm="*" --username="alice" --password="secret123"

    TERMINAL 2 - Start Bob (will register and subscribe to Alice):
    --------------------------------------------------------------------------------
    pjsua --null-audio --no-tcp --local-port=5091 \\
      --log-file=/tmp/pjsua_bob.log --log-level=5 \\
      --id="sip:bob@127.0.0.1" \\
      --registrar="sip:127.0.0.1:#{port}" \\
      --realm="*" --username="bob" --password="secret456"

    ================================================================================
    Presence Testing Steps (in Bob's pjsua console)
    ================================================================================

    1. Add Alice as a buddy:
       >>> +b sip:alice@127.0.0.1

    2. Subscribe to Alice's presence:
       >>> s
       (Bob should receive NOTIFY with Alice's current status)

    3. In Alice's pjsua console, unregister:
       >>> ru
       (Bob should receive NOTIFY showing Alice as "Offline")

    4. In Alice's pjsua console, re-register:
       >>> rr
       (Bob should receive NOTIFY showing Alice as "Available")

    ================================================================================
    Expected SIP Flow
    ================================================================================

    Registration Flow:
    1. Client sends REGISTER (no credentials)
    2. Server responds 401 Unauthorized with WWW-Authenticate challenge
    3. Client sends REGISTER with Authorization header
    4. Server validates credentials, sends 200 OK
    5. Server triggers presence NOTIFY to subscribers (if any)

    Presence Subscription Flow:
    1. Bob sends SUBSCRIBE for alice@127.0.0.1
    2. Server authorizes and responds 200 OK
    3. Server sends initial NOTIFY with Alice's current state
    4. When Alice's registration changes, server sends NOTIFY updates

    ================================================================================
    Log Files
    ================================================================================

    - Server: Check terminal output (use LOG_LEVEL=debug for more detail)
    - Alice:  /tmp/pjsua_alice.log
    - Bob:    /tmp/pjsua_bob.log

    Press Ctrl+C to stop
    """)

    Process.sleep(:infinity)

  {:error, reason} ->
    IO.puts("Failed to start server: #{inspect(reason)}")
    System.halt(1)
end
