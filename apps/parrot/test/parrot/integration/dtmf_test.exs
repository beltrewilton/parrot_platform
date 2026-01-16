defmodule Parrot.Integration.DTMFTest do
  @moduledoc """
  Integration tests for DTMF collection functionality.

  These tests verify that multiple sequential collect_dtmf calls work
  independently, supporting multi-step IVR flows such as:
  - Menu selection followed by PIN entry
  - Department selection followed by confirmation

  Each collection session should maintain its own independent configuration.
  """
  use ExUnit.Case, async: false

  alias Parrot.Call

  describe "multiple sequential collect_dtmf calls" do
    test "menu then pin collection works independently" do
      # First collection: menu selection (max: 1)
      call =
        %Call{state: :answered}
        |> Call.collect_dtmf(max: 1, timeout: 5_000)

      [{:collect_dtmf, menu_opts}] = Call.get_operations(call)
      assert menu_opts[:max] == 1
      assert menu_opts[:timeout] == 5_000

      # Clear operations (simulating execution completed)
      call = %{call | __operations__: []}

      # Second collection: PIN entry (max: 4)
      call = call |> Call.collect_dtmf(max: 4, timeout: 10_000, terminators: ["#"])

      [{:collect_dtmf, pin_opts}] = Call.get_operations(call)
      assert pin_opts[:max] == 4
      assert pin_opts[:timeout] == 10_000
      assert pin_opts[:terminators] == ["#"]
    end

    test "three-step IVR collection works independently" do
      # Step 1: Department selection (1 digit)
      call =
        %Call{state: :answered}
        |> Call.collect_dtmf(max: 1, timeout: 5_000)

      [{:collect_dtmf, step1_opts}] = Call.get_operations(call)
      assert step1_opts[:max] == 1

      # Clear and move to step 2
      call = %{call | __operations__: []}

      # Step 2: Extension entry (4 digits)
      call = call |> Call.collect_dtmf(max: 4, timeout: 15_000, terminators: ["#"])

      [{:collect_dtmf, step2_opts}] = Call.get_operations(call)
      assert step2_opts[:max] == 4
      assert step2_opts[:terminators] == ["#"]

      # Clear and move to step 3
      call = %{call | __operations__: []}

      # Step 3: Confirmation (1 digit, different terminator)
      call = call |> Call.collect_dtmf(max: 1, timeout: 3_000, terminators: ["*"])

      [{:collect_dtmf, step3_opts}] = Call.get_operations(call)
      assert step3_opts[:max] == 1
      assert step3_opts[:timeout] == 3_000
      assert step3_opts[:terminators] == ["*"]
    end

    test "each collection session is independent" do
      # Verify options don't leak between sessions
      call =
        %Call{state: :answered}
        |> Call.collect_dtmf(max: 1, terminators: ["*"])

      [{:collect_dtmf, first_opts}] = Call.get_operations(call)
      assert first_opts[:terminators] == ["*"]

      call =
        %{call | __operations__: []}
        # No terminators specified - should use default
        |> Call.collect_dtmf(max: 6)

      [{:collect_dtmf, second_opts}] = Call.get_operations(call)

      # Second call should use default terminators, not first call's
      assert second_opts[:terminators] == []
      assert second_opts[:max] == 6
    end

    test "options from previous collection do not persist" do
      # First collection with custom timeout
      call =
        %Call{state: :answered}
        |> Call.collect_dtmf(max: 2, timeout: 60_000)

      [{:collect_dtmf, first_opts}] = Call.get_operations(call)
      assert first_opts[:timeout] == 60_000

      # Second collection without specifying timeout - should use default
      call =
        %{call | __operations__: []}
        |> Call.collect_dtmf(max: 4)

      [{:collect_dtmf, second_opts}] = Call.get_operations(call)
      # Default timeout is 30_000, not 60_000 from previous collection
      assert second_opts[:timeout] == 30_000
      assert second_opts[:max] == 4
    end

    test "collection with default options followed by custom options" do
      # First collection: use all defaults
      call =
        %Call{state: :answered}
        |> Call.collect_dtmf([])

      [{:collect_dtmf, default_opts}] = Call.get_operations(call)
      assert default_opts[:max] == 20
      assert default_opts[:timeout] == 30_000
      assert default_opts[:terminators] == []

      # Second collection: fully customized
      call =
        %{call | __operations__: []}
        |> Call.collect_dtmf(max: 4, timeout: 10_000, terminators: ["#", "*"])

      [{:collect_dtmf, custom_opts}] = Call.get_operations(call)
      assert custom_opts[:max] == 4
      assert custom_opts[:timeout] == 10_000
      assert custom_opts[:terminators] == ["#", "*"]
    end

    test "state is preserved between collection sessions" do
      # Verify call state and assigns persist between operations
      call =
        %Call{state: :answered}
        |> Call.assign(:menu_selection, "1")
        |> Call.collect_dtmf(max: 1)

      assert call.assigns[:menu_selection] == "1"

      # Clear operations but keep state
      call = %{call | __operations__: []}

      # Add more state and do another collection
      call =
        call
        |> Call.assign(:department, "sales")
        |> Call.collect_dtmf(max: 4)

      # Both assigns should persist
      assert call.assigns[:menu_selection] == "1"
      assert call.assigns[:department] == "sales"
      assert call.state == :answered
    end
  end
end
