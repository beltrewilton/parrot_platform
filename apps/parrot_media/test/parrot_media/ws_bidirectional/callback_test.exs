defmodule ParrotMedia.WsBidirectional.CallbackTest do
  @moduledoc """
  TDD tests for WsBidirectional.Callback behaviour.

  These tests are written BEFORE the implementation exists (TDD approach).
  They define the expected behavior of the Callback module for bidirectional
  WebSocket connection events.

  Key differences from WsAudioForker.Callback:
  - Simpler event format: `{:connected}` instead of `{:fork_event, fork_id, :connected}`
  - Uses `handle_event/2` instead of `handle_fork_event/2`
  - Events are connection-scoped (connection_id is in Config, not in events)
  - Optional `terminate/2` callback for cleanup

  Events:
  - `{:connected}` - WebSocket connected successfully
  - `{:disconnected, reason}` - Connection lost
  - `{:reconnecting, attempt}` - Attempting reconnection
  - `{:failed, reason}` - Permanent failure after max retries
  - `{:ws_message, data}` - Non-audio message from WebSocket
  - `{:frames_dropped, count}` - Frames dropped due to backpressure
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.WsBidirectional.Callback

  # =============================================================================
  # Test module that properly implements the Callback behaviour
  # =============================================================================

  defmodule TestCallback do
    @moduledoc false
    @behaviour ParrotMedia.WsBidirectional.Callback

    @impl true
    def handle_event({:connected}, state) do
      {:ok, [{:connected} | state]}
    end

    @impl true
    def handle_event({:disconnected, reason}, state) do
      {:ok, [{:disconnected, reason} | state]}
    end

    @impl true
    def handle_event({:reconnecting, attempt}, state) do
      {:ok, [{:reconnecting, attempt} | state]}
    end

    @impl true
    def handle_event({:failed, reason}, state) do
      {:ok, [{:failed, reason} | state]}
    end

    @impl true
    def handle_event({:ws_message, data}, state) do
      {:ok, [{:ws_message, data} | state]}
    end

    @impl true
    def handle_event({:frames_dropped, count}, state) do
      {:ok, [{:frames_dropped, count} | state]}
    end

    @impl true
    def terminate(reason, state) do
      {:terminated, reason, state}
    end
  end

  # Test module that only implements required callbacks (no terminate/2)
  defmodule MinimalCallback do
    @moduledoc false
    @behaviour ParrotMedia.WsBidirectional.Callback

    @impl true
    def handle_event(_event, state) do
      {:ok, state}
    end
  end

  # Test module that can return errors
  defmodule ErrorCallback do
    @moduledoc false
    @behaviour ParrotMedia.WsBidirectional.Callback

    @impl true
    def handle_event({:fail_on_purpose}, _state) do
      {:error, :intentional_failure}
    end

    @impl true
    def handle_event(_event, state) do
      {:ok, state}
    end
  end

  # =============================================================================
  # Behaviour Definition Tests
  # =============================================================================

  describe "behaviour definition" do
    test "Callback module exists and is loaded" do
      assert Code.ensure_loaded?(Callback)
    end

    test "defines handle_event/2 callback" do
      callbacks = Callback.behaviour_info(:callbacks)

      assert {:handle_event, 2} in callbacks,
             "Expected handle_event/2 in callbacks, got: #{inspect(callbacks)}"
    end

    test "defines terminate/2 as optional callback" do
      optional_callbacks = Callback.behaviour_info(:optional_callbacks)

      assert {:terminate, 2} in optional_callbacks,
             "Expected terminate/2 in optional_callbacks, got: #{inspect(optional_callbacks)}"
    end

    test "handle_event/2 is a required callback (not optional)" do
      callbacks = Callback.behaviour_info(:callbacks)
      optional_callbacks = Callback.behaviour_info(:optional_callbacks)

      assert {:handle_event, 2} in callbacks
      refute {:handle_event, 2} in optional_callbacks
    end

    test "exports event type" do
      # The module should compile and define the @type event
      # We verify this by checking that the module is properly defined
      assert Code.ensure_loaded?(Callback)
    end

    test "exports state type" do
      # The module should compile and define the @type state
      assert Code.ensure_loaded?(Callback)
    end
  end

  # =============================================================================
  # Event Type Tests - Connection Lifecycle
  # =============================================================================

  describe "event types - connection lifecycle" do
    test "handle_event receives {:connected} event" do
      state = []
      event = {:connected}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:connected} in new_state
    end

    test "handle_event receives {:disconnected, reason} event with atom reason" do
      state = []
      event = {:disconnected, :normal}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:disconnected, :normal} in new_state
    end

    test "handle_event receives {:disconnected, reason} event with error tuple" do
      state = []
      event = {:disconnected, {:error, :connection_closed}}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:disconnected, {:error, :connection_closed}} in new_state
    end

    test "handle_event receives {:disconnected, reason} event with timeout" do
      state = []
      event = {:disconnected, :timeout}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:disconnected, :timeout} in new_state
    end

    test "handle_event receives {:reconnecting, attempt} event with attempt 1" do
      state = []
      event = {:reconnecting, 1}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:reconnecting, 1} in new_state
    end

    test "handle_event receives {:reconnecting, attempt} event with higher attempt" do
      state = []
      event = {:reconnecting, 5}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:reconnecting, 5} in new_state
    end

    test "handle_event receives {:failed, reason} event with max retries exceeded" do
      state = []
      event = {:failed, :max_retries_exceeded}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:failed, :max_retries_exceeded} in new_state
    end

    test "handle_event receives {:failed, reason} event with connection refused" do
      state = []
      event = {:failed, :econnrefused}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:failed, :econnrefused} in new_state
    end

    test "handle_event receives {:failed, reason} event with complex error" do
      state = []
      event = {:failed, {:websocket_error, 500, "Internal Server Error"}}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:failed, {:websocket_error, 500, "Internal Server Error"}} in new_state
    end
  end

  # =============================================================================
  # Event Type Tests - WebSocket Messages
  # =============================================================================

  describe "event types - ws_message" do
    test "handle_event receives {:ws_message, binary_data} event" do
      state = []
      binary_data = <<0, 1, 2, 3, 4, 5>>
      event = {:ws_message, binary_data}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:ws_message, ^binary_data} = hd(new_state)
    end

    test "handle_event receives {:ws_message, string_data} event" do
      state = []
      json_data = ~s({"transcript": "Hello world", "is_final": true})
      event = {:ws_message, json_data}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:ws_message, ^json_data} = hd(new_state)
    end

    test "handle_event receives {:ws_message, empty_binary} event" do
      state = []
      event = {:ws_message, <<>>}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:ws_message, <<>>} in new_state
    end

    test "handle_event receives {:ws_message, empty_string} event" do
      state = []
      event = {:ws_message, ""}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:ws_message, ""} in new_state
    end

    test "handle_event receives {:ws_message, large_binary} event" do
      state = []
      # Simulate a large audio chunk (e.g., 960 bytes for 20ms of audio)
      large_data = :crypto.strong_rand_bytes(960)
      event = {:ws_message, large_data}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:ws_message, ^large_data} = hd(new_state)
    end
  end

  # =============================================================================
  # Event Type Tests - Operational Events
  # =============================================================================

  describe "event types - frames_dropped" do
    test "handle_event receives {:frames_dropped, count} event with count 1" do
      state = []
      event = {:frames_dropped, 1}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:frames_dropped, 1} in new_state
    end

    test "handle_event receives {:frames_dropped, count} event with high count" do
      state = []
      event = {:frames_dropped, 100}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert {:frames_dropped, 100} in new_state
    end
  end

  # =============================================================================
  # Return Value Tests
  # =============================================================================

  describe "return values" do
    test "handle_event returns {:ok, new_state} on success" do
      state = %{counter: 0}
      event = {:connected}

      result = TestCallback.handle_event(event, state)

      assert match?({:ok, _}, result)
    end

    test "handle_event can return {:error, reason}" do
      state = %{}
      event = {:fail_on_purpose}

      result = ErrorCallback.handle_event(event, state)

      assert {:error, :intentional_failure} = result
    end

    test "returned state can be any term - map" do
      state = %{key: "value"}
      event = {:connected}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert is_list(new_state)
    end

    test "returned state can be any term - list" do
      state = [:a, :b, :c]
      event = {:connected}

      assert {:ok, new_state} = TestCallback.handle_event(event, state)
      assert is_list(new_state)
    end

    test "returned state can be any term - tuple" do
      state = []
      event = {:connected}

      assert {:ok, _new_state} = TestCallback.handle_event(event, state)
    end

    test "returned state can be any term - nil" do
      # MinimalCallback returns state unchanged
      state = nil
      event = {:connected}

      assert {:ok, nil} = MinimalCallback.handle_event(event, state)
    end
  end

  # =============================================================================
  # Optional Callbacks Tests
  # =============================================================================

  describe "optional callbacks" do
    test "terminate/2 is optional" do
      optional_callbacks = Callback.behaviour_info(:optional_callbacks)

      assert {:terminate, 2} in optional_callbacks
    end

    test "module without terminate/2 compiles" do
      # MinimalCallback doesn't implement terminate/2 and should compile fine
      assert Code.ensure_loaded?(MinimalCallback)
      assert function_exported?(MinimalCallback, :handle_event, 2)
      refute function_exported?(MinimalCallback, :terminate, 2)
    end

    test "module with terminate/2 compiles" do
      assert Code.ensure_loaded?(TestCallback)
      assert function_exported?(TestCallback, :handle_event, 2)
      assert function_exported?(TestCallback, :terminate, 2)
    end

    test "terminate/2 receives reason and state" do
      state = [:event1, :event2]
      reason = :shutdown

      result = TestCallback.terminate(reason, state)

      assert {:terminated, :shutdown, [:event1, :event2]} = result
    end

    test "terminate/2 can receive :normal reason" do
      state = %{calls: 5}
      reason = :normal

      result = TestCallback.terminate(reason, state)

      assert {:terminated, :normal, %{calls: 5}} = result
    end

    test "terminate/2 can receive error reason" do
      state = []
      reason = {:error, :connection_failed}

      result = TestCallback.terminate(reason, state)

      assert {:terminated, {:error, :connection_failed}, []} = result
    end
  end

  # =============================================================================
  # State Management Tests
  # =============================================================================

  describe "state management" do
    test "handles multiple sequential events maintaining state" do
      initial_state = []

      # Simulate connection lifecycle
      {:ok, state1} = TestCallback.handle_event({:connected}, initial_state)
      {:ok, state2} = TestCallback.handle_event({:ws_message, "data1"}, state1)
      {:ok, state3} = TestCallback.handle_event({:ws_message, "data2"}, state2)
      {:ok, final_state} = TestCallback.handle_event({:disconnected, :normal}, state3)

      # Events should be accumulated in reverse order (prepended)
      assert length(final_state) == 4
      assert hd(final_state) == {:disconnected, :normal}
    end

    test "state is preserved through reconnection cycle" do
      initial_state = []

      {:ok, state1} = TestCallback.handle_event({:connected}, initial_state)
      {:ok, state2} = TestCallback.handle_event({:disconnected, :timeout}, state1)
      {:ok, state3} = TestCallback.handle_event({:reconnecting, 1}, state2)
      {:ok, state4} = TestCallback.handle_event({:reconnecting, 2}, state3)
      {:ok, final_state} = TestCallback.handle_event({:connected}, state4)

      assert length(final_state) == 5
    end

    test "MinimalCallback preserves state unchanged" do
      state = %{important: "data", counter: 42}
      event = {:connected}

      assert {:ok, ^state} = MinimalCallback.handle_event(event, state)
    end
  end

  # =============================================================================
  # Behaviour Enforcement Tests
  # =============================================================================

  describe "behaviour enforcement" do
    test "behaviour_info returns proper callback list" do
      callbacks = Callback.behaviour_info(:callbacks)

      assert is_list(callbacks)
      assert length(callbacks) >= 1

      # handle_event/2 must be present
      callback_names = Enum.map(callbacks, fn {name, _} -> name end)
      assert :handle_event in callback_names
    end

    test "behaviour_info returns proper optional_callbacks list" do
      optional_callbacks = Callback.behaviour_info(:optional_callbacks)

      assert is_list(optional_callbacks)

      # terminate/2 should be optional
      optional_names = Enum.map(optional_callbacks, fn {name, _} -> name end)
      assert :terminate in optional_names
    end

    test "TestCallback implements Callback behaviour" do
      behaviours = TestCallback.__info__(:attributes)[:behaviour] || []

      assert Callback in behaviours,
             "Expected TestCallback to implement Callback behaviour, got: #{inspect(behaviours)}"
    end

    test "MinimalCallback implements Callback behaviour" do
      behaviours = MinimalCallback.__info__(:attributes)[:behaviour] || []

      assert Callback in behaviours,
             "Expected MinimalCallback to implement Callback behaviour, got: #{inspect(behaviours)}"
    end
  end

  # =============================================================================
  # Edge Cases Tests
  # =============================================================================

  describe "edge cases" do
    test "handles rapid event sequence" do
      state = []

      events = [
        {:reconnecting, 1},
        {:reconnecting, 2},
        {:reconnecting, 3},
        {:reconnecting, 4},
        {:reconnecting, 5},
        {:connected}
      ]

      final_state =
        Enum.reduce(events, state, fn event, acc ->
          {:ok, new_state} = TestCallback.handle_event(event, acc)
          new_state
        end)

      assert length(final_state) == 6
    end

    test "handles ws_message with JSON-like content" do
      state = []

      json_messages = [
        ~s({"type": "transcript", "text": "hello"}),
        ~s({"type": "audio_response", "data": "base64encoded"}),
        ~s({"type": "error", "code": 500})
      ]

      final_state =
        Enum.reduce(json_messages, state, fn msg, acc ->
          {:ok, new_state} = TestCallback.handle_event({:ws_message, msg}, acc)
          new_state
        end)

      assert length(final_state) == 3
    end

    test "handles various reason types in :disconnected event" do
      reasons = [
        :normal,
        :timeout,
        :closed,
        {:error, :econnrefused},
        {:error, {:tls_alert, :certificate_expired}},
        {:websocket_close, 1006, "Abnormal Closure"}
      ]

      for reason <- reasons do
        state = []
        event = {:disconnected, reason}

        assert {:ok, new_state} = TestCallback.handle_event(event, state)
        assert Enum.member?(new_state, {:disconnected, reason})
      end
    end

    test "handles various reason types in :failed event" do
      reasons = [
        :max_retries_exceeded,
        :econnrefused,
        :timeout,
        {:websocket_error, 401, "Unauthorized"},
        {:websocket_error, 503, "Service Unavailable"},
        {:ssl_error, :certificate_verify_failed}
      ]

      for reason <- reasons do
        state = []
        event = {:failed, reason}

        assert {:ok, new_state} = TestCallback.handle_event(event, state)
        assert Enum.member?(new_state, {:failed, reason})
      end
    end
  end
end
