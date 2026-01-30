defmodule ParrotMedia.MediaSessionRenegotiationTest do
  @moduledoc """
  Tests for MediaSession SDP renegotiation functionality.

  Renegotiation allows mid-call session modifications via UPDATE or re-INVITE,
  supporting features like hold/resume, codec changes, and ICE restarts.
  """

  use ExUnit.Case, async: false

  alias ParrotMedia.MediaSession
  alias ParrotMedia.Test.TestMediaHandler

  @moduletag :renegotiation

  # Standard SDP offer for initial negotiation
  @initial_offer """
  v=0
  o=- 123456 123456 IN IP4 127.0.0.1
  s=Test
  c=IN IP4 127.0.0.1
  t=0 0
  m=audio 20000 RTP/AVP 8
  a=rtpmap:8 PCMA/8000
  a=sendrecv
  """

  # SDP offer with sendonly (remote holding)
  @hold_offer """
  v=0
  o=- 123456 123457 IN IP4 127.0.0.1
  s=Test
  c=IN IP4 127.0.0.1
  t=0 0
  m=audio 20000 RTP/AVP 8
  a=rtpmap:8 PCMA/8000
  a=sendonly
  """

  # SDP offer with recvonly (remote receiving only)
  @recvonly_offer """
  v=0
  o=- 123456 123458 IN IP4 127.0.0.1
  s=Test
  c=IN IP4 127.0.0.1
  t=0 0
  m=audio 20000 RTP/AVP 8
  a=rtpmap:8 PCMA/8000
  a=recvonly
  """

  # SDP offer with inactive (both sides muted)
  @inactive_offer """
  v=0
  o=- 123456 123459 IN IP4 127.0.0.1
  s=Test
  c=IN IP4 127.0.0.1
  t=0 0
  m=audio 20000 RTP/AVP 8
  a=rtpmap:8 PCMA/8000
  a=inactive
  """

  defp start_session(id) do
    {:ok, pid} = MediaSession.start_link(
      id: id,
      dialog_id: "dialog-#{id}",
      role: :uas,
      media_handler: TestMediaHandler,
      handler_args: %{},
      audio_source: :silence
    )
    pid
  end

  defp setup_established_session(id) do
    pid = start_session(id)
    {:ok, _answer} = MediaSession.process_offer(pid, @initial_offer)
    pid
  end

  describe "renegotiate/2 in ready state" do
    test "processes hold offer (sendonly)" do
      session = setup_established_session("renego-hold-#{:rand.uniform(100_000)}")

      # Renegotiate with hold offer
      assert {:ok, answer} = MediaSession.renegotiate(session, @hold_offer)

      # Answer should contain recvonly (we accept their hold)
      assert answer =~ "recvonly"

      # Check session direction changed
      state = :gen_statem.call(session, :get_state)
      assert state.direction == :recvonly

      MediaSession.terminate_session(session)
    end

    test "processes resume offer (sendrecv)" do
      session = setup_established_session("renego-resume-#{:rand.uniform(100_000)}")

      # First put on hold
      {:ok, _} = MediaSession.renegotiate(session, @hold_offer)

      # Then resume
      resume_offer = String.replace(@hold_offer, "sendonly", "sendrecv")
      assert {:ok, answer} = MediaSession.renegotiate(session, resume_offer)

      # Answer should contain sendrecv
      assert answer =~ "sendrecv"

      state = :gen_statem.call(session, :get_state)
      assert state.direction == :sendrecv

      MediaSession.terminate_session(session)
    end

    test "processes recvonly offer" do
      session = setup_established_session("renego-recvonly-#{:rand.uniform(100_000)}")

      assert {:ok, answer} = MediaSession.renegotiate(session, @recvonly_offer)

      # When they want recvonly, we should respond with sendonly
      assert answer =~ "sendonly"

      state = :gen_statem.call(session, :get_state)
      assert state.direction == :sendonly

      MediaSession.terminate_session(session)
    end

    test "processes inactive offer" do
      session = setup_established_session("renego-inactive-#{:rand.uniform(100_000)}")

      assert {:ok, answer} = MediaSession.renegotiate(session, @inactive_offer)

      # Inactive request should be answered with inactive
      assert answer =~ "inactive"

      state = :gen_statem.call(session, :get_state)
      assert state.direction == :inactive

      MediaSession.terminate_session(session)
    end

    test "rejects offer with unsupported codec" do
      session = setup_established_session("renego-bad-codec-#{:rand.uniform(100_000)}")

      bad_codec_offer = """
      v=0
      o=- 123456 123457 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 99
      a=rtpmap:99 UNKNOWNCODEC/8000
      """

      assert {:error, :no_compatible_codec} = MediaSession.renegotiate(session, bad_codec_offer)

      MediaSession.terminate_session(session)
    end
  end

  describe "create_reoffer/2" do
    test "creates offer with sendonly for hold" do
      session = setup_established_session("reoffer-hold-#{:rand.uniform(100_000)}")

      assert {:ok, offer} = MediaSession.create_reoffer(session, direction: :sendonly)

      assert offer =~ "sendonly"

      MediaSession.terminate_session(session)
    end

    test "creates offer with sendrecv for resume" do
      session = setup_established_session("reoffer-resume-#{:rand.uniform(100_000)}")

      assert {:ok, offer} = MediaSession.create_reoffer(session, direction: :sendrecv)

      assert offer =~ "sendrecv"

      MediaSession.terminate_session(session)
    end

    test "creates offer with inactive" do
      session = setup_established_session("reoffer-inactive-#{:rand.uniform(100_000)}")

      assert {:ok, offer} = MediaSession.create_reoffer(session, direction: :inactive)

      assert offer =~ "inactive"

      MediaSession.terminate_session(session)
    end

    test "includes current codec in reoffer" do
      session = setup_established_session("reoffer-codec-#{:rand.uniform(100_000)}")

      {:ok, offer} = MediaSession.create_reoffer(session, direction: :sendrecv)

      # Should include PCMA since that's what we negotiated
      assert offer =~ "PCMA"

      MediaSession.terminate_session(session)
    end

    test "increments session version in origin" do
      session = setup_established_session("reoffer-version-#{:rand.uniform(100_000)}")

      {:ok, offer1} = MediaSession.create_reoffer(session, direction: :sendrecv)
      {:ok, offer2} = MediaSession.create_reoffer(session, direction: :sendonly)

      # Extract session versions from o= line
      # Format: o=username sess-id sess-version nettype addrtype unicast-address
      [_, version1] = Regex.run(~r/o=- \d+ (\d+)/, offer1)
      [_, version2] = Regex.run(~r/o=- \d+ (\d+)/, offer2)

      assert String.to_integer(version2) > String.to_integer(version1)

      MediaSession.terminate_session(session)
    end
  end

  describe "renegotiate/2 error handling" do
    test "returns error for invalid SDP" do
      session = setup_established_session("renego-invalid-#{:rand.uniform(100_000)}")

      assert {:error, _} = MediaSession.renegotiate(session, "not valid sdp")

      MediaSession.terminate_session(session)
    end

    test "returns error when called in idle state" do
      session = start_session("renego-idle-#{:rand.uniform(100_000)}")

      # Session is in idle state, not negotiated yet
      assert {:error, :not_negotiated} = MediaSession.renegotiate(session, @hold_offer)

      MediaSession.terminate_session(session)
    end
  end

  describe "direction transition rules" do
    test "sendrecv -> sendonly (local hold)" do
      session = setup_established_session("dir-local-hold-#{:rand.uniform(100_000)}")

      # Start with sendrecv
      state = :gen_statem.call(session, :get_state)
      assert state.direction == :sendrecv

      # Create hold offer
      {:ok, _offer} = MediaSession.create_reoffer(session, direction: :sendonly)

      # Simulate receiving their answer accepting our hold
      hold_answer = String.replace(@initial_offer, "sendrecv", "recvonly")
      :ok = MediaSession.process_reoffer_answer(session, hold_answer)

      state = :gen_statem.call(session, :get_state)
      assert state.direction == :sendonly

      MediaSession.terminate_session(session)
    end

    test "sendonly -> sendrecv (local resume)" do
      session = setup_established_session("dir-local-resume-#{:rand.uniform(100_000)}")

      # First put ourselves on hold
      {:ok, _} = MediaSession.create_reoffer(session, direction: :sendonly)
      hold_answer = String.replace(@initial_offer, "sendrecv", "recvonly")
      :ok = MediaSession.process_reoffer_answer(session, hold_answer)

      # Now resume
      {:ok, _offer} = MediaSession.create_reoffer(session, direction: :sendrecv)
      resume_answer = @initial_offer
      :ok = MediaSession.process_reoffer_answer(session, resume_answer)

      state = :gen_statem.call(session, :get_state)
      assert state.direction == :sendrecv

      MediaSession.terminate_session(session)
    end
  end
end
