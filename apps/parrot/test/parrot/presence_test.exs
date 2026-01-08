defmodule Parrot.PresenceTest do
  use ExUnit.Case, async: false

  alias Parrot.Presence

  # Test router with presence handler
  defmodule TestRouter do
    use Parrot.Router

    presence(Parrot.PresenceTest.TestPresenceHandler)
  end

  # Test presence handler that records calls for verification
  # Uses an Agent to store test state since Tasks run in separate processes
  defmodule TestPresenceHandler do
    use Parrot.PresenceHandler

    def start_test_agent do
      Agent.start_link(fn -> %{test_pid: nil, subscriptions: []} end, name: __MODULE__)
    end

    def stop_test_agent do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid when is_pid(pid) -> Agent.stop(pid, :normal, 5000)
      end
    catch
      :exit, _ -> :ok
    end

    def set_test_pid(pid) do
      Agent.update(__MODULE__, fn state -> %{state | test_pid: pid} end)
    end

    def set_subscriptions(subs) do
      Agent.update(__MODULE__, fn state -> %{state | subscriptions: subs} end)
    end

    def get_subscriptions(presentity) do
      state = Agent.get(__MODULE__, & &1)

      # Send message to test process with the presentity we were called with
      if state.test_pid, do: send(state.test_pid, {:get_subscriptions_called, presentity})

      # Return test subscriptions
      state.subscriptions
    end

    def get_presence(presentity) do
      state = Agent.get(__MODULE__, & &1)
      if state.test_pid, do: send(state.test_pid, {:get_presence_called, presentity})
      %{status: :open, note: "Available"}
    end
  end

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

        def handle_registration_expired(aor, _contact) do
          Parrot.Presence.notify(aor, %{status: :closed, note: "Offline"})
          :ok
        end
      end

      assert :ok ==
               RegistrationHandlerExample.store_binding("sip:alice@example.com", "contact", 3600)

      assert :ok ==
               RegistrationHandlerExample.handle_registration_expired(
                 "sip:alice@example.com",
                 "contact"
               )
    end
  end

  describe "notify/2 with router configuration" do
    setup do
      # Store original config
      original_config = Application.get_env(:parrot, :router)

      # Start the test agent for cross-process communication
      TestPresenceHandler.stop_test_agent()
      {:ok, _} = TestPresenceHandler.start_test_agent()

      # Configure test router
      Application.put_env(:parrot, :router, TestRouter)

      on_exit(fn ->
        # Stop the test agent
        TestPresenceHandler.stop_test_agent()

        # Restore original config
        if original_config do
          Application.put_env(:parrot, :router, original_config)
        else
          Application.delete_env(:parrot, :router)
        end
      end)

      :ok
    end

    test "looks up presence handler from router config" do
      # With router configured, notify should look up the handler
      Application.put_env(:parrot, :router, TestRouter)

      # Verify the router has the handler
      assert TestRouter.__presence_handler__() == TestPresenceHandler
    end

    test "calls get_subscriptions on the handler" do
      TestPresenceHandler.set_test_pid(self())
      TestPresenceHandler.set_subscriptions([])

      Presence.notify("sip:alice@example.com", %{status: :open, note: "Available"})

      # Give async task time to execute
      Process.sleep(100)

      # Should have called get_subscriptions with the presentity
      assert_received {:get_subscriptions_called, "sip:alice@example.com"}
    end

    test "returns :ok immediately (async operation)" do
      TestPresenceHandler.set_test_pid(self())

      TestPresenceHandler.set_subscriptions([
        %{watcher: "sip:bob@example.com", dialog_id: "dialog-1"}
      ])

      # Should return immediately
      result = Presence.notify("sip:alice@example.com", %{status: :open})
      assert result == :ok

      # Give async task time to start
      Process.sleep(10)
    end

    test "handles no router configured gracefully" do
      Application.delete_env(:parrot, :router)

      # Should not crash, just return :ok
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open})
    end

    test "handles router with no presence handler gracefully" do
      defmodule EmptyRouter do
        use Parrot.Router
        # No presence handler configured
      end

      Application.put_env(:parrot, :router, EmptyRouter)

      # Should not crash, just return :ok
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open})
    end

    test "handles empty subscription list gracefully" do
      TestPresenceHandler.set_test_pid(self())
      TestPresenceHandler.set_subscriptions([])

      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open})

      # Should still call get_subscriptions
      Process.sleep(100)
      assert_received {:get_subscriptions_called, "sip:alice@example.com"}
    end
  end

  describe "PIDF+XML generation" do
    test "generates valid PIDF for open status" do
      xml =
        ParrotSip.Presence.Pidf.build("sip:alice@example.com", %{status: :open, note: "Available"})

      assert xml =~ ~r/<presence.*entity="sip:alice@example\.com"/
      assert xml =~ ~r/<status><basic>open<\/basic><\/status>/
      assert xml =~ ~r/<note>Available<\/note>/
    end

    test "generates valid PIDF for closed status" do
      xml =
        ParrotSip.Presence.Pidf.build("sip:bob@example.com", %{status: :closed, note: "On a call"})

      assert xml =~ ~r/<status><basic>closed<\/basic><\/status>/
      assert xml =~ ~r/<note>On a call<\/note>/
    end
  end
end
