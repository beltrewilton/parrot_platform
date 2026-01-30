defmodule ParrotSip.CDR.DispatcherTest do
  @moduledoc """
  Tests for ParrotSip.CDR.Dispatcher module.

  The Dispatcher delivers CDRs to registered handlers asynchronously using
  fire-and-forget semantics. Handler failures are logged but don't affect
  other handlers.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.CDR
  alias ParrotSip.CDR.Dispatcher
  alias ParrotSip.CDR.{TerminationCause, MediaInfo}

  @moduletag :cdr

  # Helper to create a valid CDR for testing
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
        mos_summary: %{min_mos: 3.8, max_mos: 4.4, avg_mos: 4.2, total_packets: 1000, total_lost: 10, overall_loss_percent: 1.0, status: :good, quality_events: []},
        packets_sent: 5000,
        packets_received: 4980,
        jitter_ms: 15.5
      },
      custom_fields: %{}
    }

    struct(CDR, Map.merge(defaults, overrides))
  end

  # Test handler module that collects CDRs for verification
  defmodule CollectorHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def init(args) do
      {:ok, args}
    end

    @impl true
    def handle_cdr(cdr, %{collector_pid: pid} = state) do
      send(pid, {:cdr_received, cdr, state})
      :ok
    end
  end

  # Test handler that returns an error
  defmodule ErrorHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def init(args) do
      {:ok, args}
    end

    @impl true
    def handle_cdr(_cdr, %{error_reason: reason}) do
      {:error, reason}
    end
  end

  # Test handler that raises an exception
  defmodule RaisingHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def init(args) do
      {:ok, args}
    end

    @impl true
    def handle_cdr(_cdr, %{exception: exception}) do
      raise exception
    end
  end

  # Test handler that sleeps (for timing tests)
  defmodule SlowHandler do
    @moduledoc false
    @behaviour ParrotSip.CDR.Handler

    @impl true
    def init(args) do
      {:ok, args}
    end

    @impl true
    def handle_cdr(cdr, %{collector_pid: pid, sleep_ms: sleep_ms}) do
      Process.sleep(sleep_ms)
      send(pid, {:slow_handler_completed, cdr})
      :ok
    end
  end

  describe "dispatch/2 - single handler" do
    test "delivers CDR to a single handler" do
      cdr = build_test_cdr()
      handler_state = %{collector_pid: self(), extra: "data"}
      handlers = [{CollectorHandler, handler_state}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_received, received_cdr, received_state}, 1000
      assert received_cdr == cdr
      assert received_state == handler_state
    end

    test "handler receives its initialized state" do
      cdr = build_test_cdr()
      custom_state = %{collector_pid: self(), repo: "MyRepo", config: %{batch_size: 100}}
      handlers = [{CollectorHandler, custom_state}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_received, _cdr, received_state}, 1000
      assert received_state.repo == "MyRepo"
      assert received_state.config == %{batch_size: 100}
    end
  end

  describe "dispatch/2 - multiple handlers" do
    test "delivers CDR to all registered handlers" do
      cdr = build_test_cdr()

      handler1_state = %{collector_pid: self(), handler_id: 1}
      handler2_state = %{collector_pid: self(), handler_id: 2}
      handler3_state = %{collector_pid: self(), handler_id: 3}

      handlers = [
        {CollectorHandler, handler1_state},
        {CollectorHandler, handler2_state},
        {CollectorHandler, handler3_state}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # All three handlers should receive the CDR
      received_ids =
        for _i <- 1..3 do
          assert_receive {:cdr_received, ^cdr, %{handler_id: id}}, 1000
          id
        end

      assert Enum.sort(received_ids) == [1, 2, 3]
    end

    test "each handler receives the same CDR struct unchanged" do
      cdr = build_test_cdr(%{call_id: "unique-call-id-12345@test.com"})

      handlers =
        for i <- 1..5 do
          {CollectorHandler, %{collector_pid: self(), handler_id: i}}
        end

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      for _i <- 1..5 do
        assert_receive {:cdr_received, received_cdr, _state}, 1000
        assert received_cdr.call_id == "unique-call-id-12345@test.com"
        assert received_cdr.id == cdr.id
        assert received_cdr.disposition == cdr.disposition
      end
    end
  end

  describe "dispatch/2 - fire-and-forget semantics" do
    test "returns immediately without waiting for handlers" do
      cdr = build_test_cdr()
      handler_state = %{collector_pid: self(), sleep_ms: 500}
      handlers = [{SlowHandler, handler_state}]

      # Time the dispatch call
      start_time = System.monotonic_time(:millisecond)
      assert :ok = Dispatcher.dispatch(cdr, handlers)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Dispatch should return almost immediately (well under 100ms)
      # The handler sleeps for 500ms, so if dispatch blocked we'd see > 500ms
      assert elapsed < 100, "dispatch took #{elapsed}ms but should return immediately"

      # The slow handler should still complete eventually
      assert_receive {:slow_handler_completed, ^cdr}, 1000
    end

    test "dispatch returns :ok even when handler will fail" do
      cdr = build_test_cdr()
      handler_state = %{error_reason: :database_connection_failed}
      handlers = [{ErrorHandler, handler_state}]

      # Should still return :ok because it's fire-and-forget
      assert :ok = Dispatcher.dispatch(cdr, handlers)
    end

    test "dispatch returns :ok even when handler will raise" do
      cdr = build_test_cdr()
      handler_state = %{exception: "Handler explosion!"}
      handlers = [{RaisingHandler, handler_state}]

      # Should still return :ok because failures are isolated
      assert :ok = Dispatcher.dispatch(cdr, handlers)
    end
  end

  describe "dispatch/2 - empty handler list" do
    test "returns :ok with empty handler list" do
      cdr = build_test_cdr()
      handlers = []

      assert :ok = Dispatcher.dispatch(cdr, handlers)
    end

    test "does nothing with empty handler list" do
      cdr = build_test_cdr()

      # Dispatch with empty list should be a no-op
      assert :ok = Dispatcher.dispatch(cdr, [])

      # Nothing should be received since there are no handlers
      refute_receive {:cdr_received, _, _}, 100
    end
  end

  describe "dispatch/2 - handler isolation" do
    test "one handler failure does not affect other handlers" do
      cdr = build_test_cdr()

      handlers = [
        {CollectorHandler, %{collector_pid: self(), handler_id: 1}},
        {RaisingHandler, %{exception: "Handler 2 crashed!"}},
        {CollectorHandler, %{collector_pid: self(), handler_id: 3}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # Handlers 1 and 3 should still receive the CDR despite handler 2 crashing
      received_ids =
        for _i <- 1..2 do
          assert_receive {:cdr_received, ^cdr, %{handler_id: id}}, 1000
          id
        end

      assert 1 in received_ids
      assert 3 in received_ids
    end

    test "multiple failing handlers do not affect successful handlers" do
      cdr = build_test_cdr()

      handlers = [
        {ErrorHandler, %{error_reason: :fail_1}},
        {CollectorHandler, %{collector_pid: self(), handler_id: :success}},
        {RaisingHandler, %{exception: "crash"}},
        {ErrorHandler, %{error_reason: :fail_2}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # The successful handler should still receive the CDR
      assert_receive {:cdr_received, ^cdr, %{handler_id: :success}}, 1000
    end
  end

  describe "dispatch/2 - async execution" do
    test "handlers run in separate processes" do
      cdr = build_test_cdr()
      test_pid = self()

      # Create a handler that reports its process ID
      defmodule ProcessReportingHandler do
        @moduledoc false
        @behaviour ParrotSip.CDR.Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_cdr(_cdr, %{test_pid: pid}) do
          send(pid, {:handler_pid, self()})
          :ok
        end
      end

      handlers = [{ProcessReportingHandler, %{test_pid: test_pid}}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:handler_pid, handler_pid}, 1000
      # Handler should run in a different process than the test process
      assert handler_pid != test_pid
    end

    test "each handler invocation runs in its own process" do
      cdr = build_test_cdr()
      test_pid = self()

      defmodule MultiProcessHandler do
        @moduledoc false
        @behaviour ParrotSip.CDR.Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_cdr(_cdr, %{test_pid: pid, handler_id: id}) do
          send(pid, {:handler_process, id, self()})
          :ok
        end
      end

      handlers = [
        {MultiProcessHandler, %{test_pid: test_pid, handler_id: 1}},
        {MultiProcessHandler, %{test_pid: test_pid, handler_id: 2}},
        {MultiProcessHandler, %{test_pid: test_pid, handler_id: 3}}
      ]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # Collect all handler process IDs
      pids =
        for _i <- 1..3 do
          assert_receive {:handler_process, _id, pid}, 1000
          pid
        end

      # All handler processes should be unique (each runs in its own Task)
      assert length(Enum.uniq(pids)) == 3
    end

    test "handlers can run concurrently" do
      cdr = build_test_cdr()
      test_pid = self()

      defmodule ConcurrencyHandler do
        @moduledoc false
        @behaviour ParrotSip.CDR.Handler

        @impl true
        def init(args), do: {:ok, args}

        @impl true
        def handle_cdr(_cdr, %{test_pid: pid, handler_id: id, sleep_ms: sleep}) do
          send(pid, {:handler_started, id, System.monotonic_time(:millisecond)})
          Process.sleep(sleep)
          send(pid, {:handler_finished, id, System.monotonic_time(:millisecond)})
          :ok
        end
      end

      # All handlers sleep for 100ms
      handlers = [
        {ConcurrencyHandler, %{test_pid: test_pid, handler_id: 1, sleep_ms: 100}},
        {ConcurrencyHandler, %{test_pid: test_pid, handler_id: 2, sleep_ms: 100}},
        {ConcurrencyHandler, %{test_pid: test_pid, handler_id: 3, sleep_ms: 100}}
      ]

      start_time = System.monotonic_time(:millisecond)
      assert :ok = Dispatcher.dispatch(cdr, handlers)

      # Wait for all handlers to finish
      for _i <- 1..3 do
        assert_receive {:handler_finished, _, _}, 500
      end

      total_elapsed = System.monotonic_time(:millisecond) - start_time

      # If handlers run sequentially, total time would be ~300ms
      # If handlers run concurrently, total time should be ~100ms
      # Allow some margin for process overhead
      assert total_elapsed < 250,
             "Handlers took #{total_elapsed}ms but should run concurrently (~100ms)"
    end
  end

  describe "dispatch/2 - CDR struct integrity" do
    test "passes complete CDR struct with all fields" do
      now = DateTime.utc_now()

      cdr = %CDR{
        id: "cdr-integrity-test",
        correlation_id: "corr-integrity-test",
        call_id: "integrity@example.com",
        caller_uri: "sip:integrity-caller@example.com",
        caller_display_name: "Integrity Caller",
        caller_tag: "integrity-from-tag",
        callee_uri: "sip:integrity-callee@example.com",
        callee_display_name: "Integrity Callee",
        callee_tag: "integrity-to-tag",
        disposition: :busy,
        termination_cause: %TerminationCause{
          party: :callee,
          sip_code: 486,
          reason: "Busy Here",
          method: nil
        },
        invite_received_at: DateTime.add(now, -30, :second),
        answered_at: nil,
        ended_at: now,
        ring_duration_ms: 30_000,
        talk_duration_ms: 0,
        direction: :outbound,
        transport: :tcp,
        dialog_id: "integrity-dialog-id",
        media_info: nil,
        custom_fields: %{tenant_id: "tenant-123", campaign: "test"}
      }

      handlers = [{CollectorHandler, %{collector_pid: self()}}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_received, received_cdr, _state}, 1000

      # Verify all fields are passed through unchanged
      assert received_cdr.id == "cdr-integrity-test"
      assert received_cdr.correlation_id == "corr-integrity-test"
      assert received_cdr.call_id == "integrity@example.com"
      assert received_cdr.caller_uri == "sip:integrity-caller@example.com"
      assert received_cdr.caller_display_name == "Integrity Caller"
      assert received_cdr.caller_tag == "integrity-from-tag"
      assert received_cdr.callee_uri == "sip:integrity-callee@example.com"
      assert received_cdr.callee_display_name == "Integrity Callee"
      assert received_cdr.callee_tag == "integrity-to-tag"
      assert received_cdr.disposition == :busy
      assert received_cdr.termination_cause.party == :callee
      assert received_cdr.termination_cause.sip_code == 486
      assert received_cdr.invite_received_at == cdr.invite_received_at
      assert received_cdr.answered_at == nil
      assert received_cdr.ended_at == cdr.ended_at
      assert received_cdr.ring_duration_ms == 30_000
      assert received_cdr.talk_duration_ms == 0
      assert received_cdr.direction == :outbound
      assert received_cdr.transport == :tcp
      assert received_cdr.dialog_id == "integrity-dialog-id"
      assert received_cdr.media_info == nil
      assert received_cdr.custom_fields == %{tenant_id: "tenant-123", campaign: "test"}
    end

    test "passes CDR with media_info intact" do
      media_info = %MediaInfo{
        codec: "opus",
        codec_payload_type: 111,
        mos_summary: %{min_mos: 3.8, max_mos: 4.4, avg_mos: 4.5, total_packets: 1000, total_lost: 10, overall_loss_percent: 1.0, status: :good, quality_events: []},
        packets_sent: 10000,
        packets_received: 9950,
        jitter_ms: 8.3
      }

      cdr = build_test_cdr(%{media_info: media_info})
      handlers = [{CollectorHandler, %{collector_pid: self()}}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_received, received_cdr, _state}, 1000
      assert received_cdr.media_info.codec == "opus"
      assert received_cdr.media_info.codec_payload_type == 111
      assert received_cdr.media_info.mos_summary.avg_mos == 4.5
      assert received_cdr.media_info.packets_sent == 10000
      assert received_cdr.media_info.packets_received == 9950
      assert received_cdr.media_info.jitter_ms == 8.3
    end
  end

  describe "dispatch/2 - various dispositions" do
    test "dispatches CDR with :cancelled disposition" do
      cdr =
        build_test_cdr(%{
          disposition: :cancelled,
          termination_cause: %TerminationCause{
            party: :caller,
            sip_code: 487,
            reason: "Request Terminated",
            method: :cancel
          },
          answered_at: nil,
          talk_duration_ms: 0
        })

      handlers = [{CollectorHandler, %{collector_pid: self()}}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_received, received_cdr, _state}, 1000
      assert received_cdr.disposition == :cancelled
    end

    test "dispatches CDR with :no_answer disposition" do
      cdr =
        build_test_cdr(%{
          disposition: :no_answer,
          termination_cause: %TerminationCause{
            party: :callee,
            sip_code: 480,
            reason: "Temporarily Unavailable",
            method: nil
          },
          answered_at: nil,
          talk_duration_ms: 0
        })

      handlers = [{CollectorHandler, %{collector_pid: self()}}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_received, received_cdr, _state}, 1000
      assert received_cdr.disposition == :no_answer
    end

    test "dispatches CDR with :server_error disposition" do
      cdr =
        build_test_cdr(%{
          disposition: :server_error,
          termination_cause: %TerminationCause{
            party: :system,
            sip_code: 500,
            reason: "Internal Server Error",
            method: :error
          },
          answered_at: nil,
          talk_duration_ms: 0
        })

      handlers = [{CollectorHandler, %{collector_pid: self()}}]

      assert :ok = Dispatcher.dispatch(cdr, handlers)

      assert_receive {:cdr_received, received_cdr, _state}, 1000
      assert received_cdr.disposition == :server_error
    end
  end
end
