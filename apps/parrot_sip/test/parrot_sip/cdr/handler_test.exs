defmodule ParrotSip.CDR.HandlerTest do
  @moduledoc """
  Tests for CDR handler behaviour and handler lifecycle (T039-T041).

  This module tests:
  - Handler registration lifecycle (T039)
  - Handler failure isolation (T040)
  - Multiple handler dispatch (T041)

  Note: T043 (failure logging) is already implemented in dispatcher.ex
  and tested in dispatcher_test.exs.
  """
  use ExUnit.Case, async: false

  alias ParrotSip.CDR
  alias ParrotSip.CDR.Handler
  alias ParrotSip.CDR.Dispatcher
  alias ParrotSip.CDR.{TerminationCause, MediaInfo}

  @moduletag :cdr

  # ===========================================================================
  # Test Handlers
  # ===========================================================================

  # Simple handler that tracks initialization
  defmodule TestHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(args), do: {:ok, args}

    @impl true
    def handle_cdr(_cdr, _state), do: :ok
  end

  # Handler that notifies a process on initialization
  defmodule InitNotifyingHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(%{notify_pid: pid} = args) do
      send(pid, {:handler_initialized, __MODULE__, args})
      {:ok, args}
    end

    @impl true
    def handle_cdr(cdr, %{notify_pid: pid} = _state) do
      send(pid, {:handler_received_cdr, __MODULE__, cdr})
      :ok
    end
  end

  # Handler that fails initialization
  defmodule FailingInitHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(%{error: reason}), do: {:error, reason}
    def init(_args), do: {:error, :generic_init_failure}

    @impl true
    def handle_cdr(_cdr, _state), do: :ok
  end

  # Handler that raises on init
  defmodule RaisingInitHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(%{raise: message}) do
      raise message
    end

    @impl true
    def handle_cdr(_cdr, _state), do: :ok
  end

  # Handler that fails on handle_cdr
  defmodule FailingCdrHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(args), do: {:ok, args}

    @impl true
    def handle_cdr(_cdr, %{error: reason}) do
      {:error, reason}
    end
  end

  # Handler that raises on handle_cdr
  defmodule RaisingCdrHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(args), do: {:ok, args}

    @impl true
    def handle_cdr(_cdr, %{raise: message}) do
      raise message
    end
  end

  # Handler that notifies test process
  defmodule NotifyingHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(args), do: {:ok, args}

    @impl true
    def handle_cdr(cdr, %{test_pid: pid, handler_id: id}) do
      send(pid, {:cdr_handled, id, cdr})
      :ok
    end
  end

  # Handler that tracks state mutations
  defmodule StateTrackingHandler do
    @moduledoc false
    @behaviour Handler

    @impl true
    def init(%{counter: initial} = args) do
      {:ok, Map.put(args, :counter, initial)}
    end

    @impl true
    def handle_cdr(_cdr, %{test_pid: pid, counter: count} = _state) do
      send(pid, {:state_counter, count})
      # Note: handler state is immutable per dispatch, but we test the initial state
      :ok
    end
  end

  # ===========================================================================
  # Test Helpers
  # ===========================================================================

  setup do
    # Clear handlers before each test
    CDR.clear_handlers()
    :ok
  end

  defp build_test_cdr(overrides \\ %{}) do
    now = DateTime.utc_now()

    defaults = %{
      id: "cdr-#{System.unique_integer([:positive])}",
      correlation_id: "corr-#{System.unique_integer([:positive])}",
      call_id: "call-#{System.unique_integer([:positive])}@example.com",
      caller_uri: "sip:alice@example.com",
      caller_display_name: "Alice",
      caller_tag: "from-tag-123",
      callee_uri: "sip:bob@example.com",
      callee_display_name: "Bob",
      callee_tag: "to-tag-456",
      disposition: :answered,
      termination_cause: %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      },
      invite_received_at: DateTime.add(now, -60, :second),
      answered_at: DateTime.add(now, -55, :second),
      ended_at: now,
      ring_duration_ms: 5000,
      talk_duration_ms: 55_000,
      direction: :inbound,
      transport: :udp,
      dialog_id: "dialog-#{System.unique_integer([:positive])}",
      media_info: %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_summary: %{
          min_mos: 4.0,
          max_mos: 4.4,
          avg_mos: 4.2,
          total_packets: 5000,
          total_lost: 20,
          overall_loss_percent: 0.4,
          intervals_calculated: 55,
          duration_ms: 55_000,
          status: :complete,
          quality_events: []
        },
        packets_sent: 5000,
        packets_received: 4980,
        jitter_ms: 15.5
      },
      custom_fields: %{}
    }

    struct(CDR, Map.merge(defaults, overrides))
  end

  # ===========================================================================
  # T039: Handler Registration Lifecycle Tests
  # ===========================================================================

  describe "handler registration lifecycle (T039)" do
    test "can register a handler" do
      assert :ok = CDR.register_handler(TestHandler, %{test: true})
      CDR.unregister_handler(TestHandler)
    end

    test "can unregister a handler" do
      CDR.register_handler(TestHandler, %{})
      assert :ok = CDR.unregister_handler(TestHandler)
    end

    test "list_handlers returns registered handlers" do
      CDR.register_handler(TestHandler, %{key: :value})
      handlers = CDR.list_handlers()
      assert {TestHandler, %{key: :value}} in handlers
      CDR.unregister_handler(TestHandler)
    end

    test "handler init/1 is called during registration" do
      args = %{notify_pid: self()}
      assert :ok = CDR.register_handler(InitNotifyingHandler, args)

      assert_receive {:handler_initialized, InitNotifyingHandler, ^args}, 1000
    end

    test "handler init/1 receives provided args" do
      custom_args = %{
        notify_pid: self(),
        config: %{level: :debug},
        some_key: "some_value"
      }

      assert :ok = CDR.register_handler(InitNotifyingHandler, custom_args)

      assert_receive {:handler_initialized, InitNotifyingHandler, received_args}, 1000
      assert received_args.config == %{level: :debug}
      assert received_args.some_key == "some_value"
    end

    test "registration fails when init/1 returns error" do
      args = %{error: :config_invalid}

      assert {:error, :init_failed, :config_invalid} =
               CDR.register_handler(FailingInitHandler, args)

      # Handler should not be registered
      assert CDR.list_handlers() == []
    end

    test "unregister is idempotent" do
      assert :ok = CDR.unregister_handler(TestHandler)
      assert :ok = CDR.unregister_handler(TestHandler)
    end

    test "handler state persists after registration" do
      custom_state = %{counter: 42, test_pid: self()}
      CDR.register_handler(StateTrackingHandler, custom_state)

      handlers = CDR.list_handlers()

      {StateTrackingHandler, state} =
        Enum.find(handlers, fn {mod, _} -> mod == StateTrackingHandler end)

      assert state.counter == 42
    end

    test "re-registration after unregister uses new args" do
      CDR.register_handler(TestHandler, %{version: 1})
      CDR.unregister_handler(TestHandler)
      CDR.register_handler(TestHandler, %{version: 2})

      handlers = CDR.list_handlers()
      assert {TestHandler, %{version: 2}} in handlers
    end

    test "clear_handlers removes all handlers" do
      CDR.register_handler(TestHandler, %{})
      CDR.register_handler(NotifyingHandler, %{test_pid: self(), handler_id: 1})

      assert length(CDR.list_handlers()) == 2

      CDR.clear_handlers()
      assert CDR.list_handlers() == []
    end
  end

  # ===========================================================================
  # T040: Handler Failure Isolation Tests
  # ===========================================================================

  describe "handler failure isolation (T040)" do
    test "failing handler init does not prevent other handler registrations" do
      # Register a good handler first
      assert :ok = CDR.register_handler(TestHandler, %{id: 1})

      # Attempt to register a failing handler
      assert {:error, :init_failed, _reason} =
               CDR.register_handler(FailingInitHandler, %{error: :bad_config})

      # Good handler should still be registered
      handlers = CDR.list_handlers()
      assert length(handlers) == 1
      assert {TestHandler, _} = List.first(handlers)

      # Can still register more handlers after failure
      assert :ok = CDR.register_handler(NotifyingHandler, %{test_pid: self(), handler_id: 2})
      assert length(CDR.list_handlers()) == 2
    end

    test "handler returning error in handle_cdr does not crash dispatcher" do
      cdr = build_test_cdr()

      handlers = [
        {FailingCdrHandler, %{error: :database_down}}
      ]

      # Dispatch should succeed (fire-and-forget)
      assert :ok = Dispatcher.dispatch(cdr, handlers)
    end

    test "handler raising in handle_cdr does not crash dispatcher" do
      cdr = build_test_cdr()

      handlers = [
        {RaisingCdrHandler, %{raise: "handler explosion!"}}
      ]

      # Dispatch should succeed despite handler raising
      assert :ok = Dispatcher.dispatch(cdr, handlers)
    end

    test "failing handler does not prevent delivery to other handlers" do
      cdr = build_test_cdr()

      handlers = [
        {NotifyingHandler, %{test_pid: self(), handler_id: 1}},
        {FailingCdrHandler, %{error: :intentional_failure}},
        {NotifyingHandler, %{test_pid: self(), handler_id: 2}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # Both good handlers should receive the CDR
      assert_receive {:cdr_handled, 1, ^cdr}, 1000
      assert_receive {:cdr_handled, 2, ^cdr}, 1000
    end

    test "raising handler does not prevent delivery to other handlers" do
      cdr = build_test_cdr()

      handlers = [
        {NotifyingHandler, %{test_pid: self(), handler_id: 1}},
        {RaisingCdrHandler, %{raise: "boom!"}},
        {NotifyingHandler, %{test_pid: self(), handler_id: 2}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # Both good handlers should receive the CDR
      assert_receive {:cdr_handled, 1, ^cdr}, 1000
      assert_receive {:cdr_handled, 2, ^cdr}, 1000
    end

    test "multiple failing handlers do not affect successful handlers" do
      cdr = build_test_cdr()

      handlers = [
        {FailingCdrHandler, %{error: :fail_1}},
        {RaisingCdrHandler, %{raise: "crash_1"}},
        {NotifyingHandler, %{test_pid: self(), handler_id: :success}},
        {FailingCdrHandler, %{error: :fail_2}},
        {RaisingCdrHandler, %{raise: "crash_2"}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # The successful handler should receive the CDR
      assert_receive {:cdr_handled, :success, ^cdr}, 1000
    end

    test "handler failure does not affect subsequent dispatches" do
      cdr1 = build_test_cdr(%{call_id: "call-1@example.com"})
      cdr2 = build_test_cdr(%{call_id: "call-2@example.com"})

      handlers = [
        {RaisingCdrHandler, %{raise: "first dispatch crash"}},
        {NotifyingHandler, %{test_pid: self(), handler_id: 1}}
      ]

      # First dispatch
      assert :ok = Dispatcher.dispatch(cdr1, handlers)
      assert_receive {:cdr_handled, 1, ^cdr1}, 1000

      # Second dispatch should work normally
      assert :ok = Dispatcher.dispatch(cdr2, handlers)
      assert_receive {:cdr_handled, 1, ^cdr2}, 1000
    end
  end

  # ===========================================================================
  # T041: Multiple Handler Dispatch Tests
  # ===========================================================================

  describe "multiple handler dispatch (T041)" do
    test "CDR is dispatched to all registered handlers" do
      cdr = build_test_cdr()

      handlers = [
        {NotifyingHandler, %{test_pid: self(), handler_id: 1}},
        {NotifyingHandler, %{test_pid: self(), handler_id: 2}},
        {NotifyingHandler, %{test_pid: self(), handler_id: 3}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # All handlers should receive the CDR
      received_ids =
        for _i <- 1..3 do
          assert_receive {:cdr_handled, id, ^cdr}, 1000
          id
        end

      assert Enum.sort(received_ids) == [1, 2, 3]
    end

    test "each handler receives the exact same CDR" do
      cdr =
        build_test_cdr(%{
          call_id: "multi-handler-test@example.com",
          disposition: :busy
        })

      handlers = [
        {NotifyingHandler, %{test_pid: self(), handler_id: :handler_a}},
        {NotifyingHandler, %{test_pid: self(), handler_id: :handler_b}},
        {NotifyingHandler, %{test_pid: self(), handler_id: :handler_c}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      for _i <- 1..3 do
        assert_receive {:cdr_handled, _id, received_cdr}, 1000
        assert received_cdr.call_id == "multi-handler-test@example.com"
        assert received_cdr.disposition == :busy
        assert received_cdr.id == cdr.id
      end
    end

    test "handlers run concurrently" do
      # Create a handler that reports timing
      defmodule TimingHandler do
        @moduledoc false
        @behaviour Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_cdr(_cdr, %{test_pid: pid, handler_id: id, delay_ms: delay}) do
          start_time = System.monotonic_time(:millisecond)
          Process.sleep(delay)
          end_time = System.monotonic_time(:millisecond)
          send(pid, {:timing, id, start_time, end_time})
          :ok
        end
      end

      cdr = build_test_cdr()

      # Each handler sleeps for 100ms
      handlers = [
        {TimingHandler, %{test_pid: self(), handler_id: 1, delay_ms: 100}},
        {TimingHandler, %{test_pid: self(), handler_id: 2, delay_ms: 100}},
        {TimingHandler, %{test_pid: self(), handler_id: 3, delay_ms: 100}}
      ]

      overall_start = System.monotonic_time(:millisecond)
      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # Wait for all handlers to complete
      for _i <- 1..3 do
        assert_receive {:timing, _, _, _}, 1000
      end

      overall_elapsed = System.monotonic_time(:millisecond) - overall_start

      # If sequential: ~300ms; if concurrent: ~100ms
      # Allow margin for process overhead
      assert overall_elapsed < 250,
             "Expected concurrent execution (~100ms) but took #{overall_elapsed}ms"
    end

    test "handlers receive their own state independently" do
      cdr = build_test_cdr()

      # Define a handler that echoes its state
      defmodule StateEchoHandler do
        @moduledoc false
        @behaviour Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_cdr(_cdr, %{test_pid: pid} = state) do
          send(pid, {:state_echo, state})
          :ok
        end
      end

      state1 = %{test_pid: self(), handler_id: 1, config: "config_a"}
      state2 = %{test_pid: self(), handler_id: 2, config: "config_b"}
      state3 = %{test_pid: self(), handler_id: 3, config: "config_c"}

      handlers = [
        {StateEchoHandler, state1},
        {StateEchoHandler, state2},
        {StateEchoHandler, state3}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      states =
        for _i <- 1..3 do
          assert_receive {:state_echo, state}, 1000
          state
        end

      configs = Enum.map(states, & &1.config) |> Enum.sort()
      assert configs == ["config_a", "config_b", "config_c"]
    end

    test "each handler runs in its own process" do
      defmodule ProcessIdHandler do
        @moduledoc false
        @behaviour Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_cdr(_cdr, %{test_pid: pid, handler_id: id}) do
          send(pid, {:handler_pid, id, self()})
          :ok
        end
      end

      cdr = build_test_cdr()

      handlers = [
        {ProcessIdHandler, %{test_pid: self(), handler_id: 1}},
        {ProcessIdHandler, %{test_pid: self(), handler_id: 2}},
        {ProcessIdHandler, %{test_pid: self(), handler_id: 3}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      pids =
        for _i <- 1..3 do
          assert_receive {:handler_pid, _id, pid}, 1000
          pid
        end

      # All PIDs should be unique (each handler runs in separate Task)
      assert length(Enum.uniq(pids)) == 3

      # All PIDs should be different from test process
      assert self() not in pids
    end

    test "dispatch to empty handler list is a no-op" do
      cdr = build_test_cdr()

      assert :ok = Dispatcher.dispatch(cdr, [])
      refute_receive {:cdr_handled, _, _}, 100
    end

    test "handlers can be mix of different handler modules" do
      # Define another handler type
      defmodule AltNotifyingHandler do
        @moduledoc false
        @behaviour Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_cdr(cdr, %{test_pid: pid, handler_id: id}) do
          send(pid, {:alt_cdr_handled, id, cdr})
          :ok
        end
      end

      cdr = build_test_cdr()

      handlers = [
        {NotifyingHandler, %{test_pid: self(), handler_id: 1}},
        {AltNotifyingHandler, %{test_pid: self(), handler_id: 2}},
        {NotifyingHandler, %{test_pid: self(), handler_id: 3}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_handled, 1, ^cdr}, 1000
      assert_receive {:alt_cdr_handled, 2, ^cdr}, 1000
      assert_receive {:cdr_handled, 3, ^cdr}, 1000
    end

    test "large number of handlers all receive CDR" do
      cdr = build_test_cdr()
      num_handlers = 20

      handlers =
        for i <- 1..num_handlers do
          {NotifyingHandler, %{test_pid: self(), handler_id: i}}
        end

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      received_ids =
        for _i <- 1..num_handlers do
          assert_receive {:cdr_handled, id, ^cdr}, 2000
          id
        end

      assert Enum.sort(received_ids) == Enum.to_list(1..num_handlers)
    end
  end

  # ===========================================================================
  # Handler Behaviour Tests
  # ===========================================================================

  describe "Handler behaviour" do
    test "default init/1 passes args through as state" do
      assert {:ok, %{foo: "bar"}} = Handler.init(%{foo: "bar"})
      assert {:ok, [1, 2, 3]} = Handler.init([1, 2, 3])
      assert {:ok, :atom} = Handler.init(:atom)
    end

    test "handler module without init/1 uses default" do
      defmodule NoInitHandler do
        @moduledoc false
        @behaviour Handler

        @impl true
        def handle_cdr(_cdr, _state), do: :ok
      end

      args = %{some: "state"}
      assert :ok = CDR.register_handler(NoInitHandler, args)

      handlers = CDR.list_handlers()
      assert {NoInitHandler, %{some: "state"}} in handlers
    end
  end
end
