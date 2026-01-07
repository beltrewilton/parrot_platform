defmodule Parrot.PresenceTest do
  use ExUnit.Case, async: true

  alias Parrot.Presence

  describe "notify/2" do
    test "notify/2 is defined and callable" do
      # The notify function should exist and be callable
      assert function_exported?(Presence, :notify, 2)
    end

    test "notify/2 returns :ok" do
      # notify is fire-and-forget, async - returns :ok immediately
      result = Presence.notify("sip:alice@example.com", %{status: :open, note: "Available"})
      assert result == :ok
    end

    test "notify/2 accepts presentity and presence state" do
      # Should accept standard presence state maps
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open})
      assert :ok == Presence.notify("sip:bob@example.com", %{status: :closed, note: "Busy"})
      assert :ok == Presence.notify("sip:carol@example.com", %{status: :closed, note: "Offline"})
    end

    test "notify/2 handles various presentity formats" do
      # Should handle various SIP URI formats
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open})
      assert :ok == Presence.notify("sip:100@pbx.local", %{status: :open})
      assert :ok == Presence.notify("sip:user@192.168.1.1", %{status: :open})
    end

    test "notify/2 handles minimal presence state" do
      # Should work with just status
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open})
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :closed})
    end

    test "notify/2 handles extended presence state" do
      # Should work with additional fields
      presence = %{
        status: :open,
        note: "Available",
        activity: "on-the-phone",
        mood: "happy"
      }

      assert :ok == Presence.notify("sip:alice@example.com", presence)
    end
  end

  describe "notify/2 usage patterns" do
    test "can be called from anywhere in the application" do
      # Simulating being called from a call handler
      defmodule CallHandlerExample do
        def handle_bridge_complete(:answered, call) do
          Parrot.Presence.notify(call.extension, %{status: :closed, note: "On a call"})
          {:noreply, call}
        end

        def handle_hangup(call) do
          Parrot.Presence.notify(call.extension, %{status: :open, note: "Available"})
          {:noreply, call}
        end
      end

      call = %{extension: "sip:alice@example.com"}

      # Both calls should succeed
      assert {:noreply, ^call} = CallHandlerExample.handle_bridge_complete(:answered, call)
      assert {:noreply, ^call} = CallHandlerExample.handle_hangup(call)
    end

    test "can be called from registration handler" do
      defmodule RegistrationHandlerExample do
        def store_binding(aor, _contact, _expires) do
          Parrot.Presence.notify(aor, %{status: :open, note: "Available"})
          :ok
        end

        def handle_registration_expired(aor) do
          Parrot.Presence.notify(aor, %{status: :closed, note: "Offline"})
          :ok
        end
      end

      assert :ok == RegistrationHandlerExample.store_binding("sip:alice@example.com", "contact", 3600)
      assert :ok == RegistrationHandlerExample.handle_registration_expired("sip:alice@example.com")
    end
  end
end
