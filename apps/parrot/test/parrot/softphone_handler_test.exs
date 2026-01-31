defmodule Parrot.SoftphoneHandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.SoftphoneHandler

  describe "behavior definition" do
    test "defines required callbacks" do
      callbacks = SoftphoneHandler.behaviour_info(:callbacks)

      # Registration callbacks
      assert {:handle_registered, 2} in callbacks
      assert {:handle_registration_failed, 2} in callbacks
      assert {:handle_unregistered, 1} in callbacks

      # Presence callbacks
      assert {:handle_presence_update, 3} in callbacks
      assert {:handle_subscription_terminated, 3} in callbacks
      assert {:handle_publish_success, 1} in callbacks
      assert {:handle_publish_failed, 2} in callbacks

      # Call callbacks
      assert {:handle_incoming_call, 2} in callbacks
      assert {:handle_call_answered, 2} in callbacks
      assert {:handle_call_rejected, 3} in callbacks
      assert {:handle_call_ended, 3} in callbacks
      assert {:handle_ringing, 2} in callbacks
    end

    test "defines optional callbacks" do
      optional = SoftphoneHandler.behaviour_info(:optional_callbacks)

      assert {:handle_registration_failed, 2} in optional
      assert {:handle_unregistered, 1} in optional
      assert {:handle_subscription_terminated, 3} in optional
      assert {:handle_publish_success, 1} in optional
      assert {:handle_publish_failed, 2} in optional
      assert {:handle_ringing, 2} in optional

      # Required callbacks should NOT be optional
      refute {:handle_registered, 2} in optional
      refute {:handle_presence_update, 3} in optional
      refute {:handle_incoming_call, 2} in optional
      refute {:handle_call_answered, 2} in optional
      refute {:handle_call_rejected, 3} in optional
      refute {:handle_call_ended, 3} in optional
    end
  end

  describe "__using__/1 macro" do
    defmodule MinimalHandler do
      use Parrot.SoftphoneHandler

      @impl true
      def handle_registered(_info, state), do: {:ok, state}

      @impl true
      def handle_presence_update(_presentity, _presence, state), do: {:ok, state}

      @impl true
      def handle_incoming_call(_call_info, state), do: {:ring, state}

      @impl true
      def handle_call_answered(_call_id, state), do: {:ok, state}

      @impl true
      def handle_call_rejected(_call_id, _reason, state), do: {:ok, state}

      @impl true
      def handle_call_ended(_call_id, _reason, state), do: {:ok, state}
    end

    test "provides default implementations for optional callbacks" do
      state = %{test: :state}

      # Optional callbacks should have defaults
      assert {:ok, ^state} = MinimalHandler.handle_registration_failed(:timeout, state)
      assert {:ok, ^state} = MinimalHandler.handle_unregistered(state)
      assert {:ok, ^state} = MinimalHandler.handle_subscription_terminated("sip:bob@example.com", :expired, state)
      assert {:ok, ^state} = MinimalHandler.handle_publish_success(state)
      assert {:ok, ^state} = MinimalHandler.handle_publish_failed(:network_error, state)
      assert {:ok, ^state} = MinimalHandler.handle_ringing("call-123", state)
    end

    test "allows overriding optional callbacks" do
      defmodule OverrideHandler do
        use Parrot.SoftphoneHandler

        @impl true
        def handle_registered(_info, state), do: {:ok, state}

        @impl true
        def handle_presence_update(_presentity, _presence, state), do: {:ok, state}

        @impl true
        def handle_incoming_call(_call_info, state), do: {:ring, state}

        @impl true
        def handle_call_answered(_call_id, state), do: {:ok, state}

        @impl true
        def handle_call_rejected(_call_id, _reason, state), do: {:ok, state}

        @impl true
        def handle_call_ended(_call_id, _reason, state), do: {:ok, state}

        # Override optional callback
        @impl true
        def handle_registration_failed(reason, state) do
          {:retry, 5000, Map.put(state, :last_failure, reason)}
        end

        @impl true
        def handle_ringing(call_id, state) do
          {:ok, Map.put(state, :ringing_call, call_id)}
        end
      end

      state = %{}

      # Overridden callbacks should use custom implementation
      assert {:retry, 5000, %{last_failure: :auth_failed}} =
               OverrideHandler.handle_registration_failed(:auth_failed, state)

      assert {:ok, %{ringing_call: "call-456"}} =
               OverrideHandler.handle_ringing("call-456", state)
    end
  end

  describe "callback return types" do
    defmodule TypeTestHandler do
      use Parrot.SoftphoneHandler

      @impl true
      def handle_registered(info, state) do
        {:ok, Map.put(state, :registered_info, info)}
      end

      @impl true
      def handle_presence_update(presentity, presence, state) do
        {:ok, Map.put(state, :presence, {presentity, presence})}
      end

      @impl true
      def handle_incoming_call(_call_info, state) do
        case state.auto_answer do
          true -> {:answer, [codecs: [:pcma]], state}
          false -> {:ring, state}
          :reject -> {:reject, 486, state}
        end
      end

      @impl true
      def handle_call_answered(call_id, state) do
        {:ok, Map.put(state, :answered_call, call_id)}
      end

      @impl true
      def handle_call_rejected(call_id, reason, state) do
        {:ok, Map.put(state, :rejected, {call_id, reason})}
      end

      @impl true
      def handle_call_ended(call_id, reason, state) do
        {:ok, Map.put(state, :ended, {call_id, reason})}
      end
    end

    test "handle_registered returns {:ok, state}" do
      info = %{aor: "sip:alice@example.com", expires: 3600, contacts: ["sip:alice@192.168.1.100"]}
      state = %{}

      assert {:ok, %{registered_info: ^info}} = TypeTestHandler.handle_registered(info, state)
    end

    test "handle_presence_update returns {:ok, state}" do
      presence = %{status: :open, note: "Available"}
      state = %{}

      assert {:ok, %{presence: {"sip:bob@example.com", ^presence}}} =
               TypeTestHandler.handle_presence_update("sip:bob@example.com", presence, state)
    end

    test "handle_incoming_call can return {:answer, opts, state}" do
      call_info = %{call_id: "abc123", from: "sip:bob@example.com", to: "sip:alice@example.com"}
      state = %{auto_answer: true}

      assert {:answer, [codecs: [:pcma]], %{auto_answer: true}} =
               TypeTestHandler.handle_incoming_call(call_info, state)
    end

    test "handle_incoming_call can return {:ring, state}" do
      call_info = %{call_id: "abc123", from: "sip:bob@example.com", to: "sip:alice@example.com"}
      state = %{auto_answer: false}

      assert {:ring, %{auto_answer: false}} =
               TypeTestHandler.handle_incoming_call(call_info, state)
    end

    test "handle_incoming_call can return {:reject, status_code, state}" do
      call_info = %{call_id: "abc123", from: "sip:bob@example.com", to: "sip:alice@example.com"}
      state = %{auto_answer: :reject}

      assert {:reject, 486, %{auto_answer: :reject}} =
               TypeTestHandler.handle_incoming_call(call_info, state)
    end

    test "handle_registration_failed can return {:retry, delay, state}" do
      defmodule RetryHandler do
        use Parrot.SoftphoneHandler

        @impl true
        def handle_registered(_info, state), do: {:ok, state}
        @impl true
        def handle_presence_update(_p, _s, state), do: {:ok, state}
        @impl true
        def handle_incoming_call(_c, state), do: {:ring, state}
        @impl true
        def handle_call_answered(_c, state), do: {:ok, state}
        @impl true
        def handle_call_rejected(_c, _r, state), do: {:ok, state}
        @impl true
        def handle_call_ended(_c, _r, state), do: {:ok, state}

        @impl true
        def handle_registration_failed(:timeout, state) do
          {:retry, 10_000, Map.update(state, :retry_count, 1, &(&1 + 1))}
        end

        def handle_registration_failed(_reason, state) do
          {:ok, state}
        end
      end

      state = %{retry_count: 0}

      assert {:retry, 10_000, %{retry_count: 1}} =
               RetryHandler.handle_registration_failed(:timeout, state)
    end
  end
end
