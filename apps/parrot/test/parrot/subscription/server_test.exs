defmodule Parrot.Subscription.ServerTest do
  @moduledoc """
  Tests for Parrot.Subscription.Server - the subscription lifecycle manager.

  This server handles SUBSCRIBE requests similar to how Call.Server handles INVITE.
  The critical fix is ensuring 200 OK is sent BEFORE NOTIFY (RFC 6665 Section 4.2.2).
  """

  # Using async: false because:
  # 1. Registry tests depend on shared Parrot.Registry state
  # 2. We need to verify message ordering which can be timing-sensitive
  use ExUnit.Case, async: false

  require Logger

  alias Parrot.Subscription.Server, as: SubscriptionServer

  # ===========================================================================
  # Test Helper Modules
  # ===========================================================================

  # Test handler that tracks callback invocations
  defmodule TestPresenceHandler do
    use Parrot.PresenceHandler

    @impl true
    def authorize_subscription(watcher, presentity) do
      # Send to test process for verification
      if pid = Process.get(:test_pid) do
        send(pid, {:authorize_called, watcher, presentity})
      end

      :allow
    end

    @impl true
    def store_subscription(subscription) do
      if pid = Process.get(:test_pid) do
        send(pid, {:store_called, subscription})
      end

      :ok
    end

    @impl true
    def get_presence(presentity) do
      if pid = Process.get(:test_pid) do
        send(pid, {:get_presence_called, presentity})
      end

      %{status: :open, note: "Available"}
    end

    @impl true
    def get_subscriptions(presentity) do
      if pid = Process.get(:test_pid) do
        send(pid, {:get_subscriptions_called, presentity})
      end

      []
    end
  end

  # Handler that denies subscriptions
  defmodule DenyingHandler do
    use Parrot.PresenceHandler

    @impl true
    def authorize_subscription(_watcher, _presentity) do
      :deny
    end
  end

  # Handler that marks subscriptions as pending
  defmodule PendingHandler do
    use Parrot.PresenceHandler

    @impl true
    def authorize_subscription(_watcher, _presentity) do
      :pending
    end

    @impl true
    def store_subscription(subscription) do
      if pid = Process.get(:test_pid) do
        send(pid, {:store_pending_called, subscription})
      end

      :ok
    end
  end

  # Mock for tracking SIP response sends
  defmodule MockResponseTracker do
    @moduledoc """
    Tracks the order in which SIP responses are sent.
    Used to verify that 200 OK is sent before NOTIFY.
    """

    def start_link(test_pid) do
      Agent.start_link(fn -> %{test_pid: test_pid, messages: []} end)
    end

    def record_send(agent, type, data) do
      Agent.update(agent, fn state ->
        message = {type, data, System.monotonic_time(:microsecond)}
        send(state.test_pid, {:message_sent, type, data})
        %{state | messages: [message | state.messages]}
      end)
    end

    def get_messages(agent) do
      Agent.get(agent, fn state -> Enum.reverse(state.messages) end)
    end
  end

  # ===========================================================================
  # Test Setup
  # ===========================================================================

  setup do
    # Ensure Parrot.Registry is started for tests
    case Registry.start_link(keys: :unique, name: Parrot.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Store test PID for handler callbacks
    Process.put(:test_pid, self())

    :ok
  end

  # ===========================================================================
  # Basic Lifecycle Tests
  # ===========================================================================

  describe "start_link/1" do
    test "starts a Subscription.Server process with required opts" do
      subscribe_data = %{
        watcher: "sip:watcher@example.com",
        presentity: "sip:user@example.com",
        expires: 3600,
        call_id: "test-sub-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      assert Process.alive?(pid)
    end

    test "requires :handler option" do
      subscribe_data = %{watcher: "sip:w@ex.com", presentity: "sip:p@ex.com", expires: 3600}
      context = build_test_context()

      assert_raise KeyError, fn ->
        SubscriptionServer.start_link(subscribe_data: subscribe_data, context: context)
      end
    end

    test "requires :subscribe_data option" do
      context = build_test_context()

      assert_raise KeyError, fn ->
        SubscriptionServer.start_link(handler: TestPresenceHandler, context: context)
      end
    end

    test "requires :context option" do
      subscribe_data = %{watcher: "sip:w@ex.com", presentity: "sip:p@ex.com", expires: 3600}

      assert_raise KeyError, fn ->
        SubscriptionServer.start_link(handler: TestPresenceHandler, subscribe_data: subscribe_data)
      end
    end
  end

  describe "init/1" do
    test "invokes handler's authorize_subscription callback" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "auth-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Handler should have been called with watcher and presentity
      assert_receive {:authorize_called, "sip:alice@example.com", "sip:bob@example.com"}, 100
    end

    test "generates unique subscription ID" do
      subscribe_data = %{
        watcher: "sip:watcher@example.com",
        presentity: "sip:user@example.com",
        expires: 3600,
        call_id: "id-gen-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      subscription = SubscriptionServer.get_subscription(pid)
      assert subscription.id != nil
      assert is_binary(subscription.id)
    end
  end

  # ===========================================================================
  # Authorization Flow Tests
  # ===========================================================================

  describe "allowed subscription" do
    test "sends 200 OK response" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "allow-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should receive 200 OK response
      assert_receive {:response_sent, response}, 500
      assert response.status_code == 200
    end

    test "stores subscription via handler callback" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "store-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should have called store_subscription
      assert_receive {:store_called, subscription}, 500
      assert subscription.watcher == "sip:alice@example.com"
      assert subscription.presentity == "sip:bob@example.com"
      assert subscription.expires == 3600
    end

    test "triggers initial NOTIFY after storing subscription" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "notify-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should have called get_presence for initial NOTIFY
      assert_receive {:get_presence_called, "sip:bob@example.com"}, 500
    end
  end

  describe "denied subscription" do
    test "sends 403 Forbidden response" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "deny-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: DenyingHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should receive 403 Forbidden response
      assert_receive {:response_sent, response}, 500
      assert response.status_code == 403
    end

    test "does not store subscription" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "deny-no-store-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: DenyingHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should not receive store_called
      refute_receive {:store_called, _}, 100
    end

    test "does not trigger NOTIFY" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "deny-no-notify-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: DenyingHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should not receive get_presence_called (no NOTIFY triggered)
      refute_receive {:get_presence_called, _}, 100
    end
  end

  describe "pending subscription" do
    test "sends 202 Accepted response" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "pending-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: PendingHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should receive 202 Accepted response
      assert_receive {:response_sent, response}, 500
      assert response.status_code == 202
    end

    test "stores subscription with pending state" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "pending-store-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: PendingHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should have called store_subscription with pending state
      assert_receive {:store_pending_called, subscription}, 500
      assert subscription.state == :pending
    end
  end

  # ===========================================================================
  # Response Ordering Tests (THE CRITICAL FIX)
  # ===========================================================================

  describe "response ordering (RFC 6665 Section 4.2.2)" do
    @tag :critical
    test "200 OK is sent BEFORE NOTIFY" do
      # This is THE critical test that validates RFC 6665 compliance
      # RFC 6665 Section 4.2.2: "Notifier sends 200 OK, then immediately sends NOTIFY"

      {:ok, tracker} = MockResponseTracker.start_link(self())

      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "order-test-#{System.unique_integer([:positive])}"
      }

      # Create context with tracking response function
      context = build_test_context_with_tracker(tracker)

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Wait for both messages to be sent
      assert_receive {:message_sent, :response, response}, 1000
      assert response.status_code == 200

      # NOTIFY should come after 200 OK
      assert_receive {:message_sent, :notify, _notify}, 1000

      # Verify ordering via the tracker
      messages = MockResponseTracker.get_messages(tracker)

      response_time = find_message_time(messages, :response)
      notify_time = find_message_time(messages, :notify)

      # Response (200 OK) must be sent before NOTIFY
      assert response_time < notify_time,
             "200 OK must be sent before NOTIFY. Response time: #{response_time}, NOTIFY time: #{notify_time}"
    end

    @tag :critical
    test "response is fully transmitted before NOTIFY is sent" do
      # This test ensures synchronous response sending

      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "sync-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, _pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # We should receive response first, then get_presence (for NOTIFY)
      # This order proves the response was sent before NOTIFY logic started
      messages = receive_all_messages(500)

      response_idx =
        Enum.find_index(messages, fn
          {:response_sent, _} -> true
          _ -> false
        end)

      notify_idx =
        Enum.find_index(messages, fn
          {:get_presence_called, _} -> true
          _ -> false
        end)

      assert response_idx != nil, "Should have received response_sent"
      assert notify_idx != nil, "Should have received get_presence_called (for NOTIFY)"
      assert response_idx < notify_idx, "Response must be sent before NOTIFY preparation"
    end
  end

  # ===========================================================================
  # Registry Tests
  # ===========================================================================

  describe "registry registration" do
    test "registers in Parrot.Registry for lookup by dialog_id" do
      call_id = "registry-test-#{System.unique_integer([:positive])}"

      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: call_id
      }

      context = build_test_context()

      {:ok, pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Should be able to look up by subscription dialog_id
      # Wait for initialization to complete (response sent)
      assert_receive {:response_sent, _}, 500

      subscription = SubscriptionServer.get_subscription(pid)
      dialog_id = subscription.dialog_id

      assert dialog_id != nil

      # Lookup should find the server
      result = SubscriptionServer.lookup_by_dialog_id(dialog_id)
      assert {:ok, ^pid} = result
    end

    test "lookup_by_dialog_id returns {:error, :not_found} for unknown dialog_id" do
      assert {:error, :not_found} = SubscriptionServer.lookup_by_dialog_id("nonexistent")
    end
  end

  # ===========================================================================
  # Public API Tests
  # ===========================================================================

  describe "get_subscription/1" do
    test "returns the subscription struct" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "get-sub-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      subscription = SubscriptionServer.get_subscription(pid)

      assert subscription.watcher == "sip:alice@example.com"
      assert subscription.presentity == "sip:bob@example.com"
      assert subscription.expires == 3600
      assert subscription.id != nil
    end
  end

  describe "dispatch/2" do
    test "handles :refresh event to extend subscription" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "refresh-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Wait for initial processing
      assert_receive {:response_sent, _}, 500

      # Dispatch refresh event
      :ok = SubscriptionServer.dispatch(pid, {:refresh, 7200})

      subscription = SubscriptionServer.get_subscription(pid)
      assert subscription.expires == 7200
    end

    test "handles :terminate event to end subscription" do
      subscribe_data = %{
        watcher: "sip:alice@example.com",
        presentity: "sip:bob@example.com",
        expires: 3600,
        call_id: "term-test-#{System.unique_integer([:positive])}"
      }

      context = build_test_context()

      {:ok, pid} =
        SubscriptionServer.start_link(
          handler: TestPresenceHandler,
          subscribe_data: subscribe_data,
          context: context
        )

      # Wait for initial processing
      assert_receive {:response_sent, _}, 500

      # Dispatch terminate event
      :ok = SubscriptionServer.dispatch(pid, :terminate)

      subscription = SubscriptionServer.get_subscription(pid)
      assert subscription.state == :terminated
    end
  end

  # ===========================================================================
  # Helper Functions
  # ===========================================================================

  defp build_test_context do
    test_pid = self()

    %{
      uas: self(),
      sip_msg: build_test_subscribe_message(),
      test_pid: test_pid,
      response_fn: fn response, _uas ->
        send(test_pid, {:response_sent, response})
        {:ok, response}
      end
    }
  end

  defp build_test_context_with_tracker(tracker) do
    test_pid = self()

    %{
      uas: self(),
      sip_msg: build_test_subscribe_message(),
      response_fn: fn response, _uas ->
        MockResponseTracker.record_send(tracker, :response, response)
        {:ok, response}
      end,
      notify_fn: fn notify, _nexthop ->
        MockResponseTracker.record_send(tracker, :notify, notify)
        send(test_pid, {:notify_sent, notify})
        :ok
      end
    }
  end

  defp build_test_subscribe_message do
    %ParrotSip.Message{
      type: :request,
      method: :subscribe,
      request_uri: "sip:user@example.com",
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "watcher", host: "example.com"},
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %ParrotSip.Headers.To{
        uri: %ParrotSip.Uri{scheme: "sip", user: "user", host: "example.com"},
        parameters: %{}
      },
      call_id: "test-subscribe-call-id",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :subscribe},
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-test-branch"}
        }
      ],
      event: %ParrotSip.Headers.Event{event: "presence", parameters: %{}},
      expires: 3600,
      body: nil
    }
  end

  defp find_message_time(messages, type) do
    case Enum.find(messages, fn {t, _, _} -> t == type end) do
      {_, _, time} -> time
      nil -> nil
    end
  end

  defp receive_all_messages(timeout) do
    receive_all_messages([], timeout)
  end

  defp receive_all_messages(acc, timeout) do
    receive do
      msg -> receive_all_messages([msg | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
