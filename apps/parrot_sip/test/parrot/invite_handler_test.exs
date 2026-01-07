defmodule Parrot.InviteHandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.InviteHandler

  describe "behaviour callbacks" do
    test "defines handle_invite/1 as required callback" do
      callbacks = InviteHandler.behaviour_info(:callbacks)

      assert {:handle_invite, 1} in callbacks
    end

    test "defines all expected callbacks" do
      callbacks = InviteHandler.behaviour_info(:callbacks)

      expected_callbacks = [
        {:handle_invite, 1},
        {:handle_play_complete, 2},
        {:handle_dtmf, 2},
        {:handle_bridge_complete, 2},
        {:handle_fork_complete, 2},
        {:handle_record_complete, 3},
        {:handle_hangup, 1}
      ]

      for callback <- expected_callbacks do
        assert callback in callbacks,
               "Expected #{inspect(callback)} to be in callbacks, got: #{inspect(callbacks)}"
      end
    end

    test "marks optional callbacks correctly" do
      optional = InviteHandler.behaviour_info(:optional_callbacks)

      expected_optional = [
        {:handle_play_complete, 2},
        {:handle_dtmf, 2},
        {:handle_bridge_complete, 2},
        {:handle_fork_complete, 2},
        {:handle_record_complete, 3},
        {:handle_hangup, 1}
      ]

      assert length(optional) == length(expected_optional)

      for callback <- expected_optional do
        assert callback in optional,
               "Expected #{inspect(callback)} to be optional, got: #{inspect(optional)}"
      end
    end

    test "handle_invite/1 is NOT optional (required)" do
      optional = InviteHandler.behaviour_info(:optional_callbacks)

      refute {:handle_invite, 1} in optional,
             "handle_invite/1 should be required, not optional"
    end
  end

  describe "implementing the behaviour" do
    defmodule MinimalHandler do
      @behaviour Parrot.InviteHandler

      @impl true
      def handle_invite(call), do: call
    end

    defmodule FullHandler do
      @behaviour Parrot.InviteHandler

      @impl true
      def handle_invite(call), do: Map.put(call, :handled, true)

      @impl true
      def handle_play_complete(_filename, call), do: call

      @impl true
      def handle_dtmf(_digits, call), do: call

      @impl true
      def handle_bridge_complete(_result, call), do: call

      @impl true
      def handle_fork_complete(_result, call), do: call

      @impl true
      def handle_record_complete(_filename, _duration, call), do: call

      @impl true
      def handle_hangup(call), do: {:noreply, call}
    end

    test "minimal handler compiles with only handle_invite/1" do
      # If the module compiled, the test passes
      assert function_exported?(MinimalHandler, :handle_invite, 1)
    end

    test "full handler can implement all callbacks" do
      assert function_exported?(FullHandler, :handle_invite, 1)
      assert function_exported?(FullHandler, :handle_play_complete, 2)
      assert function_exported?(FullHandler, :handle_dtmf, 2)
      assert function_exported?(FullHandler, :handle_bridge_complete, 2)
      assert function_exported?(FullHandler, :handle_fork_complete, 2)
      assert function_exported?(FullHandler, :handle_record_complete, 3)
      assert function_exported?(FullHandler, :handle_hangup, 1)
    end

    test "handle_invite returns map" do
      result = FullHandler.handle_invite(%{test: true})
      assert is_map(result)
      assert result.handled == true
    end
  end
end
