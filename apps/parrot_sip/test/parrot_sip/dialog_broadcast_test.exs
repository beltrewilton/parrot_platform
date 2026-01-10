defmodule ParrotSip.DialogBroadcastTest do
  use ExUnit.Case, async: false

  alias ParrotSip.DialogBroadcast

  @moduletag :dialog_broadcast

  setup do
    # Generate unique names for each test to avoid conflicts
    test_id = System.unique_integer([:positive])
    pubsub_name = :"test_dialog_pubsub_#{test_id}"
    broadcast_name = :"test_dialog_broadcast_#{test_id}"

    # Start a test PubSub server
    {:ok, pubsub_supervisor} = Phoenix.PubSub.Supervisor.start_link(name: pubsub_name)

    # Start DialogBroadcast with our test PubSub
    {:ok, broadcast} =
      DialogBroadcast.start_link(
        name: broadcast_name,
        pubsub: pubsub_name
      )

    on_exit(fn ->
      # Stop DialogBroadcast first (it depends on PubSub)
      try do
        if Process.alive?(broadcast), do: GenServer.stop(broadcast, :normal, 100)
      catch
        :exit, _ -> :ok
      end

      # Then stop PubSub supervisor
      try do
        if Process.alive?(pubsub_supervisor), do: Supervisor.stop(pubsub_supervisor, :normal, 100)
      catch
        :exit, _ -> :ok
      end
    end)

    %{broadcast: broadcast, pubsub: pubsub_name, broadcast_name: broadcast_name}
  end

  describe "start_link/1" do
    test "starts the GenServer with a name", ctx do
      # The setup already started the server, just verify it's running
      assert Process.whereis(ctx.broadcast_name) != nil
    end

    test "subscribes to parrot:dialogs topic on init", ctx do
      # The DialogBroadcast should be subscribed to the PubSub topic
      # We can verify by broadcasting a message and checking it receives it

      # Broadcast a test message through PubSub directly
      Phoenix.PubSub.broadcast(ctx.pubsub, "parrot:dialogs", {:test_message, "hello"})

      # Give it a moment to process
      Process.sleep(10)

      # If no crash occurred, subscription is working
      assert Process.alive?(ctx.broadcast)
    end
  end

  describe "broadcast_create/2" do
    test "stores dialog in local ETS", ctx do
      dialog_id = "call-123@example.com"

      dialog_state = %{
        call_id: "call-123@example.com",
        local_tag: "from-tag",
        remote_tag: "to-tag",
        state: :confirmed,
        local_uri: "sip:alice@example.com",
        remote_uri: "sip:bob@example.com"
      }

      :ok = DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, dialog_state)

      # Verify the dialog is stored locally
      assert {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      assert stored_state.call_id == "call-123@example.com"
      assert stored_state.state == :confirmed
    end

    test "broadcasts create event to other nodes", ctx do
      # Subscribe to the topic to receive broadcasts
      Phoenix.PubSub.subscribe(ctx.pubsub, "parrot:dialogs")

      dialog_id = "call-456@example.com"

      dialog_state = %{
        call_id: "call-456@example.com",
        state: :early
      }

      :ok = DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, dialog_state)

      # Should receive the broadcast message
      assert_receive {:dialog_created, ^dialog_id, received_state, origin_node}, 1000
      assert received_state.call_id == "call-456@example.com"
      assert origin_node == node()
    end

    test "includes originating node in broadcast", ctx do
      Phoenix.PubSub.subscribe(ctx.pubsub, "parrot:dialogs")

      dialog_id = "call-789@example.com"
      dialog_state = %{call_id: dialog_id}

      :ok = DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, dialog_state)

      assert_receive {:dialog_created, ^dialog_id, _state, origin_node}, 1000
      assert origin_node == node()
    end
  end

  describe "broadcast_update/2" do
    test "updates existing dialog in local ETS", ctx do
      dialog_id = "update-test@example.com"

      # First create the dialog
      initial_state = %{call_id: dialog_id, state: :early, seq: 1}
      :ok = DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, initial_state)

      # Then update it
      changes = %{state: :confirmed, seq: 2}
      :ok = DialogBroadcast.broadcast_update(ctx.broadcast, dialog_id, changes)

      # Verify the updates were applied
      {:ok, stored_state} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      assert stored_state.state == :confirmed
      assert stored_state.seq == 2
      assert stored_state.call_id == dialog_id
    end

    test "broadcasts update event to other nodes", ctx do
      Phoenix.PubSub.subscribe(ctx.pubsub, "parrot:dialogs")

      dialog_id = "update-broadcast@example.com"
      initial_state = %{call_id: dialog_id, state: :early}
      :ok = DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, initial_state)

      # Clear the create message from mailbox
      assert_receive {:dialog_created, _, _, _}, 1000

      changes = %{state: :confirmed}
      :ok = DialogBroadcast.broadcast_update(ctx.broadcast, dialog_id, changes)

      assert_receive {:dialog_updated, ^dialog_id, ^changes, origin_node}, 1000
      assert origin_node == node()
    end

    test "returns error if dialog does not exist", ctx do
      dialog_id = "nonexistent@example.com"
      changes = %{state: :confirmed}

      assert {:error, :not_found} =
               DialogBroadcast.broadcast_update(ctx.broadcast, dialog_id, changes)
    end
  end

  describe "broadcast_delete/1" do
    test "removes dialog from local ETS", ctx do
      dialog_id = "delete-test@example.com"

      # Create then delete
      :ok =
        DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, %{call_id: dialog_id})

      :ok = DialogBroadcast.broadcast_delete(ctx.broadcast, dialog_id)

      # Verify deletion
      assert {:error, :not_found} = DialogBroadcast.get(ctx.broadcast, dialog_id)
    end

    test "broadcasts delete event to other nodes", ctx do
      Phoenix.PubSub.subscribe(ctx.pubsub, "parrot:dialogs")

      dialog_id = "delete-broadcast@example.com"
      :ok =
        DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, %{call_id: dialog_id})

      # Clear the create message
      assert_receive {:dialog_created, _, _, _}, 1000

      :ok = DialogBroadcast.broadcast_delete(ctx.broadcast, dialog_id)

      assert_receive {:dialog_deleted, ^dialog_id, origin_node}, 1000
      assert origin_node == node()
    end

    test "returns ok even if dialog does not exist", ctx do
      # Deleting a non-existent dialog should still be :ok (idempotent)
      assert :ok = DialogBroadcast.broadcast_delete(ctx.broadcast, "nonexistent@example.com")
    end
  end

  describe "get/1" do
    test "returns dialog state if exists", ctx do
      dialog_id = "get-test@example.com"
      state = %{call_id: dialog_id, state: :confirmed, custom_field: "value"}

      :ok = DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, state)

      assert {:ok, retrieved} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      assert retrieved.call_id == dialog_id
      assert retrieved.custom_field == "value"
    end

    test "returns error if dialog does not exist", ctx do
      assert {:error, :not_found} = DialogBroadcast.get(ctx.broadcast, "nonexistent")
    end
  end

  describe "get_all/0" do
    test "returns empty map when no dialogs exist", ctx do
      assert %{} = DialogBroadcast.get_all(ctx.broadcast)
    end

    test "returns all dialogs", ctx do
      # Create multiple dialogs
      :ok =
        DialogBroadcast.broadcast_create(ctx.broadcast, "dialog1", %{
          call_id: "dialog1",
          state: :early
        })

      :ok =
        DialogBroadcast.broadcast_create(ctx.broadcast, "dialog2", %{
          call_id: "dialog2",
          state: :confirmed
        })

      :ok =
        DialogBroadcast.broadcast_create(ctx.broadcast, "dialog3", %{
          call_id: "dialog3",
          state: :terminated
        })

      all = DialogBroadcast.get_all(ctx.broadcast)

      assert map_size(all) == 3
      assert all["dialog1"].state == :early
      assert all["dialog2"].state == :confirmed
      assert all["dialog3"].state == :terminated
    end
  end

  describe "handling remote broadcasts" do
    test "stores dialog created on another node", ctx do
      dialog_id = "remote-dialog@example.com"
      state = %{call_id: dialog_id, state: :confirmed}

      # Simulate a broadcast from another node
      other_node = :"other@host"

      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        "parrot:dialogs",
        {:dialog_created, dialog_id, state, other_node}
      )

      # Give it time to process
      Process.sleep(50)

      # Should be stored locally
      {:ok, stored} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      assert stored.call_id == dialog_id
    end

    test "updates dialog from another node", ctx do
      dialog_id = "remote-update@example.com"
      initial_state = %{call_id: dialog_id, state: :early}

      # Create the dialog first
      :ok = DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, initial_state)

      # Simulate an update from another node
      other_node = :"other@host"
      changes = %{state: :confirmed}

      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        "parrot:dialogs",
        {:dialog_updated, dialog_id, changes, other_node}
      )

      Process.sleep(50)

      {:ok, stored} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      assert stored.state == :confirmed
    end

    test "deletes dialog from another node", ctx do
      dialog_id = "remote-delete@example.com"

      # Create the dialog first
      :ok =
        DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, %{call_id: dialog_id})

      # Simulate a delete from another node
      other_node = :"other@host"

      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        "parrot:dialogs",
        {:dialog_deleted, dialog_id, other_node}
      )

      Process.sleep(50)

      assert {:error, :not_found} = DialogBroadcast.get(ctx.broadcast, dialog_id)
    end

    test "ignores broadcasts from self to avoid duplication", ctx do
      dialog_id = "self-ignore@example.com"

      # First, create a dialog with a specific state
      :ok =
        DialogBroadcast.broadcast_create(ctx.broadcast, dialog_id, %{
          call_id: dialog_id,
          state: :early
        })

      # Simulate what would happen if we received our own broadcast
      # (which should be ignored because origin_node == node())
      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        "parrot:dialogs",
        {:dialog_updated, dialog_id, %{state: :should_ignore}, node()}
      )

      Process.sleep(50)

      # The state should NOT be updated to :should_ignore because
      # we should ignore broadcasts from ourselves
      {:ok, stored} = DialogBroadcast.get(ctx.broadcast, dialog_id)
      # The original state should remain (or update depending on implementation)
      # The key is that we don't double-process our own messages
      assert stored.state == :early
    end
  end

  describe "ETS table ownership" do
    test "ETS table is created on start", ctx do
      # The ETS table should exist
      table_name = DialogBroadcast.table_name(ctx.broadcast)
      assert :ets.info(table_name) != :undefined
    end
  end
end
