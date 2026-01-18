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

        def get_password("alice"), do: {:ok, "alices_password"}
        def get_password("bob"), do: {:ok, "bobs_password"}
        def get_password(_), do: :error

        def store_binding(aor, contact, expires) do
          MyDB.save_registration(aor, contact, expires)
          :ok
        end

        def get_bindings(aor) do
          # Return rich binding data with contact, expires, registered_at
          # Optional q-value for Contact priority (RFC 3261 Section 10.2.1.2)
          MyDB.get_contacts(aor)
          # Returns: [%{contact: "sip:...", expires: 3600, registered_at: timestamp, q: 1.0}, ...]
        end

        def handle_registration_expired(aor, contact) do
          Logger.info("Contact \#{contact} expired for \#{aor}")
          Parrot.Presence.notify(aor, %{status: :offline})
          :ok
        end
      end

  ## Callbacks

  ### Required Callbacks

  All callbacks have default implementations, but you should override at least
  `get_password/1` and `store_binding/3` for a functional registrar:

  - `get_password/1` - Return password for digest authentication
  - `authenticate/1` - Additional authentication logic (optional)
  - `store_binding/3` - Store a registration binding
  - `get_bindings/1` - Retrieve current contacts for an AOR
  - `handle_registration_expired/2` - Called when a registration expires

  ## Registration Flow

  1. REGISTER received without Authorization - framework sends 401 challenge
  2. REGISTER received with Authorization header:
     a. Framework extracts credentials and validates nonce
     b. Framework calls `get_password/1` to retrieve user's password
     c. Framework validates digest response using the password
     d. Framework calls `authenticate/1` for additional checks
  3. If authentication succeeds, framework calls `store_binding/3`
  4. Framework builds 200 OK with contacts from `get_bindings/1`
  5. If authentication fails, framework sends 403 Forbidden

  ## Expires Handling

  - `expires > 0`: Normal registration, store the binding
  - `expires == 0`: Unregister request, remove the binding
  - When timer fires: `handle_registration_expired/2` is called

  ## Multiple Contacts

  A single AOR (Address of Record) like `sip:alice@example.com` can have
  multiple Contact bindings (different devices). The `get_bindings/1` callback
  should return all active contacts for the AOR.
  """

  @doc """
  Retrieve the password for a username.

  Called by the framework to get the password for digest authentication
  validation. The framework uses this password to verify the digest
  response from the client.

  ## Arguments

  - `username` - The username from the Authorization header

  ## Return Values

  - `{:ok, password}` - Return the password for this user
  - `:error` - Unknown user, will result in 403 Forbidden

  ## Example

      def get_password(username) do
        case MyDB.get_user(username) do
          %User{password: password} -> {:ok, password}
          nil -> :error
        end
      end

  ## Security Note

  The password should be stored securely. For production systems,
  consider using password hashing with HA1 pre-computation:
  HA1 = MD5(username:realm:password)
  """
  @callback get_password(username :: String.t()) :: {:ok, String.t()} | :error

  @doc """
  Authenticate user credentials for registration.

  Called after the digest response has been validated by the framework.
  Use this callback for any additional authentication logic (e.g.,
  checking if the user is allowed to register, rate limiting, etc.).

  ## Arguments

  - `credentials` - A map containing:
    - `:username` - The username from the Authorization header
    - `:realm` - The authentication realm
    - `:nonce` - The nonce value (for replay prevention)

  ## Return Values

  - `:ok` - Authentication successful, proceed with registration
  - `:error` - Authentication failed, framework will send 403 Forbidden

  ## Example

      def authenticate(%{username: username}) do
        if MyDB.user_can_register?(username) do
          :ok
        else
          :error
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
  registrations for the Address of Record. Per RFC 3261 Section 10.3,
  the 200 OK response MUST contain Contact headers with expires parameters
  indicating the remaining registration time for each binding.

  ## Arguments

  - `aor` - The Address of Record to look up

  ## Return Value

  A list of binding maps, each containing:

  **Required fields:**
  - `:contact` - The Contact URI string (e.g., "sip:alice@192.168.1.100:5060")
  - `:expires` - The original expiration time in seconds
  - `:registered_at` - Unix timestamp (seconds) when the binding was stored

  **Optional fields:**
  - `:q` - Priority q-value (0.0-1.0) for Contact ordering per RFC 3261 Section 10.2.1.2

  Return an empty list if no bindings exist.

  ## Example

      def get_bindings(aor) do
        MyDB.get_contacts(aor)
        # Returns: [
        #   %{contact: "sip:alice@192.168.1.100:5060", expires: 3600, registered_at: 1699999999, q: 1.0},
        #   %{contact: "sip:alice@192.168.1.101:5060", expires: 1800, registered_at: 1699999999, q: 0.5}
        # ]
      end

  ## RFC Reference

  RFC 3261 Section 10.3 requires the registrar to return the actual
  expiration interval chosen for each binding in the 200 OK response.
  RFC 3261 Section 10.2.1.2 specifies that q-values range from 0.0 to 1.0,
  with higher values indicating higher preference.
  """
  @callback get_bindings(aor :: String.t()) ::
              [
                %{
                  required(:contact) => String.t(),
                  required(:expires) => non_neg_integer(),
                  required(:registered_at) => non_neg_integer(),
                  optional(:q) => float()
                }
              ]

  @doc """
  Handle registration expiration.

  Called when a registration binding expires (timer fires). Use this
  to update presence, clean up resources, or notify other systems.

  ## Arguments

  - `aor` - The Address of Record that expired
  - `contact` - The specific Contact URI that expired

  ## Return Value

  - `:ok` - Expiration handled

  ## Example

      def handle_registration_expired(aor, contact) do
        Parrot.Presence.notify(aor, %{status: :offline})
        Logger.info("Registration expired for \#{aor} contact \#{contact}")
        :ok
      end
  """
  @callback handle_registration_expired(aor :: String.t(), contact :: String.t()) :: :ok

  @doc """
  Provides default implementations for all callbacks.

  When you `use Parrot.RegistrationHandler`, you get:

  1. Default implementations of all callbacks
  2. The `@behaviour Parrot.RegistrationHandler` annotation

  Override any callback by defining it in your module.

  ## Default Implementations

  - `get_password/1` - Returns `:error` (unknown user)
  - `authenticate/1` - Returns `:ok` (allows all authenticated users)
  - `store_binding/3` - Returns `:ok` (no-op)
  - `get_bindings/1` - Returns `[]` (empty)
  - `handle_registration_expired/2` - Returns `:ok` (no-op)
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Parrot.RegistrationHandler

      @impl Parrot.RegistrationHandler
      def get_password(_username) do
        :error
      end

      @impl Parrot.RegistrationHandler
      def authenticate(_credentials) do
        :ok
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
      def handle_registration_expired(_aor, _contact) do
        :ok
      end

      defoverridable get_password: 1,
                     authenticate: 1,
                     store_binding: 3,
                     get_bindings: 1,
                     handle_registration_expired: 2
    end
  end
end
