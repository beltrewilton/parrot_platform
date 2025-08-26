defmodule Parrot.Media.MediaSessionIPConfigTest do
  use ExUnit.Case, async: true

  alias Parrot.Media.MediaSession
  alias Parrot.Sip.Transport.Inet
  alias Parrot.Test.TestMediaHandler

  describe "IP configuration" do
    test "uses auto-detected IP by default" do
      {:ok, pid} =
        MediaSession.start_link(
          id: "test-ip-auto",
          dialog_id: "dialog-ip-auto",
          # generate_offer requires UAC role
          role: :uac,
          media_handler: TestMediaHandler
        )

      # Generate offer to see what IP is used
      {:ok, sdp} = MediaSession.generate_offer(pid)

      # Should use the auto-detected IP
      expected_ip = Inet.first_ipv4_address() |> Tuple.to_list() |> Enum.join(".")
      assert String.contains?(sdp, "c=IN IP4 #{expected_ip}")

      MediaSession.terminate_session(pid)
    end

    test "uses explicit local_ip when provided as string" do
      {:ok, pid} =
        MediaSession.start_link(
          id: "test-ip-explicit",
          dialog_id: "dialog-ip-explicit",
          role: :uac,
          media_handler: TestMediaHandler,
          local_ip: "192.168.1.100"
        )

      {:ok, sdp} = MediaSession.generate_offer(pid)
      assert String.contains?(sdp, "c=IN IP4 192.168.1.100")

      MediaSession.terminate_session(pid)
    end

    test "uses explicit local_ip when provided as tuple" do
      {:ok, pid} =
        MediaSession.start_link(
          id: "test-ip-tuple",
          dialog_id: "dialog-ip-tuple",
          role: :uac,
          media_handler: TestMediaHandler,
          local_ip: {10, 0, 0, 1}
        )

      {:ok, sdp} = MediaSession.generate_offer(pid)
      assert String.contains?(sdp, "c=IN IP4 10.0.0.1")

      MediaSession.terminate_session(pid)
    end

    test "uses advertised_ip over local_ip when both provided" do
      {:ok, pid} =
        MediaSession.start_link(
          id: "test-ip-advertised",
          dialog_id: "dialog-ip-advertised",
          role: :uac,
          media_handler: TestMediaHandler,
          local_ip: "192.168.1.100",
          advertised_ip: "203.0.113.1"
        )

      {:ok, sdp} = MediaSession.generate_offer(pid)
      # Should use advertised IP in SDP
      assert String.contains?(sdp, "c=IN IP4 203.0.113.1")
      refute String.contains?(sdp, "192.168.1.100")

      MediaSession.terminate_session(pid)
    end

    test "IP configuration in SDP answer" do
      sdp_offer = """
      v=0\r
      o=- 123456 123456 IN IP4 10.0.0.5\r
      s=-\r
      c=IN IP4 10.0.0.5\r
      t=0 0\r
      m=audio 30000 RTP/AVP 8\r
      a=rtpmap:8 PCMA/8000\r
      a=sendrecv\r
      """

      {:ok, pid} =
        MediaSession.start_link(
          id: "test-ip-answer",
          dialog_id: "dialog-ip-answer",
          role: :uas,
          media_handler: TestMediaHandler,
          local_ip: "172.16.0.10",
          advertised_ip: "198.51.100.1"
        )

      {:ok, sdp_answer} = MediaSession.process_offer(pid, sdp_offer)

      # Should use advertised IP in answer
      assert String.contains?(sdp_answer, "c=IN IP4 198.51.100.1")
      # origin line should also use advertised IP
      assert String.contains?(sdp_answer, "o=- ")

      MediaSession.terminate_session(pid)
    end

    test "handles invalid IP gracefully" do
      {:ok, pid} =
        MediaSession.start_link(
          id: "test-ip-invalid",
          dialog_id: "dialog-ip-invalid",
          role: :uac,
          media_handler: TestMediaHandler,
          local_ip: "invalid.ip.address"
        )

      {:ok, sdp} = MediaSession.generate_offer(pid)
      # Should fall back to localhost on parse error
      assert String.contains?(sdp, "c=IN IP4 127.0.0.1")

      MediaSession.terminate_session(pid)
    end
  end
end
