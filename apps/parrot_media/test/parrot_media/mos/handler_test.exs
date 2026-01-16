defmodule ParrotMedia.MOS.HandlerTest do
  @moduledoc """
  Tests for MOS Handler behaviour.

  The Handler behaviour provides callbacks for receiving MOS events:
  - handle_mos_score/3 - Called when a new MOS score is calculated
  - handle_threshold_crossed/3 - Called when a threshold crossing is detected
  - handle_call_summary/3 - Called when a call ends with a summary

  All callbacks are optional with default implementations.
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.MOS.Handler
  alias ParrotMedia.MOS.Score
  alias ParrotMedia.MOS.CallSummary
  alias ParrotMedia.MOS.Event

  # ===========================================================================
  # Test Handler Implementations
  # ===========================================================================

  defmodule FullHandler do
    @moduledoc "Handler that implements all callbacks"
    @behaviour ParrotMedia.MOS.Handler

    @impl true
    def init(opts) do
      {:ok, Map.merge(%{events: []}, opts)}
    end

    @impl true
    def handle_mos_score(session_id, score, state) do
      event = {:mos_score, session_id, score}
      {:ok, %{state | events: [event | state.events]}}
    end

    @impl true
    def handle_threshold_crossed(session_id, event, state) do
      entry = {:threshold_crossed, session_id, event}
      {:ok, %{state | events: [entry | state.events]}}
    end

    @impl true
    def handle_call_summary(session_id, summary, state) do
      event = {:call_summary, session_id, summary}
      {:ok, %{state | events: [event | state.events]}}
    end
  end

  defmodule MinimalHandler do
    @moduledoc "Handler that only implements init"
    @behaviour ParrotMedia.MOS.Handler

    @impl true
    def init(opts) do
      {:ok, opts}
    end

    # Other callbacks use defaults
  end

  defmodule RaisingHandler do
    @moduledoc "Handler that raises in callbacks"
    @behaviour ParrotMedia.MOS.Handler

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    @impl true
    def handle_mos_score(_session_id, _score, _state) do
      raise "Intentional error in handle_mos_score"
    end

    @impl true
    def handle_threshold_crossed(_session_id, _event, _state) do
      raise "Intentional error in handle_threshold_crossed"
    end

    @impl true
    def handle_call_summary(_session_id, _summary, _state) do
      raise "Intentional error in handle_call_summary"
    end
  end

  defmodule StateUpdatingHandler do
    @moduledoc "Handler that tracks call counts"
    @behaviour ParrotMedia.MOS.Handler

    @impl true
    def init(opts) do
      {:ok, Map.merge(%{score_count: 0, threshold_count: 0, summary_count: 0}, opts)}
    end

    @impl true
    def handle_mos_score(_session_id, _score, state) do
      {:ok, %{state | score_count: state.score_count + 1}}
    end

    @impl true
    def handle_threshold_crossed(_session_id, _event, state) do
      {:ok, %{state | threshold_count: state.threshold_count + 1}}
    end

    @impl true
    def handle_call_summary(_session_id, _summary, state) do
      {:ok, %{state | summary_count: state.summary_count + 1}}
    end
  end

  # ===========================================================================
  # Behaviour Definition Tests
  # ===========================================================================

  describe "Handler behaviour" do
    test "defines init/1 callback" do
      assert {:init, 1} in ParrotMedia.MOS.Handler.behaviour_info(:callbacks)
    end

    test "defines handle_mos_score/3 callback" do
      assert {:handle_mos_score, 3} in ParrotMedia.MOS.Handler.behaviour_info(:callbacks)
    end

    test "defines handle_threshold_crossed/3 callback" do
      assert {:handle_threshold_crossed, 3} in ParrotMedia.MOS.Handler.behaviour_info(:callbacks)
    end

    test "defines handle_call_summary/3 callback" do
      assert {:handle_call_summary, 3} in ParrotMedia.MOS.Handler.behaviour_info(:callbacks)
    end

    test "defines all expected optional callbacks" do
      optional = ParrotMedia.MOS.Handler.behaviour_info(:optional_callbacks)
      assert {:handle_mos_score, 3} in optional
      assert {:handle_threshold_crossed, 3} in optional
      assert {:handle_call_summary, 3} in optional
    end
  end

  # ===========================================================================
  # init/1 Callback Tests
  # ===========================================================================

  describe "init/1" do
    test "initializes handler state" do
      assert {:ok, state} = FullHandler.init(%{test: true})
      assert state.test == true
      assert state.events == []
    end

    test "can receive empty opts" do
      assert {:ok, state} = MinimalHandler.init(%{})
      assert state == %{}
    end

    test "can receive keyword list opts" do
      assert {:ok, state} = FullHandler.init(%{key: :value})
      assert state.key == :value
    end
  end

  # ===========================================================================
  # handle_mos_score/3 Callback Tests
  # ===========================================================================

  describe "handle_mos_score/3" do
    test "receives session_id, score, and state" do
      {:ok, state} = FullHandler.init(%{})

      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())

      {:ok, new_state} = FullHandler.handle_mos_score("session-123", score, state)

      assert [{:mos_score, "session-123", ^score}] = new_state.events
    end

    test "can update state" do
      {:ok, state} = StateUpdatingHandler.init(%{})
      assert state.score_count == 0

      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())

      {:ok, new_state} = StateUpdatingHandler.handle_mos_score("session-123", score, state)
      assert new_state.score_count == 1
    end

    test "minimal handler uses default implementation" do
      {:ok, state} = MinimalHandler.init(%{})
      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())

      # Default implementation should return {:ok, state}
      assert {:ok, ^state} = Handler.handle_mos_score("session-123", score, state)
    end
  end

  # ===========================================================================
  # handle_threshold_crossed/3 Callback Tests
  # ===========================================================================

  describe "handle_threshold_crossed/3" do
    test "receives session_id, event, and state" do
      {:ok, state} = FullHandler.init(%{})

      event = %Event{
        type: :threshold_crossed,
        session_id: "session-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      }

      {:ok, new_state} = FullHandler.handle_threshold_crossed("session-123", event, state)

      assert [{:threshold_crossed, "session-123", ^event}] = new_state.events
    end

    test "can update state" do
      {:ok, state} = StateUpdatingHandler.init(%{})
      assert state.threshold_count == 0

      event = %Event{
        type: :threshold_crossed,
        session_id: "session-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      }

      {:ok, new_state} = StateUpdatingHandler.handle_threshold_crossed("session-123", event, state)
      assert new_state.threshold_count == 1
    end

    test "minimal handler uses default implementation" do
      {:ok, state} = MinimalHandler.init(%{})

      event = %Event{
        type: :threshold_crossed,
        session_id: "session-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      }

      # Default implementation should return {:ok, state}
      assert {:ok, ^state} = Handler.handle_threshold_crossed("session-123", event, state)
    end
  end

  # ===========================================================================
  # handle_call_summary/3 Callback Tests
  # ===========================================================================

  describe "handle_call_summary/3" do
    test "receives session_id, summary, and state" do
      {:ok, state} = FullHandler.init(%{})

      {:ok, summary} =
        CallSummary.new(
          session_id: "session-123",
          min_mos: 3.5,
          max_mos: 4.2,
          avg_mos: 3.9,
          total_packets: 1000,
          total_lost: 10,
          intervals_calculated: 5,
          duration_ms: 25_000,
          status: :complete
        )

      {:ok, new_state} = FullHandler.handle_call_summary("session-123", summary, state)

      assert [{:call_summary, "session-123", ^summary}] = new_state.events
    end

    test "can update state" do
      {:ok, state} = StateUpdatingHandler.init(%{})
      assert state.summary_count == 0

      {:ok, summary} =
        CallSummary.new(
          session_id: "session-123",
          min_mos: 3.5,
          max_mos: 4.2,
          avg_mos: 3.9,
          total_packets: 1000,
          total_lost: 10,
          intervals_calculated: 5,
          duration_ms: 25_000,
          status: :complete
        )

      {:ok, new_state} = StateUpdatingHandler.handle_call_summary("session-123", summary, state)
      assert new_state.summary_count == 1
    end

    test "minimal handler uses default implementation" do
      {:ok, state} = MinimalHandler.init(%{})

      {:ok, summary} =
        CallSummary.new(
          session_id: "session-123",
          min_mos: 3.5,
          max_mos: 4.2,
          avg_mos: 3.9,
          total_packets: 1000,
          total_lost: 10,
          intervals_calculated: 5,
          duration_ms: 25_000,
          status: :complete
        )

      # Default implementation should return {:ok, state}
      assert {:ok, ^state} = Handler.handle_call_summary("session-123", summary, state)
    end
  end

  # ===========================================================================
  # Error Handling Tests
  # ===========================================================================

  describe "error isolation" do
    test "raising in handle_mos_score does not crash caller" do
      {:ok, state} = RaisingHandler.init(%{})
      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())

      # Should raise when called directly
      assert_raise RuntimeError, "Intentional error in handle_mos_score", fn ->
        RaisingHandler.handle_mos_score("session-123", score, state)
      end
    end

    test "raising in handle_threshold_crossed does not crash caller" do
      {:ok, state} = RaisingHandler.init(%{})

      event = %Event{
        type: :threshold_crossed,
        session_id: "session-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      }

      assert_raise RuntimeError, "Intentional error in handle_threshold_crossed", fn ->
        RaisingHandler.handle_threshold_crossed("session-123", event, state)
      end
    end

    test "raising in handle_call_summary does not crash caller" do
      {:ok, state} = RaisingHandler.init(%{})

      {:ok, summary} =
        CallSummary.new(
          session_id: "session-123",
          min_mos: 3.5,
          max_mos: 4.2,
          avg_mos: 3.9,
          total_packets: 1000,
          total_lost: 10,
          intervals_calculated: 5,
          duration_ms: 25_000,
          status: :complete
        )

      assert_raise RuntimeError, "Intentional error in handle_call_summary", fn ->
        RaisingHandler.handle_call_summary("session-123", summary, state)
      end
    end
  end

  # ===========================================================================
  # Handler.invoke_* Function Tests
  # ===========================================================================

  describe "Handler.invoke_score/4" do
    test "invokes handler and returns updated state" do
      {:ok, state} = StateUpdatingHandler.init(%{})
      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())

      {:ok, new_state} =
        Handler.invoke_score(StateUpdatingHandler, "session-123", score, state)

      assert new_state.score_count == 1
    end

    test "catches errors and returns original state" do
      {:ok, state} = RaisingHandler.init(%{})
      {:ok, score} = Score.new(value: 4.0, timestamp: DateTime.utc_now())

      result = Handler.invoke_score(RaisingHandler, "session-123", score, state)

      assert {:error, {:handler_error, _reason}} = result
    end
  end

  describe "Handler.invoke_threshold_crossed/4" do
    test "invokes handler and returns updated state" do
      {:ok, state} = StateUpdatingHandler.init(%{})

      event = %Event{
        type: :threshold_crossed,
        session_id: "session-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      }

      {:ok, new_state} =
        Handler.invoke_threshold_crossed(StateUpdatingHandler, "session-123", event, state)

      assert new_state.threshold_count == 1
    end

    test "catches errors and returns error tuple" do
      {:ok, state} = RaisingHandler.init(%{})

      event = %Event{
        type: :threshold_crossed,
        session_id: "session-123",
        mos: 3.4,
        threshold: :good,
        direction: :falling,
        timestamp: DateTime.utc_now()
      }

      result = Handler.invoke_threshold_crossed(RaisingHandler, "session-123", event, state)

      assert {:error, {:handler_error, _reason}} = result
    end
  end

  describe "Handler.invoke_summary/4" do
    test "invokes handler and returns updated state" do
      {:ok, state} = StateUpdatingHandler.init(%{})

      {:ok, summary} =
        CallSummary.new(
          session_id: "session-123",
          min_mos: 3.5,
          max_mos: 4.2,
          avg_mos: 3.9,
          total_packets: 1000,
          total_lost: 10,
          intervals_calculated: 5,
          duration_ms: 25_000,
          status: :complete
        )

      {:ok, new_state} =
        Handler.invoke_summary(StateUpdatingHandler, "session-123", summary, state)

      assert new_state.summary_count == 1
    end

    test "catches errors and returns error tuple" do
      {:ok, state} = RaisingHandler.init(%{})

      {:ok, summary} =
        CallSummary.new(
          session_id: "session-123",
          min_mos: 3.5,
          max_mos: 4.2,
          avg_mos: 3.9,
          total_packets: 1000,
          total_lost: 10,
          intervals_calculated: 5,
          duration_ms: 25_000,
          status: :complete
        )

      result = Handler.invoke_summary(RaisingHandler, "session-123", summary, state)

      assert {:error, {:handler_error, _reason}} = result
    end
  end
end
