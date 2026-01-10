defmodule Parrot.RegistrationHandlerTest do
  use ExUnit.Case, async: true

  describe "behaviour definition" do
    test "defines authenticate/1 callback" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert {:authenticate, 1} in callbacks
    end

    test "defines store_binding/3 callback" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert {:store_binding, 3} in callbacks
    end

    test "defines get_bindings/1 callback" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert {:get_bindings, 1} in callbacks
    end

    test "defines handle_registration_expired/2 callback" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert {:handle_registration_expired, 2} in callbacks
    end

    test "defines get_password/1 callback" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert {:get_password, 1} in callbacks
    end

    test "defines all 5 expected callbacks" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert length(callbacks) == 5
    end
  end

  describe "use Parrot.RegistrationHandler - default implementations" do
    defmodule MinimalHandler do
      use Parrot.RegistrationHandler
    end

    test "provides default get_password/1 that rejects all users" do
      assert :error = MinimalHandler.get_password("alice")
    end

    test "provides default authenticate/1 that allows all authenticated users" do
      # authenticate/1 is now for additional auth logic after digest validation
      # Default allows all since get_password/1 handles user validation
      credentials = %{username: "alice", realm: "example.com"}
      assert :ok = MinimalHandler.authenticate(credentials)
    end

    test "provides default store_binding/3 that returns :ok" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"
      expires = 3600

      assert :ok = MinimalHandler.store_binding(aor, contact, expires)
    end

    test "provides default get_bindings/1 that returns empty list" do
      aor = "sip:alice@example.com"
      assert [] = MinimalHandler.get_bindings(aor)
    end

    test "provides default handle_registration_expired/2 that returns :ok" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"
      assert :ok = MinimalHandler.handle_registration_expired(aor, contact)
    end
  end

  describe "authenticate/1 callback" do
    defmodule AuthenticatingHandler do
      use Parrot.RegistrationHandler

      @valid_users %{
        "alice" => "password123",
        "bob" => "secret456"
      }

      def authenticate(%{username: username, password: password}) do
        case Map.get(@valid_users, username) do
          ^password -> :ok
          _ -> :error
        end
      end

      def authenticate(_credentials), do: :error
    end

    test "returns :ok for valid credentials" do
      credentials = %{username: "alice", password: "password123"}
      assert :ok = AuthenticatingHandler.authenticate(credentials)
    end

    test "returns :error for invalid password" do
      credentials = %{username: "alice", password: "wrongpassword"}
      assert :error = AuthenticatingHandler.authenticate(credentials)
    end

    test "returns :error for unknown user" do
      credentials = %{username: "charlie", password: "anypassword"}
      assert :error = AuthenticatingHandler.authenticate(credentials)
    end

    test "receives credentials map with username and password" do
      # Verify the credentials structure is passed correctly
      credentials = %{username: "bob", password: "secret456"}
      assert :ok = AuthenticatingHandler.authenticate(credentials)
    end
  end

  describe "store_binding/3 callback" do
    defmodule StoringHandler do
      use Parrot.RegistrationHandler

      # Use process dictionary to track stored bindings for testing
      def store_binding(aor, contact, expires) do
        bindings = Process.get(:test_bindings, %{})
        contacts = Map.get(bindings, aor, [])
        new_contacts = [{contact, expires} | contacts]
        Process.put(:test_bindings, Map.put(bindings, aor, new_contacts))
        :ok
      end

      def get_bindings(aor) do
        bindings = Process.get(:test_bindings, %{})

        bindings
        |> Map.get(aor, [])
        |> Enum.map(fn {contact, _expires} -> contact end)
      end
    end

    setup do
      Process.delete(:test_bindings)
      :ok
    end

    test "stores a single binding" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"
      expires = 3600

      assert :ok = StoringHandler.store_binding(aor, contact, expires)
      assert [^contact] = StoringHandler.get_bindings(aor)
    end

    test "stores multiple contacts for same AOR" do
      aor = "sip:alice@example.com"
      contact1 = "sip:alice@192.168.1.100:5060"
      contact2 = "sip:alice@192.168.1.101:5060"

      assert :ok = StoringHandler.store_binding(aor, contact1, 3600)
      assert :ok = StoringHandler.store_binding(aor, contact2, 3600)

      bindings = StoringHandler.get_bindings(aor)
      assert length(bindings) == 2
      assert contact1 in bindings
      assert contact2 in bindings
    end

    test "receives expires value" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"
      expires = 7200

      assert :ok = StoringHandler.store_binding(aor, contact, expires)
    end

    test "handles zero expires (unregister)" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"
      expires = 0

      # Zero expires means unregister, but basic store_binding just stores
      assert :ok = StoringHandler.store_binding(aor, contact, expires)
    end
  end

  describe "get_bindings/1 callback" do
    defmodule RetrievingHandler do
      use Parrot.RegistrationHandler

      @bindings %{
        "sip:alice@example.com" => [
          "sip:alice@192.168.1.100:5060",
          "sip:alice@192.168.1.101:5060"
        ],
        "sip:bob@example.com" => [
          "sip:bob@10.0.0.50:5060"
        ]
      }

      def get_bindings(aor) do
        Map.get(@bindings, aor, [])
      end
    end

    test "returns list of contacts for existing AOR" do
      aor = "sip:alice@example.com"
      contacts = RetrievingHandler.get_bindings(aor)

      assert length(contacts) == 2
      assert "sip:alice@192.168.1.100:5060" in contacts
      assert "sip:alice@192.168.1.101:5060" in contacts
    end

    test "returns empty list for unknown AOR" do
      aor = "sip:unknown@example.com"
      assert [] = RetrievingHandler.get_bindings(aor)
    end

    test "returns single contact when only one registered" do
      aor = "sip:bob@example.com"
      contacts = RetrievingHandler.get_bindings(aor)

      assert ["sip:bob@10.0.0.50:5060"] = contacts
    end
  end

  describe "handle_registration_expired/2 callback" do
    defmodule ExpiryHandler do
      use Parrot.RegistrationHandler

      def handle_registration_expired(aor, contact) do
        # Track expired registrations for testing
        expired = Process.get(:expired_registrations, [])
        Process.put(:expired_registrations, [{aor, contact} | expired])
        :ok
      end
    end

    setup do
      Process.delete(:expired_registrations)
      :ok
    end

    test "is called with AOR and contact when registration expires" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      assert :ok = ExpiryHandler.handle_registration_expired(aor, contact)

      expired = Process.get(:expired_registrations, [])
      assert {aor, contact} in expired
    end

    test "handles multiple expirations" do
      aor1 = "sip:alice@example.com"
      aor2 = "sip:bob@example.com"
      contact1 = "sip:alice@192.168.1.100:5060"
      contact2 = "sip:bob@192.168.1.101:5060"

      assert :ok = ExpiryHandler.handle_registration_expired(aor1, contact1)
      assert :ok = ExpiryHandler.handle_registration_expired(aor2, contact2)

      expired = Process.get(:expired_registrations, [])
      assert length(expired) == 2
      assert {aor1, contact1} in expired
      assert {aor2, contact2} in expired
    end
  end

  describe "complete registration handler example" do
    defmodule CompleteHandler do
      use Parrot.RegistrationHandler

      # Simulated database using process dictionary
      def authenticate(%{username: username, password: password}) do
        users = Process.get(:users, %{})

        case Map.get(users, username) do
          ^password -> :ok
          _ -> :error
        end
      end

      def store_binding(aor, contact, expires) do
        bindings = Process.get(:bindings, %{})
        contacts = Map.get(bindings, aor, [])

        # Remove existing binding for same contact if exists
        contacts = Enum.reject(contacts, fn {c, _e} -> c == contact end)

        # Add new binding (or skip if expires == 0)
        new_contacts =
          if expires > 0 do
            [{contact, expires} | contacts]
          else
            contacts
          end

        Process.put(:bindings, Map.put(bindings, aor, new_contacts))
        :ok
      end

      def get_bindings(aor) do
        bindings = Process.get(:bindings, %{})

        bindings
        |> Map.get(aor, [])
        |> Enum.map(fn {contact, _expires} -> contact end)
      end

      def handle_registration_expired(aor, contact) do
        # Remove specific binding for this AOR and contact
        bindings = Process.get(:bindings, %{})
        contacts = Map.get(bindings, aor, [])
        new_contacts = Enum.reject(contacts, fn {c, _e} -> c == contact end)
        Process.put(:bindings, Map.put(bindings, aor, new_contacts))
        :ok
      end
    end

    setup do
      Process.put(:users, %{"alice" => "secret123", "bob" => "password456"})
      Process.put(:bindings, %{})
      :ok
    end

    test "full registration flow - register, query, unregister" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Authenticate
      assert :ok = CompleteHandler.authenticate(%{username: "alice", password: "secret123"})

      # Store binding
      assert :ok = CompleteHandler.store_binding(aor, contact, 3600)

      # Verify binding exists
      assert [^contact] = CompleteHandler.get_bindings(aor)

      # Unregister (expires = 0)
      assert :ok = CompleteHandler.store_binding(aor, contact, 0)

      # Verify binding removed
      assert [] = CompleteHandler.get_bindings(aor)
    end

    test "expired registration cleanup" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Register
      assert :ok = CompleteHandler.store_binding(aor, contact, 3600)
      assert [^contact] = CompleteHandler.get_bindings(aor)

      # Simulate expiration
      assert :ok = CompleteHandler.handle_registration_expired(aor, contact)

      # Verify bindings removed
      assert [] = CompleteHandler.get_bindings(aor)
    end

    test "authentication failure prevents registration" do
      # This is handled by framework, but test the callback
      assert :error =
               CompleteHandler.authenticate(%{username: "alice", password: "wrongpassword"})

      assert :error =
               CompleteHandler.authenticate(%{username: "unknown", password: "anypassword"})
    end

    test "multiple devices can register same AOR" do
      aor = "sip:alice@example.com"
      device1 = "sip:alice@phone1.local:5060"
      device2 = "sip:alice@phone2.local:5060"
      device3 = "sip:alice@softphone.local:5060"

      assert :ok = CompleteHandler.store_binding(aor, device1, 3600)
      assert :ok = CompleteHandler.store_binding(aor, device2, 3600)
      assert :ok = CompleteHandler.store_binding(aor, device3, 3600)

      bindings = CompleteHandler.get_bindings(aor)
      assert length(bindings) == 3
      assert device1 in bindings
      assert device2 in bindings
      assert device3 in bindings
    end

    test "re-registering same contact updates expires" do
      aor = "sip:alice@example.com"
      contact = "sip:alice@192.168.1.100:5060"

      # Initial registration
      assert :ok = CompleteHandler.store_binding(aor, contact, 3600)
      assert [^contact] = CompleteHandler.get_bindings(aor)

      # Re-register same contact (refresh)
      assert :ok = CompleteHandler.store_binding(aor, contact, 7200)

      # Should still have only one binding
      assert [^contact] = CompleteHandler.get_bindings(aor)
    end
  end

  describe "overriding default callbacks" do
    defmodule PartialOverrideHandler do
      use Parrot.RegistrationHandler

      # Only override authenticate, use defaults for everything else
      def authenticate(%{username: "admin", password: "admin123"}) do
        :ok
      end

      def authenticate(_credentials), do: :error
    end

    test "can override individual callbacks" do
      assert :ok = PartialOverrideHandler.authenticate(%{username: "admin", password: "admin123"})
      assert :error = PartialOverrideHandler.authenticate(%{username: "other", password: "pass"})
    end

    test "non-overridden callbacks use defaults" do
      # Default store_binding returns :ok
      assert :ok = PartialOverrideHandler.store_binding("aor", "contact", 3600)

      # Default get_bindings returns []
      assert [] = PartialOverrideHandler.get_bindings("aor")

      # Default handle_registration_expired returns :ok
      assert :ok = PartialOverrideHandler.handle_registration_expired("aor", "contact")
    end
  end

  describe "get_bindings/1 richer binding format (Task 6f9.3)" do
    @moduledoc """
    Tests for the richer binding data format returned by get_bindings/1.

    Per RFC 3261 Section 10.3, the registrar MUST return Contact headers
    with expires parameters. The binding format includes:
    - :contact - The Contact URI string (required)
    - :expires - The original expiration time in seconds (required)
    - :registered_at - Unix timestamp when binding was stored (required)
    - :q - Optional q-value (0.0-1.0) for Contact priority (RFC 3261 Section 10.2.1.2)
    """

    defmodule RicherBindingHandler do
      use Parrot.RegistrationHandler

      @impl Parrot.RegistrationHandler
      def get_bindings("sip:alice@example.com") do
        now = System.system_time(:second)

        [
          %{
            contact: "sip:alice@192.168.1.100:5060",
            expires: 3600,
            registered_at: now - 100,
            q: 1.0
          },
          %{
            contact: "sip:alice@192.168.1.101:5060",
            expires: 1800,
            registered_at: now - 50,
            q: 0.5
          }
        ]
      end

      @impl Parrot.RegistrationHandler
      def get_bindings("sip:bob@example.com") do
        now = System.system_time(:second)

        # Bob has no q-value (optional field omitted)
        [
          %{
            contact: "sip:bob@10.0.0.50:5060",
            expires: 3600,
            registered_at: now
          }
        ]
      end

      @impl Parrot.RegistrationHandler
      def get_bindings(_aor), do: []
    end

    test "returns binding maps with required fields" do
      bindings = RicherBindingHandler.get_bindings("sip:alice@example.com")

      assert length(bindings) == 2

      Enum.each(bindings, fn binding ->
        assert is_map(binding)
        assert Map.has_key?(binding, :contact)
        assert Map.has_key?(binding, :expires)
        assert Map.has_key?(binding, :registered_at)
        assert is_binary(binding.contact)
        assert is_integer(binding.expires)
        assert is_integer(binding.registered_at)
      end)
    end

    test "binding maps can include optional q-value" do
      bindings = RicherBindingHandler.get_bindings("sip:alice@example.com")

      # Alice has q-values on her bindings
      Enum.each(bindings, fn binding ->
        assert Map.has_key?(binding, :q)
        assert is_float(binding.q)
        assert binding.q >= 0.0 and binding.q <= 1.0
      end)
    end

    test "q-value is optional and can be omitted" do
      bindings = RicherBindingHandler.get_bindings("sip:bob@example.com")

      assert length(bindings) == 1
      [binding] = bindings

      # Bob's binding has no q-value (optional)
      refute Map.has_key?(binding, :q)

      # But still has required fields
      assert Map.has_key?(binding, :contact)
      assert Map.has_key?(binding, :expires)
      assert Map.has_key?(binding, :registered_at)
    end

    test "bindings are ordered by q-value (highest first) when present" do
      bindings = RicherBindingHandler.get_bindings("sip:alice@example.com")

      # Get q-values
      q_values = Enum.map(bindings, & &1.q)

      # Should be sorted descending by q-value (1.0 before 0.5)
      assert q_values == Enum.sort(q_values, :desc)
    end

    test "contact URIs are valid SIP URIs" do
      bindings = RicherBindingHandler.get_bindings("sip:alice@example.com")

      Enum.each(bindings, fn binding ->
        assert String.starts_with?(binding.contact, "sip:")
      end)
    end

    test "expires values are non-negative integers" do
      bindings = RicherBindingHandler.get_bindings("sip:alice@example.com")

      Enum.each(bindings, fn binding ->
        assert binding.expires >= 0
      end)
    end

    test "registered_at is a Unix timestamp" do
      bindings = RicherBindingHandler.get_bindings("sip:alice@example.com")
      now = System.system_time(:second)

      Enum.each(bindings, fn binding ->
        # registered_at should be in the past or now
        assert binding.registered_at <= now
        # And reasonably recent (within last hour for test)
        assert binding.registered_at > now - 3600
      end)
    end
  end
end
