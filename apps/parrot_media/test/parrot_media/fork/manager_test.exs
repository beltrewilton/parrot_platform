defmodule ParrotMedia.Fork.ManagerTest do
  @moduledoc """
  Tests for Fork.Manager GenServer.
  """
  use ExUnit.Case, async: true

  alias ParrotMedia.Fork.Manager
  alias ParrotMedia.Fork.Types.{ForkConfig, ForkState}

  describe "start_link/1" do
    test "starts a manager with required session_id" do
      {:ok, pid} = Manager.start_link(session_id: "test-session-123")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts a manager with optional parent_pid for notifications" do
      {:ok, pid} = Manager.start_link(
        session_id: "test-session-123",
        parent_pid: self()
      )
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "add_fork/2" do
    setup do
      {:ok, pid} = Manager.start_link(session_id: "test-session-123", parent_pid: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, manager: pid}
    end

    test "adds a websocket fork configuration", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-ws-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      assert {:ok, "fork-ws-1"} = Manager.add_fork(manager, config)
    end

    test "adds an RTP fork configuration", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-rtp-1",
        destination: {:rtp, {{192, 168, 1, 100}, 5004}},
        direction: :rx
      }

      assert {:ok, "fork-rtp-1"} = Manager.add_fork(manager, config)
    end

    test "returns error for duplicate fork id", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      assert {:ok, "fork-1"} = Manager.add_fork(manager, config)
      assert {:error, :already_exists} = Manager.add_fork(manager, config)
    end

    test "generates fork id if not provided", %{manager: manager} do
      config = %ForkConfig{
        id: nil,
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      # Create a config without id using struct update
      config_without_id = Map.put(config, :id, nil)

      # The manager should generate an ID
      result = Manager.add_fork(manager, config_without_id)
      assert {:ok, generated_id} = result
      assert is_binary(generated_id)
    end
  end

  describe "remove_fork/2" do
    setup do
      {:ok, pid} = Manager.start_link(session_id: "test-session-123", parent_pid: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, manager: pid}
    end

    test "removes an existing fork", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      {:ok, "fork-1"} = Manager.add_fork(manager, config)
      assert :ok = Manager.remove_fork(manager, "fork-1")
    end

    test "returns error for non-existent fork", %{manager: manager} do
      assert {:error, :not_found} = Manager.remove_fork(manager, "non-existent")
    end
  end

  describe "list_forks/1" do
    setup do
      {:ok, pid} = Manager.start_link(session_id: "test-session-123", parent_pid: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, manager: pid}
    end

    test "returns empty list when no forks", %{manager: manager} do
      assert [] = Manager.list_forks(manager)
    end

    test "returns all active forks", %{manager: manager} do
      config1 = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio1"},
        direction: :both
      }

      config2 = %ForkConfig{
        id: "fork-2",
        destination: {:rtp, {{192, 168, 1, 100}, 5004}},
        direction: :rx
      }

      {:ok, _} = Manager.add_fork(manager, config1)
      {:ok, _} = Manager.add_fork(manager, config2)

      forks = Manager.list_forks(manager)
      assert length(forks) == 2

      fork_ids = Enum.map(forks, fn %ForkState{config: config} -> config.id end)
      assert "fork-1" in fork_ids
      assert "fork-2" in fork_ids
    end
  end

  describe "get_fork/2" do
    setup do
      {:ok, pid} = Manager.start_link(session_id: "test-session-123", parent_pid: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, manager: pid}
    end

    test "returns fork state for existing fork", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      {:ok, _} = Manager.add_fork(manager, config)

      assert {:ok, %ForkState{} = state} = Manager.get_fork(manager, "fork-1")
      assert state.config.id == "fork-1"
      assert state.status == :pending
    end

    test "returns error for non-existent fork", %{manager: manager} do
      assert {:error, :not_found} = Manager.get_fork(manager, "non-existent")
    end
  end

  describe "event notifications" do
    setup do
      {:ok, pid} = Manager.start_link(session_id: "test-session-123", parent_pid: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, manager: pid}
    end

    test "notifies parent when fork is added", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      {:ok, _} = Manager.add_fork(manager, config)

      assert_receive {:fork_event, "test-session-123", {:fork_added, "fork-1"}}, 1000
    end

    test "notifies parent when fork is removed", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      {:ok, _} = Manager.add_fork(manager, config)
      # Drain the fork_added message
      assert_receive {:fork_event, _, {:fork_added, _}}, 1000

      :ok = Manager.remove_fork(manager, "fork-1")

      assert_receive {:fork_event, "test-session-123", {:fork_removed, "fork-1"}}, 1000
    end
  end

  describe "fork status updates" do
    setup do
      {:ok, pid} = Manager.start_link(session_id: "test-session-123", parent_pid: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      {:ok, manager: pid}
    end

    test "updates fork status to active on connection", %{manager: manager} do
      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      {:ok, _} = Manager.add_fork(manager, config)
      assert_receive {:fork_event, _, {:fork_added, _}}, 1000

      # Simulate connection event
      :ok = Manager.update_fork_status(manager, "fork-1", :active)

      {:ok, state} = Manager.get_fork(manager, "fork-1")
      assert state.status == :active
    end
  end

  describe "cleanup on termination" do
    test "cleans up all forks on manager stop" do
      {:ok, manager} = Manager.start_link(session_id: "test-session-123", parent_pid: self())

      config = %ForkConfig{
        id: "fork-1",
        destination: {:websocket, "ws://example.com/audio"},
        direction: :both
      }

      {:ok, _} = Manager.add_fork(manager, config)
      assert_receive {:fork_event, _, {:fork_added, _}}, 1000

      GenServer.stop(manager)

      # Manager should be dead
      refute Process.alive?(manager)
    end
  end
end
