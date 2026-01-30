defmodule Parrot.Examples.MiniPBX.RegistrationTest do
  @moduledoc """
  Tests for the Mini PBX Registration handler.

  Tests registration functionality:
  - Digest authentication (get_password)
  - Binding storage and retrieval
  - Multiple contacts per extension
  - Registration expiry handling
  """
  use ExUnit.Case, async: false

  alias Parrot.Examples.MiniPBX.{Registration, Storage}

  # Start storage once for all tests
  setup_all do
    :mnesia.start()

    case Storage.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Storage.clear_all()
    :ok
  end

  describe "get_password/1" do
    test "returns password for known user" do
      # Demo user 1001 has default password "1001"
      assert {:ok, _password} = Registration.get_password("1001")
    end

    test "returns error for unknown user" do
      assert :error = Registration.get_password("unknown_user")
    end
  end

  describe "authenticate/1" do
    test "accepts valid credentials" do
      credentials = %{username: "1001", realm: "pbx.local", nonce: "test_nonce"}
      assert :ok = Registration.authenticate(credentials)
    end
  end

  describe "store_binding/3" do
    test "stores registration in Mnesia" do
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"
      expires = 3600

      assert :ok = Registration.store_binding(aor, contact, expires)

      # Verify it was stored
      bindings = Registration.get_bindings(aor)
      assert length(bindings) == 1
      assert hd(bindings).contact == contact
    end

    test "handles unregister request (expires=0)" do
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"

      # First register
      :ok = Registration.store_binding(aor, contact, 3600)

      # Then unregister
      :ok = Registration.store_binding(aor, contact, 0)

      # Should be removed
      bindings = Registration.get_bindings(aor)
      assert length(bindings) == 0
    end

    test "supports multiple contacts per AOR" do
      aor = "sip:1001@pbx.local"

      :ok = Registration.store_binding(aor, "sip:1001@192.168.1.100:5060", 3600)
      :ok = Registration.store_binding(aor, "sip:1001@192.168.1.101:5060", 3600)

      bindings = Registration.get_bindings(aor)
      assert length(bindings) == 2
    end

    test "updates existing contact" do
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"

      # Register with 3600
      :ok = Registration.store_binding(aor, contact, 3600)

      # Re-register with 1800
      :ok = Registration.store_binding(aor, contact, 1800)

      # Should still have only one binding
      bindings = Registration.get_bindings(aor)
      assert length(bindings) == 1
      assert hd(bindings).expires == 1800
    end
  end

  describe "get_bindings/1" do
    test "returns empty list for unknown AOR" do
      bindings = Registration.get_bindings("sip:unknown@pbx.local")
      assert bindings == []
    end

    test "returns contact, expires, and registered_at" do
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"

      :ok = Registration.store_binding(aor, contact, 3600)

      [binding] = Registration.get_bindings(aor)

      assert binding.contact == contact
      assert binding.expires == 3600
      assert binding.registered_at != nil
    end
  end

  describe "handle_registration_expired/2" do
    test "removes expired binding" do
      aor = "sip:1001@pbx.local"
      contact = "sip:1001@192.168.1.100:5060"

      # Register
      :ok = Registration.store_binding(aor, contact, 3600)

      # Simulate expiry
      :ok = Registration.handle_registration_expired(aor, contact)

      # Should be removed
      bindings = Registration.get_bindings(aor)
      assert length(bindings) == 0
    end
  end
end
