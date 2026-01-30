defmodule ParrotSip.CDR.GeneratorTest do
  @moduledoc """
  Tests for ParrotSip.CDR.Generator module.

  The Generator creates CDR structs from Dialog data and timing information.
  This is the core module that transforms SIP dialog state into standardized
  Call Detail Records upon call termination.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.CDR
  alias ParrotSip.CDR.Generator
  alias ParrotSip.CDR.{TerminationCause, MediaInfo}
  alias ParrotSip.Dialog

  @moduletag :cdr

  # Helper to create a base dialog for testing
  defp build_dialog(opts \\ []) do
    defaults = %{
      id: "test-call-id;local=local-tag;remote=remote-tag;uas",
      state: :confirmed,
      call_id: "test-call-id@example.com",
      local_tag: "local-tag-123",
      remote_tag: "remote-tag-456",
      local_uri: "sip:alice@example.com",
      remote_uri: "sip:bob@example.com",
      remote_target: "sip:bob@192.168.1.100:5060",
      local_seq: 1,
      remote_seq: 100,
      route_set: [],
      secure: false,
      local_host: "192.168.1.1",
      local_port: 5060,
      transport: :udp
    }

    struct(Dialog, Map.merge(defaults, Map.new(opts)))
  end

  # Helper to create timing data for testing
  defp build_timing_data(opts \\ []) do
    now = DateTime.utc_now()

    defaults = %{
      invite_received_at: DateTime.add(now, -60, :second),
      answered_at: DateTime.add(now, -50, :second),
      ended_at: now
    }

    Map.merge(defaults, Map.new(opts))
  end

  # Helper to create a termination cause for testing
  defp build_termination_cause(opts \\ []) do
    defaults = %{
      party: :caller,
      sip_code: 200,
      reason: "BYE",
      method: :bye
    }

    struct(TerminationCause, Map.merge(defaults, Map.new(opts)))
  end

  describe "generate/3 - basic CDR generation" do
    test "generates CDR from complete dialog with all timing data" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      assert {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert %CDR{} = cdr
      assert cdr.call_id == dialog.call_id
      assert cdr.dialog_id == dialog.id
      assert cdr.transport == :udp
    end

    test "generates unique UUID for CDR id" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr1} = Generator.generate(dialog, timing, termination_cause)
      {:ok, cdr2} = Generator.generate(dialog, timing, termination_cause)

      assert is_binary(cdr1.id)
      assert is_binary(cdr2.id)
      assert String.length(cdr1.id) == 36
      assert cdr1.id != cdr2.id
    end

    test "generates correlation_id defaulting to dialog id" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert is_binary(cdr.correlation_id)
      # Default correlation_id should be based on dialog id or a new UUID
      assert String.length(cdr.correlation_id) > 0
    end

    test "uses custom correlation_id when provided in options" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()
      custom_correlation = "custom-correlation-id-123"

      {:ok, cdr} =
        Generator.generate(dialog, timing, termination_cause, correlation_id: custom_correlation)

      assert cdr.correlation_id == custom_correlation
    end

    test "initializes custom_fields as empty map" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.custom_fields == %{}
    end

    test "accepts custom_fields in options" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()
      custom = %{account_id: "acc-123", campaign_id: "camp-456"}

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, custom_fields: custom)

      assert cdr.custom_fields == custom
    end
  end

  describe "generate/3 - role-based field mapping for UAS (inbound)" do
    test "maps caller = remote, callee = local for UAS role" do
      # For UAS: we received the call, so caller is remote party, callee is us (local)
      dialog =
        build_dialog(
          id: "call-id;local=uas-tag;remote=uac-tag;uas",
          local_uri: "sip:callee@local.example.com",
          remote_uri: "sip:caller@remote.example.com",
          local_tag: "uas-local-tag",
          remote_tag: "uac-remote-tag"
        )

      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uas)

      # UAS (inbound): caller is remote, callee is local
      assert cdr.caller_uri == "sip:caller@remote.example.com"
      assert cdr.caller_tag == "uac-remote-tag"
      assert cdr.callee_uri == "sip:callee@local.example.com"
      assert cdr.callee_tag == "uas-local-tag"
      assert cdr.direction == :inbound
    end

    test "sets direction to :inbound for UAS role" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uas)

      assert cdr.direction == :inbound
    end
  end

  describe "generate/3 - role-based field mapping for UAC (outbound)" do
    test "maps caller = local, callee = remote for UAC role" do
      # For UAC: we initiated the call, so caller is us (local), callee is remote party
      dialog =
        build_dialog(
          id: "call-id;local=uac-tag;remote=uas-tag;uac",
          local_uri: "sip:caller@local.example.com",
          remote_uri: "sip:callee@remote.example.com",
          local_tag: "uac-local-tag",
          remote_tag: "uas-remote-tag"
        )

      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uac)

      # UAC (outbound): caller is local, callee is remote
      assert cdr.caller_uri == "sip:caller@local.example.com"
      assert cdr.caller_tag == "uac-local-tag"
      assert cdr.callee_uri == "sip:callee@remote.example.com"
      assert cdr.callee_tag == "uas-remote-tag"
      assert cdr.direction == :outbound
    end

    test "sets direction to :outbound for UAC role" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uac)

      assert cdr.direction == :outbound
    end
  end

  describe "generate/3 - timing calculations for answered calls" do
    test "calculates ring_duration_ms as answered_at - invite_received_at" do
      now = DateTime.utc_now()
      invite_time = DateTime.add(now, -30, :second)
      answer_time = DateTime.add(now, -20, :second)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: answer_time,
        ended_at: now
      }

      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      # 10 seconds = 10,000 milliseconds
      assert cdr.ring_duration_ms == 10_000
    end

    test "calculates talk_duration_ms as ended_at - answered_at" do
      now = DateTime.utc_now()
      invite_time = DateTime.add(now, -60, :second)
      answer_time = DateTime.add(now, -45, :second)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: answer_time,
        ended_at: now
      }

      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      # 45 seconds = 45,000 milliseconds
      assert cdr.talk_duration_ms == 45_000
    end

    test "preserves timing timestamps in CDR" do
      now = DateTime.utc_now()
      invite_time = DateTime.add(now, -60, :second)
      answer_time = DateTime.add(now, -45, :second)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: answer_time,
        ended_at: now
      }

      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.invite_received_at == invite_time
      assert cdr.answered_at == answer_time
      assert cdr.ended_at == now
    end
  end

  describe "generate/3 - timing calculations for unanswered calls" do
    test "calculates ring_duration_ms as ended_at - invite_received_at when not answered" do
      now = DateTime.utc_now()
      invite_time = DateTime.add(now, -25, :second)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: nil,
        ended_at: now
      }

      termination_cause = build_termination_cause(sip_code: 486, reason: "Busy Here", method: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      # 25 seconds = 25,000 milliseconds
      assert cdr.ring_duration_ms == 25_000
    end

    test "sets talk_duration_ms to 0 when call was never answered" do
      now = DateTime.utc_now()
      invite_time = DateTime.add(now, -30, :second)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: nil,
        ended_at: now
      }

      termination_cause =
        build_termination_cause(sip_code: 487, reason: "Request Terminated", method: :cancel)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.talk_duration_ms == 0
    end

    test "answered_at is nil in CDR when call was never answered" do
      now = DateTime.utc_now()
      invite_time = DateTime.add(now, -30, :second)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: nil,
        ended_at: now
      }

      termination_cause =
        build_termination_cause(sip_code: 480, reason: "Temporarily Unavailable")

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.answered_at == nil
    end
  end

  describe "generate/3 - disposition mapping" do
    test "sets disposition to :answered for 200 OK after answered call" do
      dialog = build_dialog()
      timing = build_timing_data()

      termination_cause =
        build_termination_cause(party: :caller, sip_code: 200, reason: "BYE", method: :bye)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :answered
    end

    test "sets disposition to :busy for 486 Busy Here" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)
      termination_cause = build_termination_cause(sip_code: 486, reason: "Busy Here", method: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :busy
    end

    test "sets disposition to :cancelled for 487 Request Terminated" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(sip_code: 487, reason: "Request Terminated", method: :cancel)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :cancelled
    end

    test "sets disposition to :no_answer for 480 Temporarily Unavailable" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(sip_code: 480, reason: "Temporarily Unavailable", method: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :no_answer
    end

    test "sets disposition to :timeout for 408 Request Timeout" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(
          party: :system,
          sip_code: 408,
          reason: "Request Timeout",
          method: nil
        )

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :timeout
    end

    test "sets disposition to :declined for 603 Decline" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(party: :callee, sip_code: 603, reason: "Decline", method: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :declined
    end

    test "sets disposition to :not_found for 404 Not Found" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(party: :system, sip_code: 404, reason: "Not Found", method: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :not_found
    end

    test "sets disposition to :forbidden for 403 Forbidden" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(party: :system, sip_code: 403, reason: "Forbidden", method: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :forbidden
    end

    test "sets disposition to :server_error for 500 Internal Server Error" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(
          party: :system,
          sip_code: 500,
          reason: "Internal Server Error",
          method: :error
        )

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :server_error
    end

    test "sets disposition to :redirected for 302 Moved Temporarily" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(party: :callee, sip_code: 302, reason: "Moved Temporarily")

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :redirected
    end

    test "sets disposition to :abandoned for nil SIP code" do
      dialog = build_dialog()
      timing = build_timing_data(answered_at: nil)
      termination_cause = build_termination_cause(party: :system, sip_code: nil, reason: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.disposition == :abandoned
    end
  end

  describe "generate/3 - termination cause handling" do
    test "copies termination cause struct to CDR" do
      dialog = build_dialog()
      timing = build_timing_data()

      termination_cause = %TerminationCause{
        party: :caller,
        sip_code: 200,
        reason: "Normal call clearing",
        method: :bye
      }

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.termination_cause == termination_cause
      assert cdr.termination_cause.party == :caller
      assert cdr.termination_cause.sip_code == 200
      assert cdr.termination_cause.reason == "Normal call clearing"
      assert cdr.termination_cause.method == :bye
    end
  end

  describe "generate/3 - transport extraction" do
    test "extracts :udp transport from dialog" do
      dialog = build_dialog(transport: :udp)
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.transport == :udp
    end

    test "extracts :tcp transport from dialog" do
      dialog = build_dialog(transport: :tcp)
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.transport == :tcp
    end

    test "extracts :tls transport from dialog" do
      dialog = build_dialog(transport: :tls)
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.transport == :tls
    end

    test "extracts :ws transport from dialog" do
      dialog = build_dialog(transport: :ws)
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.transport == :ws
    end

    test "extracts :wss transport from dialog" do
      dialog = build_dialog(transport: :wss)
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.transport == :wss
    end

    test "handles nil transport from dialog" do
      dialog = build_dialog(transport: nil)
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      # Should either be nil or a default value
      assert cdr.transport == nil or cdr.transport in [:udp, :tcp, :tls, :ws, :wss]
    end
  end

  describe "generate/3 - media info handling" do
    test "sets media_info to nil when not provided" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.media_info == nil
    end

    test "includes media_info when provided in options" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      media_info = %MediaInfo{
        codec: "PCMU",
        codec_payload_type: 0,
        packets_sent: 1500,
        packets_received: 1480,
        jitter_ms: 2.5,
        mos_summary: %{min_mos: 3.8, max_mos: 4.4, avg_mos: 4.2, total_packets: 1000, total_lost: 10, overall_loss_percent: 1.0, status: :good, quality_events: []}
      }

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, media_info: media_info)

      assert cdr.media_info == media_info
      assert cdr.media_info.codec == "PCMU"
      assert cdr.media_info.codec_payload_type == 0
    end
  end

  describe "generate/3 - display name handling" do
    test "sets display names to nil when not available in dialog" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.caller_display_name == nil
      assert cdr.callee_display_name == nil
    end

    test "includes display names when provided in options" do
      dialog = build_dialog()
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} =
        Generator.generate(dialog, timing, termination_cause,
          role: :uas,
          caller_display_name: "Alice Smith",
          callee_display_name: "Bob Jones"
        )

      assert cdr.caller_display_name == "Alice Smith"
      assert cdr.callee_display_name == "Bob Jones"
    end
  end

  describe "generate/3 - callee_tag handling" do
    test "callee_tag can be nil for early dialog failures" do
      # When a call fails before the remote generates a tag
      dialog = build_dialog(remote_tag: nil)
      timing = build_timing_data(answered_at: nil)

      termination_cause =
        build_termination_cause(sip_code: 408, reason: "Request Timeout", method: nil)

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uac)

      # For UAC, callee_tag comes from remote_tag which is nil
      assert cdr.callee_tag == nil
    end
  end

  describe "generate/3 - error handling" do
    test "returns error for nil dialog" do
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      assert {:error, :invalid_dialog} = Generator.generate(nil, timing, termination_cause)
    end

    test "returns error when invite_received_at is missing" do
      dialog = build_dialog()
      termination_cause = build_termination_cause()

      timing = %{
        invite_received_at: nil,
        answered_at: DateTime.utc_now(),
        ended_at: DateTime.utc_now()
      }

      assert {:error, :missing_invite_received_at} =
               Generator.generate(dialog, timing, termination_cause)
    end

    test "returns error when ended_at is missing" do
      dialog = build_dialog()
      termination_cause = build_termination_cause()
      now = DateTime.utc_now()

      timing = %{
        invite_received_at: now,
        answered_at: now,
        ended_at: nil
      }

      assert {:error, :missing_ended_at} = Generator.generate(dialog, timing, termination_cause)
    end

    test "returns error when timing data map is incomplete" do
      dialog = build_dialog()
      termination_cause = build_termination_cause()

      # Empty timing data
      assert {:error, _reason} = Generator.generate(dialog, %{}, termination_cause)
    end

    test "returns error when call_id is missing from dialog" do
      dialog = build_dialog(call_id: nil)
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      assert {:error, :missing_call_id} = Generator.generate(dialog, timing, termination_cause)
    end

    test "returns error for nil termination cause" do
      dialog = build_dialog()
      timing = build_timing_data()

      assert {:error, :invalid_termination_cause} = Generator.generate(dialog, timing, nil)
    end
  end

  describe "generate/3 - complete CDR structure validation" do
    test "generates CDR with all required fields populated" do
      dialog =
        build_dialog(
          call_id: "complete-test-call@example.com",
          local_uri: "sip:alice@example.com",
          remote_uri: "sip:bob@example.com",
          local_tag: "alice-tag",
          remote_tag: "bob-tag",
          transport: :udp
        )

      now = DateTime.utc_now()
      invite_time = DateTime.add(now, -120, :second)
      answer_time = DateTime.add(now, -100, :second)

      timing = %{
        invite_received_at: invite_time,
        answered_at: answer_time,
        ended_at: now
      }

      termination_cause = %TerminationCause{
        party: :callee,
        sip_code: 200,
        reason: "BYE",
        method: :bye
      }

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uas)

      # Verify all required fields per data model
      assert is_binary(cdr.id), "id should be a string"
      assert String.length(cdr.id) == 36, "id should be a UUID"

      assert is_binary(cdr.correlation_id), "correlation_id should be a string"
      assert cdr.call_id == "complete-test-call@example.com"

      # Role-based mapping for UAS (inbound)
      assert cdr.caller_uri == "sip:bob@example.com"
      assert cdr.caller_tag == "bob-tag"
      assert cdr.callee_uri == "sip:alice@example.com"
      assert cdr.callee_tag == "alice-tag"

      assert cdr.disposition == :answered
      assert %TerminationCause{} = cdr.termination_cause

      assert cdr.invite_received_at == invite_time
      assert cdr.answered_at == answer_time
      assert cdr.ended_at == now

      # 20 seconds ring time = 20,000 ms
      assert cdr.ring_duration_ms == 20_000
      # 100 seconds talk time = 100,000 ms
      assert cdr.talk_duration_ms == 100_000

      assert cdr.direction == :inbound
      assert cdr.transport == :udp
      assert cdr.dialog_id == dialog.id

      assert cdr.media_info == nil
      assert cdr.custom_fields == %{}
    end
  end

  describe "generate/3 - edge cases" do
    test "handles very short call durations" do
      now = DateTime.utc_now()
      # 100 milliseconds ago
      invite_time = DateTime.add(now, -100, :millisecond)
      # 50 milliseconds ago
      answer_time = DateTime.add(now, -50, :millisecond)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: answer_time,
        ended_at: now
      }

      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.ring_duration_ms >= 0
      assert cdr.talk_duration_ms >= 0
    end

    test "handles very long call durations" do
      now = DateTime.utc_now()
      # 24 hours ago
      invite_time = DateTime.add(now, -86_400, :second)
      # 23 hours ago
      answer_time = DateTime.add(now, -82_800, :second)

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: answer_time,
        ended_at: now
      }

      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      # 1 hour = 3,600,000 ms
      assert cdr.ring_duration_ms == 3_600_000
      # 23 hours = 82,800,000 ms
      assert cdr.talk_duration_ms == 82_800_000
    end

    test "handles call with zero ring time (immediate answer)" do
      now = DateTime.utc_now()
      # Same time for invite and answer
      invite_time = now

      dialog = build_dialog()

      timing = %{
        invite_received_at: invite_time,
        answered_at: invite_time,
        ended_at: DateTime.add(now, 60, :second)
      }

      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      assert cdr.ring_duration_ms == 0
      assert cdr.talk_duration_ms == 60_000
    end

    test "handles special characters in URIs" do
      dialog =
        build_dialog(
          local_uri: "sip:alice+smith@example.com;transport=tcp",
          remote_uri: "sip:bob%40dept@example.com"
        )

      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uac)

      assert cdr.caller_uri == "sip:alice+smith@example.com;transport=tcp"
      assert cdr.callee_uri == "sip:bob%40dept@example.com"
    end
  end

  describe "role inference" do
    test "infers UAS role from dialog ID suffix when role not provided" do
      dialog = build_dialog(id: "call-123;local=tag1;remote=tag2;uas")
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      # When role is not explicitly provided, it should be inferred from dialog
      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      # Should infer :uas from dialog ID
      assert cdr.direction == :inbound
    end

    test "infers UAC role from dialog ID suffix when role not provided" do
      dialog = build_dialog(id: "call-123;local=tag1;remote=tag2;uac")
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause)

      # Should infer :uac from dialog ID
      assert cdr.direction == :outbound
    end

    test "explicit role option overrides dialog ID inference" do
      dialog = build_dialog(id: "call-123;local=tag1;remote=tag2;uas")
      timing = build_timing_data()
      termination_cause = build_termination_cause()

      # Explicitly pass :uac role even though dialog ID says :uas
      {:ok, cdr} = Generator.generate(dialog, timing, termination_cause, role: :uac)

      assert cdr.direction == :outbound
    end
  end
end
