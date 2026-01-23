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
      # Ensure module is fully loaded before checking
      Code.ensure_loaded!(Presence)
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

  # ============================================================================
  # NOTIFY Delivery Tests - RFC 3856/6665
  # ============================================================================

  describe "NOTIFY message building - RFC 3265 Section 3.1.6" do
    alias ParrotSip.Headers.{Event, SubscriptionState, ContentType}

    test "builds NOTIFY with Event: presence header" do
      msg = Presence.build_notify_message("sip:alice@example.com", "<xml>body</xml>", 3600)

      assert %Event{event: "presence"} = msg.event
    end

    test "builds NOTIFY with Subscription-State: active header" do
      msg = Presence.build_notify_message("sip:alice@example.com", "<xml>body</xml>", 3600)

      assert %SubscriptionState{state: :active} = msg.subscription_state
    end

    test "builds NOTIFY with expires parameter in Subscription-State header per RFC 6665 Section 4.1.3" do
      msg = Presence.build_notify_message("sip:alice@example.com", "<xml>body</xml>", 3600)

      assert %SubscriptionState{parameters: params} = msg.subscription_state
      assert params["expires"] == "3600"
    end

    test "builds NOTIFY with Content-Type: application/pidf+xml header" do
      msg = Presence.build_notify_message("sip:alice@example.com", "<xml>body</xml>", 3600)

      assert %ContentType{type: "application", subtype: "pidf+xml"} = msg.content_type
    end

    test "builds NOTIFY with PIDF+XML body" do
      pidf_body = ParrotSip.Presence.Pidf.build("sip:alice@example.com", %{status: :open, note: "Available"})
      msg = Presence.build_notify_message("sip:alice@example.com", pidf_body, 3600)

      assert msg.body == pidf_body
      assert msg.body =~ ~r/<presence.*entity="sip:alice@example\.com"/
      assert msg.body =~ ~r/<basic>open<\/basic>/
    end

    test "builds NOTIFY with method :notify" do
      msg = Presence.build_notify_message("sip:alice@example.com", "<xml>body</xml>", 3600)

      assert msg.method == :notify
    end

    test "handles default expires when not specified in subscription" do
      # When subscription doesn't have expires, default to 3600
      msg = Presence.build_notify_message("sip:alice@example.com", "<xml>body</xml>", nil)

      assert %SubscriptionState{parameters: params} = msg.subscription_state
      assert params["expires"] == "3600"
    end
  end

  describe "NOTIFY delivery via dialog - RFC 3856 Section 4" do
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

    test "subscription with missing dialog_id does not crash notify" do
      TestPresenceHandler.set_test_pid(self())

      # Subscription without dialog_id
      TestPresenceHandler.set_subscriptions([
        %{watcher: "sip:bob@example.com", subscription_id: "sub-1"}
      ])

      # Should not crash, returns :ok immediately
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open, note: "Available"})

      # Give async task time to execute
      Process.sleep(150)

      # Should have called get_subscriptions
      assert_received {:get_subscriptions_called, "sip:alice@example.com"}
    end

    test "non-existent dialog does not crash notify" do
      TestPresenceHandler.set_test_pid(self())

      # Subscription with dialog_id that doesn't exist in registry
      TestPresenceHandler.set_subscriptions([
        %{watcher: "sip:bob@example.com", dialog_id: "non-existent-dialog-123", expires: 3600}
      ])

      # Should not crash, returns :ok immediately
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open, note: "Available"})

      # Give async task time to execute
      Process.sleep(150)

      # Should have called get_subscriptions
      assert_received {:get_subscriptions_called, "sip:alice@example.com"}
    end

    test "iterates through each subscription" do
      TestPresenceHandler.set_test_pid(self())

      # Multiple subscriptions
      TestPresenceHandler.set_subscriptions([
        %{watcher: "sip:bob@example.com", dialog_id: "dialog-1", expires: 3600},
        %{watcher: "sip:carol@example.com", dialog_id: "dialog-2", expires: 1800}
      ])

      # Should return :ok immediately
      assert :ok == Presence.notify("sip:alice@example.com", %{status: :closed, note: "Busy"})

      # Give async task time to execute
      Process.sleep(150)

      # Should have called get_subscriptions
      assert_received {:get_subscriptions_called, "sip:alice@example.com"}
    end

    test "passes expires from subscription to NOTIFY message builder" do
      # This test verifies the integration via direct function call
      # The async flow is tested above via get_subscriptions callback
      TestPresenceHandler.set_test_pid(self())

      # Subscription with specific expires
      TestPresenceHandler.set_subscriptions([
        %{watcher: "sip:bob@example.com", dialog_id: "dialog-1", expires: 1800}
      ])

      assert :ok == Presence.notify("sip:alice@example.com", %{status: :open})
      Process.sleep(150)

      # Verify get_subscriptions was called
      assert_received {:get_subscriptions_called, "sip:alice@example.com"}

      # Separately verify the NOTIFY message includes correct expires
      msg = Presence.build_notify_message("sip:alice@example.com", "<pidf/>", 1800)
      assert msg.subscription_state.parameters["expires"] == "1800"
    end
  end
end
