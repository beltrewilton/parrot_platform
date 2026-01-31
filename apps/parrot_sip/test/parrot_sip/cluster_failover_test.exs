defmodule ParrotSip.ClusterFailoverTest do
  @moduledoc """
  Integration tests for cluster failover scenario.
  Tests ClusterMonitor, DialogBroadcast, and DialogStatem recovery together.

  This test suite verifies that the cluster failover components work together to:
  1. Store dialog state in DialogBroadcast
  2. Detect node failures via ClusterMonitor
  3. Recover dialogs from stored state using DialogStatem.start_recovered/1
  4. Ensure recovered dialogs are functional

  These are integration tests that verify end-to-end failover scenarios.
  Individual unit tests for each component exist in their respective test files.
  """
  use ExUnit.Case, async: false

  alias ParrotSip.{ClusterMonitor, DialogBroadcast, DialogStatem, Message}
  alias ParrotSip.Headers.{Via, From, To, Contact, CSeq}

  @moduletag :cluster_failover

  # Test setup: Start required infrastructure
  setup do
    # Generate unique names for this test run
    test_id = System.unique_integer([:positive])
    pubsub_name = :"test_pubsub_#{test_id}"

    # Stop existing processes if they exist (from previous test)
    try do
      if pid = Process.whereis(:dialog_broadcast) do
        GenServer.stop(pid, :normal, 100)
      end
    catch
      :exit, _ -> :ok
    end

    # Start Phoenix.PubSub for DialogBroadcast
    {:ok, pubsub_supervisor} = Phoenix.PubSub.Supervisor.start_link(name: pubsub_name)

    # Start DialogBroadcast with the hardcoded name :dialog_broadcast
    # that DialogStatem expects
    {:ok, broadcast_pid} =
      DialogBroadcast.start_link(
        name: :dialog_broadcast,
        pubsub: pubsub_name
      )

    # Start ClusterMonitor
    {:ok, monitor_pid} = ClusterMonitor.start_link()

    on_exit(fn ->
      # Clean up in reverse order, catching exits
      try do
        if Process.alive?(monitor_pid), do: GenServer.stop(monitor_pid, :normal, 100)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(broadcast_pid), do: GenServer.stop(broadcast_pid, :normal, 100)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(pubsub_supervisor), do: Supervisor.stop(pubsub_supervisor, :normal, 100)
      catch
        :exit, _ -> :ok
      end
    end)

    %{
      pubsub: pubsub_name,
      broadcast: broadcast_pid,
      monitor: monitor_pid
    }
  end

  # ===========================================================================
  # Test Helpers - Public API wrappers
  # ===========================================================================

  # Assert the dialog state
  defp assert_state(pid, expected_state) do
    actual_state = DialogStatem.get_state(pid)

    assert actual_state == expected_state,
           "Expected state #{inspect(expected_state)}, got #{inspect(actual_state)}"
  end

  # Get the dialog ID
  defp get_dialog_id(pid) do
    {:ok, id} = DialogStatem.get_dialog_id(pid)
    id
  end

  # Get the full dialog data
  defp get_dialog_data(pid) do
    {:ok, dialog} = DialogStatem.get_dialog_data(pid)
    dialog
  end

  # Check if dialog was recovered
  defp is_recovered?(pid) do
    {:ok, recovered} = DialogStatem.is_recovered?(pid)
    recovered
  end

  describe "round-trip storage - DialogBroadcast integration" do
    test "dialog state can be stored and retrieved from DialogBroadcast", ctx do
      # Create a confirmed dialog
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, dialog_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      # Get the dialog state from the running dialog
      assert_state(dialog_pid, :confirmed)

      dialog_id = get_dialog_id(dialog_pid)
      dialog = get_dialog_data(dialog_pid)

      # Verify state was automatically broadcast to DialogBroadcast
      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)

      # Verify all essential fields are present
      assert stored_state.call_id == dialog.call_id
      assert stored_state.local_tag == dialog.local_tag
      assert stored_state.remote_tag == dialog.remote_tag
      assert stored_state.state == :confirmed
      assert stored_state.owner_node == node()
    end

    test "stored dialog state contains all required recovery fields", ctx do
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, dialog_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      dialog_id = get_dialog_id(dialog_pid)
      dialog = get_dialog_data(dialog_pid)

      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)

      # Verify stored state matches dialog state fields
      assert stored_state.call_id == dialog.call_id
      assert stored_state.local_tag == dialog.local_tag
      assert stored_state.remote_tag == dialog.remote_tag
      assert stored_state.state == :confirmed
    end

    test "multiple dialogs can be stored and retrieved independently", ctx do
      # Create three different dialogs
      dialogs =
        for i <- 1..3 do
          call_id = "test-call-#{i}-#{:erlang.unique_integer([:positive])}@example.com"
          invite = build_invite_with_call_id(call_id)
          response = build_response_with_call_id(200, "OK", call_id)
          {:ok, pid} = DialogStatem.start_link({:uas, response, invite})
          Process.sleep(50)
          dialog_id = get_dialog_id(pid)
          {pid, dialog_id}
        end

      # Verify all three are stored in DialogBroadcast
      all_dialogs = DialogBroadcast.get_all(ctx.broadcast)
      assert map_size(all_dialogs) >= 3

      # Verify each dialog can be retrieved individually
      for {_pid, dialog_id} <- dialogs do
        assert {:ok, _stored} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      end
    end
  end

  describe "recovery flow - DialogStatem.start_recovered/1 integration" do
    test "dialog can be recovered from DialogBroadcast stored state", ctx do
      # Create and confirm a dialog
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, original_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      # Get the dialog ID and retrieve stored state
      dialog_id = get_dialog_id(original_pid)
      dialog = get_dialog_data(original_pid)

      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)

      # Simulate node failure by stopping the original dialog
      GenServer.stop(original_pid)
      Process.sleep(10)

      # Build recovery state from stored state
      recovery_state = %{
        call_id: stored_state.call_id,
        local_tag: stored_state.local_tag,
        remote_tag: stored_state.remote_tag,
        local_uri: dialog.local_uri,
        remote_uri: dialog.remote_uri,
        local_seq: dialog.local_seq,
        remote_seq: dialog.remote_seq,
        secure: dialog.secure,
        route_set: dialog.route_set
      }

      # Recover the dialog
      assert {:ok, recovered_pid} = DialogStatem.start_recovered(recovery_state)
      assert Process.alive?(recovered_pid)

      # Verify recovered dialog is in confirmed state
      assert_state(recovered_pid, :confirmed)
      assert is_recovered?(recovered_pid) == true
    end

    test "recovered dialog has same dialog ID as original", ctx do
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, original_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      original_dialog_id = get_dialog_id(original_pid)
      original_dialog = get_dialog_data(original_pid)

      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, original_dialog_id)

      # Stop original
      GenServer.stop(original_pid)
      Process.sleep(10)

      # Recover
      recovery_state = %{
        call_id: stored_state.call_id,
        local_tag: stored_state.local_tag,
        remote_tag: stored_state.remote_tag,
        local_uri: original_dialog.local_uri,
        remote_uri: original_dialog.remote_uri,
        local_seq: original_dialog.local_seq,
        remote_seq: original_dialog.remote_seq,
        secure: false,
        route_set: []
      }

      {:ok, recovered_pid} = DialogStatem.start_recovered(recovery_state)

      recovered_dialog_id = get_dialog_id(recovered_pid)

      # Dialog IDs should match
      assert recovered_dialog_id == original_dialog_id
    end

    test "multiple dialogs can be recovered simultaneously", ctx do
      # Create multiple dialogs
      original_dialogs =
        for i <- 1..3 do
          call_id = "multi-call-#{i}-#{:erlang.unique_integer([:positive])}@example.com"
          invite = build_invite_with_call_id(call_id)
          response = build_response_with_call_id(200, "OK", call_id)
          {:ok, pid} = DialogStatem.start_link({:uas, response, invite})
          Process.sleep(50)
          dialog_id = get_dialog_id(pid)
          dialog = get_dialog_data(pid)
          {pid, dialog_id, dialog}
        end

      # Simulate node failure - stop all original dialogs
      for {pid, _id, _dialog} <- original_dialogs do
        GenServer.stop(pid)
      end

      Process.sleep(50)

      # Recover all dialogs
      recovered_pids =
        for {_original_pid, dialog_id, dialog} <- original_dialogs do
          {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)

          recovery_state = %{
            call_id: stored_state.call_id,
            local_tag: stored_state.local_tag,
            remote_tag: stored_state.remote_tag,
            local_uri: dialog.local_uri,
            remote_uri: dialog.remote_uri,
            local_seq: dialog.local_seq,
            remote_seq: dialog.remote_seq,
            secure: false,
            route_set: []
          }

          {:ok, pid} = DialogStatem.start_recovered(recovery_state)
          pid
        end

      # Verify all recovered dialogs are running
      assert length(recovered_pids) == 3

      for pid <- recovered_pids do
        assert Process.alive?(pid)
        assert_state(pid, :confirmed)
      end
    end
  end

  describe "functional recovery - recovered dialog can handle requests" do
    test "recovered dialog can process incoming BYE request", ctx do
      # Create original dialog
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, original_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      original_dialog_id = get_dialog_id(original_pid)
      original_dialog = get_dialog_data(original_pid)
      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, original_dialog_id)

      # Stop original
      GenServer.stop(original_pid)
      Process.sleep(10)

      # Recover
      recovery_state = %{
        call_id: stored_state.call_id,
        local_tag: stored_state.local_tag,
        remote_tag: stored_state.remote_tag,
        local_uri: original_dialog.local_uri,
        remote_uri: original_dialog.remote_uri,
        local_seq: original_dialog.local_seq,
        remote_seq: original_dialog.remote_seq,
        secure: false,
        route_set: []
      }

      {:ok, recovered_pid} = DialogStatem.start_recovered(recovery_state)

      # Build BYE request matching recovered dialog
      bye_msg = %Message{
        type: :request,
        method: :bye,
        request_uri: original_dialog.local_uri,
        version: "SIP/2.0",
        via: %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-bye-recovered"}
        },
        from: %From{
          uri: original_dialog.remote_uri,
          parameters: %{"tag" => original_dialog.remote_tag}
        },
        to: %To{
          uri: original_dialog.local_uri,
          parameters: %{"tag" => original_dialog.local_tag}
        },
        call_id: original_dialog.call_id,
        cseq: %CSeq{number: original_dialog.remote_seq + 1, method: :bye},
        other_headers: %{},
        body: ""
      }

      # Send BYE to recovered dialog
      assert :process = :gen_statem.call(recovered_pid, {:uas_request, bye_msg})

      # Dialog should transition to terminated and eventually stop
      Process.sleep(100)
    end

    test "recovered dialog can create outbound UAC request", ctx do
      # Create original dialog
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, original_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      original_dialog_id = get_dialog_id(original_pid)
      original_dialog = get_dialog_data(original_pid)
      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, original_dialog_id)

      # Stop original
      GenServer.stop(original_pid)
      Process.sleep(10)

      # Recover
      recovery_state = %{
        call_id: stored_state.call_id,
        local_tag: stored_state.local_tag,
        remote_tag: stored_state.remote_tag,
        local_uri: original_dialog.local_uri,
        remote_uri: original_dialog.remote_uri,
        local_seq: original_dialog.local_seq,
        remote_seq: original_dialog.remote_seq,
        secure: false,
        route_set: []
      }

      {:ok, recovered_pid} = DialogStatem.start_recovered(recovery_state)

      recovered_dialog_id = get_dialog_id(recovered_pid)

      # Create outbound BYE request
      bye_template = %Message{method: :bye}

      assert {:ok, bye_request} = DialogStatem.uac_request(recovered_dialog_id, bye_template)
      assert %Message{} = bye_request
      assert bye_request.method == :bye
      assert bye_request.call_id == stored_state.call_id
    end

    test "recovered dialog maintains correct sequence numbers", ctx do
      # Create dialog with specific sequence numbers
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, original_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      original_dialog_id = get_dialog_id(original_pid)
      original_dialog = get_dialog_data(original_pid)
      original_local_seq = original_dialog.local_seq
      original_remote_seq = original_dialog.remote_seq

      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, original_dialog_id)

      # Stop and recover
      GenServer.stop(original_pid)
      Process.sleep(10)

      recovery_state = %{
        call_id: stored_state.call_id,
        local_tag: stored_state.local_tag,
        remote_tag: stored_state.remote_tag,
        local_uri: original_dialog.local_uri,
        remote_uri: original_dialog.remote_uri,
        local_seq: original_local_seq,
        remote_seq: original_remote_seq,
        secure: false,
        route_set: []
      }

      {:ok, recovered_pid} = DialogStatem.start_recovered(recovery_state)

      # Verify sequence numbers are preserved
      recovered_dialog = get_dialog_data(recovered_pid)
      assert recovered_dialog.local_seq == original_local_seq
      assert recovered_dialog.remote_seq == original_remote_seq
    end
  end

  describe "end-to-end failover - ClusterMonitor integration" do
    test "ClusterMonitor detects nodedown events", ctx do
      # Simulate a node joining
      send(ctx.monitor, {:nodeup, :test_node@host})
      Process.sleep(10)

      # Verify node is tracked
      nodes = ClusterMonitor.get_nodes(ctx.monitor)
      assert :test_node@host in nodes

      # Simulate node failure
      send(ctx.monitor, {:nodedown, :test_node@host})
      Process.sleep(10)

      # Verify node is removed
      nodes = ClusterMonitor.get_nodes(ctx.monitor)
      refute :test_node@host in nodes
    end

    test "dialogs can be found in DialogBroadcast for failed node", ctx do
      # Create dialogs tagged with a specific node
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, dialog_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      # Get all dialogs from DialogBroadcast
      all_dialogs = DialogBroadcast.get_all(ctx.broadcast)

      # Verify we can filter dialogs by owner_node
      local_dialogs =
        all_dialogs
        |> Enum.filter(fn {_id, state} -> state.owner_node == node() end)

      assert length(local_dialogs) >= 1

      # Cleanup
      GenServer.stop(dialog_pid)
    end

    test "simulated failover: nodedown -> find orphaned dialogs -> recover them", ctx do
      # Step 1: Create dialogs on "remote" node (simulated)
      remote_node = :remote@host

      # Create local dialog and manually update its owner_node in broadcast
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, original_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      dialog_id = get_dialog_id(original_pid)
      original_dialog = get_dialog_data(original_pid)

      # Update the stored state to simulate it came from remote node
      {:ok, _stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      :ok = DialogBroadcast.broadcast_update(ctx.broadcast, dialog_id, %{owner_node: remote_node})

      Process.sleep(50)

      # Step 2: Simulate node failure
      send(ctx.monitor, {:nodeup, remote_node})
      Process.sleep(10)
      send(ctx.monitor, {:nodedown, remote_node})
      Process.sleep(10)

      # Step 3: Find orphaned dialogs
      all_dialogs = DialogBroadcast.get_all(ctx.broadcast)

      orphaned_dialogs =
        all_dialogs
        |> Enum.filter(fn {_id, state} ->
          Map.get(state, :owner_node) == remote_node
        end)

      assert length(orphaned_dialogs) >= 1

      # Step 4: Stop original dialog to simulate actual failure
      GenServer.stop(original_pid)
      Process.sleep(10)

      # Step 5: Recover the orphaned dialog
      {_orphaned_id, orphaned_state} = hd(orphaned_dialogs)

      recovery_state = %{
        call_id: orphaned_state.call_id,
        local_tag: orphaned_state.local_tag,
        remote_tag: orphaned_state.remote_tag,
        local_uri: original_dialog.local_uri,
        remote_uri: original_dialog.remote_uri,
        local_seq: original_dialog.local_seq,
        remote_seq: original_dialog.remote_seq,
        secure: false,
        route_set: []
      }

      {:ok, recovered_pid} = DialogStatem.start_recovered(recovery_state)

      # Step 6: Verify recovery was successful
      assert Process.alive?(recovered_pid)
      assert_state(recovered_pid, :confirmed)
      assert is_recovered?(recovered_pid) == true
    end
  end

  describe "edge cases and error handling" do
    test "recovery handles missing optional fields gracefully" do
      # Test recovery with minimal required fields
      minimal_state = %{
        call_id: "minimal-#{:erlang.unique_integer([:positive])}@example.com",
        local_tag: "local-tag-minimal",
        remote_tag: "remote-tag-minimal",
        local_uri: "sip:local@example.com",
        remote_uri: "sip:remote@example.com",
        local_seq: 1,
        remote_seq: 1
        # Missing: secure, route_set, remote_target, local_host, local_port, transport
      }

      assert {:ok, pid} = DialogStatem.start_recovered(minimal_state)
      assert Process.alive?(pid)

      assert_state(pid, :confirmed)
      dialog = get_dialog_data(pid)
      assert dialog.secure == false
      assert dialog.route_set == []
    end

    test "recovery handles all optional fields when present" do
      full_state = %{
        call_id: "full-#{:erlang.unique_integer([:positive])}@example.com",
        local_tag: "local-tag-full",
        remote_tag: "remote-tag-full",
        local_uri: "sip:local@example.com",
        remote_uri: "sip:remote@example.com",
        remote_target: "sip:target@example.com",
        local_seq: 5,
        remote_seq: 3,
        route_set: ["<sip:proxy1.example.com>", "<sip:proxy2.example.com>"],
        secure: true,
        local_host: "192.168.1.100",
        local_port: 5060,
        transport: :tcp
      }

      assert {:ok, pid} = DialogStatem.start_recovered(full_state)
      assert Process.alive?(pid)

      assert_state(pid, :confirmed)
      dialog = get_dialog_data(pid)
      assert dialog.secure == true
      assert dialog.route_set == ["<sip:proxy1.example.com>", "<sip:proxy2.example.com>"]
      assert dialog.local_host == "192.168.1.100"
      assert dialog.local_port == 5060
      assert dialog.transport == :tcp
    end

    test "DialogBroadcast gracefully handles dialog deletion after recovery", ctx do
      call_id = unique_call_id()
      invite = build_invite_with_call_id(call_id)
      response = build_response_with_call_id(200, "OK", call_id)
      {:ok, original_pid} = DialogStatem.start_link({:uas, response, invite})

      Process.sleep(50)

      dialog_id = get_dialog_id(original_pid)
      original_dialog = get_dialog_data(original_pid)

      # Verify dialog is stored
      assert {:ok, _} = DialogBroadcast.get(ctx.broadcast, dialog_id)

      # Stop original
      GenServer.stop(original_pid)
      Process.sleep(10)

      # Dialog should still be in broadcast even after original stopped
      assert {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)

      # Recover
      recovery_state = %{
        call_id: stored_state.call_id,
        local_tag: stored_state.local_tag,
        remote_tag: stored_state.remote_tag,
        local_uri: original_dialog.local_uri,
        remote_uri: original_dialog.remote_uri,
        local_seq: original_dialog.local_seq,
        remote_seq: original_dialog.remote_seq,
        secure: false,
        route_set: []
      }

      {:ok, recovered_pid} = DialogStatem.start_recovered(recovery_state)

      # Manually delete from broadcast to simulate cleanup
      :ok = DialogBroadcast.broadcast_delete(ctx.broadcast, dialog_id)
      Process.sleep(10)

      # Verify deletion
      assert {:error, :not_found} = DialogBroadcast.get(ctx.broadcast, dialog_id)

      # Recovered dialog should still be alive
      assert Process.alive?(recovered_pid)
    end
  end

  # Helper functions

  defp unique_call_id do
    "failover-test-#{:erlang.unique_integer([:positive])}@example.com"
  end

  defp build_invite_with_call_id(call_id) do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:user@example.com",
      version: "SIP/2.0",
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-#{call_id}"}
      },
      from: %From{
        display_name: "Test User",
        uri: "sip:test@example.com",
        parameters: %{"tag" => "test-from-tag"}
      },
      to: %To{
        display_name: "Target User",
        uri: "sip:target@example.com",
        parameters: %{}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :invite},
      contact: %Contact{
        uri: "sip:test@127.0.0.1:5060",
        parameters: %{}
      },
      other_headers: %{},
      body:
        "v=0\r\no=test 123 456 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 8000 RTP/AVP 0\r\n"
    }
  end

  defp build_response_with_call_id(status, reason, call_id) do
    %Message{
      type: :response,
      method: nil,
      request_uri: nil,
      version: "SIP/2.0",
      status_code: status,
      reason_phrase: reason,
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bK-#{call_id}"}
      },
      from: %From{
        display_name: "Test User",
        uri: "sip:test@example.com",
        parameters: %{"tag" => "test-from-tag"}
      },
      to: %To{
        display_name: "Target User",
        uri: "sip:target@example.com",
        parameters: %{"tag" => "test-to-tag"}
      },
      call_id: call_id,
      cseq: %CSeq{number: 1, method: :invite},
      other_headers: %{},
      body: ""
    }
  end
end
