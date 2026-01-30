defmodule ParrotMedia.MediaSessionForkTest do
  @moduledoc """
  Tests for MediaSession fork_media/stop_fork_media functionality.
  """
  use ExUnit.Case, async: false

  alias ParrotMedia.MediaSession
  alias ParrotMedia.Fork.Types.ForkState
  alias ParrotMedia.Test.TestMediaHandler

  describe "fork_media/4" do
    setup do
      session_id = "fork-test-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog-123",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          notify_pid: self()
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          MediaSession.terminate_session(session_id)
        end
      end)

      {:ok, session_id: session_id, pid: pid}
    end

    test "returns error when not in active state", %{session_id: session_id} do
      # Session is in :idle state, should fail
      result = MediaSession.fork_media(session_id, "wss://example.com/audio")
      assert {:error, :not_active} = result
    end
  end

  describe "fork_media with active session" do
    setup do
      session_id = "fork-active-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog-123",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Need to get session into active state by processing SDP offer
      offer = """
      v=0
      o=- 123 456 IN IP4 192.168.1.1
      s=-
      c=IN IP4 192.168.1.1
      t=0 0
      m=audio 5000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      a=sendrecv
      """

      {:ok, _answer} = MediaSession.process_offer(session_id, offer)
      :ok = MediaSession.start_media(session_id)

      on_exit(fn ->
        if Process.alive?(pid) do
          MediaSession.terminate_session(session_id)
        end
      end)

      {:ok, session_id: session_id, pid: pid}
    end

    test "creates WebSocket fork with URL destination", %{session_id: session_id} do
      result = MediaSession.fork_media(session_id, "wss://ai-service.com/audio")
      assert {:ok, fork_id} = result
      assert is_binary(fork_id)
      assert String.starts_with?(fork_id, "fork-")
    end

    test "creates RTP fork with tuple destination", %{session_id: session_id} do
      result = MediaSession.fork_media(session_id, {{192, 168, 1, 100}, 5004})
      assert {:ok, fork_id} = result
      assert is_binary(fork_id)
    end

    test "supports direction option", %{session_id: session_id} do
      result = MediaSession.fork_media(session_id, "wss://example.com/audio", direction: :rx)
      assert {:ok, _fork_id} = result
    end

    test "supports label option", %{session_id: session_id} do
      result =
        MediaSession.fork_media(session_id, "wss://example.com/audio", label: "transcription")

      assert {:ok, _fork_id} = result
    end
  end

  describe "stop_fork_media/3" do
    setup do
      session_id = "fork-stop-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog-123",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Get session into active state
      offer = """
      v=0
      o=- 123 456 IN IP4 192.168.1.1
      s=-
      c=IN IP4 192.168.1.1
      t=0 0
      m=audio 5000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      a=sendrecv
      """

      {:ok, _answer} = MediaSession.process_offer(session_id, offer)
      :ok = MediaSession.start_media(session_id)

      on_exit(fn ->
        if Process.alive?(pid) do
          MediaSession.terminate_session(session_id)
        end
      end)

      {:ok, session_id: session_id, pid: pid}
    end

    test "removes existing fork", %{session_id: session_id} do
      {:ok, fork_id} = MediaSession.fork_media(session_id, "wss://example.com/audio")
      result = MediaSession.stop_fork_media(session_id, fork_id)
      assert :ok = result
    end

    test "returns error for non-existent fork", %{session_id: session_id} do
      # First create a fork to ensure fork manager is started
      {:ok, _fork_id} = MediaSession.fork_media(session_id, "wss://example.com/audio")

      # Now try to remove a non-existent fork
      result = MediaSession.stop_fork_media(session_id, "non-existent")
      assert {:error, :not_found} = result
    end
  end

  describe "list_forks/2" do
    setup do
      session_id = "fork-list-#{:rand.uniform(10000)}"

      {:ok, pid} =
        MediaSession.start_link(
          id: session_id,
          dialog_id: "dialog-123",
          role: :uas,
          media_handler: TestMediaHandler,
          handler_args: %{},
          notify_pid: self()
        )

      # Get session into active state
      offer = """
      v=0
      o=- 123 456 IN IP4 192.168.1.1
      s=-
      c=IN IP4 192.168.1.1
      t=0 0
      m=audio 5000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      a=sendrecv
      """

      {:ok, _answer} = MediaSession.process_offer(session_id, offer)
      :ok = MediaSession.start_media(session_id)

      on_exit(fn ->
        if Process.alive?(pid) do
          MediaSession.terminate_session(session_id)
        end
      end)

      {:ok, session_id: session_id, pid: pid}
    end

    test "returns empty list when no forks", %{session_id: session_id} do
      forks = MediaSession.list_forks(session_id)
      assert [] = forks
    end

    test "returns all active forks", %{session_id: session_id} do
      {:ok, fork_id1} = MediaSession.fork_media(session_id, "wss://service1.com/audio")
      {:ok, fork_id2} = MediaSession.fork_media(session_id, "wss://service2.com/audio")

      forks = MediaSession.list_forks(session_id)
      assert length(forks) == 2

      fork_ids = Enum.map(forks, fn %ForkState{config: config} -> config.id end)
      assert fork_id1 in fork_ids
      assert fork_id2 in fork_ids
    end
  end
end
