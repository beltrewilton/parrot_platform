defmodule ParrotMedia.WsAudioForker.CallbackTest do
  @moduledoc """
  Compile-time and runtime tests for WsAudioForker.Callback behaviour.

  Tests verify:
  1. Callback behaviour is defined with handle_fork_event/2 callback
  2. DefaultCallback module exists and implements Callback behaviour
  3. DefaultCallback.handle_fork_event/2 returns {:ok, state} for all event types
  4. A module implementing Callback must define handle_fork_event/2
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.WsAudioForker.Callback
  alias ParrotMedia.WsAudioForker.DefaultCallback

  # =============================================================================
  # Test module that properly implements the Callback behaviour
  # =============================================================================

  defmodule ValidCallbackHandler do
    @moduledoc false
    @behaviour Callback

    @impl true
    def init(args), do: {:ok, args}

    @impl true
    def handle_fork_event({:fork_event, _fork_id, :connected}, state) do
      {:ok, Map.put(state, :connected, true)}
    end

    @impl true
    def handle_fork_event({:fork_event, _fork_id, {:disconnected, reason}}, state) do
      {:ok, Map.put(state, :disconnected_reason, reason)}
    end

    @impl true
    def handle_fork_event({:fork_event, _fork_id, {:reconnecting, attempt}}, state) do
      {:ok, Map.put(state, :reconnect_attempt, attempt)}
    end

    @impl true
    def handle_fork_event({:fork_event, _fork_id, {:ws_message, data}}, state) do
      {:ok, Map.put(state, :last_message, data)}
    end

    @impl true
    def handle_fork_event({:fork_event, _fork_id, {:failed, reason}}, state) do
      {:stop, reason, Map.put(state, :failed, true)}
    end

    @impl true
    def handle_fork_event({:fork_event, _fork_id, {:backpressure_warning, drops}}, state) do
      {:ok, Map.put(state, :dropped_count, drops)}
    end

    @impl true
    def handle_fork_event(_event, state) do
      {:ok, state}
    end
  end

  # =============================================================================
  # Behaviour Definition Tests
  # =============================================================================

  describe "Callback behaviour definition" do
    test "Callback module exists and is loaded" do
      assert Code.ensure_loaded?(Callback)
    end

    test "Callback behaviour defines handle_fork_event/2 callback" do
      callbacks = Callback.behaviour_info(:callbacks)

      assert {:handle_fork_event, 2} in callbacks,
             "Expected handle_fork_event/2 in callbacks, got: #{inspect(callbacks)}"
    end

    test "Callback behaviour defines init/1 as optional callback" do
      optional_callbacks = Callback.behaviour_info(:optional_callbacks)

      assert {:init, 1} in optional_callbacks,
             "Expected init/1 in optional_callbacks, got: #{inspect(optional_callbacks)}"
    end

    test "handle_fork_event/2 is a required callback" do
      callbacks = Callback.behaviour_info(:callbacks)
      optional_callbacks = Callback.behaviour_info(:optional_callbacks)

      assert {:handle_fork_event, 2} in callbacks
      refute {:handle_fork_event, 2} in optional_callbacks
    end
  end

  # =============================================================================
  # DefaultCallback Module Tests
  # =============================================================================

  describe "DefaultCallback module" do
    test "DefaultCallback module exists and is loaded" do
      assert Code.ensure_loaded?(DefaultCallback)
    end

    test "DefaultCallback implements Callback behaviour" do
      # Check that the module compiles with @behaviour Callback
      behaviours = DefaultCallback.__info__(:attributes)[:behaviour] || []

      assert Callback in behaviours,
             "Expected DefaultCallback to implement Callback behaviour, got: #{inspect(behaviours)}"
    end

    test "DefaultCallback exports handle_fork_event/2" do
      assert function_exported?(DefaultCallback, :handle_fork_event, 2)
    end

    test "DefaultCallback exports init/1" do
      assert function_exported?(DefaultCallback, :init, 1)
    end
  end

  # =============================================================================
  # DefaultCallback.init/1 Tests
  # =============================================================================

  describe "DefaultCallback.init/1" do
    test "returns {:ok, state} with empty map args" do
      assert {:ok, %{}} = DefaultCallback.init(%{})
    end

    test "returns {:ok, state} with provided args" do
      args = %{custom: "data", foo: :bar}
      assert {:ok, ^args} = DefaultCallback.init(args)
    end

    test "returns {:ok, state} with nil args" do
      assert {:ok, nil} = DefaultCallback.init(nil)
    end

    test "returns {:ok, state} with list args" do
      args = [a: 1, b: 2]
      assert {:ok, ^args} = DefaultCallback.init(args)
    end
  end

  # =============================================================================
  # DefaultCallback.handle_fork_event/2 - Connection Events
  # =============================================================================

  describe "DefaultCallback.handle_fork_event/2 - :connected event" do
    test "returns {:ok, state} for connected event" do
      fork_id = "fork-123"
      state = %{test: true}
      event = {:fork_event, fork_id, :connected}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "preserves state unchanged for connected event" do
      fork_id = "fork-abc"
      state = %{counter: 42, name: "test"}
      event = {:fork_event, fork_id, :connected}

      assert {:ok, returned_state} = DefaultCallback.handle_fork_event(event, state)
      assert returned_state == state
    end
  end

  describe "DefaultCallback.handle_fork_event/2 - :disconnected event" do
    test "returns {:ok, state} for disconnected event with reason" do
      fork_id = "fork-456"
      state = %{}
      event = {:fork_event, fork_id, {:disconnected, :normal}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles disconnected with error reason" do
      fork_id = "fork-789"
      state = %{data: "preserved"}
      event = {:fork_event, fork_id, {:disconnected, {:error, :connection_closed}}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles disconnected with timeout reason" do
      fork_id = "fork-xyz"
      state = %{}
      event = {:fork_event, fork_id, {:disconnected, :timeout}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end
  end

  describe "DefaultCallback.handle_fork_event/2 - :reconnecting event" do
    test "returns {:ok, state} for reconnecting event with attempt 1" do
      fork_id = "fork-reconnect"
      state = %{}
      event = {:fork_event, fork_id, {:reconnecting, 1}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "returns {:ok, state} for reconnecting event with higher attempt" do
      fork_id = "fork-reconnect"
      state = %{existing: :data}
      event = {:fork_event, fork_id, {:reconnecting, 5}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles maximum retry attempt" do
      fork_id = "fork-max"
      state = %{}
      event = {:fork_event, fork_id, {:reconnecting, 10}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end
  end

  describe "DefaultCallback.handle_fork_event/2 - :failed event" do
    test "returns {:ok, state} for failed event with reason" do
      fork_id = "fork-failed"
      state = %{}
      event = {:fork_event, fork_id, {:failed, :max_retries_exceeded}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles failed with connection refused reason" do
      fork_id = "fork-refused"
      state = %{call_id: "call-123"}
      event = {:fork_event, fork_id, {:failed, :econnrefused}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles failed with complex error tuple" do
      fork_id = "fork-complex-error"
      state = %{}
      event = {:fork_event, fork_id, {:failed, {:websocket_error, 500, "Internal Server Error"}}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end
  end

  # =============================================================================
  # DefaultCallback.handle_fork_event/2 - Data Events
  # =============================================================================

  describe "DefaultCallback.handle_fork_event/2 - :ws_message event" do
    test "returns {:ok, state} for ws_message with binary data" do
      fork_id = "fork-msg"
      state = %{}
      binary_data = <<0, 1, 2, 3, 4, 5>>
      event = {:fork_event, fork_id, {:ws_message, binary_data}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "returns {:ok, state} for ws_message with string data" do
      fork_id = "fork-json"
      state = %{}
      json_data = ~s({"transcript": "Hello world", "is_final": true})
      event = {:fork_event, fork_id, {:ws_message, json_data}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles empty binary message" do
      fork_id = "fork-empty"
      state = %{existing: :state}
      event = {:fork_event, fork_id, {:ws_message, <<>>}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles large binary message" do
      fork_id = "fork-large"
      state = %{}
      # Simulate a large audio chunk (e.g., 960 bytes for 20ms of audio)
      large_data = :crypto.strong_rand_bytes(960)
      event = {:fork_event, fork_id, {:ws_message, large_data}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end
  end

  describe "DefaultCallback.handle_fork_event/2 - :backpressure_warning event" do
    test "returns {:ok, state} for backpressure_warning with drop count" do
      fork_id = "fork-backpressure"
      state = %{}
      event = {:fork_event, fork_id, {:backpressure_warning, 5}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles high drop count" do
      fork_id = "fork-high-drops"
      state = %{session: "active"}
      event = {:fork_event, fork_id, {:backpressure_warning, 100}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles single frame drop" do
      fork_id = "fork-single-drop"
      state = %{}
      event = {:fork_event, fork_id, {:backpressure_warning, 1}}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end
  end

  # =============================================================================
  # Custom Callback Implementation Tests
  # =============================================================================

  describe "ValidCallbackHandler - custom implementation" do
    test "handles :connected event and updates state" do
      fork_id = "fork-custom"
      state = %{}
      event = {:fork_event, fork_id, :connected}

      assert {:ok, new_state} = ValidCallbackHandler.handle_fork_event(event, state)
      assert new_state.connected == true
    end

    test "handles :disconnected event and records reason" do
      fork_id = "fork-custom"
      state = %{}
      event = {:fork_event, fork_id, {:disconnected, :network_error}}

      assert {:ok, new_state} = ValidCallbackHandler.handle_fork_event(event, state)
      assert new_state.disconnected_reason == :network_error
    end

    test "handles :reconnecting event and tracks attempt number" do
      fork_id = "fork-custom"
      state = %{}
      event = {:fork_event, fork_id, {:reconnecting, 3}}

      assert {:ok, new_state} = ValidCallbackHandler.handle_fork_event(event, state)
      assert new_state.reconnect_attempt == 3
    end

    test "handles :ws_message event and stores data" do
      fork_id = "fork-custom"
      state = %{}
      data = ~s({"result": "transcription"})
      event = {:fork_event, fork_id, {:ws_message, data}}

      assert {:ok, new_state} = ValidCallbackHandler.handle_fork_event(event, state)
      assert new_state.last_message == data
    end

    test "handles :failed event and returns :stop" do
      fork_id = "fork-custom"
      state = %{}
      event = {:fork_event, fork_id, {:failed, :permanent_failure}}

      assert {:stop, :permanent_failure, new_state} =
               ValidCallbackHandler.handle_fork_event(event, state)

      assert new_state.failed == true
    end

    test "handles :backpressure_warning event and tracks dropped count" do
      fork_id = "fork-custom"
      state = %{}
      event = {:fork_event, fork_id, {:backpressure_warning, 42}}

      assert {:ok, new_state} = ValidCallbackHandler.handle_fork_event(event, state)
      assert new_state.dropped_count == 42
    end

    test "handles unknown events with catch-all clause" do
      fork_id = "fork-custom"
      state = %{preserved: true}
      event = {:fork_event, fork_id, :unknown_event_type}

      assert {:ok, new_state} = ValidCallbackHandler.handle_fork_event(event, state)
      assert new_state == state
    end
  end

  # =============================================================================
  # Callback Return Value Tests
  # =============================================================================

  describe "Callback return values" do
    test "{:ok, state} is a valid return for handle_fork_event/2" do
      fork_id = "fork-return"
      state = %{data: "test"}
      event = {:fork_event, fork_id, :connected}

      result = DefaultCallback.handle_fork_event(event, state)

      assert match?({:ok, _}, result)
    end

    test "{:stop, reason, state} is a valid return for handle_fork_event/2" do
      fork_id = "fork-stop"
      state = %{}
      event = {:fork_event, fork_id, {:failed, :test_failure}}

      result = ValidCallbackHandler.handle_fork_event(event, state)

      assert match?({:stop, _, _}, result)
    end

    test "returned state can be any term" do
      fork_id = "fork-any-state"

      # Test with map state
      assert {:ok, %{}} = DefaultCallback.handle_fork_event({:fork_event, fork_id, :connected}, %{})

      # Test with list state
      assert {:ok, []} = DefaultCallback.handle_fork_event({:fork_event, fork_id, :connected}, [])

      # Test with tuple state
      assert {:ok, {:state, 1}} =
               DefaultCallback.handle_fork_event({:fork_event, fork_id, :connected}, {:state, 1})

      # Test with nil state
      assert {:ok, nil} = DefaultCallback.handle_fork_event({:fork_event, fork_id, :connected}, nil)
    end
  end

  # =============================================================================
  # Fork ID Variations Tests
  # =============================================================================

  describe "fork_id variations" do
    test "handles UUID-style fork_id" do
      fork_id = "550e8400-e29b-41d4-a716-446655440000"
      state = %{}
      event = {:fork_event, fork_id, :connected}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles simple string fork_id" do
      fork_id = "fork-1"
      state = %{}
      event = {:fork_event, fork_id, :connected}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles fork_id with special characters" do
      fork_id = "fork:session/123#abc"
      state = %{}
      event = {:fork_event, fork_id, :connected}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end

    test "handles empty string fork_id" do
      fork_id = ""
      state = %{}
      event = {:fork_event, fork_id, :connected}

      assert {:ok, ^state} = DefaultCallback.handle_fork_event(event, state)
    end
  end

  # =============================================================================
  # Edge Cases and Error Handling
  # =============================================================================

  describe "edge cases" do
    test "handles multiple sequential events" do
      fork_id = "fork-sequential"
      initial_state = %{}

      # Simulate connection lifecycle
      {:ok, state1} =
        DefaultCallback.handle_fork_event({:fork_event, fork_id, :connected}, initial_state)

      {:ok, state2} =
        DefaultCallback.handle_fork_event(
          {:fork_event, fork_id, {:ws_message, "data"}},
          state1
        )

      {:ok, state3} =
        DefaultCallback.handle_fork_event(
          {:fork_event, fork_id, {:disconnected, :normal}},
          state2
        )

      # State should be preserved through the lifecycle
      assert state3 == initial_state
    end

    test "handles events from multiple fork_ids" do
      state = %{}

      {:ok, state1} =
        DefaultCallback.handle_fork_event({:fork_event, "fork-1", :connected}, state)

      {:ok, state2} =
        DefaultCallback.handle_fork_event({:fork_event, "fork-2", :connected}, state1)

      {:ok, state3} =
        DefaultCallback.handle_fork_event(
          {:fork_event, "fork-1", {:ws_message, "data1"}},
          state2
        )

      {:ok, final_state} =
        DefaultCallback.handle_fork_event(
          {:fork_event, "fork-2", {:ws_message, "data2"}},
          state3
        )

      # DefaultCallback should preserve state unchanged
      assert final_state == state
    end

    test "handles rapid reconnection events" do
      fork_id = "fork-rapid"
      state = %{}

      events = [
        {:fork_event, fork_id, {:reconnecting, 1}},
        {:fork_event, fork_id, {:reconnecting, 2}},
        {:fork_event, fork_id, {:reconnecting, 3}},
        {:fork_event, fork_id, :connected}
      ]

      final_state =
        Enum.reduce(events, state, fn event, acc ->
          {:ok, new_state} = DefaultCallback.handle_fork_event(event, acc)
          new_state
        end)

      assert final_state == state
    end
  end

  # =============================================================================
  # Compile-time Behaviour Enforcement Tests
  # =============================================================================

  describe "behaviour enforcement at compile-time" do
    @tag :compile_time
    test "module implementing Callback without handle_fork_event/2 should fail compilation" do
      # This test verifies that the behaviour is properly enforced
      # by checking that the behaviour info is correctly defined.
      #
      # A module that declares @behaviour Callback but doesn't implement
      # handle_fork_event/2 will produce a compiler warning about missing callback.
      #
      # We can't easily test compile-time failures in ExUnit, but we verify
      # the behaviour definition is correct.

      callbacks = Callback.behaviour_info(:callbacks)
      assert {:handle_fork_event, 2} in callbacks

      # Verify the arity is correct
      callback_arities = Enum.map(callbacks, fn {name, arity} -> {name, arity} end)
      assert {:handle_fork_event, 2} in callback_arities
    end

    test "behaviour_info returns proper callback list" do
      callbacks = Callback.behaviour_info(:callbacks)

      assert is_list(callbacks)
      assert length(callbacks) >= 1

      # handle_fork_event/2 must be present
      callback_names = Enum.map(callbacks, fn {name, _} -> name end)
      assert :handle_fork_event in callback_names
    end

    test "behaviour_info returns proper optional_callbacks list" do
      optional_callbacks = Callback.behaviour_info(:optional_callbacks)

      assert is_list(optional_callbacks)

      # init/1 should be optional
      optional_names = Enum.map(optional_callbacks, fn {name, _} -> name end)
      assert :init in optional_names
    end
  end
end
