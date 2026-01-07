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

    test "defines handle_registration_expired/1 callback" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert {:handle_registration_expired, 1} in callbacks
    end

    test "defines all 4 expected callbacks" do
      callbacks = Parrot.RegistrationHandler.behaviour_info(:callbacks)
      assert length(callbacks) == 4
    end
  end

  describe "use Parrot.RegistrationHandler - default implementations" do
    defmodule MinimalHandler do
      use Parrot.RegistrationHandler
    end

    test "provides default authenticate/1 that rejects all" do
      credentials = %{username: "alice", password: "secret"}
      assert :error = MinimalHandler.authenticate(credentials)
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

    test "provides default handle_registration_expired/1 that returns :ok" do
      aor = "sip:alice@example.com"
      assert :ok = MinimalHandler.handle_registration_expired(aor)
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

  describe "handle_registration_expired/1 callback" do
    defmodule ExpiryHandler do
      use Parrot.RegistrationHandler

      def handle_registration_expired(aor) do
        # Track expired registrations for testing
        expired = Process.get(:expired_registrations, [])
        Process.put(:expired_registrations, [aor | expired])
        :ok
      end
    end

    setup do
      Process.delete(:expired_registrations)
      :ok
    end

    test "is called with AOR when registration expires" do
      aor = "sip:alice@example.com"

      assert :ok = ExpiryHandler.handle_registration_expired(aor)

      expired = Process.get(:expired_registrations, [])
      assert aor in expired
    end

    test "handles multiple expirations" do
      aor1 = "sip:alice@example.com"
      aor2 = "sip:bob@example.com"

      assert :ok = ExpiryHandler.handle_registration_expired(aor1)
      assert :ok = ExpiryHandler.handle_registration_expired(aor2)

      expired = Process.get(:expired_registrations, [])
      assert length(expired) == 2
      assert aor1 in expired
      assert aor2 in expired
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

      def handle_registration_expired(aor) do
        # Remove all bindings for this AOR
        bindings = Process.get(:bindings, %{})
        Process.put(:bindings, Map.delete(bindings, aor))
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
      assert :ok = CompleteHandler.handle_registration_expired(aor)

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
      assert :ok = PartialOverrideHandler.handle_registration_expired("aor")
    end
  end
end
