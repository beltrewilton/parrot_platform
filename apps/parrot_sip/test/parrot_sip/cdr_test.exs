defmodule ParrotSip.CDRTest do
  use ExUnit.Case, async: true

  alias ParrotSip.CDR
  alias ParrotSip.CDR.{TerminationCause, MediaInfo}

  describe "struct creation" do
    test "creates struct with all required fields" do
      now = DateTime.utc_now()
      answered_at = DateTime.add(now, 5, :second)
      ended_at = DateTime.add(answered_at, 120, :second)

      termination_cause = %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      cdr = %CDR{
        id: "550e8400-e29b-41d4-a716-446655440000",
        correlation_id: "550e8400-e29b-41d4-a716-446655440001",
        call_id: "call-123@example.com",
        caller_uri: "sip:alice@example.com",
        caller_display_name: "Alice",
        caller_tag: "from-tag-123",
        callee_uri: "sip:bob@example.com",
        callee_display_name: "Bob",
        callee_tag: "to-tag-456",
        disposition: :answered,
        termination_cause: termination_cause,
        invite_received_at: now,
        answered_at: answered_at,
        ended_at: ended_at,
        ring_duration_ms: 5000,
        talk_duration_ms: 120_000,
        direction: :inbound,
        transport: :udp,
        dialog_id: "dialog-abc-123",
        media_info: nil,
        custom_fields: %{}
      }

      assert cdr.id == "550e8400-e29b-41d4-a716-446655440000"
      assert cdr.correlation_id == "550e8400-e29b-41d4-a716-446655440001"
      assert cdr.call_id == "call-123@example.com"
      assert cdr.caller_uri == "sip:alice@example.com"
      assert cdr.caller_display_name == "Alice"
      assert cdr.caller_tag == "from-tag-123"
      assert cdr.callee_uri == "sip:bob@example.com"
      assert cdr.callee_display_name == "Bob"
      assert cdr.callee_tag == "to-tag-456"
      assert cdr.disposition == :answered
      assert cdr.termination_cause == termination_cause
      assert cdr.invite_received_at == now
      assert cdr.answered_at == answered_at
      assert cdr.ended_at == ended_at
      assert cdr.ring_duration_ms == 5000
      assert cdr.talk_duration_ms == 120_000
      assert cdr.direction == :inbound
      assert cdr.transport == :udp
      assert cdr.dialog_id == "dialog-abc-123"
      assert cdr.media_info == nil
      assert cdr.custom_fields == %{}
    end

    test "default values are applied correctly" do
      # Only custom_fields has a default value (%{})
      cdr = %CDR{}

      # Fields without defaults should be nil
      assert cdr.id == nil
      assert cdr.correlation_id == nil
      assert cdr.call_id == nil
      assert cdr.caller_uri == nil
      assert cdr.caller_display_name == nil
      assert cdr.caller_tag == nil
      assert cdr.callee_uri == nil
      assert cdr.callee_display_name == nil
      assert cdr.callee_tag == nil
      assert cdr.disposition == nil
      assert cdr.termination_cause == nil
      assert cdr.invite_received_at == nil
      assert cdr.answered_at == nil
      assert cdr.ended_at == nil
      assert cdr.ring_duration_ms == nil
      assert cdr.talk_duration_ms == nil
      assert cdr.direction == nil
      assert cdr.transport == nil
      assert cdr.dialog_id == nil
      assert cdr.media_info == nil

      # custom_fields has a default value of %{}
      assert cdr.custom_fields == %{}
    end

    test "struct can be created with struct!/2 for partial fields" do
      cdr =
        struct!(CDR,
          id: "test-id",
          call_id: "call-id@host",
          disposition: :answered
        )

      assert cdr.id == "test-id"
      assert cdr.call_id == "call-id@host"
      assert cdr.disposition == :answered
      assert cdr.custom_fields == %{}
    end
  end

  describe "disposition values" do
    @dispositions [
      :answered,
      :busy,
      :no_answer,
      :timeout,
      :cancelled,
      :declined,
      :not_found,
      :forbidden,
      :server_error,
      :failed,
      :redirected,
      :abandoned
    ]

    test "all disposition values are valid atoms" do
      for disposition <- @dispositions do
        cdr = %CDR{disposition: disposition}
        assert cdr.disposition == disposition
        assert is_atom(cdr.disposition)
      end
    end

    test "answered disposition represents completed call" do
      cdr = %CDR{disposition: :answered}
      assert cdr.disposition == :answered
    end

    test "busy disposition represents 486 Busy Here" do
      cdr = %CDR{disposition: :busy}
      assert cdr.disposition == :busy
    end

    test "no_answer disposition represents 480 Temporarily Unavailable" do
      cdr = %CDR{disposition: :no_answer}
      assert cdr.disposition == :no_answer
    end

    test "timeout disposition represents 408 Request Timeout" do
      cdr = %CDR{disposition: :timeout}
      assert cdr.disposition == :timeout
    end

    test "cancelled disposition represents 487 Request Terminated" do
      cdr = %CDR{disposition: :cancelled}
      assert cdr.disposition == :cancelled
    end

    test "declined disposition represents 603 Decline" do
      cdr = %CDR{disposition: :declined}
      assert cdr.disposition == :declined
    end

    test "not_found disposition represents 404/604" do
      cdr = %CDR{disposition: :not_found}
      assert cdr.disposition == :not_found
    end

    test "forbidden disposition represents authentication failures" do
      cdr = %CDR{disposition: :forbidden}
      assert cdr.disposition == :forbidden
    end

    test "server_error disposition represents 5xx errors" do
      cdr = %CDR{disposition: :server_error}
      assert cdr.disposition == :server_error
    end

    test "failed disposition represents other 4xx errors" do
      cdr = %CDR{disposition: :failed}
      assert cdr.disposition == :failed
    end

    test "redirected disposition represents 3xx responses" do
      cdr = %CDR{disposition: :redirected}
      assert cdr.disposition == :redirected
    end

    test "abandoned disposition represents no final response" do
      cdr = %CDR{disposition: :abandoned}
      assert cdr.disposition == :abandoned
    end
  end

  describe "direction values" do
    test "inbound direction is valid" do
      cdr = %CDR{direction: :inbound}
      assert cdr.direction == :inbound
    end

    test "outbound direction is valid" do
      cdr = %CDR{direction: :outbound}
      assert cdr.direction == :outbound
    end

    test "direction can be pattern matched" do
      inbound_cdr = %CDR{direction: :inbound}
      outbound_cdr = %CDR{direction: :outbound}

      assert %CDR{direction: :inbound} = inbound_cdr
      assert %CDR{direction: :outbound} = outbound_cdr
    end
  end

  describe "transport values" do
    @transports [:udp, :tcp, :tls, :ws, :wss]

    test "udp transport is valid" do
      cdr = %CDR{transport: :udp}
      assert cdr.transport == :udp
    end

    test "tcp transport is valid" do
      cdr = %CDR{transport: :tcp}
      assert cdr.transport == :tcp
    end

    test "tls transport is valid" do
      cdr = %CDR{transport: :tls}
      assert cdr.transport == :tls
    end

    test "ws transport is valid" do
      cdr = %CDR{transport: :ws}
      assert cdr.transport == :ws
    end

    test "wss transport is valid" do
      cdr = %CDR{transport: :wss}
      assert cdr.transport == :wss
    end

    test "all transport values can be assigned to CDR" do
      for transport <- @transports do
        cdr = %CDR{transport: transport}
        assert cdr.transport == transport
        assert is_atom(cdr.transport)
      end
    end
  end

  describe "answered call scenario" do
    test "complete answered call has all timing fields populated" do
      invite_time = ~U[2026-01-10 10:00:00Z]
      answer_time = ~U[2026-01-10 10:00:05Z]
      end_time = ~U[2026-01-10 10:02:05Z]

      termination_cause = %TerminationCause{
        party: :callee,
        sip_code: 200,
        reason: "Normal call clearing",
        method: :bye
      }

      cdr = %CDR{
        id: "cdr-answered-001",
        correlation_id: "cdr-answered-001",
        call_id: "answered-call@example.com",
        caller_uri: "sip:alice@example.com",
        caller_display_name: "Alice Smith",
        caller_tag: "alice-tag-123",
        callee_uri: "sip:bob@example.com",
        callee_display_name: "Bob Jones",
        callee_tag: "bob-tag-456",
        disposition: :answered,
        termination_cause: termination_cause,
        invite_received_at: invite_time,
        answered_at: answer_time,
        ended_at: end_time,
        ring_duration_ms: 5000,
        talk_duration_ms: 120_000,
        direction: :inbound,
        transport: :udp,
        dialog_id: "dialog-answered-001"
      }

      # Verify call was answered
      assert cdr.disposition == :answered

      # Verify timing relationships (accessing answered_at verifies it's not nil)
      assert DateTime.compare(cdr.answered_at, cdr.invite_received_at) == :gt
      assert DateTime.compare(cdr.ended_at, cdr.answered_at) == :gt

      # Verify duration values
      assert cdr.ring_duration_ms == 5000
      assert cdr.talk_duration_ms == 120_000

      # Verify termination was normal
      assert cdr.termination_cause.method == :bye
      assert cdr.termination_cause.sip_code == 200
    end

    test "answered call with embedded media info" do
      now = DateTime.utc_now()

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        mos_score: 4.2,
        packets_sent: 12000,
        packets_received: 11950,
        jitter_ms: 15.5
      }

      cdr = %CDR{
        id: "cdr-media-001",
        correlation_id: "cdr-media-001",
        call_id: "media-call@example.com",
        caller_uri: "sip:alice@example.com",
        caller_tag: "tag-a",
        callee_uri: "sip:bob@example.com",
        callee_tag: "tag-b",
        disposition: :answered,
        termination_cause: %TerminationCause{
          party: :caller,
          sip_code: 200,
          reason: "BYE",
          method: :bye
        },
        invite_received_at: now,
        answered_at: DateTime.add(now, 3, :second),
        ended_at: DateTime.add(now, 63, :second),
        ring_duration_ms: 3000,
        talk_duration_ms: 60_000,
        direction: :outbound,
        transport: :tcp,
        dialog_id: "dialog-media-001",
        media_info: media_info
      }

      # Verify media_info is populated (accessing fields will fail if nil)
      assert cdr.media_info.codec == "PCMU"
      assert cdr.media_info.codec_payload_type == 0
      assert cdr.media_info.mos_score == 4.2
      assert cdr.media_info.packets_sent == 12000
      assert cdr.media_info.packets_received == 11950
      assert cdr.media_info.jitter_ms == 15.5
    end
  end

  describe "unanswered call scenario" do
    test "unanswered call has nil answered_at and zero talk_duration_ms" do
      invite_time = ~U[2026-01-10 10:00:00Z]
      end_time = ~U[2026-01-10 10:00:30Z]

      termination_cause = %TerminationCause{
        party: :callee,
        sip_code: 486,
        reason: "Busy Here",
        method: nil
      }

      cdr = %CDR{
        id: "cdr-busy-001",
        correlation_id: "cdr-busy-001",
        call_id: "busy-call@example.com",
        caller_uri: "sip:alice@example.com",
        caller_tag: "alice-tag",
        callee_uri: "sip:bob@example.com",
        callee_tag: nil,
        disposition: :busy,
        termination_cause: termination_cause,
        invite_received_at: invite_time,
        answered_at: nil,
        ended_at: end_time,
        ring_duration_ms: 30_000,
        talk_duration_ms: 0,
        direction: :inbound,
        transport: :udp,
        dialog_id: "dialog-busy-001"
      }

      # Verify call was not answered
      assert cdr.disposition == :busy
      assert cdr.answered_at == nil

      # Verify no talk duration
      assert cdr.talk_duration_ms == 0

      # Ring duration should be total time (invite to end)
      assert cdr.ring_duration_ms == 30_000

      # Callee tag may be nil for early failures
      assert cdr.callee_tag == nil
    end

    test "cancelled call scenario" do
      invite_time = ~U[2026-01-10 10:00:00Z]
      end_time = ~U[2026-01-10 10:00:10Z]

      cdr = %CDR{
        id: "cdr-cancel-001",
        correlation_id: "cdr-cancel-001",
        call_id: "cancel-call@example.com",
        caller_uri: "sip:alice@example.com",
        caller_tag: "alice-tag",
        callee_uri: "sip:bob@example.com",
        callee_tag: nil,
        disposition: :cancelled,
        termination_cause: %TerminationCause{
          party: :caller,
          sip_code: 487,
          reason: "Request Terminated",
          method: :cancel
        },
        invite_received_at: invite_time,
        answered_at: nil,
        ended_at: end_time,
        ring_duration_ms: 10_000,
        talk_duration_ms: 0,
        direction: :outbound,
        transport: :udp,
        dialog_id: "dialog-cancel-001"
      }

      assert cdr.disposition == :cancelled
      assert cdr.answered_at == nil
      assert cdr.talk_duration_ms == 0
      assert cdr.termination_cause.method == :cancel
      assert cdr.termination_cause.party == :caller
    end

    test "timeout call scenario" do
      invite_time = ~U[2026-01-10 10:00:00Z]
      end_time = ~U[2026-01-10 10:00:32Z]

      cdr = %CDR{
        id: "cdr-timeout-001",
        correlation_id: "cdr-timeout-001",
        call_id: "timeout-call@example.com",
        caller_uri: "sip:alice@example.com",
        caller_tag: "alice-tag",
        callee_uri: "sip:bob@example.com",
        callee_tag: nil,
        disposition: :timeout,
        termination_cause: %TerminationCause{
          party: :system,
          sip_code: 408,
          reason: "Request Timeout",
          method: :error
        },
        invite_received_at: invite_time,
        answered_at: nil,
        ended_at: end_time,
        ring_duration_ms: 32_000,
        talk_duration_ms: 0,
        direction: :inbound,
        transport: :tcp,
        dialog_id: "dialog-timeout-001"
      }

      assert cdr.disposition == :timeout
      assert cdr.termination_cause.sip_code == 408
      assert cdr.termination_cause.party == :system
    end
  end

  describe "custom fields support" do
    test "custom_fields defaults to empty map" do
      cdr = %CDR{}
      assert cdr.custom_fields == %{}
    end

    test "custom_fields accepts arbitrary map data" do
      cdr = %CDR{
        custom_fields: %{
          "account_code" => "12345",
          "billing_category" => "premium",
          "recording_id" => "rec-abc-123"
        }
      }

      assert cdr.custom_fields["account_code"] == "12345"
      assert cdr.custom_fields["billing_category"] == "premium"
      assert cdr.custom_fields["recording_id"] == "rec-abc-123"
    end

    test "custom_fields can contain nested maps" do
      cdr = %CDR{
        custom_fields: %{
          "metadata" => %{
            "source" => "api",
            "version" => "1.0"
          },
          "tags" => ["important", "callback"]
        }
      }

      assert cdr.custom_fields["metadata"]["source"] == "api"
      assert cdr.custom_fields["tags"] == ["important", "callback"]
    end

    test "custom_fields can contain atom keys" do
      cdr = %CDR{
        custom_fields: %{
          account_id: 42,
          priority: :high,
          retry_count: 3
        }
      }

      assert cdr.custom_fields.account_id == 42
      assert cdr.custom_fields.priority == :high
      assert cdr.custom_fields.retry_count == 3
    end

    test "custom_fields preserves data through update" do
      original = %CDR{
        id: "cdr-001",
        custom_fields: %{
          "key1" => "value1"
        }
      }

      updated = %{
        original
        | custom_fields: Map.put(original.custom_fields, "key2", "value2")
      }

      assert updated.custom_fields["key1"] == "value1"
      assert updated.custom_fields["key2"] == "value2"
    end
  end

  describe "pattern matching" do
    test "can pattern match on CDR struct fields" do
      cdr = %CDR{
        id: "cdr-pattern-001",
        disposition: :answered,
        direction: :inbound,
        transport: :udp
      }

      assert %CDR{disposition: :answered} = cdr
      assert %CDR{direction: :inbound} = cdr
      assert %CDR{transport: :udp} = cdr
    end

    test "can pattern match to extract multiple fields" do
      cdr = %CDR{
        id: "cdr-extract-001",
        caller_uri: "sip:alice@example.com",
        callee_uri: "sip:bob@example.com",
        disposition: :answered
      }

      %CDR{
        caller_uri: caller,
        callee_uri: callee,
        disposition: outcome
      } = cdr

      assert caller == "sip:alice@example.com"
      assert callee == "sip:bob@example.com"
      assert outcome == :answered
    end

    test "can use guards with pattern matching" do
      cdr = %CDR{
        ring_duration_ms: 5000,
        talk_duration_ms: 120_000
      }

      # Pattern match with guards
      assert match?(
               %CDR{ring_duration_ms: ring} when ring < 10_000,
               cdr
             )

      assert match?(
               %CDR{talk_duration_ms: talk} when talk > 60_000,
               cdr
             )
    end
  end

  describe "build_query_filter/1" do
    test "returns empty map for empty options" do
      assert CDR.build_query_filter([]) == %{}
    end

    test "includes valid filter keys" do
      filter =
        CDR.build_query_filter(
          start_time: ~U[2024-01-01 00:00:00Z],
          disposition: :answered
        )

      assert filter.start_time == ~U[2024-01-01 00:00:00Z]
      assert filter.disposition == :answered
    end

    test "filters out invalid keys" do
      filter =
        CDR.build_query_filter(
          start_time: ~U[2024-01-01 00:00:00Z],
          invalid_key: "should be ignored"
        )

      assert Map.has_key?(filter, :start_time)
      refute Map.has_key?(filter, :invalid_key)
    end

    test "accepts all valid filter keys" do
      filter =
        CDR.build_query_filter(
          start_time: ~U[2024-01-01 00:00:00Z],
          end_time: ~U[2024-01-02 00:00:00Z],
          caller_uri: "sip:alice@example.com",
          callee_uri: "sip:bob@example.com",
          disposition: [:answered, :busy],
          call_id: "abc123",
          direction: :inbound
        )

      assert map_size(filter) == 7
    end

    test "accepts single disposition atom" do
      filter = CDR.build_query_filter(disposition: :answered)
      assert filter.disposition == :answered
    end

    test "accepts list of disposition atoms" do
      filter = CDR.build_query_filter(disposition: [:answered, :busy, :no_answer])
      assert filter.disposition == [:answered, :busy, :no_answer]
    end

    test "accepts direction filter" do
      filter = CDR.build_query_filter(direction: :outbound)
      assert filter.direction == :outbound
    end

    test "accepts caller_uri filter" do
      filter = CDR.build_query_filter(caller_uri: "sip:alice@example.com")
      assert filter.caller_uri == "sip:alice@example.com"
    end

    test "accepts callee_uri filter" do
      filter = CDR.build_query_filter(callee_uri: "sip:bob@example.com")
      assert filter.callee_uri == "sip:bob@example.com"
    end

    test "accepts call_id filter" do
      filter = CDR.build_query_filter(call_id: "call-123@example.com")
      assert filter.call_id == "call-123@example.com"
    end

    test "preserves DateTime values correctly" do
      start_time = ~U[2024-01-01 00:00:00Z]
      end_time = ~U[2024-01-02 23:59:59Z]

      filter = CDR.build_query_filter(start_time: start_time, end_time: end_time)

      assert filter.start_time == start_time
      assert filter.end_time == end_time
    end

    test "ignores multiple invalid keys" do
      filter =
        CDR.build_query_filter(
          start_time: ~U[2024-01-01 00:00:00Z],
          foo: "bar",
          baz: 123,
          qux: :atom
        )

      assert map_size(filter) == 1
      assert Map.has_key?(filter, :start_time)
    end

    test "returns empty map when all keys are invalid" do
      filter = CDR.build_query_filter(invalid: "value", also_invalid: 123)
      assert filter == %{}
    end
  end

  describe "struct field types" do
    test "timestamps are DateTime structs" do
      now = DateTime.utc_now()

      cdr = %CDR{
        invite_received_at: now,
        answered_at: DateTime.add(now, 5, :second),
        ended_at: DateTime.add(now, 65, :second)
      }

      assert %DateTime{} = cdr.invite_received_at
      assert %DateTime{} = cdr.answered_at
      assert %DateTime{} = cdr.ended_at
    end

    test "duration fields are integers" do
      cdr = %CDR{
        ring_duration_ms: 5000,
        talk_duration_ms: 120_000
      }

      assert is_integer(cdr.ring_duration_ms)
      assert is_integer(cdr.talk_duration_ms)
    end

    test "URI fields are strings" do
      cdr = %CDR{
        caller_uri: "sip:alice@example.com",
        callee_uri: "sip:bob@example.com"
      }

      assert is_binary(cdr.caller_uri)
      assert is_binary(cdr.callee_uri)
    end

    test "termination_cause is TerminationCause struct" do
      termination_cause = %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      cdr = %CDR{termination_cause: termination_cause}

      assert %TerminationCause{} = cdr.termination_cause
    end

    test "media_info is MediaInfo struct when present" do
      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0
      }

      cdr = %CDR{media_info: media_info}

      assert %MediaInfo{} = cdr.media_info
    end
  end
end
