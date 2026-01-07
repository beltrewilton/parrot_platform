defmodule Parrot.RegistrationHandler do
  @moduledoc """
  Behaviour for handling SIP REGISTER requests in Parrot VoIP applications.

  The RegistrationHandler provides callbacks for authentication and registration
  storage. The framework handles all SIP mechanics (401 challenge/response,
  expiry management, 200 OK response building) - you just provide the decisions
  and storage logic.

  ## Usage

  Use `use Parrot.RegistrationHandler` in your module to get default implementations
  of all callbacks:

      defmodule MyApp.RegistrationHandler do
        use Parrot.RegistrationHandler

        def authenticate(%{username: username, password: password}) do
          case MyDB.check_password(username, password) do
            :ok -> :ok
            :error -> :error
          end
        end

        def store_binding(aor, contact, expires) do
          MyDB.save_registration(aor, contact, expires)
          :ok
        end

        def get_bindings(aor) do
          MyDB.get_contacts(aor)
        end

        def handle_registration_expired(aor) do
          Parrot.Presence.notify(aor, %{status: :offline})
          :ok
        end
      end

  ## Callbacks

  ### Required Callbacks

  All callbacks have default implementations, but you should override at least
  `authenticate/1` and `store_binding/3` for a functional registrar:

  - `authenticate/1` - Validate user credentials
  - `store_binding/3` - Store a registration binding
  - `get_bindings/1` - Retrieve current contacts for an AOR
  - `handle_registration_expired/1` - Called when a registration expires

  ## Registration Flow

  1. REGISTER received by framework
  2. Framework calls `authenticate/1` with credentials
  3. If `:ok`, framework calls `store_binding/3` for each contact
  4. Framework builds 200 OK with contacts from `get_bindings/1`
  5. If `:error`, framework sends 401/403 response

  ## Expires Handling

  - `expires > 0`: Normal registration, store the binding
  - `expires == 0`: Unregister request, remove the binding
  - When timer fires: `handle_registration_expired/1` is called

  ## Multiple Contacts

  A single AOR (Address of Record) like `sip:alice@example.com` can have
  multiple Contact bindings (different devices). The `get_bindings/1` callback
  should return all active contacts for the AOR.
  """

  @doc """
  Authenticate user credentials for registration.

  Called when a REGISTER request is received with credentials (either in
  the initial request or in response to a 401 challenge).

  ## Arguments

  - `credentials` - A map containing:
    - `:username` - The username from the Authorization header
    - `:password` - The password (after digest validation by framework)
    - `:realm` - The authentication realm
    - `:nonce` - The nonce value (for replay prevention)

  ## Return Values

  - `:ok` - Authentication successful, proceed with registration
  - `:error` - Authentication failed, framework will send 403 Forbidden

  ## Example

      def authenticate(%{username: username, password: password}) do
        case MyDB.check_password(username, password) do
          :ok -> :ok
          :error -> :error
        end
      end
  """
  @callback authenticate(credentials :: map()) :: :ok | :error

  @doc """
  Store a registration binding.

  Called after successful authentication to store or update a Contact
  binding for an Address of Record (AOR).

  ## Arguments

  - `aor` - The Address of Record (e.g., "sip:alice@example.com")
  - `contact` - The Contact URI where the user can be reached
  - `expires` - Time in seconds until the binding expires (0 = unregister)

  ## Return Values

  - `:ok` - Binding stored/updated successfully
  - `{:error, reason}` - Storage failed

  ## Expiry Handling

  When `expires` is 0, this indicates an unregister request. The handler
  should remove the binding for this contact.

  ## Example

      def store_binding(aor, contact, expires) do
        if expires > 0 do
          MyDB.save_registration(aor, contact, expires)
        else
          MyDB.remove_registration(aor, contact)
        end
        :ok
      end
  """
  @callback store_binding(aor :: String.t(), contact :: String.t(), expires :: non_neg_integer()) ::
              :ok | {:error, term()}

  @doc """
  Retrieve current contact bindings for an AOR.

  Called when building the 200 OK response to return all current
  registrations for the Address of Record.

  ## Arguments

  - `aor` - The Address of Record to look up

  ## Return Value

  A list of contact URIs currently registered for this AOR.
  Return an empty list if no bindings exist.

  ## Example

      def get_bindings(aor) do
        MyDB.get_contacts(aor)
        # Returns: ["sip:alice@192.168.1.100:5060", "sip:alice@192.168.1.101:5060"]
      end
  """
  @callback get_bindings(aor :: String.t()) :: [String.t()]

  @doc """
  Handle registration expiration.

  Called when a registration binding expires (timer fires). Use this
  to update presence, clean up resources, or notify other systems.

  ## Arguments

  - `aor` - The Address of Record that expired

  ## Return Value

  - `:ok` - Expiration handled

  ## Example

      def handle_registration_expired(aor) do
        Parrot.Presence.notify(aor, %{status: :offline})
        Logger.info("Registration expired for \#{aor}")
        :ok
      end
  """
  @callback handle_registration_expired(aor :: String.t()) :: :ok

  @doc """
  Provides default implementations for all callbacks.

  When you `use Parrot.RegistrationHandler`, you get:

  1. Default implementations of all callbacks
  2. The `@behaviour Parrot.RegistrationHandler` annotation

  Override any callback by defining it in your module.

  ## Default Implementations

  - `authenticate/1` - Returns `:error` (rejects all)
  - `store_binding/3` - Returns `:ok` (no-op)
  - `get_bindings/1` - Returns `[]` (empty)
  - `handle_registration_expired/1` - Returns `:ok` (no-op)
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.RegistrationHandler

      @impl Parrot.RegistrationHandler
      def authenticate(_credentials) do
        :error
      end

      @impl Parrot.RegistrationHandler
      def store_binding(_aor, _contact, _expires) do
        :ok
      end

      @impl Parrot.RegistrationHandler
      def get_bindings(_aor) do
        []
      end

      @impl Parrot.RegistrationHandler
      def handle_registration_expired(_aor) do
        :ok
      end

      defoverridable authenticate: 1,
                     store_binding: 3,
                     get_bindings: 1,
                     handle_registration_expired: 1
    end
  end
end
