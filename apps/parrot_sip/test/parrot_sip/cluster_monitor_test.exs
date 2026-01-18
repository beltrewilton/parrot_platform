defmodule ParrotSip.ClusterMonitorTest do
  use ExUnit.Case, async: false

  alias ParrotSip.ClusterMonitor

  describe "start_link/1" do
    test "starts successfully and subscribes to node events" do
      assert {:ok, pid} = ClusterMonitor.start_link()
      assert Process.alive?(pid)
    end

    test "starts with custom name" do
      assert {:ok, pid} = ClusterMonitor.start_link(name: :test_monitor)
      assert Process.whereis(:test_monitor) == pid
      GenServer.stop(pid)
    end
  end

  describe "get_nodes/1" do
    test "returns list of currently connected nodes" do
      {:ok, pid} = ClusterMonitor.start_link()

      # Initially should have the current node's connected nodes
      nodes = ClusterMonitor.get_nodes(pid)
      assert is_list(nodes)

      GenServer.stop(pid)
    end

    test "tracks nodes after nodeup events" do
      {:ok, pid} = ClusterMonitor.start_link()

      # Simulate a node joining
      send(pid, {:nodeup, :node1@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      assert :node1@host in nodes

      GenServer.stop(pid)
    end

    test "removes nodes after nodedown events" do
      {:ok, pid} = ClusterMonitor.start_link()

      # Simulate a node joining then leaving
      send(pid, {:nodeup, :node1@host})
      Process.sleep(10)

      send(pid, {:nodedown, :node1@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      refute :node1@host in nodes

      GenServer.stop(pid)
    end
  end

  describe "nodedown handling" do
    test "handles node failure and logs it" do
      {:ok, pid} = ClusterMonitor.start_link()

      # Add node first
      send(pid, {:nodeup, :failing_node@host})
      Process.sleep(10)

      # Verify node was added
      assert :failing_node@host in ClusterMonitor.get_nodes(pid)

      # Now simulate node failure - this will log at warning level
      send(pid, {:nodedown, :failing_node@host})
      Process.sleep(10)

      # Verify node was removed
      refute :failing_node@host in ClusterMonitor.get_nodes(pid)

      GenServer.stop(pid)
    end

    test "removes node from tracked nodes" do
      {:ok, pid} = ClusterMonitor.start_link()

      # Add multiple nodes
      send(pid, {:nodeup, :node1@host})
      send(pid, {:nodeup, :node2@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      assert :node1@host in nodes
      assert :node2@host in nodes

      # Remove one node
      send(pid, {:nodedown, :node1@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      refute :node1@host in nodes
      assert :node2@host in nodes

      GenServer.stop(pid)
    end
  end

  describe "nodeup handling" do
    test "handles node joining and logs it" do
      {:ok, pid} = ClusterMonitor.start_link()

      initial_nodes = ClusterMonitor.get_nodes(pid)
      refute :new_node@host in initial_nodes

      # Simulate node joining - this will log at info level
      send(pid, {:nodeup, :new_node@host})
      Process.sleep(10)

      # Verify node was added
      assert :new_node@host in ClusterMonitor.get_nodes(pid)

      GenServer.stop(pid)
    end

    test "adds node to tracked nodes" do
      {:ok, pid} = ClusterMonitor.start_link()

      initial_nodes = ClusterMonitor.get_nodes(pid)
      refute :new_node@host in initial_nodes

      send(pid, {:nodeup, :new_node@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      assert :new_node@host in nodes

      GenServer.stop(pid)
    end

    test "handles duplicate nodeup messages" do
      {:ok, pid} = ClusterMonitor.start_link()

      send(pid, {:nodeup, :node1@host})
      send(pid, {:nodeup, :node1@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      # Should only appear once
      assert Enum.count(nodes, &(&1 == :node1@host)) == 1

      GenServer.stop(pid)
    end
  end

  describe "integration" do
    test "handles multiple node events in sequence" do
      {:ok, pid} = ClusterMonitor.start_link()

      # Simulate cluster activity
      send(pid, {:nodeup, :node1@host})
      send(pid, {:nodeup, :node2@host})
      send(pid, {:nodeup, :node3@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      assert :node1@host in nodes
      assert :node2@host in nodes
      assert :node3@host in nodes

      send(pid, {:nodedown, :node2@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      assert :node1@host in nodes
      refute :node2@host in nodes
      assert :node3@host in nodes

      send(pid, {:nodedown, :node1@host})
      send(pid, {:nodedown, :node3@host})
      Process.sleep(10)

      nodes = ClusterMonitor.get_nodes(pid)
      refute :node1@host in nodes
      refute :node2@host in nodes
      refute :node3@host in nodes

      GenServer.stop(pid)
    end
  end
end
