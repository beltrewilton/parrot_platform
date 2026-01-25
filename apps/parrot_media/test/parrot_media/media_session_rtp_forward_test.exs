defmodule ParrotMedia.MediaSessionRtpForwardTest do
  @moduledoc """
  Tests for MediaSession RTP forwarding functionality for B2BUA proxy mode.

  RTP forwarding allows media from one call leg to be forwarded to another,
  enabling proxy-mode B2BUA operation where media passes through the B2BUA.
  """

  use ExUnit.Case, async: true

  alias ParrotMedia.MediaSession
  alias ParrotMedia.Test.TestMediaHandler

  describe "set_rtp_forward/2" do
    test "configures RTP forwarding in ready state" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_forward_config_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      # Create a mock target process
      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :both
      }

      # Configure forwarding should succeed in ready state
      assert :ok = MediaSession.set_rtp_forward(session, config)

      # Verify forwarding is configured via state inspection
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_config != nil
      assert state_info.rtp_forward_config.target_pid == target_pid
      assert state_info.rtp_forward_config.direction == :both

      # Cleanup
      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end

    test "configures RTP forwarding with send_only direction" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_forward_send_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :send_only
      }

      assert :ok = MediaSession.set_rtp_forward(session, config)

      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_config.direction == :send_only

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end

    test "configures RTP forwarding with recv_only direction" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_forward_recv_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :recv_only
      }

      assert :ok = MediaSession.set_rtp_forward(session, config)

      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_config.direction == :recv_only

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end

    test "returns error when target_pid is not a valid pid" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_forward_invalid_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      invalid_config = %{
        target_pid: :not_a_pid,
        direction: :both
      }

      assert {:error, :invalid_target_pid} = MediaSession.set_rtp_forward(session, invalid_config)

      MediaSession.terminate_session(session)
    end

    test "returns error for invalid direction" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_forward_bad_dir_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      invalid_config = %{
        target_pid: target_pid,
        direction: :invalid_direction
      }

      assert {:error, :invalid_direction} = MediaSession.set_rtp_forward(session, invalid_config)

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end
  end

  describe "pause_forward/1" do
    test "pauses RTP forwarding when forwarding is configured" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_pause_forward_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :both
      }

      :ok = MediaSession.set_rtp_forward(session, config)

      # Pause forwarding should succeed
      assert :ok = MediaSession.pause_forward(session)

      # Verify forwarding is paused
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_paused == true

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end

    test "returns error when no forwarding is configured" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_pause_no_fwd_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      # Pause without configuring forwarding should return error
      assert {:error, :no_forward_configured} = MediaSession.pause_forward(session)

      MediaSession.terminate_session(session)
    end
  end

  describe "resume_forward/1" do
    test "resumes RTP forwarding after pause" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_resume_forward_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :both
      }

      :ok = MediaSession.set_rtp_forward(session, config)
      :ok = MediaSession.pause_forward(session)

      # Resume forwarding should succeed
      assert :ok = MediaSession.resume_forward(session)

      # Verify forwarding is no longer paused
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_paused == false

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end

    test "returns error when no forwarding is configured" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_resume_no_fwd_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      # Resume without configuring forwarding should return error
      assert {:error, :no_forward_configured} = MediaSession.resume_forward(session)

      MediaSession.terminate_session(session)
    end

    test "returns error when not paused" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_resume_not_paused_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :both
      }

      :ok = MediaSession.set_rtp_forward(session, config)

      # Resume without pausing first should return error
      assert {:error, :not_paused} = MediaSession.resume_forward(session)

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end
  end

  describe "forward state tracking" do
    test "get_state returns forwarding configuration" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_state_tracking_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      # Initially no forwarding configured
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_config == nil
      assert state_info.rtp_forward_paused == false

      # Configure forwarding
      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :both
      }

      :ok = MediaSession.set_rtp_forward(session, config)

      # Verify state reflects configuration
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_config != nil
      assert state_info.rtp_forward_paused == false

      # Pause and verify
      :ok = MediaSession.pause_forward(session)
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_paused == true

      # Resume and verify
      :ok = MediaSession.resume_forward(session)
      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_paused == false

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end

    test "clearing forward configuration" do
      {:ok, session} =
        MediaSession.start_link(
          id: "test_clear_forward_#{:rand.uniform(100_000)}",
          dialog_id: "dialog_test",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          audio_source: :silence
        )

      sdp_offer = """
      v=0
      o=- 123456 123456 IN IP4 127.0.0.1
      s=Test
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 20000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(session, sdp_offer)

      target_pid = spawn(fn -> Process.sleep(:infinity) end)

      config = %{
        target_pid: target_pid,
        direction: :both
      }

      :ok = MediaSession.set_rtp_forward(session, config)

      # Clear forwarding by setting nil
      assert :ok = MediaSession.set_rtp_forward(session, nil)

      state_info = :gen_statem.call(session, :get_state)
      assert state_info.rtp_forward_config == nil
      assert state_info.rtp_forward_paused == false

      Process.exit(target_pid, :kill)
      MediaSession.terminate_session(session)
    end
  end
end
