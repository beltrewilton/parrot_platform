defmodule ParrotMedia.Elements.TelephoneEventParserTest do
  @moduledoc """
  Unit tests for TelephoneEventParser Membrane element.

  Tests RFC 2833/4733 telephone-event parsing for DTMF detection.
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.Elements.TelephoneEventParser
  alias Membrane.Buffer

  # RFC 4733 telephone-event payload format:
  # - event (4 bits): DTMF digit (0-9, 10=*, 11=#, 12-15=A-D)
  # - end_bit (1 bit): Set on final packet of event
  # - reserved (1 bit): Always 0
  # - volume (6 bits): Power level (0-63)
  # - duration (16 bits): Event duration in timestamp units
  #
  # Byte layout:
  #   Byte 0: event_id (bits 7-4), end_bit (bit 3), reserved (bit 2), volume high (bits 1-0)
  #   Byte 1: volume low (bits 7-2) ... actually volume is only 6 bits in byte 0's lower portion
  #
  # Correct layout per RFC 4733:
  #   Byte 0: event (8 bits)
  #   Byte 1: E(1 bit) | R(1 bit) | volume(6 bits)
  #   Bytes 2-3: duration (16 bits)

  defp build_telephone_event_payload(event_id, end_bit, volume, duration) do
    # RFC 4733 Section 2.3 format:
    # 0                   1                   2                   3
    # 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    # |     event     |E|R| volume    |          duration             |
    # +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    e_bit = if end_bit, do: 1, else: 0
    reserved = 0
    <<event_id::8, e_bit::1, reserved::1, volume::6, duration::16>>
  end

  defp build_rtp_buffer(payload, timestamp, payload_type) do
    # Create a buffer with RTP metadata
    %Buffer{
      payload: payload,
      pts: timestamp,
      metadata: %{
        rtp: %{
          payload_type: payload_type,
          timestamp: timestamp,
          sequence_number: 1
        }
      }
    }
  end

  describe "RFC 4733 payload parsing (T9)" do
    @describetag :t9

    @tag :t9
    test "parses valid 4-byte payload with event_id=1, end_bit=1, volume=10, duration=1600" do
      # Construct RFC 4733 payload per Section 2.3:
      # - event_id = 1 (DTMF digit "1")
      # - end_bit = 1 (final packet)
      # - reserved = 0
      # - volume = 10
      # - duration = 1600
      payload = build_telephone_event_payload(1, true, 10, 1600)

      # Verify payload is exactly 4 bytes per RFC 4733
      assert byte_size(payload) == 4

      # Verify binary structure matches expected format
      # Byte 0: event_id = 1 (0x01)
      # Byte 1: end_bit=1, reserved=0, volume=10 -> 1_0_001010 = 0x8A (138 decimal)
      # Bytes 2-3: duration=1600 -> 0x0640
      assert payload == <<1, 138, 6, 64>>

      # Initialize the parser
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      # Forward stream format
      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Create buffer and process it
      buffer = build_rtp_buffer(payload, 1000, payload_type)
      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Should emit {:dtmf, "1"} notification when end_bit=1
      notifications = extract_notifications(actions)

      assert notifications == [{:dtmf, "1"}],
             "Expected {:dtmf, \"1\"} notification for event_id=1 with end_bit=1"
    end

    @tag :t9
    test "correctly parses event_id from first byte" do
      # Test that event_id is correctly extracted from the first byte
      # Test with digit "5" (event_id = 5)
      payload = build_telephone_event_payload(5, true, 10, 800)

      # First byte should be event_id = 5
      <<event_byte::8, _rest::binary>> = payload
      assert event_byte == 5

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      buffer = build_rtp_buffer(payload, 1000, payload_type)
      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      notifications = extract_notifications(actions)

      assert notifications == [{:dtmf, "5"}],
             "Expected {:dtmf, \"5\"} for event_id=5"
    end

    @tag :t9
    test "correctly identifies end_bit=1 from second byte" do
      # Test that end_bit is correctly extracted from bit 7 of second byte
      # end_bit=1 should emit notification, end_bit=0 should not

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Payload with end_bit=0 (in progress)
      payload_no_end = build_telephone_event_payload(9, false, 10, 400)
      # Second byte should have bit 7 = 0
      <<_event::8, second_byte::8, _rest::binary>> = payload_no_end
      import Bitwise
      assert band(second_byte, 0x80) == 0, "end_bit should be 0"

      buffer_no_end = build_rtp_buffer(payload_no_end, 1000, payload_type)

      {actions_no_end, state} =
        TelephoneEventParser.handle_buffer(:input, buffer_no_end, nil, state)

      notifications_no_end = extract_notifications(actions_no_end)

      assert notifications_no_end == [],
             "end_bit=0 should NOT emit notification"

      # Payload with end_bit=1 (final packet)
      payload_end = build_telephone_event_payload(9, true, 10, 1600)
      # Second byte should have bit 7 = 1
      <<_event2::8, second_byte2::8, _rest2::binary>> = payload_end
      assert band(second_byte2, 0x80) == 0x80, "end_bit should be 1"

      buffer_end = build_rtp_buffer(payload_end, 1000, payload_type)
      {actions_end, _state} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state)

      notifications_end = extract_notifications(actions_end)

      assert notifications_end == [{:dtmf, "9"}],
             "end_bit=1 SHOULD emit {:dtmf, \"9\"} notification"
    end

    @tag :t9
    test "parses all valid DTMF event_ids (0-15)" do
      # RFC 4733 Section 3.2: Event codes for DTMF
      # 0-9: digits "0"-"9"
      # 10: "*"
      # 11: "#"
      # 12-15: "A"-"D"

      expected_mappings = [
        {0, "0"},
        {1, "1"},
        {2, "2"},
        {3, "3"},
        {4, "4"},
        {5, "5"},
        {6, "6"},
        {7, "7"},
        {8, "8"},
        {9, "9"},
        {10, "*"},
        {11, "#"},
        {12, "A"},
        {13, "B"},
        {14, "C"},
        {15, "D"}
      ]

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      for {event_id, expected_digit} <- expected_mappings do
        payload = build_telephone_event_payload(event_id, true, 10, 1600)
        buffer = build_rtp_buffer(payload, event_id * 1000, payload_type)
        {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

        notifications = extract_notifications(actions)

        assert notifications == [{:dtmf, expected_digit}],
               "Expected {:dtmf, \"#{expected_digit}\"} for event_id=#{event_id}, got: #{inspect(notifications)}"
      end
    end

    @tag :t9
    test "buffers are passed through unchanged to output" do
      # TelephoneEventParser is a filter - it should pass all buffers through
      payload = build_telephone_event_payload(5, true, 10, 1600)

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      original_buffer = build_rtp_buffer(payload, 1000, payload_type)
      {actions, _state} = TelephoneEventParser.handle_buffer(:input, original_buffer, nil, state)

      # Should have buffer action passing through the original buffer
      buffer_actions =
        Enum.filter(actions, fn
          {:buffer, {:output, _}} -> true
          _ -> false
        end)

      assert length(buffer_actions) == 1,
             "Buffer should be passed through to output"

      [{:buffer, {:output, output_buffer}}] = buffer_actions

      assert output_buffer.payload == payload,
             "Buffer payload should be unchanged"
    end
  end

  describe "single digit detection with end_bit=1 (T10)" do
    @describetag :t10

    @tag :t10
    test "emits {:dtmf, digit} notification when end_bit=1 is received" do
      # When a telephone-event packet with end_bit=1 is received,
      # a {:dtmf, digit} notification should be emitted

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      # Forward stream format first
      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Build end packet for digit "5" (event_id=5, end_bit=1)
      event_id = 5
      timestamp = 1000
      end_payload = build_telephone_event_payload(event_id, true, 10, 160)
      buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      # Process the buffer
      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Should emit a {:dtmf, "5"} notification
      notifications = extract_notifications(actions)

      assert notifications == [{:dtmf, "5"}],
             "Expected [{:dtmf, \"5\"}] notification, got: #{inspect(notifications)}"
    end

    @tag :t10
    test "notification contains the correct digit character for event_id=5" do
      # The notification must contain the correct digit as a string character,
      # not the raw event_id integer

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # End packet for digit "5"
      event_id = 5
      timestamp = 1000
      end_payload = build_telephone_event_payload(event_id, true, 10, 160)
      buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      notifications = extract_notifications(actions)

      # Verify the notification contains a string digit, not integer
      assert length(notifications) == 1, "Expected exactly one notification"
      [{:dtmf, digit}] = notifications

      assert digit == "5", "Expected digit \"5\", got: #{inspect(digit)}"
      assert is_binary(digit), "Digit should be a string, not #{inspect(digit)}"
    end

    @tag :t10
    test "emits only one notification per complete DTMF event" do
      # Simulates a sequence of RTP buffers representing a DTMF digit "5" press:
      # - Intermediate packets (end_bit=0) followed by
      # - Final packet (end_bit=1)
      # Should emit exactly one {:dtmf, "5"} notification

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Same timestamp for all packets in the same event
      timestamp = 1000
      event_id = 5

      # Intermediate packet 1: duration=160 (20ms), end_bit=0
      intermediate1 = build_telephone_event_payload(event_id, false, 10, 160)
      buffer1 = build_rtp_buffer(intermediate1, timestamp, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # Intermediate packet 2: duration=320 (40ms), end_bit=0
      intermediate2 = build_telephone_event_payload(event_id, false, 10, 320)
      buffer2 = build_rtp_buffer(intermediate2, timestamp, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      # Intermediate packet 3: duration=480 (60ms), end_bit=0
      intermediate3 = build_telephone_event_payload(event_id, false, 10, 480)
      buffer3 = build_rtp_buffer(intermediate3, timestamp, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)

      # Final packet: duration=640 (80ms), end_bit=1
      end_packet = build_telephone_event_payload(event_id, true, 10, 640)
      buffer_end = build_rtp_buffer(end_packet, timestamp, payload_type)

      {actions_end, _state_end} =
        TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state3)

      # Collect all notifications from all actions
      all_notifications =
        extract_notifications(actions1) ++
          extract_notifications(actions2) ++
          extract_notifications(actions3) ++
          extract_notifications(actions_end)

      # Should have exactly ONE notification from the entire sequence
      assert all_notifications == [{:dtmf, "5"}],
             "Expected exactly one {:dtmf, \"5\"} notification from the sequence, got: #{inspect(all_notifications)}"
    end

    @tag :t10
    test "intermediate packets (end_bit=0) do not emit notifications" do
      # Intermediate packets should NOT emit any notifications
      # Only the final packet (end_bit=1) triggers a notification

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Intermediate packet for digit "5" (end_bit=0)
      event_id = 5
      timestamp = 1000
      intermediate_payload = build_telephone_event_payload(event_id, false, 10, 160)
      buffer = build_rtp_buffer(intermediate_payload, timestamp, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Should NOT emit any notification
      notifications = extract_notifications(actions)

      assert notifications == [],
             "Intermediate packets (end_bit=0) should not emit notifications, got: #{inspect(notifications)}"
    end

    @tag :t10
    test "detects digit correctly from a realistic DTMF sequence with RFC 4733 retransmissions" do
      # Simulates a realistic DTMF digit "5" press sequence:
      # - Multiple intermediate packets with increasing duration
      # - Final end packet with end_bit=1
      # - RFC 4733 mandates retransmitting end packet 2 more times (total 3)
      # Should emit exactly ONE notification despite multiple end packets

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      timestamp = 1000
      event_id = 5

      # Intermediate packets (typical 20ms intervals with increasing duration)
      {actions1, state1} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(
            build_telephone_event_payload(event_id, false, 10, 160),
            timestamp,
            payload_type
          ),
          nil,
          state
        )

      {actions2, state2} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(
            build_telephone_event_payload(event_id, false, 10, 320),
            timestamp,
            payload_type
          ),
          nil,
          state1
        )

      {actions3, state3} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(
            build_telephone_event_payload(event_id, false, 10, 480),
            timestamp,
            payload_type
          ),
          nil,
          state2
        )

      {actions4, state4} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(
            build_telephone_event_payload(event_id, false, 10, 640),
            timestamp,
            payload_type
          ),
          nil,
          state3
        )

      # First end packet transmission (end_bit=1)
      {actions_end1, state_end1} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(
            build_telephone_event_payload(event_id, true, 10, 800),
            timestamp,
            payload_type
          ),
          nil,
          state4
        )

      # RFC 4733 retransmission 1 (same timestamp, same duration, end_bit=1)
      {actions_end2, state_end2} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(
            build_telephone_event_payload(event_id, true, 10, 800),
            timestamp,
            payload_type
          ),
          nil,
          state_end1
        )

      # RFC 4733 retransmission 2 (same timestamp, same duration, end_bit=1)
      {actions_end3, _state_end3} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(
            build_telephone_event_payload(event_id, true, 10, 800),
            timestamp,
            payload_type
          ),
          nil,
          state_end2
        )

      # Collect all notifications
      all_notifications =
        extract_notifications(actions1) ++
          extract_notifications(actions2) ++
          extract_notifications(actions3) ++
          extract_notifications(actions4) ++
          extract_notifications(actions_end1) ++
          extract_notifications(actions_end2) ++
          extract_notifications(actions_end3)

      # Should receive exactly ONE {:dtmf, "5"} notification despite:
      # - 4 intermediate packets
      # - 3 end packets (1 original + 2 retransmissions per RFC 4733)
      assert all_notifications == [{:dtmf, "5"}],
             "Expected exactly one {:dtmf, \"5\"} notification for complete DTMF sequence, got: #{inspect(all_notifications)}"
    end

    @tag :t10
    test "buffers pass through unchanged after detection" do
      # The TelephoneEventParser should pass all buffers through to the output pad
      # unchanged (it's a filter, not a sink)

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # End packet for digit "5"
      event_id = 5
      timestamp = 1000
      end_payload = build_telephone_event_payload(event_id, true, 10, 160)
      original_buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, original_buffer, nil, state)

      # Should include buffer action to pass the buffer through
      buffer_actions =
        actions
        |> Enum.filter(fn
          {:buffer, _} -> true
          _ -> false
        end)

      assert length(buffer_actions) == 1,
             "Expected one buffer action, got: #{inspect(buffer_actions)}"

      [{:buffer, {:output, output_buffer}}] = buffer_actions
      assert output_buffer == original_buffer, "Buffer should pass through unchanged"
    end
  end

  describe "duplicate suppression (T11)" do
    @tag :t11
    test "suppresses retransmitted end packets - emits exactly one notification for RFC 4733 triple transmission" do
      # RFC 4733 Section 2.5.1.4: "The RTP sender SHOULD send the final packet at
      # least three times to minimize the chance of packet loss causing the receiver
      # to miss the transition from active to inactive state."
      #
      # When the same end packet is retransmitted (same timestamp + event_id),
      # we should only emit ONE notification, not three.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      # Forward stream format first
      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Build end packet for digit "7" (event_id=7)
      # Same timestamp=1000, end_bit=1, volume=10, duration=1600
      event_id = 7
      timestamp = 1000
      end_payload = build_telephone_event_payload(event_id, true, 10, 1600)

      # First end packet transmission
      buffer1 = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # Second end packet transmission (retransmission with same timestamp)
      buffer2 = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      # Third end packet transmission (retransmission with same timestamp)
      buffer3 = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions3, _state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)

      # Extract notifications from all actions
      notifications1 = extract_notifications(actions1)
      notifications2 = extract_notifications(actions2)
      notifications3 = extract_notifications(actions3)

      all_notifications = notifications1 ++ notifications2 ++ notifications3

      # Should receive exactly ONE {:dtmf, "7"} notification, not three
      assert all_notifications == [{:dtmf, "7"}],
             "Expected exactly one {:dtmf, \"7\"} notification, got: #{inspect(all_notifications)}"
    end

    @tag :t11
    test "completed_events MapSet tracks unique {timestamp, event_id} pairs" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      # Initial state should have empty completed_events
      assert state.completed_events == MapSet.new()

      # Forward stream format
      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Process end packet for digit "7"
      event_id = 7
      timestamp = 1000
      end_payload = build_telephone_event_payload(event_id, true, 10, 1600)
      buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      {_actions, state_after} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # The completed_events set should now contain the {timestamp, event_id} pair
      assert MapSet.member?(state_after.completed_events, {timestamp, event_id}),
             "Expected {#{timestamp}, #{event_id}} to be in completed_events"
    end

    @tag :t11
    test "different timestamps for same event_id are not suppressed" do
      # This tests that we only suppress truly duplicate packets (same timestamp + event_id),
      # not legitimate new presses of the same digit

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # First press of digit "5" at timestamp 1000
      event_id = 5
      timestamp1 = 1000
      end_payload1 = build_telephone_event_payload(event_id, true, 10, 1600)
      buffer1 = build_rtp_buffer(end_payload1, timestamp1, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # Second press of digit "5" at different timestamp 2000
      timestamp2 = 2000
      end_payload2 = build_telephone_event_payload(event_id, true, 10, 1600)
      buffer2 = build_rtp_buffer(end_payload2, timestamp2, payload_type)
      {actions2, _state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      notifications1 = extract_notifications(actions1)
      notifications2 = extract_notifications(actions2)

      # Both presses should generate notifications since they have different timestamps
      assert notifications1 == [{:dtmf, "5"}],
             "First press should generate notification"

      assert notifications2 == [{:dtmf, "5"}],
             "Second press (different timestamp) should also generate notification"
    end

    @tag :t11
    test "same timestamp with different event_ids are not suppressed" do
      # This tests that different digits pressed at the same timestamp base
      # are both reported (unlikely in practice, but tests the logic)

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      timestamp = 1000

      # End packet for digit "3"
      end_payload_3 = build_telephone_event_payload(3, true, 10, 1600)
      buffer3 = build_rtp_buffer(end_payload_3, timestamp, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state)

      # End packet for digit "9" at same timestamp
      end_payload_9 = build_telephone_event_payload(9, true, 10, 1600)
      buffer9 = build_rtp_buffer(end_payload_9, timestamp, payload_type)
      {actions9, _state9} = TelephoneEventParser.handle_buffer(:input, buffer9, nil, state3)

      notifications3 = extract_notifications(actions3)
      notifications9 = extract_notifications(actions9)

      # Both should generate notifications since they are different events
      assert notifications3 == [{:dtmf, "3"}]
      assert notifications9 == [{:dtmf, "9"}]
    end

    @tag :t11
    test "non-end packets are not tracked in completed_events" do
      # Only end packets (end_bit=1) should be deduplicated
      # Intermediate packets should pass through without tracking

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Non-end packet for digit "7" (end_bit=0)
      event_id = 7
      timestamp = 1000
      non_end_payload = build_telephone_event_payload(event_id, false, 10, 800)
      buffer = build_rtp_buffer(non_end_payload, timestamp, payload_type)

      {_actions, state_after} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Non-end packets should NOT be added to completed_events
      assert state_after.completed_events == MapSet.new(),
             "Non-end packets should not be tracked in completed_events"
    end
  end

  describe "digit mapping: event_id 0-9 → \"0\"-\"9\" (T25)" do
    @describetag :t25

    @tag :t25
    test "event_id 0 maps to digit \"0\"" do
      assert_digit_mapping(0, "0")
    end

    @tag :t25
    test "event_id 1 maps to digit \"1\"" do
      assert_digit_mapping(1, "1")
    end

    @tag :t25
    test "event_id 2 maps to digit \"2\"" do
      assert_digit_mapping(2, "2")
    end

    @tag :t25
    test "event_id 3 maps to digit \"3\"" do
      assert_digit_mapping(3, "3")
    end

    @tag :t25
    test "event_id 4 maps to digit \"4\"" do
      assert_digit_mapping(4, "4")
    end

    @tag :t25
    test "event_id 5 maps to digit \"5\"" do
      assert_digit_mapping(5, "5")
    end

    @tag :t25
    test "event_id 6 maps to digit \"6\"" do
      assert_digit_mapping(6, "6")
    end

    @tag :t25
    test "event_id 7 maps to digit \"7\"" do
      assert_digit_mapping(7, "7")
    end

    @tag :t25
    test "event_id 8 maps to digit \"8\"" do
      assert_digit_mapping(8, "8")
    end

    @tag :t25
    test "event_id 9 maps to digit \"9\"" do
      assert_digit_mapping(9, "9")
    end

    @tag :t25
    test "all numeric digits 0-9 map correctly" do
      # Comprehensive test for all numeric mappings
      for event_id <- 0..9 do
        expected_digit = Integer.to_string(event_id)
        assert_digit_mapping(event_id, expected_digit)
      end
    end
  end

  describe "special key mapping: event_id 10 → \"*\", 11 → \"#\" (T26)" do
    @describetag :t26

    @tag :t26
    test "event_id 10 maps to star key \"*\"" do
      # RFC 4733 Section 3.2: Event code 10 = "*" (star/asterisk)
      assert_digit_mapping(10, "*")
    end

    @tag :t26
    test "event_id 11 maps to pound key \"#\"" do
      # RFC 4733 Section 3.2: Event code 11 = "#" (pound/hash)
      assert_digit_mapping(11, "#")
    end

    @tag :t26
    test "star key notification contains correct character" do
      # Ensure the notification contains exactly "*", not "10" or other encoding
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # End packet for star key (event_id=10)
      end_payload = build_telephone_event_payload(10, true, 10, 1600)
      buffer = build_rtp_buffer(end_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      notifications = extract_notifications(actions)

      assert length(notifications) == 1
      [{:dtmf, digit}] = notifications

      assert digit == "*", "Expected \"*\", got: #{inspect(digit)}"
      assert byte_size(digit) == 1, "Star key should be single character"
    end

    @tag :t26
    test "pound key notification contains correct character" do
      # Ensure the notification contains exactly "#", not "11" or other encoding
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # End packet for pound key (event_id=11)
      end_payload = build_telephone_event_payload(11, true, 10, 1600)
      buffer = build_rtp_buffer(end_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      notifications = extract_notifications(actions)

      assert length(notifications) == 1
      [{:dtmf, digit}] = notifications

      assert digit == "#", "Expected \"#\", got: #{inspect(digit)}"
      assert byte_size(digit) == 1, "Pound key should be single character"
    end
  end

  describe "extended key mapping: event_id 12-15 → \"A\"-\"D\" (T27)" do
    @describetag :t27

    @tag :t27
    test "event_id 12 maps to extended key \"A\"" do
      # RFC 4733 Section 3.2: Event code 12 = "A"
      assert_digit_mapping(12, "A")
    end

    @tag :t27
    test "event_id 13 maps to extended key \"B\"" do
      # RFC 4733 Section 3.2: Event code 13 = "B"
      assert_digit_mapping(13, "B")
    end

    @tag :t27
    test "event_id 14 maps to extended key \"C\"" do
      # RFC 4733 Section 3.2: Event code 14 = "C"
      assert_digit_mapping(14, "C")
    end

    @tag :t27
    test "event_id 15 maps to extended key \"D\"" do
      # RFC 4733 Section 3.2: Event code 15 = "D"
      assert_digit_mapping(15, "D")
    end

    @tag :t27
    test "all extended keys A-D map correctly in sequence" do
      # Test all extended DTMF keys in order
      extended_mappings = [
        {12, "A"},
        {13, "B"},
        {14, "C"},
        {15, "D"}
      ]

      for {event_id, expected_digit} <- extended_mappings do
        assert_digit_mapping(event_id, expected_digit)
      end
    end

    @tag :t27
    test "extended keys use uppercase letters" do
      # Verify that A-D are uppercase, not lowercase
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      for event_id <- 12..15 do
        end_payload = build_telephone_event_payload(event_id, true, 10, 1600)
        buffer = build_rtp_buffer(end_payload, event_id * 1000, payload_type)

        {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

        [{:dtmf, digit}] = extract_notifications(actions)

        # Verify uppercase
        assert digit == String.upcase(digit),
               "Extended key for event_id=#{event_id} should be uppercase, got: #{inspect(digit)}"
      end
    end
  end

  describe "sequential digit detection (T17)" do
    @describetag :t17

    @tag :t17
    test "emits four separate notifications for sequential digits 1234" do
      # When digits "1", "2", "3", "4" are pressed in sequence (each with different timestamps),
      # four separate {:dtmf, "1"}, {:dtmf, "2"}, {:dtmf, "3"}, {:dtmf, "4"} notifications are emitted
      # in the correct order.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Digit "1" at timestamp 1000
      buffer1 = build_rtp_buffer(build_telephone_event_payload(1, true, 10, 1600), 1000, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # Digit "2" at timestamp 2000
      buffer2 = build_rtp_buffer(build_telephone_event_payload(2, true, 10, 1600), 2000, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      # Digit "3" at timestamp 3000
      buffer3 = build_rtp_buffer(build_telephone_event_payload(3, true, 10, 1600), 3000, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)

      # Digit "4" at timestamp 4000
      buffer4 = build_rtp_buffer(build_telephone_event_payload(4, true, 10, 1600), 4000, payload_type)
      {actions4, _state4} = TelephoneEventParser.handle_buffer(:input, buffer4, nil, state3)

      # Collect notifications in order
      all_notifications =
        extract_notifications(actions1) ++
          extract_notifications(actions2) ++
          extract_notifications(actions3) ++
          extract_notifications(actions4)

      assert all_notifications == [{:dtmf, "1"}, {:dtmf, "2"}, {:dtmf, "3"}, {:dtmf, "4"}],
             "Expected four sequential notifications {:dtmf, \"1\"}, {:dtmf, \"2\"}, {:dtmf, \"3\"}, {:dtmf, \"4\"}, got: #{inspect(all_notifications)}"
    end

    @tag :t17
    test "preserves order for mixed digit sequence" do
      # Test with a non-sequential digit pattern to ensure order is preserved
      # Sequence: "9", "1", "5", "0" should emit in that exact order

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Process digits in sequence with different timestamps
      digits_to_press = [{9, 1000}, {1, 2000}, {5, 3000}, {0, 4000}]

      {all_notifications, _final_state} =
        Enum.reduce(digits_to_press, {[], state}, fn {event_id, timestamp}, {notifications_acc, current_state} ->
          buffer = build_rtp_buffer(build_telephone_event_payload(event_id, true, 10, 1600), timestamp, payload_type)
          {actions, new_state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)
          {notifications_acc ++ extract_notifications(actions), new_state}
        end)

      assert all_notifications == [{:dtmf, "9"}, {:dtmf, "1"}, {:dtmf, "5"}, {:dtmf, "0"}],
             "Expected notifications in order 9, 1, 5, 0, got: #{inspect(all_notifications)}"
    end

    @tag :t17
    test "handles complete event sequences with intermediate packets for each digit" do
      # More realistic scenario: each digit has intermediate packets before end packet
      # Digits: "1", "2" each with 2 intermediate packets before end

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      all_notifications = []

      # Digit "1" sequence at timestamp 1000
      timestamp1 = 1000
      # Intermediate packets
      buffer1_int1 = build_rtp_buffer(build_telephone_event_payload(1, false, 10, 160), timestamp1, payload_type)
      {actions1_int1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1_int1, nil, state)

      buffer1_int2 = build_rtp_buffer(build_telephone_event_payload(1, false, 10, 320), timestamp1, payload_type)
      {actions1_int2, state2} = TelephoneEventParser.handle_buffer(:input, buffer1_int2, nil, state1)

      # End packet for digit "1"
      buffer1_end = build_rtp_buffer(build_telephone_event_payload(1, true, 10, 480), timestamp1, payload_type)
      {actions1_end, state3} = TelephoneEventParser.handle_buffer(:input, buffer1_end, nil, state2)

      all_notifications =
        all_notifications ++
          extract_notifications(actions1_int1) ++
          extract_notifications(actions1_int2) ++
          extract_notifications(actions1_end)

      # Digit "2" sequence at timestamp 2000
      timestamp2 = 2000
      # Intermediate packets
      buffer2_int1 = build_rtp_buffer(build_telephone_event_payload(2, false, 10, 160), timestamp2, payload_type)
      {actions2_int1, state4} = TelephoneEventParser.handle_buffer(:input, buffer2_int1, nil, state3)

      buffer2_int2 = build_rtp_buffer(build_telephone_event_payload(2, false, 10, 320), timestamp2, payload_type)
      {actions2_int2, state5} = TelephoneEventParser.handle_buffer(:input, buffer2_int2, nil, state4)

      # End packet for digit "2"
      buffer2_end = build_rtp_buffer(build_telephone_event_payload(2, true, 10, 480), timestamp2, payload_type)
      {actions2_end, _state6} = TelephoneEventParser.handle_buffer(:input, buffer2_end, nil, state5)

      all_notifications =
        all_notifications ++
          extract_notifications(actions2_int1) ++
          extract_notifications(actions2_int2) ++
          extract_notifications(actions2_end)

      # Should have exactly 2 notifications in order
      assert all_notifications == [{:dtmf, "1"}, {:dtmf, "2"}],
             "Expected [{:dtmf, \"1\"}, {:dtmf, \"2\"}] from complete sequences, got: #{inspect(all_notifications)}"
    end

    @tag :t17
    test "handles rapid digit sequence with minimal gaps" do
      # Simulate rapid digit entry where timestamps are close together
      # Each digit is a short press (small duration)

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Rapid sequence: timestamps only 200 samples apart (25ms at 8kHz)
      rapid_digits = [
        {1, 1000, 160},  # Digit "1" at 1000, duration 160 (20ms)
        {2, 1200, 160},  # Digit "2" at 1200, duration 160 (20ms)
        {3, 1400, 160},  # Digit "3" at 1400, duration 160 (20ms)
        {4, 1600, 160}   # Digit "4" at 1600, duration 160 (20ms)
      ]

      {all_notifications, _final_state} =
        Enum.reduce(rapid_digits, {[], state}, fn {event_id, timestamp, duration}, {notifications_acc, current_state} ->
          buffer = build_rtp_buffer(build_telephone_event_payload(event_id, true, 10, duration), timestamp, payload_type)
          {actions, new_state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)
          {notifications_acc ++ extract_notifications(actions), new_state}
        end)

      assert all_notifications == [{:dtmf, "1"}, {:dtmf, "2"}, {:dtmf, "3"}, {:dtmf, "4"}],
             "Expected 4 notifications even with rapid sequence, got: #{inspect(all_notifications)}"
    end

    @tag :t17
    test "handles special characters in sequence with digits" do
      # Test mixed sequence: "1", "*", "#", "A"

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Mixed sequence including special characters
      # event_id: 1="1", 10="*", 11="#", 12="A"
      mixed_sequence = [
        {1, 1000},   # "1"
        {10, 2000},  # "*"
        {11, 3000},  # "#"
        {12, 4000}   # "A"
      ]

      {all_notifications, _final_state} =
        Enum.reduce(mixed_sequence, {[], state}, fn {event_id, timestamp}, {notifications_acc, current_state} ->
          buffer = build_rtp_buffer(build_telephone_event_payload(event_id, true, 10, 1600), timestamp, payload_type)
          {actions, new_state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)
          {notifications_acc ++ extract_notifications(actions), new_state}
        end)

      assert all_notifications == [{:dtmf, "1"}, {:dtmf, "*"}, {:dtmf, "#"}, {:dtmf, "A"}],
             "Expected mixed sequence with special chars, got: #{inspect(all_notifications)}"
    end
  end

  describe "state reset between events (T18)" do
    @describetag :t18

    @tag :t18
    test "new event with different timestamp resets tracking for same digit" do
      # When a new event starts (different timestamp), it should be tracked independently
      # even if it's the same digit as a previous event

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # First press of digit "5" at timestamp 1000
      event_id = 5
      timestamp1 = 1000
      buffer1 = build_rtp_buffer(build_telephone_event_payload(event_id, true, 10, 1600), timestamp1, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # State should track this event as completed
      assert MapSet.member?(state1.completed_events, {timestamp1, event_id})

      # Second press of same digit "5" at different timestamp 5000
      timestamp2 = 5000
      buffer2 = build_rtp_buffer(build_telephone_event_payload(event_id, true, 10, 1600), timestamp2, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      # State should now track both events as completed
      assert MapSet.member?(state2.completed_events, {timestamp1, event_id})
      assert MapSet.member?(state2.completed_events, {timestamp2, event_id})

      # Both events should have generated notifications
      notifications1 = extract_notifications(actions1)
      notifications2 = extract_notifications(actions2)

      assert notifications1 == [{:dtmf, "5"}]
      assert notifications2 == [{:dtmf, "5"}]
    end

    @tag :t18
    test "each event_id is tracked independently at same timestamp" do
      # Different event_ids at the same timestamp should be tracked separately
      # (This is an edge case but tests the state isolation correctly)

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      timestamp = 1000

      # Press digit "3" at timestamp 1000
      buffer3 = build_rtp_buffer(build_telephone_event_payload(3, true, 10, 1600), timestamp, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state)

      # Press digit "7" at same timestamp 1000 (different event)
      buffer7 = build_rtp_buffer(build_telephone_event_payload(7, true, 10, 1600), timestamp, payload_type)
      {actions7, state7} = TelephoneEventParser.handle_buffer(:input, buffer7, nil, state3)

      # State should have both {1000, 3} and {1000, 7} tracked
      assert MapSet.member?(state7.completed_events, {timestamp, 3})
      assert MapSet.member?(state7.completed_events, {timestamp, 7})

      # Both should generate notifications (no cross-contamination)
      assert extract_notifications(actions3) == [{:dtmf, "3"}]
      assert extract_notifications(actions7) == [{:dtmf, "7"}]
    end

    @tag :t18
    test "no cross-contamination between separate DTMF events" do
      # Verify that intermediate packets from one event don't affect another event

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      all_notifications = []

      # Start event for digit "1" at timestamp 1000 (intermediate packets)
      timestamp1 = 1000
      int1_1 = build_rtp_buffer(build_telephone_event_payload(1, false, 10, 160), timestamp1, payload_type)
      {actions_int1_1, state1} = TelephoneEventParser.handle_buffer(:input, int1_1, nil, state)

      int1_2 = build_rtp_buffer(build_telephone_event_payload(1, false, 10, 320), timestamp1, payload_type)
      {actions_int1_2, state2} = TelephoneEventParser.handle_buffer(:input, int1_2, nil, state1)

      all_notifications =
        all_notifications ++
          extract_notifications(actions_int1_1) ++
          extract_notifications(actions_int1_2)

      # Before ending event "1", start event for digit "2" at timestamp 2000
      # (This simulates overlapping events - unlikely but tests state isolation)
      timestamp2 = 2000
      int2_1 = build_rtp_buffer(build_telephone_event_payload(2, false, 10, 160), timestamp2, payload_type)
      {actions_int2_1, state3} = TelephoneEventParser.handle_buffer(:input, int2_1, nil, state2)

      all_notifications = all_notifications ++ extract_notifications(actions_int2_1)

      # End event for digit "1"
      end1 = build_rtp_buffer(build_telephone_event_payload(1, true, 10, 480), timestamp1, payload_type)
      {actions_end1, state4} = TelephoneEventParser.handle_buffer(:input, end1, nil, state3)

      all_notifications = all_notifications ++ extract_notifications(actions_end1)

      # End event for digit "2"
      end2 = build_rtp_buffer(build_telephone_event_payload(2, true, 10, 320), timestamp2, payload_type)
      {actions_end2, _state5} = TelephoneEventParser.handle_buffer(:input, end2, nil, state4)

      all_notifications = all_notifications ++ extract_notifications(actions_end2)

      # Should get exactly 2 notifications in order: "1" then "2"
      assert all_notifications == [{:dtmf, "1"}, {:dtmf, "2"}],
             "Expected separate notifications for each event, got: #{inspect(all_notifications)}"
    end

    @tag :t18
    test "completed_events grows with each new unique event" do
      # Verify that the completed_events MapSet accumulates unique events correctly

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Initially empty
      assert MapSet.size(state.completed_events) == 0

      # First event: digit "1" at timestamp 1000
      buffer1 = build_rtp_buffer(build_telephone_event_payload(1, true, 10, 1600), 1000, payload_type)
      {_actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)
      assert MapSet.size(state1.completed_events) == 1

      # Second event: digit "2" at timestamp 2000
      buffer2 = build_rtp_buffer(build_telephone_event_payload(2, true, 10, 1600), 2000, payload_type)
      {_actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)
      assert MapSet.size(state2.completed_events) == 2

      # Third event: digit "1" again at timestamp 3000 (different event, same digit)
      buffer3 = build_rtp_buffer(build_telephone_event_payload(1, true, 10, 1600), 3000, payload_type)
      {_actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)
      assert MapSet.size(state3.completed_events) == 3

      # Retransmission of third event (same timestamp, same digit) - should NOT grow
      buffer3_retx = build_rtp_buffer(build_telephone_event_payload(1, true, 10, 1600), 3000, payload_type)
      {_actions3_retx, state3_retx} = TelephoneEventParser.handle_buffer(:input, buffer3_retx, nil, state3)
      assert MapSet.size(state3_retx.completed_events) == 3, "Retransmission should not add new entry"
    end

    @tag :t18
    test "state tracks event by both timestamp AND event_id tuple" do
      # Verify the state uses {timestamp, event_id} tuple for tracking

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Event: digit "5" (event_id=5) at timestamp 1234
      buffer = build_rtp_buffer(build_telephone_event_payload(5, true, 10, 1600), 1234, payload_type)
      {_actions, new_state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Verify the exact tuple is in the set
      assert MapSet.member?(new_state.completed_events, {1234, 5})

      # Verify similar but different tuples are NOT in the set
      refute MapSet.member?(new_state.completed_events, {1234, 6})  # Different event_id
      refute MapSet.member?(new_state.completed_events, {1235, 5})  # Different timestamp
      refute MapSet.member?(new_state.completed_events, {5, 1234})  # Wrong order
    end
  end

  # Helper function for digit mapping assertions
  defp assert_digit_mapping(event_id, expected_digit) do
    payload_type = 101
    {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

    stream_format = %Membrane.RTP{}

    {[stream_format: {:output, _}], state} =
      TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

    # Build end packet with the specified event_id
    end_payload = build_telephone_event_payload(event_id, true, 10, 1600)
    buffer = build_rtp_buffer(end_payload, 1000, payload_type)

    {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

    notifications = extract_notifications(actions)

    assert notifications == [{:dtmf, expected_digit}],
           "Expected {:dtmf, \"#{expected_digit}\"} for event_id=#{event_id}, got: #{inspect(notifications)}"
  end

  describe "malformed payload handling (T41)" do
    @describetag :t41

    @tag :t41
    test "malformed payload (1 byte) passes buffer through unchanged without crashing" do
      # Malformed payloads should be handled gracefully:
      # - Log a warning
      # - Pass buffer through unchanged
      # - Don't crash

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Malformed: only 1 byte instead of required 4
      malformed_payload = <<5>>

      buffer = %Buffer{
        payload: malformed_payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            payload_type: payload_type,
            timestamp: 1000,
            sequence_number: 1
          }
        }
      }

      # Should not crash and should pass buffer through
      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Should pass buffer through unchanged
      buffer_actions =
        Enum.filter(actions, fn
          {:buffer, {:output, _}} -> true
          _ -> false
        end)

      assert length(buffer_actions) == 1, "Malformed payload buffer should pass through"

      [{:buffer, {:output, output_buffer}}] = buffer_actions
      assert output_buffer.payload == malformed_payload, "Payload should be unchanged"

      # Should NOT emit any DTMF notifications
      notifications = extract_notifications(actions)
      assert notifications == [], "Malformed payload should not emit notifications"
    end

    @tag :t41
    test "malformed payload (3 bytes) passes buffer through unchanged" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Malformed: 3 bytes instead of required 4
      malformed_payload = <<5, 138, 6>>

      buffer = %Buffer{
        payload: malformed_payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            payload_type: payload_type,
            timestamp: 1000,
            sequence_number: 1
          }
        }
      }

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Should pass buffer through
      buffer_actions =
        Enum.filter(actions, fn
          {:buffer, {:output, _}} -> true
          _ -> false
        end)

      assert length(buffer_actions) == 1
      notifications = extract_notifications(actions)
      assert notifications == []
    end

    @tag :t41
    test "malformed payload (5 bytes) passes buffer through unchanged" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Malformed: 5 bytes instead of required 4
      malformed_payload = <<5, 138, 6, 64, 99>>

      buffer = %Buffer{
        payload: malformed_payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            payload_type: payload_type,
            timestamp: 1000,
            sequence_number: 1
          }
        }
      }

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions =
        Enum.filter(actions, fn
          {:buffer, {:output, _}} -> true
          _ -> false
        end)

      assert length(buffer_actions) == 1
      notifications = extract_notifications(actions)
      assert notifications == []
    end

    @tag :t41
    test "empty payload passes buffer through unchanged" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Empty payload
      empty_payload = <<>>

      buffer = %Buffer{
        payload: empty_payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            payload_type: payload_type,
            timestamp: 1000,
            sequence_number: 1
          }
        }
      }

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions =
        Enum.filter(actions, fn
          {:buffer, {:output, _}} -> true
          _ -> false
        end)

      assert length(buffer_actions) == 1
      notifications = extract_notifications(actions)
      assert notifications == []
    end
  end

  describe "payload_type validation (T42)" do
    @describetag :t42

    @tag :t42
    test "valid positive integer payload_type is accepted" do
      # Valid payload types should work
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: 101})
      assert state.payload_type == 101

      {[], state2} = TelephoneEventParser.handle_init(nil, %{payload_type: 96})
      assert state2.payload_type == 96

      {[], state3} = TelephoneEventParser.handle_init(nil, %{payload_type: 127})
      assert state3.payload_type == 127
    end

    @tag :t42
    test "payload_type of 0 raises ArgumentError" do
      # payload_type must be positive
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: 0})
      end
    end

    @tag :t42
    test "negative payload_type raises ArgumentError" do
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: -1})
      end
    end

    @tag :t42
    test "nil payload_type raises ArgumentError" do
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: nil})
      end
    end

    @tag :t42
    test "non-integer payload_type raises ArgumentError" do
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: "101"})
      end

      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: 101.5})
      end
    end

    @tag :t42
    test "missing payload_type key raises appropriate error" do
      # Missing key should raise (via KeyError or pattern match failure)
      assert_raise KeyError, fn ->
        TelephoneEventParser.handle_init(nil, %{})
      end
    end
  end

  describe "long key press tracking (T30)" do
    @describetag :t30

    @tag :t30
    test "handles 40+ intermediate packets with only 1 notification on end" do
      # When a key is held down for an extended period, many intermediate packets
      # are sent (end_bit=0), all with the same timestamp but increasing duration.
      # Only ONE notification should be emitted when the final end packet arrives.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Same timestamp for all packets in the same event (key press)
      timestamp = 1000
      event_id = 5
      volume = 10

      # Send 40 intermediate packets with increasing duration
      # Each packet represents ~20ms of audio (160 timestamp units at 8kHz)
      {all_intermediate_notifications, state_after_intermediates} =
        Enum.reduce(1..40, {[], state}, fn i, {notifications_acc, current_state} ->
          duration = i * 160
          intermediate_payload = build_telephone_event_payload(event_id, false, volume, duration)
          buffer = build_rtp_buffer(intermediate_payload, timestamp, payload_type)

          {actions, new_state} =
            TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)

          new_notifications = extract_notifications(actions)
          {notifications_acc ++ new_notifications, new_state}
        end)

      # Verify no notifications were emitted during the intermediate packets
      assert all_intermediate_notifications == [],
             "No notifications should be emitted during intermediate packets (end_bit=0), got: #{inspect(all_intermediate_notifications)}"

      # Now send the final end packet (end_bit=1) with total duration
      final_duration = 41 * 160
      end_payload = build_telephone_event_payload(event_id, true, volume, final_duration)
      end_buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      {end_actions, _final_state} =
        TelephoneEventParser.handle_buffer(:input, end_buffer, nil, state_after_intermediates)

      end_notifications = extract_notifications(end_actions)

      # Should emit exactly ONE notification on the end packet
      assert end_notifications == [{:dtmf, "5"}],
             "Expected exactly one {:dtmf, \"5\"} notification on end packet, got: #{inspect(end_notifications)}"
    end

    @tag :t30
    test "handles 100 intermediate packets gracefully" do
      # Stress test: even longer key press with 100 intermediate packets
      # This simulates a key held for ~2 seconds (100 * 20ms)

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      timestamp = 5000
      event_id = 9
      volume = 10

      # Send 100 intermediate packets
      {all_intermediate_notifications, state_after_intermediates} =
        Enum.reduce(1..100, {[], state}, fn i, {notifications_acc, current_state} ->
          duration = i * 160
          intermediate_payload = build_telephone_event_payload(event_id, false, volume, duration)
          buffer = build_rtp_buffer(intermediate_payload, timestamp, payload_type)

          {actions, new_state} =
            TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)

          new_notifications = extract_notifications(actions)
          {notifications_acc ++ new_notifications, new_state}
        end)

      # No notifications during intermediate packets
      assert all_intermediate_notifications == [],
             "No notifications should be emitted during 100 intermediate packets"

      # Final end packet
      final_duration = 101 * 160
      end_payload = build_telephone_event_payload(event_id, true, volume, final_duration)
      end_buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      {end_actions, _final_state} =
        TelephoneEventParser.handle_buffer(:input, end_buffer, nil, state_after_intermediates)

      end_notifications = extract_notifications(end_actions)

      assert end_notifications == [{:dtmf, "9"}],
             "Expected {:dtmf, \"9\"} after 100 intermediate packets"
    end

    @tag :t30
    test "all intermediate packets have same timestamp but increasing duration" do
      # Verify our understanding: intermediate packets all share the same RTP timestamp
      # (the timestamp of when the key was first pressed), but duration increases

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      timestamp = 3000
      event_id = 7
      volume = 10

      # Process 5 intermediate packets and verify all pass through
      {buffer_actions_list, _final_state} =
        Enum.reduce(1..5, {[], state}, fn i, {actions_acc, current_state} ->
          duration = i * 160
          intermediate_payload = build_telephone_event_payload(event_id, false, volume, duration)
          buffer = build_rtp_buffer(intermediate_payload, timestamp, payload_type)

          {actions, new_state} =
            TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)

          # Extract buffer pass-through actions
          buffer_actions =
            Enum.filter(actions, fn
              {:buffer, {:output, _}} -> true
              _ -> false
            end)

          {actions_acc ++ buffer_actions, new_state}
        end)

      # All 5 intermediate buffers should pass through
      assert length(buffer_actions_list) == 5,
             "All intermediate packets should be passed through to output"
    end

    @tag :t30
    test "long press with RFC 4733 end packet retransmissions" do
      # Simulates a realistic long key press:
      # - 50 intermediate packets (1 second hold)
      # - 3 end packet transmissions per RFC 4733
      # Should emit exactly ONE notification total

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      timestamp = 2000
      event_id = 0
      volume = 10

      # Send 50 intermediate packets
      {intermediate_notifications, state_after} =
        Enum.reduce(1..50, {[], state}, fn i, {notifications_acc, current_state} ->
          duration = i * 160
          intermediate_payload = build_telephone_event_payload(event_id, false, volume, duration)
          buffer = build_rtp_buffer(intermediate_payload, timestamp, payload_type)

          {actions, new_state} =
            TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)

          new_notifications = extract_notifications(actions)
          {notifications_acc ++ new_notifications, new_state}
        end)

      assert intermediate_notifications == []

      # Send 3 end packet transmissions (RFC 4733 requirement)
      final_duration = 51 * 160
      end_payload = build_telephone_event_payload(event_id, true, volume, final_duration)

      {end1_actions, state1} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(end_payload, timestamp, payload_type),
          nil,
          state_after
        )

      {end2_actions, state2} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(end_payload, timestamp, payload_type),
          nil,
          state1
        )

      {end3_actions, _state3} =
        TelephoneEventParser.handle_buffer(
          :input,
          build_rtp_buffer(end_payload, timestamp, payload_type),
          nil,
          state2
        )

      all_end_notifications =
        extract_notifications(end1_actions) ++
          extract_notifications(end2_actions) ++
          extract_notifications(end3_actions)

      # Exactly one notification despite 3 end packet transmissions
      assert all_end_notifications == [{:dtmf, "0"}],
             "Expected exactly one {:dtmf, \"0\"} notification from 3 end packet transmissions"
    end
  end

  describe "maximum duration handling (T31)" do
    @describetag :t31

    @tag :t31
    test "handles maximum duration value (65535 = 0xFFFF)" do
      # RFC 4733 duration is a 16-bit unsigned integer
      # Maximum value is 65535 (0xFFFF)
      # Parser should handle this without overflow or error

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      event_id = 3
      timestamp = 1000
      volume = 10
      max_duration = 65535

      # Create payload with maximum duration
      end_payload = build_telephone_event_payload(event_id, true, volume, max_duration)

      # Verify the payload is correctly formed with max duration
      <<_event::8, _flags::8, duration_bytes::16>> = end_payload
      assert duration_bytes == 65535, "Duration bytes should be 0xFFFF"

      buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      # Should parse without error and emit correct notification
      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      notifications = extract_notifications(actions)

      assert notifications == [{:dtmf, "3"}],
             "Maximum duration should not affect DTMF detection"
    end

    @tag :t31
    test "correctly parses duration near maximum (65534)" do
      # Test duration just below maximum to ensure no off-by-one issues

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      event_id = 11
      timestamp = 1000
      volume = 10
      near_max_duration = 65534

      end_payload = build_telephone_event_payload(event_id, true, volume, near_max_duration)
      buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      notifications = extract_notifications(actions)

      assert notifications == [{:dtmf, "#"}],
             "Near-maximum duration should parse correctly"
    end

    @tag :t31
    test "handles sequence from zero to maximum duration" do
      # Simulates an impossibly long key press that reaches max duration
      # In practice, max duration at 8kHz represents ~8.19 seconds

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      timestamp = 1000
      event_id = 12
      volume = 10

      # Send a few intermediate packets with large durations leading up to max
      durations = [10000, 30000, 50000, 65000]

      {intermediate_notifications, state_after} =
        Enum.reduce(durations, {[], state}, fn duration, {notifications_acc, current_state} ->
          intermediate_payload = build_telephone_event_payload(event_id, false, volume, duration)
          buffer = build_rtp_buffer(intermediate_payload, timestamp, payload_type)

          {actions, new_state} =
            TelephoneEventParser.handle_buffer(:input, buffer, nil, current_state)

          new_notifications = extract_notifications(actions)
          {notifications_acc ++ new_notifications, new_state}
        end)

      # No notifications from intermediate packets
      assert intermediate_notifications == []

      # Final packet with maximum duration
      max_duration = 65535
      end_payload = build_telephone_event_payload(event_id, true, volume, max_duration)
      end_buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      {end_actions, _final_state} =
        TelephoneEventParser.handle_buffer(:input, end_buffer, nil, state_after)

      end_notifications = extract_notifications(end_actions)

      assert end_notifications == [{:dtmf, "A"}],
             "Maximum duration end packet should emit correct notification for event_id=12 (A)"
    end

    @tag :t31
    test "no integer overflow with maximum duration in binary parsing" do
      # Ensure the binary pattern matching handles 16-bit max correctly
      # This explicitly tests the binary format construction

      event_id = 15
      volume = 63
      max_duration = 65535

      payload = build_telephone_event_payload(event_id, true, volume, max_duration)

      # Verify binary structure
      assert byte_size(payload) == 4, "Payload must be exactly 4 bytes"

      # Parse back and verify values
      <<parsed_event::8, e_bit::1, _r::1, parsed_volume::6, parsed_duration::16>> = payload

      assert parsed_event == 15
      assert e_bit == 1
      assert parsed_volume == 63
      assert parsed_duration == 65535, "Duration should be correctly encoded as 65535"
    end

    @tag :t31
    test "handles various large duration values without errors" do
      # Test several large duration values to ensure robust handling

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      large_durations = [
        32768,
        40000,
        50000,
        60000,
        65000,
        65535
      ]

      for {duration, index} <- Enum.with_index(large_durations) do
        event_id = rem(index, 10)
        timestamp = 1000 + index * 1000

        end_payload = build_telephone_event_payload(event_id, true, 10, duration)
        buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

        # Should not crash or error
        {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

        notifications = extract_notifications(actions)
        expected_digit = Integer.to_string(event_id)

        assert notifications == [{:dtmf, expected_digit}],
               "Duration #{duration} should parse correctly for event_id=#{event_id}"
      end
    end
  end

  describe "payload type filtering (T21)" do
    @describetag :t21

    @tag :t21
    test "only parses packets matching the configured payload_type for DTMF" do
      # Configure parser with payload_type=101 for telephone-event
      # Packets with PT=101 should be parsed for DTMF
      # Packets with other payload types (e.g., PT=0 for PCMU) should be ignored

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Telephone-event packet with PT=101 (matching payload type)
      event_id = 5
      timestamp = 1000
      te_payload = build_telephone_event_payload(event_id, true, 10, 1600)
      te_buffer = build_rtp_buffer(te_payload, timestamp, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, te_buffer, nil, state)

      notifications = extract_notifications(actions)

      assert notifications == [{:dtmf, "5"}],
             "PT=101 (telephone-event) should trigger DTMF detection"
    end

    @tag :t21
    test "ignores packets with different payload types for DTMF detection" do
      # Configure parser with payload_type=101
      # Send a packet with PT=0 (PCMU audio) - should NOT trigger DTMF detection
      # even if the payload happens to look like a valid telephone-event

      payload_type = 101
      pcmu_payload_type = 0

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Create a packet that looks like telephone-event but has wrong payload type
      # (simulating audio data that happens to have similar byte pattern)
      event_id = 5
      timestamp = 1000
      # Use telephone-event format, but mark it as PCMU (PT=0)
      fake_te_payload = build_telephone_event_payload(event_id, true, 10, 1600)
      pcmu_buffer = build_rtp_buffer(fake_te_payload, timestamp, pcmu_payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, pcmu_buffer, nil, state)

      notifications = extract_notifications(actions)

      assert notifications == [],
             "PT=0 (PCMU audio) should NOT trigger DTMF detection, got: #{inspect(notifications)}"
    end

    @tag :t21
    test "no notification emitted for non-matching payload types" do
      # Comprehensive test with multiple non-matching payload types
      payload_type = 101

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Test various payload types that should NOT trigger DTMF
      non_matching_pts = [
        {0, "PCMU"},
        {8, "PCMA"},
        {9, "G722"},
        {96, "dynamic audio"},
        {100, "almost matching but not 101"},
        {102, "close but different"}
      ]

      te_payload = build_telephone_event_payload(7, true, 10, 1600)

      for {pt, description} <- non_matching_pts do
        buffer = build_rtp_buffer(te_payload, 1000 + pt, pt)
        {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

        notifications = extract_notifications(actions)

        assert notifications == [],
               "PT=#{pt} (#{description}) should NOT trigger DTMF detection"
      end
    end

    @tag :t21
    test "only matching payload type triggers detection in mixed stream" do
      # Send a sequence with mixed payload types, verify only PT=101 triggers DTMF
      payload_type = 101

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Mix of packets: audio (PT=0), then telephone-event (PT=101), then more audio (PT=0)
      audio_payload = <<0, 1, 2, 3, 4, 5, 6, 7>>
      te_payload = build_telephone_event_payload(9, true, 10, 1600)

      # Audio packet 1 (PT=0)
      audio_buffer1 = build_rtp_buffer(audio_payload, 1000, 0)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, audio_buffer1, nil, state)

      # Audio packet 2 (PT=0)
      audio_buffer2 = build_rtp_buffer(audio_payload, 1160, 0)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, audio_buffer2, nil, state1)

      # Telephone-event packet (PT=101)
      te_buffer = build_rtp_buffer(te_payload, 2000, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, te_buffer, nil, state2)

      # Audio packet 3 (PT=0)
      audio_buffer3 = build_rtp_buffer(audio_payload, 2160, 0)
      {actions4, _state4} = TelephoneEventParser.handle_buffer(:input, audio_buffer3, nil, state3)

      # Collect all notifications
      all_notifications =
        extract_notifications(actions1) ++
          extract_notifications(actions2) ++
          extract_notifications(actions3) ++
          extract_notifications(actions4)

      # Only the telephone-event packet should trigger DTMF
      assert all_notifications == [{:dtmf, "9"}],
             "Only PT=101 should trigger DTMF, got: #{inspect(all_notifications)}"
    end
  end

  describe "pass-through of non-telephone-event packets (T22)" do
    @describetag :t22

    @tag :t22
    test "ALL packets are passed through to output pad regardless of payload type" do
      # The filter should pass through all packets, not just telephone-event ones
      payload_type = 101

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Audio packet (PT=0) - should pass through
      audio_payload = <<0, 1, 2, 3, 4, 5, 6, 7>>
      audio_buffer = build_rtp_buffer(audio_payload, 1000, 0)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, audio_buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)

      assert length(buffer_actions) == 1,
             "Audio packet should pass through to output"

      [{:buffer, {:output, output_buffer}}] = buffer_actions

      assert output_buffer == audio_buffer,
             "Audio buffer should be unchanged"
    end

    @tag :t22
    test "audio packets (PT=0) flow through untouched" do
      payload_type = 101

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Multiple audio packets
      audio_payloads = [
        <<0xFF, 0x00, 0x7F, 0x80>>,
        <<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08>>,
        <<0xAA, 0xBB, 0xCC, 0xDD>>
      ]

      all_buffer_actions =
        audio_payloads
        |> Enum.with_index()
        |> Enum.flat_map(fn {payload, idx} ->
          buffer = build_rtp_buffer(payload, 1000 + idx * 160, 0)
          {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)
          extract_buffer_actions(actions)
        end)

      assert length(all_buffer_actions) == 3,
             "All 3 audio packets should pass through"

      # Verify payloads are unchanged
      output_payloads =
        all_buffer_actions
        |> Enum.map(fn {:buffer, {:output, buf}} -> buf.payload end)

      assert output_payloads == audio_payloads,
             "Audio payloads should be unchanged"
    end

    @tag :t22
    test "filter doesn't drop or modify any packets in mixed stream" do
      # Configure parser with payload_type=101
      # Send mix of packets: PT=0 (audio), PT=101 (telephone-event)
      # Verify all packets appear at output unchanged
      payload_type = 101

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Create a mixed sequence of packets
      audio_payload_1 = <<0x00, 0x01, 0x02, 0x03>>
      audio_payload_2 = <<0x04, 0x05, 0x06, 0x07>>
      te_payload = build_telephone_event_payload(5, true, 10, 1600)

      # Build the packet sequence
      packets = [
        build_rtp_buffer(audio_payload_1, 1000, 0),
        build_rtp_buffer(audio_payload_2, 1160, 0),
        build_rtp_buffer(te_payload, 2000, payload_type),
        build_rtp_buffer(audio_payload_1, 2160, 0)
      ]

      # Process all packets and collect output buffers
      {all_output_buffers, _final_state} =
        Enum.reduce(packets, {[], state}, fn packet, {acc_buffers, current_state} ->
          {actions, new_state} =
            TelephoneEventParser.handle_buffer(:input, packet, nil, current_state)

          buffer_actions = extract_buffer_actions(actions)
          output_buffers = Enum.map(buffer_actions, fn {:buffer, {:output, buf}} -> buf end)
          {acc_buffers ++ output_buffers, new_state}
        end)

      # All 4 packets should appear at output
      assert length(all_output_buffers) == 4,
             "All 4 packets should pass through, got #{length(all_output_buffers)}"

      # Verify each packet is unchanged
      assert Enum.at(all_output_buffers, 0).payload == audio_payload_1
      assert Enum.at(all_output_buffers, 1).payload == audio_payload_2
      assert Enum.at(all_output_buffers, 2).payload == te_payload
      assert Enum.at(all_output_buffers, 3).payload == audio_payload_1
    end

    @tag :t22
    test "only PT=101 triggers DTMF detection while all packets pass through" do
      # Complete scenario: mixed packets, verify:
      # 1. Only PT=101 triggers DTMF detection
      # 2. All packets (both PT=0 and PT=101) appear at output
      payload_type = 101

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Create packet sequence
      audio_payload = <<0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87>>
      te_payload = build_telephone_event_payload(3, true, 10, 1600)

      packets = [
        {:audio, build_rtp_buffer(audio_payload, 1000, 0)},
        {:audio, build_rtp_buffer(audio_payload, 1160, 0)},
        {:te, build_rtp_buffer(te_payload, 2000, payload_type)},
        {:audio, build_rtp_buffer(audio_payload, 2160, 0)},
        {:audio, build_rtp_buffer(audio_payload, 2320, 0)}
      ]

      # Process and collect both notifications and buffer outputs
      {all_notifications, all_output_buffers, _final_state} =
        Enum.reduce(packets, {[], [], state}, fn {_type, packet},
                                                 {notifs, buffers, current_state} ->
          {actions, new_state} =
            TelephoneEventParser.handle_buffer(:input, packet, nil, current_state)

          new_notifs = extract_notifications(actions)
          buffer_actions = extract_buffer_actions(actions)
          new_buffers = Enum.map(buffer_actions, fn {:buffer, {:output, buf}} -> buf end)

          {notifs ++ new_notifs, buffers ++ new_buffers, new_state}
        end)

      # Verify DTMF detection: only one notification from the telephone-event packet
      assert all_notifications == [{:dtmf, "3"}],
             "Only PT=101 should trigger DTMF, got: #{inspect(all_notifications)}"

      # Verify pass-through: all 5 packets appear at output
      assert length(all_output_buffers) == 5,
             "All 5 packets should pass through, got #{length(all_output_buffers)}"
    end

    @tag :t22
    test "metadata is preserved on pass-through" do
      # Verify that RTP metadata (payload_type, timestamp, sequence_number) is preserved
      payload_type = 101

      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Create buffer with specific metadata
      audio_payload = <<0x00, 0x01, 0x02, 0x03>>

      original_buffer = %Buffer{
        payload: audio_payload,
        pts: 1000,
        metadata: %{
          rtp: %{
            payload_type: 0,
            timestamp: 1000,
            sequence_number: 42
          }
        }
      }

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, original_buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)
      [{:buffer, {:output, output_buffer}}] = buffer_actions

      # Metadata should be completely preserved
      assert output_buffer.metadata == original_buffer.metadata,
             "RTP metadata should be preserved"

      assert output_buffer.metadata.rtp.payload_type == 0
      assert output_buffer.metadata.rtp.timestamp == 1000
      assert output_buffer.metadata.rtp.sequence_number == 42
    end
  end

  # ============================================================================
  # Phase 9: Edge Cases (T39-T40)
  # ============================================================================

  describe "malformed payload - wrong size (T39)" do
    @describetag :t39

    @tag :t39
    test "1-byte payload passes through without crash" do
      # Payloads that are NOT exactly 4 bytes should be handled gracefully
      # - Pass through to output (no crash)
      # - No DTMF notification emitted for malformed payloads
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # 1-byte payload (too short - should be 4 bytes per RFC 4733)
      malformed_payload = <<0x05>>
      buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      # Should not crash - handle gracefully
      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      # Buffer should still flow to output
      buffer_actions = extract_buffer_actions(actions)
      assert length(buffer_actions) == 1, "1-byte malformed buffer should still pass through"

      # No DTMF notification should be emitted for malformed payload
      notifications = extract_notifications(actions)
      assert notifications == [], "1-byte payload should not emit DTMF notification"
    end

    @tag :t39
    test "2-byte payload passes through without crash" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # 2-byte payload (too short)
      malformed_payload = <<0x05, 0x8A>>
      buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)
      assert length(buffer_actions) == 1, "2-byte buffer should pass through"

      notifications = extract_notifications(actions)
      assert notifications == [], "2-byte payload should not emit notification"
    end

    @tag :t39
    test "3-byte payload passes through without crash" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # 3-byte payload (one byte short of valid RFC 4733 payload)
      malformed_payload = <<0x05, 0x8A, 0x06>>
      buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)
      assert length(buffer_actions) == 1, "3-byte buffer should pass through"

      notifications = extract_notifications(actions)
      assert notifications == [], "3-byte payload should not emit notification"
    end

    @tag :t39
    test "5-byte payload (too long) passes through without crash" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # 5-byte payload (one byte too long)
      malformed_payload = <<0x05, 0x8A, 0x06, 0x40, 0xFF>>
      buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)
      assert length(buffer_actions) == 1, "5-byte buffer should pass through"

      notifications = extract_notifications(actions)
      assert notifications == [], "5-byte payload should not emit notification"
    end

    @tag :t39
    test "8-byte payload (double size) passes through without crash" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # 8-byte payload (double the expected size)
      malformed_payload = <<0x05, 0x8A, 0x06, 0x40, 0x05, 0x8A, 0x06, 0x40>>
      buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)
      assert length(buffer_actions) == 1, "8-byte buffer should pass through"

      notifications = extract_notifications(actions)
      assert notifications == [], "8-byte payload should not emit notification"
    end

    @tag :t39
    test "empty payload (0 bytes) passes through without crash" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Empty payload (0 bytes)
      malformed_payload = <<>>
      buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)
      assert length(buffer_actions) == 1, "Empty buffer should pass through"

      notifications = extract_notifications(actions)
      assert notifications == [], "Empty payload should not emit notification"
    end

    @tag :t39
    test "very large payload (100 bytes) passes through without crash" do
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Very large payload (100 bytes)
      malformed_payload = :binary.copy(<<0xFF>>, 100)
      buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, buffer, nil, state)

      buffer_actions = extract_buffer_actions(actions)
      assert length(buffer_actions) == 1, "Large buffer should pass through"

      notifications = extract_notifications(actions)
      assert notifications == [], "Large payload should not emit notification"
    end

    @tag :t39
    test "valid 4-byte payload still works correctly after malformed payloads" do
      # Confirm that processing malformed payloads doesn't break the parser state
      # and valid payloads still work correctly afterward
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # First, process a malformed 2-byte payload
      malformed_payload = <<0x05, 0x8A>>
      malformed_buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)
      {_actions, state} = TelephoneEventParser.handle_buffer(:input, malformed_buffer, nil, state)

      # Then, process a valid 4-byte payload
      valid_payload = build_telephone_event_payload(5, true, 10, 1600)
      assert byte_size(valid_payload) == 4
      valid_buffer = build_rtp_buffer(valid_payload, 2000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, valid_buffer, nil, state)

      notifications = extract_notifications(actions)

      assert notifications == [{:dtmf, "5"}],
             "Valid 4-byte payload should still emit notification after processing malformed payloads"
    end

    @tag :t39
    test "buffer payload is preserved unchanged for malformed payloads" do
      # Verify the original buffer content is passed through unmodified
      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # Malformed 3-byte payload
      malformed_payload = <<0xAB, 0xCD, 0xEF>>
      original_buffer = build_rtp_buffer(malformed_payload, 1000, payload_type)

      {actions, _state} = TelephoneEventParser.handle_buffer(:input, original_buffer, nil, state)

      [{:buffer, {:output, output_buffer}}] = extract_buffer_actions(actions)

      assert output_buffer.payload == malformed_payload,
             "Malformed payload should be passed through unchanged"

      assert output_buffer.pts == original_buffer.pts,
             "Buffer PTS should be preserved"
    end
  end

  describe "missing payload_type config (T40)" do
    @describetag :t40

    @tag :t40
    test "initialization without payload_type option raises KeyError" do
      # Membrane Framework requires all options without defaults to be provided.
      # Missing payload_type should raise KeyError when accessing the key.
      assert_raise KeyError, fn ->
        TelephoneEventParser.handle_init(nil, %{})
      end
    end

    @tag :t40
    test "initialization with empty map raises KeyError" do
      # Empty options map should raise KeyError for missing payload_type
      assert_raise KeyError, fn ->
        TelephoneEventParser.handle_init(nil, %{})
      end
    end

    @tag :t40
    test "initialization with unrelated options but missing payload_type raises KeyError" do
      # Having other options but missing payload_type should still raise
      assert_raise KeyError, fn ->
        TelephoneEventParser.handle_init(nil, %{some_other_option: 42})
      end
    end

    @tag :t40
    test "initialization with nil payload_type raises ArgumentError" do
      # Explicitly passing nil for payload_type should raise ArgumentError
      # because payload_type must be a positive integer
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: nil})
      end
    end

    @tag :t40
    test "initialization with valid payload_type succeeds" do
      # Confirm that valid payload_type works correctly
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: 101})

      assert state.payload_type == 101
      assert state.completed_events == MapSet.new()
      assert state.current_event == nil
    end

    @tag :t40
    test "initialization with various valid payload_type values" do
      # Test various valid payload type values (96-127 dynamic range per RFC 3551)
      for payload_type <- [96, 97, 101, 110, 127] do
        {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})
        assert state.payload_type == payload_type
      end
    end

    @tag :t40
    test "initialization with zero payload_type raises ArgumentError" do
      # Zero is not a valid positive integer
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: 0})
      end
    end

    @tag :t40
    test "initialization with negative payload_type raises ArgumentError" do
      # Negative numbers are not valid
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: -5})
      end
    end

    @tag :t40
    test "initialization with non-integer payload_type raises ArgumentError" do
      # String is not a valid payload_type
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: "101"})
      end

      # Float is not a valid payload_type
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: 101.5})
      end

      # Atom is not a valid payload_type
      assert_raise ArgumentError, ~r/payload_type must be a positive integer/, fn ->
        TelephoneEventParser.handle_init(nil, %{payload_type: :invalid})
      end
    end
  end

  # Helper to extract :notify actions from Membrane action list
  describe "packet loss recovery - missing intermediate packets (T34)" do
    @describetag :t34

    @tag :t34
    test "notification is emitted when intermediate packets are lost but end packet arrives" do
      # Simulates packet loss where intermediate packets are dropped but the
      # final end packet arrives. The parser should still emit the notification
      # because it only needs the end packet to trigger detection.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      event_id = 5
      timestamp = 1000

      # First intermediate packet arrives (duration=160)
      intermediate1 = build_telephone_event_payload(event_id, false, 10, 160)
      buffer1 = build_rtp_buffer(intermediate1, timestamp, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # Packets 2, 3, 4 are LOST (we skip them entirely)
      # They would have had durations 320, 480, 640

      # End packet arrives directly (duration=800, end_bit=1)
      end_payload = build_telephone_event_payload(event_id, true, 10, 800)
      buffer_end = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state1)

      all_notifications = extract_notifications(actions1) ++ extract_notifications(actions_end)

      # Should still emit exactly one notification despite missing intermediate packets
      assert all_notifications == [{:dtmf, "5"}],
             "Expected {:dtmf, \"5\"} notification even with lost intermediate packets, got: #{inspect(all_notifications)}"
    end

    @tag :t34
    test "parser does not require seeing all packets, just the end packet" do
      # The parser doesn't need to see a complete sequence of packets.
      # Even if we only receive the end packet alone, it should work.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      event_id = 8
      timestamp = 2000

      # Only the end packet arrives (all intermediate packets lost)
      end_payload = build_telephone_event_payload(event_id, true, 10, 1600)
      buffer_end = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state)

      notifications = extract_notifications(actions_end)

      # Should emit notification from just the end packet
      assert notifications == [{:dtmf, "8"}],
             "Expected {:dtmf, \"8\"} from end packet alone, got: #{inspect(notifications)}"
    end

    @tag :t34
    test "all buffers pass through even when intermediate packets are lost" do
      # Verify that buffers are passed through regardless of packet loss scenarios

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      event_id = 3
      timestamp = 1000

      # First intermediate arrives
      intermediate1 = build_telephone_event_payload(event_id, false, 10, 160)
      buffer1 = build_rtp_buffer(intermediate1, timestamp, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # (packets 2-4 lost)

      # End packet arrives
      end_payload = build_telephone_event_payload(event_id, true, 10, 800)
      buffer_end = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state1)

      # Both received buffers should be passed through
      buffer_actions1 = extract_buffer_actions(actions1)
      buffer_actions_end = extract_buffer_actions(actions_end)

      assert length(buffer_actions1) == 1, "First buffer should be passed through"
      assert length(buffer_actions_end) == 1, "End buffer should be passed through"
    end
  end

  describe "packet loss recovery - lost end packets (T35)" do
    @describetag :t35

    @tag :t35
    test "no notification is emitted when end packet is lost" do
      # If the end packet is never received for an event, no notification should
      # be emitted for that event.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      event_id = 5
      timestamp = 1000

      # Intermediate packets arrive but end packet is lost
      intermediate1 = build_telephone_event_payload(event_id, false, 10, 160)
      buffer1 = build_rtp_buffer(intermediate1, timestamp, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      intermediate2 = build_telephone_event_payload(event_id, false, 10, 320)
      buffer2 = build_rtp_buffer(intermediate2, timestamp, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      intermediate3 = build_telephone_event_payload(event_id, false, 10, 480)
      buffer3 = build_rtp_buffer(intermediate3, timestamp, payload_type)
      {actions3, _state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)

      # End packet is LOST - we never receive it

      all_notifications =
        extract_notifications(actions1) ++
          extract_notifications(actions2) ++
          extract_notifications(actions3)

      # No notifications should be emitted since end packet was lost
      assert all_notifications == [],
             "Expected no notifications when end packet is lost, got: #{inspect(all_notifications)}"
    end

    @tag :t35
    test "new event with different timestamp resets state implicitly" do
      # When a new event starts (different timestamp), the parser should track
      # the new event correctly. The old incomplete event is simply abandoned.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # First event: digit "5" at timestamp 1000
      # End packet is LOST
      event_id_1 = 5
      timestamp_1 = 1000

      intermediate1 = build_telephone_event_payload(event_id_1, false, 10, 160)
      buffer1 = build_rtp_buffer(intermediate1, timestamp_1, payload_type)
      {actions1, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      intermediate2 = build_telephone_event_payload(event_id_1, false, 10, 320)
      buffer2 = build_rtp_buffer(intermediate2, timestamp_1, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      # End packet for event 1 is LOST

      # Second event: digit "7" at timestamp 2000 (different timestamp)
      event_id_2 = 7
      timestamp_2 = 2000

      intermediate3 = build_telephone_event_payload(event_id_2, false, 10, 160)
      buffer3 = build_rtp_buffer(intermediate3, timestamp_2, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)

      # End packet arrives for second event
      end_payload = build_telephone_event_payload(event_id_2, true, 10, 800)
      buffer_end = build_rtp_buffer(end_payload, timestamp_2, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state3)

      all_notifications =
        extract_notifications(actions1) ++
          extract_notifications(actions2) ++
          extract_notifications(actions3) ++
          extract_notifications(actions_end)

      # Should only receive notification for the second event (digit "7")
      # First event's notification is lost since its end packet was lost
      assert all_notifications == [{:dtmf, "7"}],
             "Expected only {:dtmf, \"7\"} for the completed second event, got: #{inspect(all_notifications)}"
    end

    @tag :t35
    test "new event is tracked correctly after previous event's end packet was lost" do
      # Verify that the new event tracking is independent of the abandoned event

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # First event (incomplete - end packet lost)
      intermediate1 = build_telephone_event_payload(3, false, 10, 160)
      buffer1 = build_rtp_buffer(intermediate1, 1000, payload_type)
      {_, state1} = TelephoneEventParser.handle_buffer(:input, buffer1, nil, state)

      # Second event at different timestamp - full sequence
      event_id_2 = 9
      timestamp_2 = 3000

      # Intermediate for second event
      intermediate2 = build_telephone_event_payload(event_id_2, false, 10, 160)
      buffer2 = build_rtp_buffer(intermediate2, timestamp_2, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state1)

      intermediate3 = build_telephone_event_payload(event_id_2, false, 10, 320)
      buffer3 = build_rtp_buffer(intermediate3, timestamp_2, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)

      # End packet for second event
      end_payload = build_telephone_event_payload(event_id_2, true, 10, 640)
      buffer_end = build_rtp_buffer(end_payload, timestamp_2, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state3)

      all_notifications =
        extract_notifications(actions2) ++
          extract_notifications(actions3) ++
          extract_notifications(actions_end)

      # Second event should complete normally
      assert all_notifications == [{:dtmf, "9"}],
             "Expected {:dtmf, \"9\"} for the second event, got: #{inspect(all_notifications)}"
    end
  end

  describe "packet loss recovery - lost first packet (T36)" do
    @describetag :t36

    @tag :t36
    test "tracking starts from first received packet when initial packets are lost" do
      # If the first packet(s) of an event are lost, tracking should start
      # from the first packet we actually receive.

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      event_id = 5
      timestamp = 1000

      # First two packets are LOST (durations 160, 320)
      # We start receiving at duration 480

      # Third packet is first we receive
      intermediate3 = build_telephone_event_payload(event_id, false, 10, 480)
      buffer3 = build_rtp_buffer(intermediate3, timestamp, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state)

      intermediate4 = build_telephone_event_payload(event_id, false, 10, 640)
      buffer4 = build_rtp_buffer(intermediate4, timestamp, payload_type)
      {actions4, state4} = TelephoneEventParser.handle_buffer(:input, buffer4, nil, state3)

      # End packet arrives
      end_payload = build_telephone_event_payload(event_id, true, 10, 800)
      buffer_end = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state4)

      all_notifications =
        extract_notifications(actions3) ++
          extract_notifications(actions4) ++
          extract_notifications(actions_end)

      # Should still emit notification - starting mid-event is fine
      assert all_notifications == [{:dtmf, "5"}],
             "Expected {:dtmf, \"5\"} even when first packets were lost, got: #{inspect(all_notifications)}"
    end

    @tag :t36
    test "parser handles receiving only end packet when all others lost" do
      # Extreme case: all packets except end packet are lost
      # Parser should still work with just the end packet

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # "#" symbol
      event_id = 11
      timestamp = 5000

      # ALL intermediate packets lost - only end packet received
      end_payload = build_telephone_event_payload(event_id, true, 10, 3200)
      buffer_end = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state)

      notifications = extract_notifications(actions_end)

      assert notifications == [{:dtmf, "#"}],
             "Expected {:dtmf, \"#\"} from just end packet, got: #{inspect(notifications)}"
    end

    @tag :t36
    test "subsequent packets after joining mid-event work correctly" do
      # Verify that once we start tracking an event mid-stream,
      # subsequent packets are handled correctly

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # "A"
      event_id = 12
      timestamp = 1000

      # First packet lost, start at second
      intermediate2 = build_telephone_event_payload(event_id, false, 10, 320)
      buffer2 = build_rtp_buffer(intermediate2, timestamp, payload_type)
      {actions2, state2} = TelephoneEventParser.handle_buffer(:input, buffer2, nil, state)

      # Third packet
      intermediate3 = build_telephone_event_payload(event_id, false, 10, 480)
      buffer3 = build_rtp_buffer(intermediate3, timestamp, payload_type)
      {actions3, state3} = TelephoneEventParser.handle_buffer(:input, buffer3, nil, state2)

      # Fourth packet
      intermediate4 = build_telephone_event_payload(event_id, false, 10, 640)
      buffer4 = build_rtp_buffer(intermediate4, timestamp, payload_type)
      {actions4, state4} = TelephoneEventParser.handle_buffer(:input, buffer4, nil, state3)

      # Fifth packet
      intermediate5 = build_telephone_event_payload(event_id, false, 10, 800)
      buffer5 = build_rtp_buffer(intermediate5, timestamp, payload_type)
      {actions5, state5} = TelephoneEventParser.handle_buffer(:input, buffer5, nil, state4)

      # End packet
      end_payload = build_telephone_event_payload(event_id, true, 10, 960)
      buffer_end = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state5)

      all_notifications =
        extract_notifications(actions2) ++
          extract_notifications(actions3) ++
          extract_notifications(actions4) ++
          extract_notifications(actions5) ++
          extract_notifications(actions_end)

      # All intermediate packets should produce no notifications
      # Only end packet should trigger the notification
      assert all_notifications == [{:dtmf, "A"}],
             "Expected exactly one {:dtmf, \"A\"} notification, got: #{inspect(all_notifications)}"

      # Verify all buffers were passed through (5 total)
      all_buffer_count =
        [actions2, actions3, actions4, actions5, actions_end]
        |> Enum.flat_map(&extract_buffer_actions/1)
        |> length()

      assert all_buffer_count == 5, "All 5 buffers should be passed through"
    end

    @tag :t36
    test "parser doesn't get confused by starting mid-event with high duration" do
      # Verify parser handles the case where the first packet we see
      # already has a high duration value (indicating we missed earlier packets)

      payload_type = 101
      {[], state} = TelephoneEventParser.handle_init(nil, %{payload_type: payload_type})

      stream_format = %Membrane.RTP{}

      {[stream_format: {:output, _}], state} =
        TelephoneEventParser.handle_stream_format(:input, stream_format, nil, state)

      # "0"
      event_id = 0
      timestamp = 8000

      # First packet we receive has high duration (many packets lost)
      # Duration=3200 means ~400ms into the event already
      intermediate_late = build_telephone_event_payload(event_id, false, 10, 3200)
      buffer_late = build_rtp_buffer(intermediate_late, timestamp, payload_type)
      {actions_late, state_late} = TelephoneEventParser.handle_buffer(:input, buffer_late, nil, state)

      # A few more packets
      intermediate_later = build_telephone_event_payload(event_id, false, 10, 3360)
      buffer_later = build_rtp_buffer(intermediate_later, timestamp, payload_type)

      {actions_later, state_later} =
        TelephoneEventParser.handle_buffer(:input, buffer_later, nil, state_late)

      # End packet
      end_payload = build_telephone_event_payload(event_id, true, 10, 3520)
      buffer_end = build_rtp_buffer(end_payload, timestamp, payload_type)
      {actions_end, _state_end} = TelephoneEventParser.handle_buffer(:input, buffer_end, nil, state_later)

      all_notifications =
        extract_notifications(actions_late) ++
          extract_notifications(actions_later) ++
          extract_notifications(actions_end)

      # Should work correctly regardless of initial duration value
      assert all_notifications == [{:dtmf, "0"}],
             "Expected {:dtmf, \"0\"} even with high initial duration, got: #{inspect(all_notifications)}"
    end
  end
  defp extract_notifications(actions) do
    actions
    |> Enum.filter(fn
      {:notify_parent, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:notify_parent, notification} -> notification end)
  end

  # Helper to extract :buffer actions from Membrane action list
  defp extract_buffer_actions(actions) do
    Enum.filter(actions, fn
      {:buffer, {:output, _}} -> true
      _ -> false
    end)
  end
end
