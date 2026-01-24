defmodule ParrotMedia.DTMFRTPIntegrationTest do
  @moduledoc """
  End-to-end integration tests for RFC 4733 DTMF detection.

  These tests verify that DTMF digits sent via RTP telephone-event packets
  are correctly detected by the MediaSession pipeline with TelephoneEventParser.

  Unlike SIPp-based tests (which require raw socket access), these tests
  send RFC 4733 packets via regular UDP sockets, making them portable
  across all platforms including macOS.

  ## Why this test exists

  SIPp's `play_dtmf` command requires raw socket access which:
  - Needs root/sudo on Linux
  - Is blocked by System Integrity Protection on macOS even with sudo
  - See: https://github.com/SIPp/sipp/issues/368

  This test provides reliable DTMF detection verification without those limitations.
  """
  use ExUnit.Case, async: false
  @moduletag :slow

  require Logger

  alias ParrotMedia.MediaSession

  @moduletag :dtmf_rtp

  # RFC 4733 telephone-event payload format:
  # - event (8 bits): DTMF digit (0-9=0-9, 10=*, 11=#, 12-15=A-D)
  # - end_bit (1 bit): Set on final packet of event
  # - reserved (1 bit): Always 0
  # - volume (6 bits): Power level (0-63, where 0 is 0 dBm0)
  # - duration (16 bits): Event duration in timestamp units

  @doc """
  Builds an RFC 4733 telephone-event payload.

  ## Parameters
    - event_id: DTMF digit (0-9 for digits, 10=*, 11=#, 12-15=A-D)
    - end_bit: true if this is the final packet for this event
    - volume: Power level (default 10)
    - duration: Duration in timestamp units (default 160 = 20ms @ 8kHz)
  """
  def build_telephone_event_payload(event_id, end_bit, volume \\ 10, duration \\ 160) do
    e_bit = if end_bit, do: 1, else: 0
    reserved = 0
    <<event_id::8, e_bit::1, reserved::1, volume::6, duration::16>>
  end

  @doc """
  Builds an RTP packet with telephone-event payload.

  Uses standard RTP header format per RFC 3550:
  - Version: 2
  - Padding: 0
  - Extension: 0
  - CSRC count: 0
  - Marker: 1 for first packet, 0 for subsequent
  - Payload type: As specified (typically 96-127 for dynamic types)
  - Sequence number: For ordering
  - Timestamp: RTP timestamp
  - SSRC: Synchronization source identifier
  """
  def build_rtp_packet(payload, opts) do
    version = 2
    padding = 0
    extension = 0
    csrc_count = 0
    marker = Keyword.get(opts, :marker, 0)
    payload_type = Keyword.fetch!(opts, :payload_type)
    sequence_number = Keyword.fetch!(opts, :sequence_number)
    timestamp = Keyword.fetch!(opts, :timestamp)
    ssrc = Keyword.get(opts, :ssrc, 0x12345678)

    <<version::2, padding::1, extension::1, csrc_count::4, marker::1, payload_type::7,
      sequence_number::16, timestamp::32, ssrc::32, payload::binary>>
  end

  @doc """
  Sends a sequence of RFC 4733 DTMF packets for a single digit.

  Per RFC 4733, a digit press consists of:
  1. Multiple packets with end_bit=0 (intermediate)
  2. Final packet(s) with end_bit=1 (typically sent 3 times for reliability)
  """
  def send_dtmf_digit(socket, dest_ip, dest_port, event_id, opts) do
    payload_type = Keyword.fetch!(opts, :payload_type)
    base_timestamp = Keyword.fetch!(opts, :timestamp)
    start_seq = Keyword.get(opts, :start_sequence, 1000)
    ssrc = Keyword.get(opts, :ssrc, 0x12345678)
    volume = Keyword.get(opts, :volume, 10)
    # Duration per packet in timestamp units (20ms = 160 samples @ 8kHz)
    packet_duration = 160
    # Number of intermediate packets before end
    intermediate_count = Keyword.get(opts, :intermediate_packets, 3)

    # Send intermediate packets (end_bit=0)
    Enum.each(0..(intermediate_count - 1), fn i ->
      duration = (i + 1) * packet_duration
      payload = build_telephone_event_payload(event_id, false, volume, duration)

      rtp_packet =
        build_rtp_packet(payload,
          payload_type: payload_type,
          sequence_number: start_seq + i,
          timestamp: base_timestamp,
          ssrc: ssrc,
          # Marker bit on first packet of event
          marker: if(i == 0, do: 1, else: 0)
        )

      :ok = :gen_udp.send(socket, dest_ip, dest_port, rtp_packet)
      # Small delay between packets (20ms typical)
      Process.sleep(20)
    end)

    # Send end packets (end_bit=1) - RFC 4733 recommends 3 retransmissions
    final_duration = (intermediate_count + 1) * packet_duration
    final_payload = build_telephone_event_payload(event_id, true, volume, final_duration)

    Enum.each(0..2, fn i ->
      rtp_packet =
        build_rtp_packet(final_payload,
          payload_type: payload_type,
          sequence_number: start_seq + intermediate_count + i,
          timestamp: base_timestamp,
          ssrc: ssrc,
          marker: 0
        )

      :ok = :gen_udp.send(socket, dest_ip, dest_port, rtp_packet)
      Process.sleep(20)
    end)

    # Return the next sequence number to use
    start_seq + intermediate_count + 3
  end

  @doc """
  Maps a digit character to RFC 4733 event ID.
  """
  def digit_to_event_id(digit) when digit in ~c"0123456789" do
    digit - ?0
  end

  def digit_to_event_id(?*), do: 10
  def digit_to_event_id(?#), do: 11
  def digit_to_event_id(?A), do: 12
  def digit_to_event_id(?B), do: 13
  def digit_to_event_id(?C), do: 14
  def digit_to_event_id(?D), do: 15

  # Extract local RTP port from SDP answer
  defp extract_port_from_sdp(sdp) do
    case Regex.run(~r/m=audio (\d+)/, sdp) do
      [_, port_str] -> String.to_integer(port_str)
      nil -> nil
    end
  end

  # Extract telephone-event payload type from SDP
  defp extract_telephone_event_pt(sdp) do
    case Regex.run(~r/a=rtpmap:(\d+) telephone-event/, sdp) do
      [_, pt_str] -> String.to_integer(pt_str)
      nil -> 101
    end
  end

  describe "RFC 4733 DTMF over RTP detection" do
    @tag timeout: 30_000
    test "detects single DTMF digit via RTP telephone-event" do
      # Create a test handler that collects DTMF and notifies us
      test_pid = self()

      handler_module = __MODULE__.TestMediaHandler
      Code.ensure_loaded!(handler_module)

      # Start MediaSession
      session_id = "dtmf_test_#{:erlang.unique_integer([:positive])}"

      {:ok, media_pid} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_#{session_id}",
          role: :uas,
          media_handler: handler_module,
          handler_args: %{test_pid: test_pid},
          audio_source: :silence,
          audio_sink: :none,
          supported_codecs: [:pcma],
          notify_pid: test_pid
        )

      # Create SDP offer with telephone-event support
      # Use payload type 96 for telephone-event (dynamic range 96-127)
      sdp_offer = """
      v=0
      o=test 123456 123456 IN IP4 127.0.0.1
      s=DTMF Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8 96
      a=rtpmap:8 PCMA/8000
      a=rtpmap:96 telephone-event/8000
      a=fmtp:96 0-15
      a=sendrecv
      """

      # Process offer and get answer
      {:ok, sdp_answer} = MediaSession.process_offer(media_pid, sdp_offer)

      # Extract local RTP port from answer
      local_rtp_port = extract_port_from_sdp(sdp_answer)
      assert local_rtp_port != nil, "Could not extract RTP port from SDP answer"

      # Extract telephone-event payload type (should match offer)
      te_pt = extract_telephone_event_pt(sdp_answer)
      Logger.debug("DTMF test: Local RTP port=#{local_rtp_port}, telephone-event PT=#{te_pt}")

      # Start media
      :ok = MediaSession.start_media(media_pid)

      # Start DTMF collection
      send(media_pid, {:collect_dtmf, max: 5, terminators: [], timeout: 10_000})

      # Wait for pipeline to initialize
      Process.sleep(500)

      # Open UDP socket to send DTMF packets
      {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Send DTMF digit "5" (event_id = 5)
      _next_seq =
        send_dtmf_digit(send_socket, {127, 0, 0, 1}, local_rtp_port, 5,
          payload_type: te_pt,
          timestamp: 1000,
          start_sequence: 1000
        )

      :gen_udp.close(send_socket)

      # Wait for DTMF detection
      # The handler should receive the DTMF and notify us
      receive do
        {:media_event, ^session_id, {:dtmf_collected, digits}} ->
          assert String.contains?(digits, "5"),
                 "Expected digit '5' in collected digits, got: #{inspect(digits)}"

        {:media_event, ^session_id, {:dtmf_timeout, partial}} ->
          # Timeout is acceptable if we got partial digits
          if partial != "" do
            assert String.contains?(partial, "5"),
                   "Expected digit '5' in partial digits, got: #{inspect(partial)}"
          else
            flunk("DTMF collection timed out with no digits")
          end
      after
        10_000 ->
          flunk("Did not receive DTMF notification within 10 seconds")
      end

      # Cleanup
      GenServer.stop(media_pid, :normal)
    end

    @tag timeout: 30_000
    test "detects DTMF sequence '123#' via RTP telephone-event" do
      test_pid = self()

      handler_module = __MODULE__.TestMediaHandler
      session_id = "dtmf_seq_#{:erlang.unique_integer([:positive])}"

      {:ok, media_pid} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_#{session_id}",
          role: :uas,
          media_handler: handler_module,
          handler_args: %{test_pid: test_pid},
          audio_source: :silence,
          audio_sink: :none,
          supported_codecs: [:pcma],
          notify_pid: test_pid
        )

      sdp_offer = """
      v=0
      o=test 123456 123456 IN IP4 127.0.0.1
      s=DTMF Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8 96
      a=rtpmap:8 PCMA/8000
      a=rtpmap:96 telephone-event/8000
      a=fmtp:96 0-15
      a=sendrecv
      """

      {:ok, sdp_answer} = MediaSession.process_offer(media_pid, sdp_offer)
      local_rtp_port = extract_port_from_sdp(sdp_answer)
      te_pt = extract_telephone_event_pt(sdp_answer)

      :ok = MediaSession.start_media(media_pid)

      # Collect up to 4 digits with '#' as terminator
      send(media_pid, {:collect_dtmf, max: 10, terminators: [?#], timeout: 15_000})

      Process.sleep(500)

      {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Send "123#" - each digit has different timestamp
      digits_to_send = ~c"123#"
      base_timestamp = 1000
      timestamp_increment = 2000

      Enum.reduce(digits_to_send, {1000, base_timestamp}, fn digit, {seq, ts} ->
        event_id = digit_to_event_id(digit)

        next_seq =
          send_dtmf_digit(send_socket, {127, 0, 0, 1}, local_rtp_port, event_id,
            payload_type: te_pt,
            timestamp: ts,
            start_sequence: seq
          )

        # Gap between digits
        Process.sleep(100)
        {next_seq, ts + timestamp_increment}
      end)

      :gen_udp.close(send_socket)

      # Wait for DTMF collection to complete (should terminate on '#')
      receive do
        {:media_event, ^session_id, {:dtmf_collected, digits}} ->
          # Should have collected "123#" or at least "123" before '#' terminator
          assert digits == "123#" or digits == "123",
                 "Expected '123#' or '123', got: #{inspect(digits)}"

        {:media_event, ^session_id, {:dtmf_timeout, partial}} ->
          # Acceptable if we got partial
          assert partial != "", "DTMF collection timed out with no digits, got: #{partial}"
      after
        15_000 ->
          flunk("Did not receive DTMF notification within 15 seconds")
      end

      GenServer.stop(media_pid, :normal)
    end

    @tag timeout: 30_000
    test "handles different payload types from SDP negotiation" do
      # Test that we correctly handle PT=101 (common alternative to 96)
      test_pid = self()

      handler_module = __MODULE__.TestMediaHandler
      session_id = "dtmf_pt101_#{:erlang.unique_integer([:positive])}"

      {:ok, media_pid} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog_#{session_id}",
          role: :uas,
          media_handler: handler_module,
          handler_args: %{test_pid: test_pid},
          audio_source: :silence,
          audio_sink: :none,
          supported_codecs: [:pcma],
          notify_pid: test_pid
        )

      # Use PT=101 for telephone-event (another common value)
      sdp_offer = """
      v=0
      o=test 123456 123456 IN IP4 127.0.0.1
      s=DTMF Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8 101
      a=rtpmap:8 PCMA/8000
      a=rtpmap:101 telephone-event/8000
      a=fmtp:101 0-15
      a=sendrecv
      """

      {:ok, sdp_answer} = MediaSession.process_offer(media_pid, sdp_offer)
      local_rtp_port = extract_port_from_sdp(sdp_answer)
      te_pt = extract_telephone_event_pt(sdp_answer)

      # Verify the negotiated PT is 101
      assert te_pt == 101, "Expected telephone-event PT=101, got: #{te_pt}"

      :ok = MediaSession.start_media(media_pid)
      send(media_pid, {:collect_dtmf, max: 5, terminators: [], timeout: 10_000})
      Process.sleep(500)

      {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])

      # Send digit "9" using PT=101
      _next_seq =
        send_dtmf_digit(send_socket, {127, 0, 0, 1}, local_rtp_port, 9,
          payload_type: 101,
          timestamp: 1000,
          start_sequence: 1000
        )

      :gen_udp.close(send_socket)

      receive do
        {:media_event, ^session_id, {:dtmf_collected, digits}} ->
          assert String.contains?(digits, "9"), "Expected digit '9', got: #{inspect(digits)}"

        {:media_event, ^session_id, {:dtmf_timeout, partial}} ->
          if partial != "" do
            assert String.contains?(partial, "9"), "Expected '9' in partial: #{partial}"
          else
            flunk("DTMF collection timed out with no digits")
          end
      after
        10_000 ->
          flunk("Did not receive DTMF notification")
      end

      GenServer.stop(media_pid, :normal)
    end
  end
end

# Simple test media handler for DTMF tests
defmodule ParrotMedia.DTMFRTPIntegrationTest.TestMediaHandler do
  @moduledoc false
  @behaviour ParrotMedia.Handler

  require Logger

  @impl true
  def init(args), do: {:ok, args}

  @impl true
  def handle_session_start(_session_id, _opts, state), do: {:ok, state}

  @impl true
  def handle_offer(_sdp, _direction, state), do: {:noreply, state}

  @impl true
  def handle_answer(_sdp, _direction, state), do: {:ok, state}

  @impl true
  def handle_stream_start(_session_id, _direction, state) do
    Logger.info("[TestMediaHandler] Stream started - ready for DTMF")
    {:noreply, state}
  end

  @impl true
  def handle_stream_stop(_session_id, _reason, state), do: {:ok, state}

  @impl true
  def handle_play_complete(_file, state), do: {:noreply, state}

  @impl true
  def handle_codec_negotiation(offered, supported, state) do
    codec = Enum.find(supported, fn c -> c in offered end) || hd(supported)
    {:ok, codec, state}
  end

  @impl true
  def handle_negotiation_complete(_answer, _offer, _codec, state), do: {:ok, state}

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[TestMediaHandler] handle_info: #{inspect(msg)}")
    {:noreply, state}
  end
end
