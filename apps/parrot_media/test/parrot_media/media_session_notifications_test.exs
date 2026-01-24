defmodule ParrotMedia.MediaSessionNotificationsTest do
  @moduledoc """
  Tests for MediaSession notification system.

  These tests verify that MediaSession sends proper notification messages
  to a configured notify_pid for events like:
  - play_complete
  - record_complete
  - dtmf_collected
  - dtmf_timeout
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.{MediaSession, MediaSessionSupervisor}

  require Logger

  # Test handler that implements required callbacks
  # Sends confirmation messages to test_pid when provided in handler_args
  defmodule NotificationTestHandler do
    @behaviour ParrotMedia.Handler

    @impl true
    def init(args) do
      {:ok, Map.merge(%{messages_received: [], test_pid: nil}, args)}
    end

    @impl true
    def handle_info({:play_files, files, opts}, state) do
      Logger.info("NotificationTestHandler: play_files #{inspect(files)}")

      # Send confirmation to test process if configured
      if state[:test_pid] do
        send(state.test_pid, {:handler_processed, :play_files, files, opts})
      end

      action =
        if Keyword.get(opts, :loop, false), do: {:play_loop, files}, else: {:play_sequence, files}

      {[action], state}
    end

    @impl true
    def handle_info({:start_record, path, opts}, state) do
      Logger.info("NotificationTestHandler: start_record #{inspect(path)}")

      # Send confirmation to test process if configured
      if state[:test_pid] do
        send(state.test_pid, {:handler_processed, :start_record, path, opts})
      end

      {[{:record, path}], state}
    end

    @impl true
    def handle_info({:collect_dtmf, opts}, state) do
      Logger.info("NotificationTestHandler: collect_dtmf #{inspect(opts)}")

      # Send confirmation to test process if configured
      if state[:test_pid] do
        send(state.test_pid, {:handler_processed, :collect_dtmf, opts})
      end

      {:noreply, Map.put(state, :collecting_dtmf, opts)}
    end

    @impl true
    def handle_info(msg, state) do
      Logger.debug("NotificationTestHandler: unhandled message #{inspect(msg)}")
      {:noreply, state}
    end

    @impl true
    def handle_session_start(_session_id, _opts, state), do: {:ok, state}

    @impl true
    def handle_offer(_sdp, _direction, state), do: {:noreply, state}

    @impl true
    def handle_negotiation_complete(_local_sdp, _remote_sdp, _codec, state), do: {:ok, state}

    @impl true
    def handle_stream_start(_session_id, _direction, state), do: {:noreply, state}

    @impl true
    def handle_codec_negotiation(offered, supported, state) do
      codec = Enum.find(offered, &(&1 in supported)) || :pcma
      {:ok, codec, state}
    end
  end

  describe "notify_pid option" do
    test "accepts notify_pid option in start_link" do
      session_id = "notify-test-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          notify_pid: self()
        )

      assert Process.alive?(pid)

      # Verify notify_pid works by testing notification delivery
      send(pid, {:pipeline_event, :play_complete, "test.wav"})
      assert_receive {:media_event, ^session_id, {:play_complete, "test.wav"}}, 1000

      MediaSession.terminate_session(pid)
    end

    test "defaults notify_pid to nil when not provided" do
      session_id = "no-notify-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{}
        )

      assert Process.alive?(pid)

      # Verify no notifications are sent when notify_pid is nil
      send(pid, {:pipeline_event, :play_complete, "test.wav"})
      Process.sleep(100)
      refute_receive {:media_event, _, _}

      MediaSession.terminate_session(pid)
    end
  end

  describe "set_notify_pid/2" do
    test "sets notify_pid after session creation" do
      session_id = "set-notify-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{}
          # No notify_pid initially
        )

      assert Process.alive?(pid)

      # Verify no notifications before set_notify_pid
      send(pid, {:pipeline_event, :play_complete, "before.wav"})
      Process.sleep(50)
      refute_receive {:media_event, _, _}

      # Set notify_pid using the new function
      :ok = MediaSession.set_notify_pid(session_id, self())

      # Verify notifications work after set_notify_pid
      send(pid, {:pipeline_event, :play_complete, "after.wav"})
      assert_receive {:media_event, ^session_id, {:play_complete, "after.wav"}}, 1000

      MediaSession.terminate_session(pid)
    end

    test "enables notifications after set_notify_pid is called" do
      session_id = "set-notify-enables-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{}
          # No notify_pid initially
        )

      # Set notify_pid
      :ok = MediaSession.set_notify_pid(session_id, self())

      # Simulate play complete event from pipeline
      send(pid, {:pipeline_event, :play_complete, "test.wav"})

      # Should now receive notification
      assert_receive {:media_event, ^session_id, {:play_complete, "test.wav"}}, 1000

      MediaSession.terminate_session(pid)
    end

    test "set_notify_pid works in ready state" do
      session_id = "set-notify-ready-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          supported_codecs: [:pcma]
        )

      # Process an SDP offer to move to ready state
      sdp_offer = """
      v=0
      o=- 1234567890 1234567890 IN IP4 127.0.0.1
      s=-
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 5004 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      {:ok, _answer} = MediaSession.process_offer(pid, sdp_offer)

      # Verify we're now in ready state via public API
      state_info = :gen_statem.call(pid, :get_state)
      assert state_info.state == :ready

      # Set notify_pid in ready state
      :ok = MediaSession.set_notify_pid(session_id, self())

      # Verify set_notify_pid works by testing notification delivery
      send(pid, {:pipeline_event, :play_complete, "ready-test.wav"})
      assert_receive {:media_event, ^session_id, {:play_complete, "ready-test.wav"}}, 1000

      MediaSession.terminate_session(pid)
    end
  end

  describe "play_complete notification" do
    test "sends play_complete notification when file playback completes" do
      session_id = "play-complete-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Simulate play complete event from pipeline
      send(pid, {:pipeline_event, :play_complete, "test.wav"})

      # Should receive notification
      assert_receive {:media_event, ^session_id, {:play_complete, "test.wav"}}, 1000

      MediaSession.terminate_session(pid)
    end

    test "does not send notification when notify_pid is nil" do
      session_id = "play-no-notify-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{}
          # No notify_pid
        )

      # Simulate play complete event
      send(pid, {:pipeline_event, :play_complete, "test.wav"})
      Process.sleep(100)

      # Should not receive any message
      refute_receive {:media_event, _, _}

      MediaSession.terminate_session(pid)
    end
  end

  describe "record_complete notification" do
    test "sends record_complete notification when recording completes" do
      session_id = "record-complete-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Simulate record complete event from pipeline with duration
      send(pid, {:pipeline_event, :record_complete, "/tmp/recording.wav", 5000})

      # Should receive notification with filename and duration
      assert_receive {:media_event, ^session_id, {:record_complete, "/tmp/recording.wav", 5000}},
                     1000

      MediaSession.terminate_session(pid)
    end
  end

  describe "DTMF collection" do
    test "sends dtmf_collected notification when digits collected" do
      session_id = "dtmf-collect-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Start DTMF collection
      send(pid, {:collect_dtmf, max: 4, terminators: ["#"], timeout: 10_000})
      Process.sleep(50)

      # Simulate DTMF digits received
      send(pid, {:dtmf, "1"})
      send(pid, {:dtmf, "2"})
      send(pid, {:dtmf, "3"})
      # terminator
      send(pid, {:dtmf, "#"})

      # Should receive collected digits
      assert_receive {:media_event, ^session_id, {:dtmf_collected, "123"}}, 1000

      MediaSession.terminate_session(pid)
    end

    test "sends dtmf_collected when max digits reached" do
      session_id = "dtmf-max-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Start DTMF collection with max 4 digits
      send(pid, {:collect_dtmf, max: 4, terminators: ["#"], timeout: 10_000})
      Process.sleep(50)

      # Simulate exactly 4 DTMF digits
      send(pid, {:dtmf, "1"})
      send(pid, {:dtmf, "2"})
      send(pid, {:dtmf, "3"})
      send(pid, {:dtmf, "4"})

      # Should receive collected digits when max reached
      assert_receive {:media_event, ^session_id, {:dtmf_collected, "1234"}}, 1000

      MediaSession.terminate_session(pid)
    end

    test "sends dtmf_timeout notification on timeout" do
      session_id = "dtmf-timeout-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Start DTMF collection with short timeout
      send(pid, {:collect_dtmf, max: 4, terminators: ["#"], timeout: 100})
      Process.sleep(50)

      # Send one digit but don't complete
      send(pid, {:dtmf, "1"})

      # Should receive timeout notification with partial digits
      assert_receive {:media_event, ^session_id, {:dtmf_timeout, "1"}}, 500

      MediaSession.terminate_session(pid)
    end

    test "ignores DTMF when not collecting" do
      session_id = "dtmf-ignore-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Send DTMF without starting collection
      send(pid, {:dtmf, "1"})
      Process.sleep(100)

      # Should not receive any notification
      refute_receive {:media_event, _, {:dtmf_collected, _}}
      refute_receive {:media_event, _, {:dtmf_timeout, _}}

      MediaSession.terminate_session(pid)
    end
  end

  describe "play_files message handling" do
    test "handles play_files message and forwards to handler" do
      session_id = "play-files-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{test_pid: self()},
          notify_pid: self()
        )

      # Send play_files message
      files = ["file1.wav", "file2.wav"]
      opts = [loop: false]
      send(pid, {:play_files, files, opts})

      # Verify handler received the message with correct files and options
      assert_receive {:handler_processed, :play_files, ^files, ^opts}, 1000

      MediaSession.terminate_session(pid)
    end
  end

  describe "start_record message handling" do
    test "handles start_record message and forwards to handler" do
      session_id = "start-record-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{test_pid: self()},
          notify_pid: self()
        )

      # Send start_record message
      path = "/tmp/recording.wav"
      opts = [max_duration: 30_000]
      send(pid, {:start_record, path, opts})

      # Verify handler received the message with correct path and options
      assert_receive {:handler_processed, :start_record, ^path, ^opts}, 1000

      MediaSession.terminate_session(pid)
    end
  end

  describe "collect_dtmf message handling" do
    test "handles collect_dtmf message and forwards to handler" do
      session_id = "collect-dtmf-msg-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSessionSupervisor.start_session(
          id: session_id,
          dialog_id: "test-dialog",
          role: :uas,
          media_handler: NotificationTestHandler,
          handler_args: %{test_pid: self()},
          notify_pid: self()
        )

      # Send collect_dtmf message
      opts = [max: 4, terminators: ["#", "*"], timeout: 10_000]
      send(pid, {:collect_dtmf, opts})

      # Verify handler received the message with correct options
      assert_receive {:handler_processed, :collect_dtmf, ^opts}, 1000

      MediaSession.terminate_session(pid)
    end
  end
end
