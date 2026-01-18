defmodule ParrotMedia.Elements.TelephoneEventParserIntegrationTest do
  @moduledoc """
  Integration tests for TelephoneEventParser using Membrane.Testing.Pipeline.

  Tests RFC 2833/4733 telephone-event parsing in a real pipeline context,
  verifying that {:dtmf, digit} notifications are sent to the parent.
  """
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.RTP
  alias Membrane.Testing.Pipeline
  alias ParrotMedia.Elements.TelephoneEventParser

  @moduletag :t43

  # RFC 4733 telephone-event payload format:
  # - event (8 bits): DTMF digit (0-9, 10=*, 11=#, 12-15=A-D)
  # - end_bit (1 bit): Set on final packet of event
  # - reserved (1 bit): Always 0
  # - volume (6 bits): Power level (0-63)
  # - duration (16 bits): Event duration in timestamp units

  defp build_telephone_event_payload(event_id, end_bit, volume, duration) do
    e_bit = if end_bit, do: 1, else: 0
    reserved = 0
    <<event_id::8, e_bit::1, reserved::1, volume::6, duration::16>>
  end

  defp build_rtp_buffer(payload, timestamp, payload_type) do
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

  describe "pipeline integration (T43)" do
    @describetag :t43

    @tag :t43
    test "receives {:dtmf, digit} notifications for single digit with end_bit=1" do
      # Single digit "5" with end_bit=1 should trigger notification
      payload_type = 101
      timestamp = 1000

      end_payload = build_telephone_event_payload(5, true, 10, 160)
      buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: [buffer],
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Verify we receive the DTMF notification
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "5"})

      # Verify buffer passes through
      assert_sink_buffer(pipeline, :sink, %Buffer{})

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "realistic sequence: digits 1, 2, 3, # with intermediate and end packets" do
      # Simulates pressing digits "1", "2", "3", "#" in sequence
      # Each digit has intermediate packets (end_bit=0) followed by end packets (end_bit=1)
      payload_type = 101
      volume = 10

      # Digit "1" - event_id=1, starts at timestamp 1000
      # 3 intermediate packets + 1 end packet
      digit_1_buffers = [
        build_rtp_buffer(build_telephone_event_payload(1, false, volume, 160), 1000, payload_type),
        build_rtp_buffer(build_telephone_event_payload(1, false, volume, 320), 1000, payload_type),
        build_rtp_buffer(build_telephone_event_payload(1, false, volume, 480), 1000, payload_type),
        build_rtp_buffer(build_telephone_event_payload(1, true, volume, 640), 1000, payload_type)
      ]

      # Digit "2" - event_id=2, starts at timestamp 2000
      digit_2_buffers = [
        build_rtp_buffer(build_telephone_event_payload(2, false, volume, 160), 2000, payload_type),
        build_rtp_buffer(build_telephone_event_payload(2, false, volume, 320), 2000, payload_type),
        build_rtp_buffer(build_telephone_event_payload(2, true, volume, 480), 2000, payload_type)
      ]

      # Digit "3" - event_id=3, starts at timestamp 3000
      digit_3_buffers = [
        build_rtp_buffer(build_telephone_event_payload(3, false, volume, 160), 3000, payload_type),
        build_rtp_buffer(build_telephone_event_payload(3, true, volume, 320), 3000, payload_type)
      ]

      # Digit "#" - event_id=11, starts at timestamp 4000
      digit_hash_buffers = [
        build_rtp_buffer(
          build_telephone_event_payload(11, false, volume, 160),
          4000,
          payload_type
        ),
        build_rtp_buffer(
          build_telephone_event_payload(11, false, volume, 320),
          4000,
          payload_type
        ),
        build_rtp_buffer(
          build_telephone_event_payload(11, false, volume, 480),
          4000,
          payload_type
        ),
        build_rtp_buffer(build_telephone_event_payload(11, true, volume, 640), 4000, payload_type)
      ]

      all_buffers =
        digit_1_buffers ++ digit_2_buffers ++ digit_3_buffers ++ digit_hash_buffers

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: all_buffers,
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Verify we receive exactly 4 DTMF notifications in order
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "1"})
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "2"})
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "3"})
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "#"})

      # Verify all 13 buffers pass through
      for _i <- 1..13 do
        assert_sink_buffer(pipeline, :sink, %Buffer{})
      end

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "intermediate packets (end_bit=0) do not trigger notifications" do
      # Only end packets should trigger notifications
      payload_type = 101
      timestamp = 1000

      # 3 intermediate packets only (no end packet)
      intermediate_buffers = [
        build_rtp_buffer(build_telephone_event_payload(5, false, 10, 160), timestamp, payload_type),
        build_rtp_buffer(build_telephone_event_payload(5, false, 10, 320), timestamp, payload_type),
        build_rtp_buffer(build_telephone_event_payload(5, false, 10, 480), timestamp, payload_type)
      ]

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: intermediate_buffers,
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Buffers should pass through
      for _i <- 1..3 do
        assert_sink_buffer(pipeline, :sink, %Buffer{})
      end

      # Wait for end of stream to ensure no notifications were sent
      assert_end_of_stream(pipeline, :sink)

      # No DTMF notifications should have been sent
      # (if one was sent, this refute would catch it after the timeout)
      refute_receive({:pipeline_notified, :parser, {:dtmf, _}}, 100)

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "RFC 4733 end packet retransmissions emit only one notification" do
      # RFC 4733 Section 2.5.1.4 specifies end packets should be sent 3 times
      # We should only emit ONE notification, not three
      payload_type = 101
      timestamp = 1000

      # Same end packet sent 3 times (retransmissions)
      end_payload = build_telephone_event_payload(7, true, 10, 1600)

      retransmitted_buffers = [
        build_rtp_buffer(end_payload, timestamp, payload_type),
        build_rtp_buffer(end_payload, timestamp, payload_type),
        build_rtp_buffer(end_payload, timestamp, payload_type)
      ]

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: retransmitted_buffers,
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Should receive exactly ONE notification despite 3 end packets
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "7"})

      # All 3 buffers should still pass through
      for _i <- 1..3 do
        assert_sink_buffer(pipeline, :sink, %Buffer{})
      end

      # Wait for end of stream
      assert_end_of_stream(pipeline, :sink)

      # No additional DTMF notification should have been sent
      refute_receive({:pipeline_notified, :parser, {:dtmf, _}}, 100)

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "buffers pass through unchanged to sink" do
      payload_type = 101
      timestamp = 1000
      original_payload = build_telephone_event_payload(9, true, 10, 1600)

      buffer = build_rtp_buffer(original_payload, timestamp, payload_type)

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: [buffer],
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Verify buffer content is preserved
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: ^original_payload, pts: ^timestamp})

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "non-matching payload types do not trigger DTMF notifications" do
      # Configure parser for payload_type=101, but send PT=0 (audio)
      parser_payload_type = 101
      audio_payload_type = 0
      timestamp = 1000

      # This looks like a telephone-event but has wrong payload type
      te_payload = build_telephone_event_payload(5, true, 10, 1600)
      audio_buffer = build_rtp_buffer(te_payload, timestamp, audio_payload_type)

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: [audio_buffer],
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: parser_payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Buffer should still pass through
      assert_sink_buffer(pipeline, :sink, %Buffer{})

      # Wait for end of stream
      assert_end_of_stream(pipeline, :sink)

      # No DTMF notification should have been sent
      refute_receive({:pipeline_notified, :parser, {:dtmf, _}}, 100)

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "mixed stream with audio and telephone-event packets" do
      parser_payload_type = 101
      audio_payload_type = 0

      # Audio packet
      audio_payload = <<0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87>>
      audio_buffer = build_rtp_buffer(audio_payload, 1000, audio_payload_type)

      # Telephone-event packet
      te_payload = build_telephone_event_payload(3, true, 10, 1600)
      te_buffer = build_rtp_buffer(te_payload, 2000, parser_payload_type)

      # Another audio packet
      audio_buffer2 = build_rtp_buffer(audio_payload, 3000, audio_payload_type)

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: [audio_buffer, te_buffer, audio_buffer2],
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: parser_payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Should receive exactly one DTMF notification
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "3"})

      # All 3 buffers should pass through
      for _i <- 1..3 do
        assert_sink_buffer(pipeline, :sink, %Buffer{})
      end

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "all DTMF digits are correctly detected in sequence" do
      # Test all 16 DTMF digits: 0-9, *, #, A-D
      payload_type = 101
      volume = 10

      digits_with_event_ids = [
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

      # Build buffers for each digit (just end packets)
      buffers =
        digits_with_event_ids
        |> Enum.with_index()
        |> Enum.map(fn {{event_id, _digit}, idx} ->
          timestamp = 1000 + idx * 1000
          payload = build_telephone_event_payload(event_id, true, volume, 1600)
          build_rtp_buffer(payload, timestamp, payload_type)
        end)

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: buffers,
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Verify we receive all 16 DTMF notifications in order
      for {_event_id, expected_digit} <- digits_with_event_ids do
        assert_pipeline_notified(pipeline, :parser, {:dtmf, ^expected_digit})
      end

      Pipeline.terminate(pipeline)
    end

    @tag :t43
    test "long key press with many intermediate packets" do
      # Simulates holding a key for extended duration (40 intermediate packets)
      payload_type = 101
      timestamp = 1000
      event_id = 5
      volume = 10

      # 40 intermediate packets with increasing duration
      intermediate_buffers =
        for i <- 1..40 do
          duration = i * 160
          payload = build_telephone_event_payload(event_id, false, volume, duration)
          build_rtp_buffer(payload, timestamp, payload_type)
        end

      # Final end packet
      end_payload = build_telephone_event_payload(event_id, true, volume, 41 * 160)
      end_buffer = build_rtp_buffer(end_payload, timestamp, payload_type)

      all_buffers = intermediate_buffers ++ [end_buffer]

      pipeline =
        Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Membrane.Testing.Source{
              output: all_buffers,
              stream_format: %RTP{}
            })
            |> child(:parser, %TelephoneEventParser{
              payload_type: payload_type
            })
            |> child(:sink, Membrane.Testing.Sink)
          ]
        )

      # Should receive exactly ONE notification after all packets
      assert_pipeline_notified(pipeline, :parser, {:dtmf, "5"})

      # All 41 buffers should pass through
      for _i <- 1..41 do
        assert_sink_buffer(pipeline, :sink, %Buffer{})
      end

      # Wait for end of stream
      assert_end_of_stream(pipeline, :sink)

      # No additional notifications
      refute_receive({:pipeline_notified, :parser, {:dtmf, _}}, 100)

      Pipeline.terminate(pipeline)
    end
  end
end
