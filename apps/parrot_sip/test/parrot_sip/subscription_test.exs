defmodule ParrotSip.SubscriptionTest do
  @moduledoc """
  Tests for ParrotSip.Subscription gen_statem.

  Implements tests for RFC 6665 (supersedes RFC 3265) - SIP-Specific Event Notification
  and RFC 3903 - SIP PUBLISH.

  Subscription state machine per RFC 6665 Section 4.1.2:
  - pending: Subscription received but not yet authorized
  - active: Subscription is active and notifications will be sent
  - terminated: Subscription has ended

  State transitions:
  - pending -> active (authorized)
  - pending -> terminated (rejected or timeout)
  - active -> terminated (expires, unsubscribe, or error)
  """
  use ExUnit.Case, async: false

  alias ParrotSip.Subscription
  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, From, To, CSeq, Contact, Event, SubscriptionState}

  describe "Subscription gen_statem initialization - RFC 6665 Section 4" do
    test "starts subscriber in pending state" do
      _subscribe_msg = build_subscribe_message()
      opts = [
        id: unique_subscription_id(),
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]

      assert {:ok, pid} = Subscription.start_link(opts)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify initial state is pending per RFC 6665 Section 4.1.2
      {state, data} = :sys.get_state(pid)
      assert state == :pending
      assert data.role == :subscriber
      assert data.event_package == "presence"
    end

    test "starts notifier in pending state" do
      opts = [
        id: unique_subscription_id(),
        role: :notifier,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]

      assert {:ok, pid} = Subscription.start_link(opts)
      assert is_pid(pid)
      assert Process.alive?(pid)

      {state, data} = :sys.get_state(pid)
      assert state == :pending
      assert data.role == :notifier
    end

    test "uses :state_functions callback mode" do
      assert Subscription.callback_mode() == :state_functions
    end

    test "creates proper child spec" do
      opts = [
        id: "test-sub-123",
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      spec = Subscription.child_spec(opts)

      assert spec.id == Subscription
      assert spec.start == {Subscription, :start_link, [opts]}
      assert spec.type == :worker
      assert spec.restart == :temporary
    end

    test "registers in Registry with subscription ID" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]

      assert {:ok, pid} = Subscription.start_link(opts)

      # Should be registered in ParrotSip.Registry
      assert [{^pid, _}] = Registry.lookup(ParrotSip.Registry, {:subscription, sub_id})
    end
  end

  describe "Subscription state transitions - RFC 6665 Section 4.1.2" do
    setup do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      %{pid: pid, sub_id: sub_id}
    end

    test "transitions from pending to active on 200 OK response", %{pid: pid} do
      response = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:subscribe_response, response})

      Process.sleep(10)

      {state, _data} = :sys.get_state(pid)
      assert state == :active
    end

    test "transitions from pending to terminated on 4xx/5xx/6xx response", %{pid: pid} do
      response = build_response_message(403, "Forbidden")
      :gen_statem.cast(pid, {:subscribe_response, response})

      Process.sleep(20)

      refute Process.alive?(pid)
    end

    test "stays in pending on 1xx provisional response", %{pid: pid} do
      response = build_response_message(100, "Trying")
      :gen_statem.cast(pid, {:subscribe_response, response})

      Process.sleep(10)

      {state, _data} = :sys.get_state(pid)
      assert state == :pending
    end

    test "transitions from active to terminated on subscription expiry", %{pid: pid} do
      # First activate the subscription
      response = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:subscribe_response, response})
      Process.sleep(10)

      # Simulate expiry timeout
      send(pid, {:state_timeout, :subscription_expired})
      Process.sleep(20)

      refute Process.alive?(pid)
    end

    test "handles NOTIFY in active state", %{pid: pid} do
      # First activate
      response = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:subscribe_response, response})
      Process.sleep(10)

      # Receive NOTIFY
      notify_msg = build_notify_message(:active)
      result = :gen_statem.call(pid, {:notify_received, notify_msg})

      assert result == :ok
      assert Process.alive?(pid)
    end

    test "terminates on NOTIFY with terminated state", %{pid: pid} do
      # First activate
      response = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:subscribe_response, response})
      Process.sleep(10)

      # Receive terminated NOTIFY
      notify_msg = build_notify_message(:terminated)
      :gen_statem.call(pid, {:notify_received, notify_msg})

      Process.sleep(20)

      refute Process.alive?(pid)
    end
  end

  describe "Notifier role - RFC 6665 Section 4.2" do
    setup do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :notifier,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      %{pid: pid, sub_id: sub_id}
    end

    test "can send NOTIFY from notifier in pending state", %{pid: pid} do
      # Notifier should be able to send initial NOTIFY
      result = :gen_statem.call(pid, {:send_notify, :pending, "state body"})

      assert {:ok, notify_msg} = result
      assert notify_msg.method == :notify
    end

    test "transitions to active after authorization", %{pid: pid} do
      :gen_statem.cast(pid, :authorize)

      Process.sleep(10)

      {state, _data} = :sys.get_state(pid)
      assert state == :active
    end

    test "can send NOTIFY from notifier in active state", %{pid: pid} do
      # Activate first
      :gen_statem.cast(pid, :authorize)
      Process.sleep(10)

      result = :gen_statem.call(pid, {:send_notify, :active, "state body"})

      assert {:ok, notify_msg} = result
      assert notify_msg.method == :notify
    end

    test "terminates subscription on request", %{pid: pid} do
      :gen_statem.cast(pid, :authorize)
      Process.sleep(10)

      :gen_statem.cast(pid, {:terminate, :deactivated})

      Process.sleep(20)

      refute Process.alive?(pid)
    end

    test "handles unsubscribe request (expires=0)", %{pid: pid} do
      :gen_statem.cast(pid, :authorize)
      Process.sleep(10)

      # Receive SUBSCRIBE with expires=0
      unsubscribe_msg = build_unsubscribe_message()
      :gen_statem.cast(pid, {:unsubscribe, unsubscribe_msg})

      Process.sleep(20)

      refute Process.alive?(pid)
    end
  end

  describe "Refresh timer handling - RFC 6665 Section 4.2.2" do
    test "subscriber sets refresh timer based on expires" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        # Very short expiry for testing
        expires: 1
      ]
      {:ok, pid} = Subscription.start_link(opts)

      # Activate the subscription with nil expires so original value is preserved
      response = build_response_with_expires(200, "OK", nil)
      :gen_statem.cast(pid, {:subscribe_response, response})

      Process.sleep(10)

      {state, data} = :sys.get_state(pid)
      assert state == :active

      # Verify expires value is preserved from init
      assert data.expires == 1
    end

    test "notifier sets expiry timer" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :notifier,
        dialog_pid: self(),
        event_package: "presence",
        expires: 1
      ]
      {:ok, pid} = Subscription.start_link(opts)

      :gen_statem.cast(pid, :authorize)
      Process.sleep(10)

      {state, data} = :sys.get_state(pid)
      assert state == :active
      assert data.expires == 1
    end

    test "updates expires on re-SUBSCRIBE response" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      # Initial activation
      response = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:subscribe_response, response})
      Process.sleep(10)

      # Re-SUBSCRIBE response with different expires
      resubscribe_response = build_response_with_expires(200, "OK", 7200)
      :gen_statem.cast(pid, {:subscribe_response, resubscribe_response})
      Process.sleep(10)

      {_state, data} = :sys.get_state(pid)
      assert data.expires == 7200
    end
  end

  describe "PUBLISH handling - RFC 3903" do
    test "notifier can receive PUBLISH request" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :notifier,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      :gen_statem.cast(pid, :authorize)
      Process.sleep(10)

      # Send PUBLISH to subscription
      publish_msg = build_publish_message()
      result = :gen_statem.call(pid, {:publish, publish_msg})

      assert result == :ok
    end

    test "PUBLISH updates subscription state" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :notifier,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      :gen_statem.cast(pid, :authorize)
      Process.sleep(10)

      publish_msg = build_publish_message()
      :gen_statem.call(pid, {:publish, publish_msg})

      {_state, data} = :sys.get_state(pid)
      # State body should be updated
      assert data.state_body != nil
    end
  end

  describe "Error handling and edge cases" do
    test "handles dialog termination" do
      dialog_pid = spawn(fn -> Process.sleep(5000) end)
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: dialog_pid,
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      # Activate
      response = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:subscribe_response, response})
      Process.sleep(10)

      # Kill dialog
      Process.exit(dialog_pid, :kill)
      Process.sleep(20)

      # Subscription should terminate when dialog dies
      refute Process.alive?(pid)
    end

    test "handles unknown events gracefully" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      :gen_statem.cast(pid, {:unknown_event, "data"})

      Process.sleep(10)

      # Should still be alive
      assert Process.alive?(pid)
    end

    test "handles unexpected call in pending state" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      result = :gen_statem.call(pid, {:unexpected_call, "data"})

      assert result == {:error, :unexpected_call}
      assert Process.alive?(pid)
    end
  end

  describe "Subscription lookup and management" do
    test "finds subscription by ID" do
      sub_id = unique_subscription_id()
      opts = [
        id: sub_id,
        role: :subscriber,
        dialog_pid: self(),
        event_package: "presence",
        expires: 3600
      ]
      {:ok, pid} = Subscription.start_link(opts)

      assert {:ok, ^pid} = Subscription.find(sub_id)
    end

    test "returns error for non-existent subscription" do
      assert {:error, :not_found} = Subscription.find("non-existent-sub")
    end

    test "counts active subscriptions" do
      # Create a few subscriptions through the supervisor
      for _ <- 1..3 do
        opts = [
          id: unique_subscription_id(),
          role: :subscriber,
          dialog_pid: self(),
          event_package: "presence",
          expires: 3600
        ]
        ParrotSip.Subscription.Supervisor.start_child(opts)
      end

      count = Subscription.count()
      assert count >= 3
    end
  end

  # Helper functions

  defp unique_subscription_id do
    "sub-#{:erlang.unique_integer([:positive])}"
  end

  defp build_subscribe_message do
    %Message{
      type: :request,
      method: :subscribe,
      request_uri: "sip:target@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-subscribe-#{unique_subscription_id()}"}
      },
      from: %From{
        display_name: "Subscriber",
        uri: "sip:subscriber@example.com",
        parameters: %{"tag" => "from-tag-#{unique_subscription_id()}"}
      },
      to: %To{
        display_name: "Notifier",
        uri: "sip:notifier@example.com",
        parameters: %{}
      },
      call_id: "subscribe-call-#{unique_subscription_id()}@example.com",
      cseq: %CSeq{number: 1, method: :subscribe},
      contact: %Contact{
        uri: "sip:subscriber@127.0.0.1:5060",
        parameters: %{}
      },
      event: %Event{event: "presence", parameters: %{}},
      expires: 3600,
      other_headers: %{},
      body: ""
    }
  end

  defp build_response_message(status, reason) do
    %Message{
      type: :response,
      status_code: status,
      reason_phrase: reason,
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-response"}
      },
      from: %From{
        display_name: "Subscriber",
        uri: "sip:subscriber@example.com",
        parameters: %{"tag" => "from-tag"}
      },
      to: %To{
        display_name: "Notifier",
        uri: "sip:notifier@example.com",
        parameters: %{"tag" => "to-tag"}
      },
      call_id: "subscribe-call@example.com",
      cseq: %CSeq{number: 1, method: :subscribe},
      expires: 3600,
      other_headers: %{},
      body: ""
    }
  end

  defp build_response_with_expires(status, reason, expires) do
    build_response_message(status, reason)
    |> Map.put(:expires, expires)
  end

  defp build_notify_message(subscription_state) do
    sub_state = SubscriptionState.new(subscription_state)

    %Message{
      type: :request,
      method: :notify,
      request_uri: "sip:subscriber@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-notify"}
      },
      from: %From{
        display_name: "Notifier",
        uri: "sip:notifier@example.com",
        parameters: %{"tag" => "from-tag"}
      },
      to: %To{
        display_name: "Subscriber",
        uri: "sip:subscriber@example.com",
        parameters: %{"tag" => "to-tag"}
      },
      call_id: "subscribe-call@example.com",
      cseq: %CSeq{number: 1, method: :notify},
      event: %Event{event: "presence", parameters: %{}},
      subscription_state: sub_state,
      other_headers: %{},
      body: "<?xml version=\"1.0\"?><presence/>"
    }
  end

  defp build_unsubscribe_message do
    %Message{
      type: :request,
      method: :subscribe,
      request_uri: "sip:notifier@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-unsubscribe"}
      },
      from: %From{
        display_name: "Subscriber",
        uri: "sip:subscriber@example.com",
        parameters: %{"tag" => "from-tag"}
      },
      to: %To{
        display_name: "Notifier",
        uri: "sip:notifier@example.com",
        parameters: %{"tag" => "to-tag"}
      },
      call_id: "subscribe-call@example.com",
      cseq: %CSeq{number: 2, method: :subscribe},
      event: %Event{event: "presence", parameters: %{}},
      # Expires=0 means unsubscribe
      expires: 0,
      other_headers: %{},
      body: ""
    }
  end

  defp build_publish_message do
    %Message{
      type: :request,
      method: :publish,
      request_uri: "sip:notifier@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-publish"}
      },
      from: %From{
        display_name: "Publisher",
        uri: "sip:publisher@example.com",
        parameters: %{"tag" => "from-tag"}
      },
      to: %To{
        display_name: "ESC",
        uri: "sip:esc@example.com",
        parameters: %{}
      },
      call_id: "publish-call@example.com",
      cseq: %CSeq{number: 1, method: :publish},
      event: %Event{event: "presence", parameters: %{}},
      expires: 3600,
      content_type: "application/pidf+xml",
      other_headers: %{},
      body: "<?xml version=\"1.0\"?><presence entity=\"sip:publisher@example.com\"/>"
    }
  end
end
