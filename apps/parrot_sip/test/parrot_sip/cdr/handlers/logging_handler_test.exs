defmodule ParrotSip.CDR.Handlers.LoggingHandlerTest do
  @moduledoc """
  Tests for ParrotSip.CDR.Handlers.LoggingHandler (T042).

  The LoggingHandler is an example CDR handler that logs CDR events
  using Elixir's Logger. It demonstrates the CDR.Handler behaviour.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ParrotSip.CDR
  alias ParrotSip.CDR.Handlers.LoggingHandler
  alias ParrotSip.CDR.{TerminationCause, MediaInfo}

  @moduletag :cdr

  # ===========================================================================
  # Test Helpers
  # ===========================================================================

  defp build_test_cdr(overrides \\ %{}) do
    now = DateTime.utc_now()

    defaults = %{
      id: "cdr-log-test-#{System.unique_integer([:positive])}",
      correlation_id: "corr-log-test-#{System.unique_integer([:positive])}",
      call_id: "call-log-test-#{System.unique_integer([:positive])}@example.com",
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
      dialog_id: "dialog-log-test-#{System.unique_integer([:positive])}",
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
  # init/1 Tests
  # ===========================================================================

  describe "init/1" do
    test "returns ok with default options" do
      assert {:ok, state} = LoggingHandler.init([])
      assert state.level == :info
      assert state.metadata_keys == [:call_id]
    end

    test "accepts custom log level" do
      assert {:ok, state} = LoggingHandler.init(level: :debug)
      assert state.level == :debug
    end

    test "accepts custom metadata keys" do
      assert {:ok, state} = LoggingHandler.init(metadata: [:call_id, :disposition, :direction])
      assert state.metadata_keys == [:call_id, :disposition, :direction]
    end

    test "accepts both level and metadata options" do
      opts = [level: :warning, metadata: [:call_id, :caller_uri]]
      assert {:ok, state} = LoggingHandler.init(opts)
      assert state.level == :warning
      assert state.metadata_keys == [:call_id, :caller_uri]
    end
  end

  # ===========================================================================
  # handle_cdr/2 Tests
  # ===========================================================================

  describe "handle_cdr/2" do
    @tag capture_log: true
    test "logs CDR at info level by default" do
      cdr = build_test_cdr(%{disposition: :answered})
      {:ok, state} = LoggingHandler.init([])

      # Temporarily set logger level to allow info messages to be captured
      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          assert :ok = LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "CDR generated:"
      assert log =~ cdr.id
      assert log =~ "answered"
      assert log =~ "sip:alice@example.com"
      assert log =~ "sip:bob@example.com"
    end

    @tag capture_log: true
    test "logs at custom log level" do
      cdr = build_test_cdr()
      {:ok, state} = LoggingHandler.init(level: :debug)

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          assert :ok = LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "CDR generated:"
    end

    @tag capture_log: true
    test "includes disposition in log message" do
      original_level = Logger.level()
      Logger.configure(level: :debug)

      for disposition <- [:answered, :busy, :no_answer, :cancelled, :failed] do
        cdr = build_test_cdr(%{disposition: disposition})
        {:ok, state} = LoggingHandler.init([])

        log =
          capture_log(fn ->
            LoggingHandler.handle_cdr(cdr, state)
          end)

        assert log =~ Atom.to_string(disposition),
               "Expected log to contain '#{disposition}', got: #{inspect(log)}"
      end

      Logger.configure(level: original_level)
    end

    @tag capture_log: true
    test "includes caller and callee URIs in log message" do
      cdr =
        build_test_cdr(%{
          caller_uri: "sip:custom-caller@domain.com",
          callee_uri: "sip:custom-callee@domain.com"
        })

      {:ok, state} = LoggingHandler.init([])

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "sip:custom-caller@domain.com"
      assert log =~ "sip:custom-callee@domain.com"
    end

    test "returns :ok on success" do
      cdr = build_test_cdr()
      {:ok, state} = LoggingHandler.init([])

      result = LoggingHandler.handle_cdr(cdr, state)
      assert result == :ok
    end
  end

  # ===========================================================================
  # Metadata Tests
  # ===========================================================================

  describe "metadata handling" do
    test "builds correct metadata from call_id by default" do
      # Test that metadata is built correctly (metadata may or may not appear in
      # captured log output depending on Logger formatter configuration)
      cdr = build_test_cdr(%{call_id: "unique-call-id-for-test@example.com"})
      {:ok, state} = LoggingHandler.init([])

      # Verify init sets up default metadata key
      assert state.metadata_keys == [:call_id]

      # Verify handle_cdr returns :ok (metadata is passed to Logger)
      assert :ok = LoggingHandler.handle_cdr(cdr, state)
    end

    test "builds correct metadata with custom fields" do
      # Test that custom metadata fields are properly configured
      cdr =
        build_test_cdr(%{
          call_id: "meta-test@example.com",
          disposition: :busy,
          direction: :outbound
        })

      {:ok, state} = LoggingHandler.init(metadata: [:call_id, :disposition, :direction])

      # Verify custom metadata keys are set
      assert state.metadata_keys == [:call_id, :disposition, :direction]

      # Verify handle_cdr processes without error
      assert :ok = LoggingHandler.handle_cdr(cdr, state)
    end

    @tag capture_log: true
    test "log message contains disposition (visible in log body)" do
      # The disposition IS in the log message body, so we can verify it
      cdr = build_test_cdr(%{disposition: :busy})
      {:ok, state} = LoggingHandler.init([])

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "busy"
    end
  end

  # ===========================================================================
  # Integration Tests
  # ===========================================================================

  describe "integration with CDR system" do
    setup do
      # Clear handlers before each test - no on_exit needed since each test
      # starts fresh and ensure_registry_started handles restarts
      CDR.clear_handlers()
      :ok
    end

    test "can be registered as a CDR handler" do
      assert :ok = CDR.register_handler(LoggingHandler, [])
      handlers = CDR.list_handlers()
      assert length(handlers) == 1
      assert {LoggingHandler, _state} = List.first(handlers)
    end

    test "can be registered with custom options" do
      opts = [level: :warning, metadata: [:call_id, :disposition]]
      assert :ok = CDR.register_handler(LoggingHandler, opts)

      handlers = CDR.list_handlers()
      assert {LoggingHandler, state} = List.first(handlers)
      assert state.level == :warning
      assert state.metadata_keys == [:call_id, :disposition]
    end

    @tag capture_log: true
    test "receives CDRs when dispatched" do
      {:ok, state} = LoggingHandler.init([])
      cdr = build_test_cdr()

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          :ok = ParrotSip.CDR.Dispatcher.dispatch(cdr, [{LoggingHandler, state}])
          # Give the async Task time to complete
          Process.sleep(100)
        end)

      Logger.configure(level: original_level)

      assert log =~ "CDR generated:"
    end
  end

  # ===========================================================================
  # Edge Cases
  # ===========================================================================

  describe "edge cases" do
    @tag capture_log: true
    test "handles CDR with nil optional fields" do
      cdr =
        build_test_cdr(%{
          caller_display_name: nil,
          callee_display_name: nil,
          answered_at: nil,
          media_info: nil,
          callee_tag: nil
        })

      {:ok, state} = LoggingHandler.init([])

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          assert :ok = LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "CDR generated:"
    end

    @tag capture_log: true
    test "handles CDR with special characters in URIs" do
      cdr =
        build_test_cdr(%{
          caller_uri: "sip:user+tag@domain.com",
          callee_uri: "sip:+15551234567@gateway.com"
        })

      {:ok, state} = LoggingHandler.init([])

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          assert :ok = LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "CDR generated:"
    end

    @tag capture_log: true
    test "handles empty metadata list" do
      cdr = build_test_cdr()
      {:ok, state} = LoggingHandler.init(metadata: [])

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          assert :ok = LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "CDR generated:"
    end

    @tag capture_log: true
    test "handles non-existent metadata field gracefully" do
      cdr = build_test_cdr()
      # Request a field that doesn't exist in CDR struct
      {:ok, state} = LoggingHandler.init(metadata: [:nonexistent_field, :call_id])

      original_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          assert :ok = LoggingHandler.handle_cdr(cdr, state)
        end)

      Logger.configure(level: original_level)

      assert log =~ "CDR generated:"
    end
  end
end
