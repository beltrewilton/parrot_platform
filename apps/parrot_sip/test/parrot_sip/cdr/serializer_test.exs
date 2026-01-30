defmodule ParrotSip.CDR.SerializerTest do
  use ExUnit.Case, async: true

  alias ParrotSip.CDR
  alias ParrotSip.CDR.{Serializer, TerminationCause, MediaInfo}

  # Shared test fixtures
  @invite_time ~U[2026-01-10 10:00:00Z]
  @answer_time ~U[2026-01-10 10:00:05Z]
  @end_time ~U[2026-01-10 10:02:05Z]

  defp build_complete_cdr do
    %CDR{
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
      termination_cause: %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      },
      invite_received_at: @invite_time,
      answered_at: @answer_time,
      ended_at: @end_time,
      ring_duration_ms: 5000,
      talk_duration_ms: 120_000,
      direction: :inbound,
      transport: :udp,
      dialog_id: "dialog-abc-123",
      media_info: nil,
      custom_fields: %{}
    }
  end

  defp build_unanswered_cdr do
    %CDR{
      id: "unanswered-cdr-001",
      correlation_id: "unanswered-corr-001",
      call_id: "busy-call@example.com",
      caller_uri: "sip:alice@example.com",
      callee_uri: "sip:bob@example.com",
      disposition: :busy,
      termination_cause: %TerminationCause{
        party: :callee,
        sip_code: 486,
        reason: "Busy Here",
        method: nil
      },
      invite_received_at: @invite_time,
      answered_at: nil,
      ended_at: @end_time,
      ring_duration_ms: 125_000,
      talk_duration_ms: 0,
      direction: :outbound,
      transport: :tcp,
      dialog_id: "dialog-busy-001"
    }
  end

  defp build_minimal_cdr do
    %CDR{
      id: nil,
      correlation_id: nil,
      call_id: nil,
      caller_uri: nil,
      callee_uri: nil,
      disposition: :failed,
      direction: :inbound,
      transport: nil,
      invite_received_at: nil,
      answered_at: nil,
      ended_at: nil,
      ring_duration_ms: nil,
      talk_duration_ms: nil,
      termination_cause: nil
    }
  end

  defp build_cdr_with_mos_summary do
    %CDR{
      id: "mos-cdr-001",
      correlation_id: "mos-corr-001",
      call_id: "mos-call@example.com",
      caller_uri: "sip:alice@example.com",
      caller_display_name: "Alice",
      caller_tag: "from-tag-mos",
      callee_uri: "sip:bob@example.com",
      callee_display_name: "Bob",
      callee_tag: "to-tag-mos",
      disposition: :answered,
      termination_cause: %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      },
      invite_received_at: @invite_time,
      answered_at: @answer_time,
      ended_at: @end_time,
      ring_duration_ms: 5000,
      talk_duration_ms: 120_000,
      direction: :inbound,
      transport: :udp,
      dialog_id: "dialog-mos-001",
      media_info: %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        packets_sent: 1500,
        packets_received: 1480,
        jitter_ms: 5.5,
        mos_summary: %{
          min_mos: 3.5,
          max_mos: 4.4,
          avg_mos: 3.9,
          total_packets: 1500,
          total_lost: 20,
          overall_loss_percent: 1.33,
          status: :good,
          quality_events: [
            %{
              timestamp: ~U[2026-01-10 10:01:00Z],
              mos: 3.5,
              type: :degradation,
              jitter: 25.0,
              loss_percent: 2.5
            }
          ]
        }
      },
      custom_fields: %{}
    }
  end

  # ===========================================================================
  # T034: csv_headers/0 tests
  # ===========================================================================
  describe "csv_headers/0" do
    test "returns list of header strings" do
      headers = Serializer.csv_headers()

      assert is_list(headers)
      assert Enum.all?(headers, &is_binary/1)
    end

    test "contains all expected column headers" do
      headers = Serializer.csv_headers()

      assert "id" in headers
      assert "correlation_id" in headers
      assert "call_id" in headers
      assert "caller_uri" in headers
      assert "callee_uri" in headers
      assert "disposition" in headers
      assert "direction" in headers
      assert "transport" in headers
      assert "invite_received_at" in headers
      assert "answered_at" in headers
      assert "ended_at" in headers
      assert "ring_duration_ms" in headers
      assert "talk_duration_ms" in headers
      assert "termination_party" in headers
      assert "termination_sip_code" in headers
      assert "termination_reason" in headers
    end

    test "returns headers in consistent order" do
      headers1 = Serializer.csv_headers()
      headers2 = Serializer.csv_headers()

      assert headers1 == headers2
    end

    test "returns exactly 21 columns" do
      headers = Serializer.csv_headers()
      assert length(headers) == 21
    end
  end

  # ===========================================================================
  # T032: to_map/1 tests
  # ===========================================================================
  describe "to_map/1" do
    test "converts complete CDR to map" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      assert is_map(map)
      assert map.id == "550e8400-e29b-41d4-a716-446655440000"
      assert map.correlation_id == "550e8400-e29b-41d4-a716-446655440001"
      assert map.call_id == "call-123@example.com"
      assert map.caller_uri == "sip:alice@example.com"
      assert map.callee_uri == "sip:bob@example.com"
    end

    test "converts disposition atom to string" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      assert map.disposition == "answered"
    end

    test "converts direction atom to string" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      assert map.direction == "inbound"
    end

    test "converts transport atom to string" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      assert map.transport == "udp"
    end

    test "converts DateTime to ISO8601 string" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      assert map.invite_received_at == "2026-01-10T10:00:00Z"
      assert map.answered_at == "2026-01-10T10:00:05Z"
      assert map.ended_at == "2026-01-10T10:02:05Z"
    end

    test "handles nil answered_at for unanswered calls" do
      cdr = build_unanswered_cdr()
      map = Serializer.to_map(cdr)

      assert map.answered_at == nil
    end

    test "preserves duration values" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      assert map.ring_duration_ms == 5000
      assert map.talk_duration_ms == 120_000
    end

    test "converts termination_cause to nested map" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      assert is_map(map.termination_cause)
      assert map.termination_cause.party == "caller"
      assert map.termination_cause.sip_code == 200
      assert map.termination_cause.reason == "BYE"
      assert map.termination_cause.method == "bye"
    end

    test "handles nil termination_cause" do
      cdr = build_minimal_cdr()
      map = Serializer.to_map(cdr)

      assert map.termination_cause == nil
    end

    test "handles nil transport" do
      cdr = build_minimal_cdr()
      map = Serializer.to_map(cdr)

      assert map.transport == nil
    end

    test "handles all disposition types" do
      dispositions = [
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

      for disposition <- dispositions do
        cdr = %CDR{disposition: disposition, direction: :inbound}
        map = Serializer.to_map(cdr)
        assert map.disposition == to_string(disposition)
      end
    end

    test "handles all transport types" do
      transports = [:udp, :tcp, :tls, :ws, :wss]

      for transport <- transports do
        cdr = %CDR{transport: transport, direction: :inbound, disposition: :answered}
        map = Serializer.to_map(cdr)
        assert map.transport == to_string(transport)
      end
    end

    test "handles termination_cause with nil method" do
      cdr = build_unanswered_cdr()
      map = Serializer.to_map(cdr)

      assert map.termination_cause.party == "callee"
      assert map.termination_cause.sip_code == 486
      assert map.termination_cause.reason == "Busy Here"
      assert map.termination_cause.method == nil
    end
  end

  # ===========================================================================
  # T031: to_json/1 tests
  # ===========================================================================
  describe "to_json/1" do
    test "returns {:ok, json_string} for valid CDR" do
      cdr = build_complete_cdr()
      result = Serializer.to_json(cdr)

      assert {:ok, json} = result
      assert is_binary(json)
    end

    test "produces valid JSON that can be decoded" do
      cdr = build_complete_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert is_map(decoded)
      assert decoded["id"] == "550e8400-e29b-41d4-a716-446655440000"
    end

    test "JSON contains all expected fields" do
      cdr = build_complete_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["id"] == "550e8400-e29b-41d4-a716-446655440000"
      assert decoded["correlation_id"] == "550e8400-e29b-41d4-a716-446655440001"
      assert decoded["call_id"] == "call-123@example.com"
      assert decoded["caller_uri"] == "sip:alice@example.com"
      assert decoded["callee_uri"] == "sip:bob@example.com"
      assert decoded["disposition"] == "answered"
      assert decoded["direction"] == "inbound"
      assert decoded["transport"] == "udp"
    end

    test "JSON contains ISO8601 timestamps" do
      cdr = build_complete_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["invite_received_at"] == "2026-01-10T10:00:00Z"
      assert decoded["answered_at"] == "2026-01-10T10:00:05Z"
      assert decoded["ended_at"] == "2026-01-10T10:02:05Z"
    end

    test "JSON contains nested termination_cause" do
      cdr = build_complete_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert is_map(decoded["termination_cause"])
      assert decoded["termination_cause"]["party"] == "caller"
      assert decoded["termination_cause"]["sip_code"] == 200
      assert decoded["termination_cause"]["reason"] == "BYE"
      assert decoded["termination_cause"]["method"] == "bye"
    end

    test "handles nil values in JSON" do
      cdr = build_unanswered_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["answered_at"] == nil
    end

    test "handles minimal CDR with many nil fields" do
      cdr = build_minimal_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["id"] == nil
      assert decoded["termination_cause"] == nil
      assert decoded["transport"] == nil
    end

    test "JSON preserves numeric values" do
      cdr = build_complete_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["ring_duration_ms"] == 5000
      assert decoded["talk_duration_ms"] == 120_000
    end
  end

  # ===========================================================================
  # T033: to_csv_row/1 tests
  # ===========================================================================
  describe "to_csv_row/1" do
    test "returns list of strings" do
      cdr = build_complete_cdr()
      row = Serializer.to_csv_row(cdr)

      assert is_list(row)
      assert Enum.all?(row, &is_binary/1)
    end

    test "row length matches csv_headers length" do
      cdr = build_complete_cdr()
      row = Serializer.to_csv_row(cdr)
      headers = Serializer.csv_headers()

      assert length(row) == length(headers)
    end

    test "contains CDR field values in correct order" do
      cdr = build_complete_cdr()
      row = Serializer.to_csv_row(cdr)

      # Values should match the header order defined in csv_headers/0
      [
        id,
        correlation_id,
        call_id,
        caller_uri,
        callee_uri,
        disposition,
        direction,
        transport,
        invite_received_at,
        answered_at,
        ended_at,
        ring_duration_ms,
        talk_duration_ms,
        termination_party,
        termination_sip_code,
        termination_reason,
        _codec,
        _mos_avg,
        _mos_min,
        _mos_max,
        _mos_status
      ] = row

      assert id == "550e8400-e29b-41d4-a716-446655440000"
      assert correlation_id == "550e8400-e29b-41d4-a716-446655440001"
      assert call_id == "call-123@example.com"
      assert caller_uri == "sip:alice@example.com"
      assert callee_uri == "sip:bob@example.com"
      assert disposition == "answered"
      assert direction == "inbound"
      assert transport == "udp"
      assert invite_received_at == "2026-01-10T10:00:00Z"
      assert answered_at == "2026-01-10T10:00:05Z"
      assert ended_at == "2026-01-10T10:02:05Z"
      assert ring_duration_ms == "5000"
      assert talk_duration_ms == "120000"
      assert termination_party == "caller"
      assert termination_sip_code == "200"
      assert termination_reason == "BYE"
    end

    test "handles nil values by converting to empty string" do
      cdr = build_minimal_cdr()
      row = Serializer.to_csv_row(cdr)

      # Check that nil values become empty strings
      [
        id,
        correlation_id,
        call_id,
        caller_uri,
        callee_uri,
        _disposition,
        _direction,
        transport,
        invite_received_at,
        answered_at,
        ended_at,
        ring_duration_ms,
        talk_duration_ms,
        termination_party,
        termination_sip_code,
        termination_reason,
        codec,
        mos_avg,
        mos_min,
        mos_max,
        mos_status
      ] = row

      assert id == ""
      assert correlation_id == ""
      assert call_id == ""
      assert caller_uri == ""
      assert callee_uri == ""
      assert transport == ""
      assert invite_received_at == ""
      assert answered_at == ""
      assert ended_at == ""
      assert ring_duration_ms == "0"
      assert talk_duration_ms == "0"
      assert termination_party == ""
      assert termination_sip_code == ""
      assert termination_reason == ""
      # Media info fields should be empty for nil media_info
      assert codec == ""
      assert mos_avg == ""
      assert mos_min == ""
      assert mos_max == ""
      assert mos_status == ""
    end

    test "handles unanswered call with nil answered_at" do
      cdr = build_unanswered_cdr()
      row = Serializer.to_csv_row(cdr)

      # Get the answered_at position (index 9)
      answered_at = Enum.at(row, 9)
      assert answered_at == ""
    end

    test "converts numeric durations to strings" do
      cdr = build_complete_cdr()
      row = Serializer.to_csv_row(cdr)

      ring_duration = Enum.at(row, 11)
      talk_duration = Enum.at(row, 12)

      assert ring_duration == "5000"
      assert talk_duration == "120000"
    end

    test "extracts termination_cause fields correctly" do
      cdr = build_complete_cdr()
      row = Serializer.to_csv_row(cdr)

      termination_party = Enum.at(row, 13)
      termination_sip_code = Enum.at(row, 14)
      termination_reason = Enum.at(row, 15)

      assert termination_party == "caller"
      assert termination_sip_code == "200"
      assert termination_reason == "BYE"
    end

    test "handles termination_cause with nil method" do
      cdr = build_unanswered_cdr()
      row = Serializer.to_csv_row(cdr)

      termination_party = Enum.at(row, 13)
      termination_sip_code = Enum.at(row, 14)
      termination_reason = Enum.at(row, 15)

      assert termination_party == "callee"
      assert termination_sip_code == "486"
      assert termination_reason == "Busy Here"
    end

    test "handles nil termination_cause" do
      cdr = build_minimal_cdr()
      row = Serializer.to_csv_row(cdr)

      termination_party = Enum.at(row, 13)
      termination_sip_code = Enum.at(row, 14)
      termination_reason = Enum.at(row, 15)

      assert termination_party == ""
      assert termination_sip_code == ""
      assert termination_reason == ""
    end

    test "row can be used with CSV library" do
      cdr = build_complete_cdr()
      headers = Serializer.csv_headers()
      row = Serializer.to_csv_row(cdr)

      # Simulate what a CSV library would do
      zipped = Enum.zip(headers, row)

      assert length(zipped) == 21
      assert {"id", "550e8400-e29b-41d4-a716-446655440000"} in zipped
      assert {"disposition", "answered"} in zipped
    end

    test "handles all dispositions" do
      dispositions = [
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

      for disposition <- dispositions do
        cdr = %CDR{
          disposition: disposition,
          direction: :inbound,
          ring_duration_ms: 0,
          talk_duration_ms: 0
        }

        row = Serializer.to_csv_row(cdr)
        disposition_value = Enum.at(row, 5)
        assert disposition_value == to_string(disposition)
      end
    end

    test "handles all transport types" do
      transports = [:udp, :tcp, :tls, :ws, :wss]

      for transport <- transports do
        cdr = %CDR{
          transport: transport,
          direction: :inbound,
          disposition: :answered,
          ring_duration_ms: 0,
          talk_duration_ms: 0
        }

        row = Serializer.to_csv_row(cdr)
        transport_value = Enum.at(row, 7)
        assert transport_value == to_string(transport)
      end
    end
  end

  # ===========================================================================
  # Integration tests
  # ===========================================================================
  describe "serialization round-trip" do
    test "to_map output is suitable for Jason encoding" do
      cdr = build_complete_cdr()
      map = Serializer.to_map(cdr)

      # Should be able to encode the map directly
      assert {:ok, _json} = Jason.encode(map)
    end

    test "csv_headers and to_csv_row are aligned" do
      cdr = build_complete_cdr()
      headers = Serializer.csv_headers()
      row = Serializer.to_csv_row(cdr)

      # Build a map from headers and row
      map =
        Enum.zip(headers, row)
        |> Map.new()

      # Verify key fields
      assert map["id"] == "550e8400-e29b-41d4-a716-446655440000"
      assert map["caller_uri"] == "sip:alice@example.com"
      assert map["disposition"] == "answered"
      assert map["termination_party"] == "caller"
    end
  end

  # ===========================================================================
  # T07: MOS Summary Serialization Tests
  # ===========================================================================
  describe "MOS summary JSON serialization" do
    test "JSON contains nested media_info with mos_summary" do
      cdr = build_cdr_with_mos_summary()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert is_map(decoded["media_info"])
      assert decoded["media_info"]["codec"] == "PCMU"
      assert decoded["media_info"]["codec_payload_type"] == 0
      assert decoded["media_info"]["packets_sent"] == 1500
      assert decoded["media_info"]["packets_received"] == 1480
      assert decoded["media_info"]["jitter_ms"] == 5.5
    end

    test "JSON mos_summary contains all MOS metrics" do
      cdr = build_cdr_with_mos_summary()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      mos_summary = decoded["media_info"]["mos_summary"]

      assert mos_summary["min_mos"] == 3.5
      assert mos_summary["max_mos"] == 4.4
      assert mos_summary["avg_mos"] == 3.9
      assert mos_summary["total_packets"] == 1500
      assert mos_summary["total_lost"] == 20
      assert mos_summary["overall_loss_percent"] == 1.33
      assert mos_summary["status"] == "good"
    end

    test "JSON mos_summary contains quality_events array" do
      cdr = build_cdr_with_mos_summary()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      events = decoded["media_info"]["mos_summary"]["quality_events"]

      assert is_list(events)
      assert length(events) == 1

      [event] = events
      assert event["timestamp"] == "2026-01-10T10:01:00Z"
      assert event["mos"] == 3.5
      assert event["type"] == "degradation"
      assert event["jitter"] == 25.0
      assert event["loss_percent"] == 2.5
    end

    test "JSON handles nil media_info" do
      cdr = build_complete_cdr()
      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["media_info"] == nil
    end

    test "JSON handles media_info with nil mos_summary" do
      cdr = %CDR{
        build_complete_cdr()
        | media_info: %MediaInfo{
            codec: "PCMU",
            codec_payload_type: 0,
            mos_summary: nil
          }
      }

      {:ok, json} = Serializer.to_json(cdr)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["media_info"]["codec"] == "PCMU"
      assert decoded["media_info"]["mos_summary"] == nil
    end
  end

  describe "MOS summary CSV serialization" do
    test "CSV row contains MOS metrics in correct columns" do
      cdr = build_cdr_with_mos_summary()
      row = Serializer.to_csv_row(cdr)
      headers = Serializer.csv_headers()

      # Build a map for easier assertions
      map = Enum.zip(headers, row) |> Map.new()

      assert map["codec"] == "PCMU"
      assert map["mos_avg"] == "3.9"
      assert map["mos_min"] == "3.5"
      assert map["mos_max"] == "4.4"
      assert map["mos_status"] == "good"
    end

    test "CSV handles nil media_info with empty strings" do
      cdr = build_complete_cdr()
      row = Serializer.to_csv_row(cdr)
      headers = Serializer.csv_headers()

      map = Enum.zip(headers, row) |> Map.new()

      assert map["codec"] == ""
      assert map["mos_avg"] == ""
      assert map["mos_min"] == ""
      assert map["mos_max"] == ""
      assert map["mos_status"] == ""
    end

    test "CSV handles media_info with nil mos_summary" do
      cdr = %CDR{
        build_complete_cdr()
        | media_info: %MediaInfo{
            codec: "PCMU",
            codec_payload_type: 0,
            mos_summary: nil
          }
      }

      row = Serializer.to_csv_row(cdr)
      headers = Serializer.csv_headers()
      map = Enum.zip(headers, row) |> Map.new()

      # Codec should be present
      assert map["codec"] == "PCMU"
      # MOS fields should be empty when mos_summary is nil
      assert map["mos_avg"] == ""
      assert map["mos_min"] == ""
      assert map["mos_max"] == ""
      assert map["mos_status"] == ""
    end
  end

  describe "to_map MOS summary handling" do
    test "to_map includes media_info with mos_summary" do
      cdr = build_cdr_with_mos_summary()
      map = Serializer.to_map(cdr)

      assert map.media_info.codec == "PCMU"
      assert map.media_info.mos_summary.avg_mos == 3.9
      assert map.media_info.mos_summary.min_mos == 3.5
      assert map.media_info.mos_summary.max_mos == 4.4
      assert map.media_info.mos_summary.status == "good"
    end

    test "to_map handles atom keys in mos_summary" do
      cdr = build_cdr_with_mos_summary()
      map = Serializer.to_map(cdr)

      # The original mos_summary has atom keys, to_map should handle them
      assert is_float(map.media_info.mos_summary.avg_mos)
      assert is_float(map.media_info.mos_summary.overall_loss_percent)
    end

    test "to_map converts quality event atoms to strings" do
      cdr = build_cdr_with_mos_summary()
      map = Serializer.to_map(cdr)

      [event] = map.media_info.mos_summary.quality_events
      assert event.type == "degradation"
      assert event.timestamp == "2026-01-10T10:01:00Z"
    end
  end
end
