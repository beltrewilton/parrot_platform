defmodule ParrotSip.DialogStatemCdrTest do
  @moduledoc """
  Tests for DialogStatem CDR timing capture.

  These tests verify that DialogStatem captures timestamps at key lifecycle events
  for Call Detail Record (CDR) generation:

  - invite_received_at: Captured when dialog is created
  - answered_at: Captured when dialog transitions from :early to :confirmed

  TDD: Tests written first, implementation to follow.
  """
  use ExUnit.Case, async: false

  alias ParrotSip.{DialogStatem, Message}
  alias ParrotSip.Headers.{Via, From, To, Contact, CSeq}

  # ===========================================================================
  # Test Helpers - Public API wrappers
  # ===========================================================================

  # Assert that the dialog is in the expected state
  defp assert_state(pid, expected_state) do
    actual_state = DialogStatem.get_state(pid)
    assert actual_state == expected_state,
           "Expected state #{inspect(expected_state)}, got #{inspect(actual_state)}"
  end

  # Get timing data from the dialog
  defp get_timing_data(pid) do
    {:ok, data} = DialogStatem.get_timing_data(pid)
    data
  end

  describe "invite_received_at timestamp capture" do
    test "UAS dialog captures invite_received_at on creation" do
      invite = build_invite_message()
      response = build_response_message(200, "OK")

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})

      # Get the dialog data and verify timestamp is captured
      timing = get_timing_data(pid)

      assert timing.invite_received_at != nil,
             "invite_received_at should be set when UAS dialog is created"

      assert %DateTime{} = timing.invite_received_at,
             "invite_received_at should be a DateTime struct"

      assert timing.invite_received_at.time_zone == "Etc/UTC",
             "invite_received_at should have UTC timezone"

      # Verify timestamp is recent (within last 5 seconds)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, timing.invite_received_at, :second)
      assert diff >= 0 and diff < 5, "invite_received_at should be recent"
    end

    test "UAC dialog captures invite_received_at on creation with 2xx response" do
      invite = build_invite_message()
      response = build_response_message(200, "OK")

      {:ok, pid} = DialogStatem.start_link({:uac, invite, response})

      timing = get_timing_data(pid)

      assert timing.invite_received_at != nil,
             "invite_received_at should be set when UAC dialog is created"

      assert %DateTime{} = timing.invite_received_at
      assert timing.invite_received_at.time_zone == "Etc/UTC"
    end

    test "UAC dialog captures invite_received_at on creation with provisional response" do
      invite = build_invite_message()
      provisional = build_response_message(180, "Ringing")

      {:ok, pid} = DialogStatem.start_link({:uac, invite, provisional})

      timing = get_timing_data(pid)

      assert timing.invite_received_at != nil,
             "invite_received_at should be set for early UAC dialog"

      assert %DateTime{} = timing.invite_received_at
    end
  end

  describe "answered_at timestamp capture" do
    test "answered_at is captured when UAS dialog transitions :early -> :confirmed" do
      invite = build_invite_message()
      # Start with provisional response to create early dialog
      provisional = build_response_message(180, "Ringing")

      {:ok, pid} = DialogStatem.start_link({:uas, provisional, invite})

      # Verify starts in early state with no answered_at
      assert_state(pid, :early)
      timing = get_timing_data(pid)
      assert timing.answered_at == nil, "answered_at should be nil in early state"

      # Transition to confirmed with 200 OK
      final = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:uas_response, final, invite})

      Process.sleep(20)

      # Verify transition and answered_at capture
      assert_state(pid, :confirmed)
      new_timing = get_timing_data(pid)

      assert new_timing.answered_at != nil,
             "answered_at should be set after :early -> :confirmed transition"

      assert %DateTime{} = new_timing.answered_at,
             "answered_at should be a DateTime struct"

      assert new_timing.answered_at.time_zone == "Etc/UTC",
             "answered_at should have UTC timezone"
    end

    test "answered_at is captured when UAC dialog transitions :early -> :confirmed" do
      invite = build_invite_message()
      provisional = build_response_message(180, "Ringing")

      {:ok, pid} = DialogStatem.start_link({:uac, invite, provisional})

      # Verify starts in early state
      assert_state(pid, :early)
      timing = get_timing_data(pid)
      assert timing.answered_at == nil

      # Transition to confirmed with 200 OK
      final = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:uac_trans_result, {:message, final}})

      Process.sleep(20)

      # Verify transition and answered_at capture
      assert_state(pid, :confirmed)
      new_timing = get_timing_data(pid)

      assert new_timing.answered_at != nil,
             "answered_at should be set after :early -> :confirmed transition"

      assert %DateTime{} = new_timing.answered_at
    end

    test "answered_at remains nil if call is never answered" do
      invite = build_invite_message()
      provisional = build_response_message(180, "Ringing")

      {:ok, pid} = DialogStatem.start_link({:uas, provisional, invite})

      # Verify in early state with nil answered_at
      assert_state(pid, :early)
      timing = get_timing_data(pid)
      assert timing.answered_at == nil

      # Simulate call abandonment (stop without answering)
      :gen_statem.cast(pid, {:uac_trans_result, {:stop, :timeout}})

      Process.sleep(20)

      # Dialog should have terminated
      refute Process.alive?(pid)
    end

    test "answered_at is set for dialogs starting directly in :confirmed state" do
      # When a 200 OK response creates the dialog directly in confirmed state
      invite = build_invite_message()
      response = build_response_message(200, "OK")

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})

      assert_state(pid, :confirmed)
      timing = get_timing_data(pid)

      # For dialogs created directly in confirmed, answered_at should equal invite_received_at
      # or be set at creation time
      assert timing.answered_at != nil,
             "answered_at should be set for dialogs starting in :confirmed state"

      assert %DateTime{} = timing.answered_at
    end
  end

  describe "timing data available at termination" do
    test "timing data is available when dialog terminates normally via BYE" do
      invite = build_invite_message()
      response = build_response_message(200, "OK")

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})

      # Get timing data before termination
      timing = get_timing_data(pid)

      assert timing.invite_received_at != nil
      assert timing.answered_at != nil

      # Capture timestamps
      invite_time = timing.invite_received_at
      answered_time = timing.answered_at

      # Verify answered_at is >= invite_received_at
      assert DateTime.compare(answered_time, invite_time) in [:eq, :gt],
             "answered_at should be at or after invite_received_at"

      # Terminate with BYE
      bye = build_bye_message()
      :gen_statem.call(pid, {:uas_request, bye})

      Process.sleep(20)
    end

    test "timing data preserved during state transitions" do
      invite = build_invite_message()
      provisional = build_response_message(180, "Ringing")

      {:ok, pid} = DialogStatem.start_link({:uas, provisional, invite})

      # Capture invite_received_at in early state
      early_timing = get_timing_data(pid)
      invite_time = early_timing.invite_received_at
      assert invite_time != nil

      # Transition to confirmed
      final = build_response_message(200, "OK")
      :gen_statem.cast(pid, {:uas_response, final, invite})

      Process.sleep(20)

      # Verify invite_received_at is preserved after transition
      confirmed_timing = get_timing_data(pid)
      assert confirmed_timing.invite_received_at == invite_time,
             "invite_received_at should be preserved across state transitions"
    end
  end

  describe "timestamp format and precision" do
    test "timestamps are DateTime structs with microsecond precision" do
      invite = build_invite_message()
      response = build_response_message(200, "OK")

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})

      timing = get_timing_data(pid)

      # Verify DateTime struct
      assert %DateTime{} = timing.invite_received_at

      # Verify microsecond precision is available
      {_usec, precision} = timing.invite_received_at.microsecond
      assert precision > 0, "DateTime should have microsecond precision"
    end

    test "timestamps use UTC timezone" do
      invite = build_invite_message()
      response = build_response_message(200, "OK")

      {:ok, pid} = DialogStatem.start_link({:uas, response, invite})

      timing = get_timing_data(pid)

      assert timing.invite_received_at.time_zone == "Etc/UTC"
      assert timing.invite_received_at.utc_offset == 0
      assert timing.invite_received_at.std_offset == 0
    end
  end

  describe "recovered dialogs" do
    test "recovered dialog preserves timing fields from stored state" do
      # For recovered dialogs, timing should come from stored state
      # This tests the recovery path in init({:recover, stored_state})

      stored_state = %{
        call_id: "recovered-cdr-test@example.com",
        local_tag: "local-tag-cdr",
        remote_tag: "remote-tag-cdr",
        local_uri: "sip:local@example.com",
        remote_uri: "sip:remote@example.com",
        local_seq: 1,
        remote_seq: 1,
        secure: false,
        route_set: [],
        # CDR timing fields that should be recovered
        invite_received_at: ~U[2026-01-10 10:00:00.000000Z],
        answered_at: ~U[2026-01-10 10:00:05.123456Z]
      }

      {:ok, pid} = DialogStatem.start_recovered(stored_state)

      timing = get_timing_data(pid)

      # Verify timing fields are recovered
      assert timing.invite_received_at == ~U[2026-01-10 10:00:00.000000Z],
             "invite_received_at should be recovered from stored state"

      assert timing.answered_at == ~U[2026-01-10 10:00:05.123456Z],
             "answered_at should be recovered from stored state"
    end

    test "recovered dialog without timing fields gets current time" do
      # Older stored states might not have timing fields
      stored_state = %{
        call_id: "recovered-no-timing@example.com",
        local_tag: "local-tag-nt",
        remote_tag: "remote-tag-nt",
        local_uri: "sip:local@example.com",
        remote_uri: "sip:remote@example.com",
        local_seq: 1,
        remote_seq: 1,
        secure: false,
        route_set: []
        # No timing fields
      }

      {:ok, pid} = DialogStatem.start_recovered(stored_state)

      timing = get_timing_data(pid)

      # Recovered dialogs should still have timing fields set
      # (either from stored state or set to current time as fallback)
      assert timing.invite_received_at != nil,
             "recovered dialog should have invite_received_at"

      assert timing.answered_at != nil,
             "recovered confirmed dialog should have answered_at"
    end
  end

  # Helper functions for building test messages

  defp unique_call_id do
    "cdr-test-#{:erlang.unique_integer([:positive])}@example.com"
  end

  defp build_invite_message do
    call_id = unique_call_id()

    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:user@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-cdr-#{call_id}"}
      },
      from: %From{
        display_name: "CDR Test",
        uri: "sip:cdr-test@example.com",
        parameters: %{"tag" => "cdr-from-tag"}
      },
      to: %To{
        display_name: "Target",
        uri: "sip:target@example.com",
        parameters: %{}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :invite},
      contact: %Contact{
        uri: "sip:cdr-test@127.0.0.1:5060",
        parameters: %{}
      },
      other_headers: %{},
      body: "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 10000 RTP/AVP 0\r\n"
    }
  end

  defp build_response_message(status, reason) do
    call_id = unique_call_id()

    %Message{
      type: :response,
      method: nil,
      request_uri: nil,
      version: "SIP/2.0",
      status_code: status,
      reason_phrase: reason,
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-cdr-#{call_id}"}
      },
      from: %From{
        display_name: "CDR Test",
        uri: "sip:cdr-test@example.com",
        parameters: %{"tag" => "cdr-from-tag"}
      },
      to: %To{
        display_name: "Target",
        uri: "sip:target@example.com",
        parameters: %{"tag" => "cdr-to-tag"}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :invite},
      other_headers: %{},
      body: ""
    }
  end

  defp build_bye_message do
    call_id = unique_call_id()

    %Message{
      type: :request,
      method: :bye,
      request_uri: "sip:target@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-cdr-bye-#{call_id}"}
      },
      from: %From{
        display_name: "CDR Test",
        uri: "sip:cdr-test@example.com",
        parameters: %{"tag" => "cdr-from-tag"}
      },
      to: %To{
        display_name: "Target",
        uri: "sip:target@example.com",
        parameters: %{"tag" => "cdr-to-tag"}
      },
      call_id: call_id,
      cseq: %CSeq{number: 2, method: :bye},
      other_headers: %{},
      body: ""
    }
  end
end
