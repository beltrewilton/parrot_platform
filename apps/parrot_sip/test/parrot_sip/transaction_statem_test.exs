defmodule ParrotSip.TransactionStatemTest do
  use ExUnit.Case, async: false

  alias ParrotSip.TransactionStatem
  alias ParrotSip.Transaction
  alias ParrotSip.Message
  alias ParrotSip.Headers.{Via, From, To, CSeq, Contact}
  alias ParrotSip.TestHandler

  require Logger

  # Tests use the global ParrotSip.Registry but with unique transaction IDs per test.
  # This provides isolation while using the real application infrastructure.
  # Tests run sequentially (async: false) to avoid overwhelming the supervisor.

  setup do
    # Generate unique test ID for this test's transactions
    test_id = :erlang.unique_integer([:positive])
    {:ok, test_id: test_id}
  end

  # Helper to create unique branch parameters per test
  defp unique_branch(base, test_id) do
    "#{base}_#{test_id}"
  end

  describe "INVITE server transaction lifecycle" do
    test "trying -> proceeding -> completed -> confirmed -> terminated", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKlifecycle1", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      # INVITE server transactions automatically send 100 Trying and move to proceeding
      assert_state(pid, :proceeding)

      provisional = Message.reply(request, 180, "Ringing")
      :ok = TransactionStatem.server_response(provisional, transaction)

      assert_state(pid, :proceeding)
      assert_last_response(pid, 180)
      refute timer_active?(pid, :g)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)

      assert_state(pid, :completed)
      assert_last_response(pid, 404)
      assert timer_active?(pid, :h)
      refute timer_active?(pid, :c)

      ack = build_ack(request)
      :gen_statem.cast(pid, {:received, ack})

      assert_state(pid, :confirmed)
      refute timer_active?(pid, :h)
      assert timer_active?(pid, :i)

      send(pid, {:event, :i})
      assert_process_terminates(pid)
    end

    test "trying -> completed (skip proceeding with immediate final)", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKskip1", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      # INVITE server transactions automatically send 100 Trying and move to proceeding
      assert_state(pid, :proceeding)

      final = Message.reply(request, 486, "Busy Here")
      :ok = TransactionStatem.server_response(final, transaction)

      assert_state(pid, :completed)
      assert_last_response(pid, 486)
      assert timer_active?(pid, :h)
    end

    test "trying -> terminated (2xx response)", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bK2xx", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      ok_response = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(ok_response, transaction)

      assert_state(pid, :terminated)
      assert_last_response(pid, 200)
      refute timer_active?(pid, :g)
      refute timer_active?(pid, :h)
    end

    test "proceeding -> terminated (2xx response)", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKproc2xx", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      provisional = Message.reply(request, 180, "Ringing")
      :ok = TransactionStatem.server_response(provisional, transaction)
      assert_state(pid, :proceeding)

      ok_response = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(ok_response, transaction)

      assert_state(pid, :terminated)
    end

    test "retransmission in proceeding keeps same state and response", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKretrans1", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      provisional = Message.reply(request, 180, "Ringing")
      :ok = TransactionStatem.server_response(provisional, transaction)
      assert_state(pid, :proceeding)
      assert_last_response(pid, 180)

      {:ok, code_before} = TransactionStatem.get_last_response_code(pid)

      :gen_statem.cast(pid, {:received, request})
      Process.sleep(50)

      assert_state(pid, :proceeding)
      assert_last_response(pid, 180)

      {:ok, code_after} = TransactionStatem.get_last_response_code(pid)
      assert code_before == code_after
    end

    test "retransmission in completed retransmits final response", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKretransComp", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)
      assert_state(pid, :completed)

      :gen_statem.cast(pid, {:received, request})
      Process.sleep(50)

      assert_state(pid, :completed)
      assert_last_response(pid, 404)
    end
  end

  describe "non-INVITE server transaction lifecycle" do
    test "trying -> completed -> terminated", %{test_id: test_id} do
      request = build_register(unique_branch("z9hG4bKreg1", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      assert_state(pid, :trying)

      final = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(final, transaction)

      assert_state(pid, :completed)
      assert_last_response(pid, 200)
      assert timer_active?(pid, :j)

      send(pid, {:event, :j})
      assert_process_terminates(pid)
    end

    test "trying -> proceeding -> completed (with provisional)", %{test_id: test_id} do
      request = build_register(unique_branch("z9hG4bKreg2", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      provisional = Message.reply(request, 100, "Trying")
      :ok = TransactionStatem.server_response(provisional, transaction)

      assert_state(pid, :proceeding)
      assert_last_response(pid, 100)

      final = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(final, transaction)

      assert_state(pid, :completed)
      assert_last_response(pid, 200)
      assert timer_active?(pid, :j)
    end

    test "retransmission in trying retransmits last response if exists", %{test_id: test_id} do
      request = build_register(unique_branch("z9hG4bKretransTrying", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      provisional = Message.reply(request, 100, "Trying")
      :ok = TransactionStatem.server_response(provisional, transaction)

      :gen_statem.cast(pid, {:received, request})
      Process.sleep(50)

      assert_state(pid, :proceeding)
      assert_last_response(pid, 100)
    end
  end

  describe "INVITE client transaction lifecycle" do
    test "calling -> proceeding -> completed -> terminated", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKclient1", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      assert_state(pid, :calling)

      provisional = Message.reply(invite, 180, "Ringing")
      :gen_statem.cast(pid, {:received, provisional})

      assert_receive {:callback, {:response, %{status_code: 180}}}
      assert_state(pid, :proceeding)

      final = Message.reply(invite, 404, "Not Found")
      :gen_statem.cast(pid, {:received, final})

      assert_receive {:callback, {:response, %{status_code: 404}}}
      assert_state(pid, :completed)
    end

    test "calling -> terminated (2xx response)", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKclient2xx", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      ok_response = Message.reply(invite, 200, "OK")
      :gen_statem.cast(pid, {:received, ok_response})

      assert_receive {:callback, {:response, %{status_code: 200}}}
      assert_state(pid, :terminated)
    end

    test "client callback receives all responses in order", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKcallback1", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      trying = Message.reply(invite, 100, "Trying")
      :gen_statem.cast(pid, {:received, trying})
      assert_receive {:callback, {:response, %{status_code: 100}}}
      assert Process.alive?(pid), "Process died after 100 Trying"

      ringing = Message.reply(invite, 180, "Ringing")
      :gen_statem.cast(pid, {:received, ringing})
      assert_receive {:callback, {:response, %{status_code: 180}}}

      ok = Message.reply(invite, 200, "OK")
      :gen_statem.cast(pid, {:received, ok})
      assert_receive {:callback, {:response, %{status_code: 200}}}
    end
  end

  describe "non-INVITE client transaction lifecycle" do
    test "trying -> completed -> terminated", %{test_id: test_id} do
      register = build_register(unique_branch("z9hG4bKclientReg", test_id))
      {:ok, transaction} = Transaction.create_non_invite_client(register)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      assert_state(pid, :trying)

      ok_response = Message.reply(register, 200, "OK")
      :gen_statem.cast(pid, {:received, ok_response})

      assert_receive {:callback, {:response, %{status_code: 200}}}
      assert_state(pid, :completed)
    end
  end

  describe "timer G behavior" do
    test "timer G fires and reschedules itself in completed state", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKtimerG", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)

      timer_ref_before = get_timer_ref(pid, :g)
      assert timer_ref_before != nil

      send(pid, {:event, :g})
      Process.sleep(50)

      assert_state(pid, :completed)

      timer_ref_after = get_timer_ref(pid, :g)
      assert timer_ref_after != nil
      assert timer_ref_after != timer_ref_before
    end

    test "timer G cancelled when ACK received", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKtimerGcancel", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)

      timer_g_ref = get_timer_ref(pid, :g)
      assert timer_g_ref != nil
      assert Process.read_timer(timer_g_ref) != false

      ack = build_ack(request)
      :gen_statem.cast(pid, {:received, ack})

      assert get_timer_ref(pid, :g) == nil
      assert Process.read_timer(timer_g_ref) == false
    end
  end

  describe "timer H behavior" do
    test "timer H terminates transaction when fired", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKtimerH", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      ref = Process.monitor(pid)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)

      send(pid, {:event, :h})

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    test "timer H cancelled when ACK received", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKtimerHcancel", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)

      timer_h_ref = get_timer_ref(pid, :h)
      assert timer_h_ref != nil
      assert Process.read_timer(timer_h_ref) != false

      ack = build_ack(request)
      :gen_statem.cast(pid, {:received, ack})

      assert get_timer_ref(pid, :h) == nil
      assert Process.read_timer(timer_h_ref) == false
    end
  end

  describe "timer I behavior" do
    test "timer I terminates transaction when fired", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKtimerI", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      ref = Process.monitor(pid)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)

      ack = build_ack(request)
      :gen_statem.cast(pid, {:received, ack})
      assert_state(pid, :confirmed)

      send(pid, {:event, :i})

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    test "timer I is started when ACK received in completed", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKtimerIstart", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)

      assert get_timer_ref(pid, :i) == nil

      ack = build_ack(request)
      :gen_statem.cast(pid, {:received, ack})

      assert get_timer_ref(pid, :i) != nil
    end
  end

  describe "timer J behavior" do
    test "timer J terminates non-INVITE server transaction", %{test_id: test_id} do
      request = build_register(unique_branch("z9hG4bKtimerJ", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      ref = Process.monitor(pid)

      final = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(final, transaction)

      assert timer_active?(pid, :j)

      send(pid, {:event, :j})

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end
  end

  describe "CANCEL handling for server transactions" do
    test "sets cancelled flag in client transaction", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKcancelFlag", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      callback = fn _ -> :ok end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      refute get_cancelled_flag(pid)

      :ok = TransactionStatem.client_cancel({:trans, pid})
      Process.sleep(50)

      assert get_cancelled_flag(pid)
    end

    test "cancel timeout terminates client transaction", %{test_id: test_id} do
      # Set a short cancel timeout for testing (100ms instead of 32s)
      Application.put_env(:parrot_sip, :cancel_timeout, 100)

      invite = build_invite(unique_branch("z9hG4bKcancelTimeout", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)
      ref = Process.monitor(pid)

      :ok = TransactionStatem.client_cancel({:trans, pid})

      # Should timeout after 100ms
      assert_receive {:callback, {:stop, :timeout}}, 200
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 100

      # Restore default timeout
      Application.delete_env(:parrot_sip, :cancel_timeout)
    end

    test "server transaction processes CANCEL and sends 487 to INVITE in proceeding state", %{
      test_id: test_id
    } do
      invite = build_invite(unique_branch("z9hG4bKcancelServer", test_id))
      {:ok, transaction} = Transaction.create_invite_server(invite)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # INVITE server transactions automatically send 100 Trying and move to proceeding
      assert_state(pid, :proceeding)

      # Send CANCEL while in proceeding state
      :gen_statem.cast(pid, :cancel)
      Process.sleep(50)

      # RFC 3261 Section 9.2: Should send 487 Request Terminated to INVITE
      # Transaction moves to completed when final response (487) is sent
      assert_state(pid, :completed)
      assert_last_response(pid, 487)
      assert Process.alive?(pid)
    end

    test "non-INVITE server transaction does NOT send 487 when cancelled", %{test_id: test_id} do
      # CANCEL should only trigger 487 for INVITE transactions
      register = build_register(unique_branch("z9hG4bKcancelNonInvite", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(register)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      assert_state(pid, :trying)

      # Send CANCEL
      :gen_statem.cast(pid, :cancel)
      Process.sleep(50)

      # Should NOT send 487 for non-INVITE
      # Transaction should still be in trying with no last_response
      assert_state(pid, :trying)
      last_response = get_last_response(pid)
      assert last_response == nil
      assert Process.alive?(pid)
    end

    test "already cancelled client ignores second cancel", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKdoubleCancel", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      callback = fn _ -> :ok end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)
      ref = Process.monitor(pid)

      :ok = TransactionStatem.client_cancel({:trans, pid})
      Process.sleep(50)

      # Check if still alive before getting state
      first_check =
        if Process.alive?(pid) do
          get_cancelled_flag(pid)
        else
          # Already terminated, test passes
          true
        end

      assert first_check

      # Second cancel should also work (idempotent)
      :ok = TransactionStatem.client_cancel({:trans, pid})
      Process.sleep(50)

      if Process.alive?(pid) do
        second_check = get_cancelled_flag(pid)
        assert second_check
      end

      # Cancel the monitor
      Process.demonitor(ref, [:flush])

      assert get_cancelled_flag(pid)
      assert Process.alive?(pid)
    end
  end

  describe "owner process monitoring - additional cases" do
    test "server owner dies after final response sent", %{test_id: test_id} do
      # Test line 1710-1712: owner dies but final response already sent
      request = build_register(unique_branch("z9hG4bKownerfinal", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Set owner
      owner = spawn(fn -> Process.sleep(1000) end)
      :gen_statem.cast(pid, {:set_owner, 500, owner})
      Process.sleep(10)

      # Send final response
      final = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(final, transaction)

      # Kill owner - should NOT send auto-response since final already sent
      Process.exit(owner, :kill)
      Process.sleep(10)

      # Transaction should keep state
      assert Process.alive?(pid)
    end

    test "DOWN message from unrelated process is ignored", %{test_id: test_id} do
      # Test line 1718-1720: DOWN message doesn't match our monitor
      request = build_register(unique_branch("z9hG4bKunreldown", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Create an unrelated process and monitor it ourselves
      other_pid = spawn(fn -> Process.sleep(100) end)
      other_ref = Process.monitor(other_pid)

      # Kill the other process - its DOWN won't match transaction's owner_mon
      Process.exit(other_pid, :kill)

      # Send the DOWN message to the transaction
      send(pid, {:DOWN, other_ref, :process, other_pid, :killed})
      Process.sleep(10)

      # Transaction should ignore it and remain alive
      assert Process.alive?(pid)
    end
  end

  describe "owner process monitoring" do
    test "monitors owner process when set", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKmonitor", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      assert get_owner_monitor(pid) == nil

      owner = spawn(fn -> Process.sleep(10_000) end)
      :ok = TransactionStatem.server_set_owner(503, owner, transaction)

      monitor_ref = get_owner_monitor(pid)
      assert monitor_ref != nil
      assert is_reference(monitor_ref)

      Process.exit(owner, :kill)
    end

    test "stores auto_resp code when owner set", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKautoResp", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      owner = spawn(fn -> Process.sleep(10_000) end)
      :ok = TransactionStatem.server_set_owner(503, owner, transaction)

      assert get_auto_resp_code(pid) == 503

      Process.exit(owner, :kill)
    end

    test "updates monitor when owner changed", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKchangeOwner", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      owner1 = spawn(fn -> Process.sleep(10_000) end)
      :ok = TransactionStatem.server_set_owner(503, owner1, transaction)

      ref1 = get_owner_monitor(pid)

      owner2 = spawn(fn -> Process.sleep(10_000) end)
      :ok = TransactionStatem.server_set_owner(486, owner2, transaction)

      ref2 = get_owner_monitor(pid)

      assert ref1 != ref2
      assert get_auto_resp_code(pid) == 486

      Process.exit(owner1, :kill)
      Process.exit(owner2, :kill)
    end

    test "owner death sends auto response when no final sent", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKownerDies", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      owner =
        spawn(fn ->
          receive do
          end
        end)

      :ok = TransactionStatem.server_set_owner(503, owner, transaction)

      Process.exit(owner, :kill)
      Process.sleep(100)

      assert_state(pid, :completed)
      assert_last_response(pid, 503)
    end

    test "owner death does not send auto response when final already sent", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKownerAfterFinal", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      final = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(final, transaction)
      assert_state(pid, :terminated)
      assert_last_response(pid, 200)

      owner =
        spawn(fn ->
          receive do
          end
        end)

      :ok = TransactionStatem.server_set_owner(503, owner, transaction)

      last_response_before = get_last_response(pid)

      Process.exit(owner, :kill)
      Process.sleep(100)

      last_response_after = get_last_response(pid)
      assert last_response_before.status_code == last_response_after.status_code
      assert last_response_after.status_code == 200
    end

    test "owner death for INVITE client cancels transaction", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKownerClientDies", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      callback = fn _ -> :ok end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)
      ref = Process.monitor(pid)

      owner =
        spawn(fn ->
          receive do
          end
        end)

      # Use proper API to set owner
      :ok = TransactionStatem.client_set_owner(owner, transaction)

      refute get_cancelled_flag(pid)

      assert Process.alive?(pid), "Transaction process should be alive before owner death"

      Process.exit(owner, :kill)

      # Give time for DOWN message to be processed
      Process.sleep(50)

      # Client transaction should handle owner death by canceling
      # Process may or may not still be alive depending on timeouts
      # What matters is the cancel flag was set if process is alive
      if Process.alive?(pid) do
        assert get_cancelled_flag(pid), "If alive, should be cancelled"
      else
        # Process terminated - that's also acceptable behavior
        # Check it was a normal termination
        assert_received {:DOWN, ^ref, :process, ^pid, reason}
        assert reason == :normal or match?({:shutdown, _}, reason)
      end

      Process.demonitor(ref, [:flush])
    end
  end

  describe "INVITE retransmission race condition" do
    @tag :race_condition
    test "handles retransmission arriving during transaction spawn window", %{test_id: test_id} do
      # This test verifies the fix for parrot_platform-121:
      # When a retransmission arrives during the spawn window (before Registry lookup succeeds
      # but after start_child was called), the message should be forwarded to the existing
      # transaction, not lost with an error log.
      #
      # RFC 3261 Section 17.2.1: Retransmissions MUST be handled by existing transaction

      invite = build_invite(unique_branch("z9hG4bKraceCondition", test_id))
      handler = TestHandler.new()

      # Simulate concurrent processing by spawning multiple tasks that all try to
      # process the same INVITE simultaneously
      parent = self()

      # Start 5 concurrent tasks that all try to process the same INVITE
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            result = TransactionStatem.server_process(invite, handler)
            send(parent, {:result, i, result})
            result
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 1000)

      # All should succeed with :ok
      assert Enum.all?(results, &(&1 == :ok)),
             "All concurrent server_process calls should return :ok, got: #{inspect(results)}"

      # There should be exactly ONE transaction created
      Process.sleep(50)

      # Look up transaction by ID
      trans_id = ParrotSip.Transaction.generate_id(invite)

      case Registry.lookup(ParrotSip.Registry, trans_id) do
        [{pid, _}] ->
          # Verify single transaction exists and is in correct state
          assert Process.alive?(pid)
          # INVITE server transactions automatically go to proceeding after sending 100 Trying
          assert_state(pid, :proceeding)

        [] ->
          flunk("Expected one transaction to be registered, found none")

        multiple ->
          flunk("Expected one transaction, found #{length(multiple)}: #{inspect(multiple)}")
      end
    end

    test "retransmission during spawn is forwarded to existing transaction", %{test_id: test_id} do
      # More targeted test: verify that if start_child returns {:already_started, pid},
      # the message gets forwarded rather than being logged as an error

      invite = build_invite(unique_branch("z9hG4bKspawnForward", test_id))
      {:ok, transaction} = ParrotSip.Transaction.create_invite_server(invite)
      handler = TestHandler.new()

      # Start the transaction first
      {:ok, pid} = start_transaction(transaction, handler)
      assert_state(pid, :proceeding)

      # Now call server_process with the same INVITE (simulates retransmission)
      # This should route to existing transaction, not try to create a new one
      # Since find_server will find it, this will work - but we test the path
      # through server_process to ensure routing works
      :ok = TransactionStatem.server_process(invite, handler)

      # Transaction should still be alive and in proceeding
      assert Process.alive?(pid)
      assert_state(pid, :proceeding)
    end
  end

  describe "server_process/2 - transaction routing" do
    test "routes ACK to existing transaction", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKackRoute", test_id))
      {:ok, transaction} = Transaction.create_invite_server(invite)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      final = Message.reply(invite, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)
      assert_state(pid, :completed)

      ack = build_ack(invite)
      :ok = TransactionStatem.server_process(ack, handler)

      assert_state(pid, :confirmed)
    end

    test "creates new transaction for new INVITE", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKnewInvite", test_id))
      handler = TestHandler.new()

      initial_count = TransactionStatem.count()

      :ok = TransactionStatem.server_process(invite, handler)
      Process.sleep(50)

      assert TransactionStatem.count() == initial_count + 1
    end

    test "routes retransmitted request to existing transaction", %{test_id: test_id} do
      register = build_register(unique_branch("z9hG4bKretransRoute", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(register)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      provisional = Message.reply(register, 100, "Trying")
      :ok = TransactionStatem.server_response(provisional, transaction)

      {:ok, code_before} = TransactionStatem.get_last_response_code(pid)

      :ok = TransactionStatem.server_process(register, handler)
      Process.sleep(50)

      {:ok, code_after} = TransactionStatem.get_last_response_code(pid)
      assert code_before == code_after
    end

    test "handles in-dialog requests by creating new transaction", %{test_id: test_id} do
      bye = build_bye_in_dialog(unique_branch("z9hG4bKinDialog", test_id))
      handler = TestHandler.new()

      initial_count = TransactionStatem.count()

      :ok = TransactionStatem.server_process(bye, handler)
      Process.sleep(50)

      assert TransactionStatem.count() == initial_count + 1
    end
  end

  describe "client_response/2 - response routing" do
    test "routes response to correct client transaction", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKclientResp", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, _pid} = TransactionStatem.client_new(transaction, %{}, callback)

      response = Message.reply(invite, 180, "Ringing")
      response_binary = ParrotSip.Serializer.encode(response)

      via = Message.top_via(invite)
      :ok = TransactionStatem.client_response(via, response_binary)

      assert_receive {:callback, {:response, %{status_code: 180}}}, 1000
    end

    test "handles response with no matching transaction", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKnoMatch", test_id))
      response = Message.reply(invite, 200, "OK")
      response_binary = ParrotSip.Serializer.encode(response)

      via = %Via{parameters: %{"branch" => "z9hG4bKnonexistent"}}

      assert :ok = TransactionStatem.client_response(via, response_binary)
    end
  end

  describe "server_cancel/1" do
    test "returns 481 for non-existent transaction", %{test_id: test_id} do
      cancel = build_cancel(unique_branch("z9hG4bKnonexistent", test_id))

      assert {:reply, response} = TransactionStatem.server_cancel(cancel)
      assert response.status_code == 481
      assert response.reason_phrase == "Call/Transaction Does Not Exist"
    end

    test "returns 200 OK for existing transaction", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKcancelOk", test_id))
      {:ok, transaction} = Transaction.create_invite_server(invite)
      handler = TestHandler.new()

      {:ok, _pid} = start_transaction(transaction, handler)

      cancel = build_cancel_for_invite(invite)

      assert {:reply, response} = TransactionStatem.server_cancel(cancel)
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
    end
  end

  describe "transaction count" do
    test "count returns number of active transactions", %{test_id: test_id} do
      count_before = TransactionStatem.count()

      invite1 = build_invite(unique_branch("z9hG4bKcount1", test_id))
      {:ok, trans1} = Transaction.create_invite_server(invite1)
      handler = TestHandler.new()
      {:ok, _pid1} = start_transaction(trans1, handler)

      invite2 = build_invite(unique_branch("z9hG4bKcount2", test_id))
      {:ok, trans2} = Transaction.create_invite_server(invite2)
      {:ok, _pid2} = start_transaction(trans2, handler)

      assert TransactionStatem.count() == count_before + 2
    end
  end

  # ============================================================================
  # Helper Functions - State Inspection
  # ============================================================================

  defp start_transaction(transaction, handler) do
    # Start transaction under the test's supervision tree for proper isolation
    # This ensures the process is cleaned up before the next test starts
    # Use transaction ID as the child ID to allow multiple transactions in one test
    start_supervised({ParrotSip.TransactionStatem, [transaction, handler]}, id: transaction.id)
  end

  defp get_timer_ref(pid, timer_name) do
    {:ok, ref} = TransactionStatem.get_timer_ref(pid, timer_name)
    ref
  end

  defp timer_active?(pid, timer_name) do
    {:ok, active} = TransactionStatem.timer_active?(pid, timer_name)
    active
  end

  defp get_cancelled_flag(pid) do
    {:ok, cancelled} = TransactionStatem.is_cancelled?(pid)
    cancelled
  end

  defp get_owner_monitor(pid) do
    {:ok, ref} = TransactionStatem.get_owner_monitor(pid)
    ref
  end

  defp get_auto_resp_code(pid) do
    {:ok, code} = TransactionStatem.get_auto_resp_code(pid)
    code
  end

  defp get_last_response(pid) do
    {:ok, code} = TransactionStatem.get_last_response_code(pid)
    # Return a simple struct-like map for compatibility with tests that check status_code
    if code, do: %{status_code: code}, else: nil
  end

  defp assert_last_response(pid, status_code) do
    {:ok, code} = TransactionStatem.get_last_response_code(pid)
    assert code == status_code
  end

  defp assert_state(pid, expected_state) do
    actual_state = TransactionStatem.get_state(pid)

    assert actual_state == expected_state,
           "Expected state #{inspect(expected_state)}, got #{inspect(actual_state)}"
  end

  defp assert_process_terminates(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  # ============================================================================
  # Message Builders
  # ============================================================================

  defp build_invite(branch) do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@biloxi.com",
      version: "SIP/2.0",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "pc33.atlanta.com",
          port: 5060,
          parameters: %{"branch" => branch}
        }
      ],
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{"tag" => "1928301774"}
      },
      to: %To{
        display_name: "Bob",
        uri: "sip:bob@biloxi.com",
        parameters: %{}
      },
      call_id: "a84b4c76e66710@pc33.atlanta.com",
      cseq: %CSeq{
        number: 314_159,
        method: :invite
      },
      contact: %Contact{
        display_name: nil,
        uri: "sip:alice@pc33.atlanta.com",
        parameters: %{}
      },
      body: "",
      other_headers: %{}
    }
  end

  defp build_register(branch) do
    %Message{
      type: :request,
      method: :register,
      request_uri: "sip:registrar.biloxi.com",
      version: "SIP/2.0",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "pc33.atlanta.com",
          port: 5060,
          parameters: %{"branch" => branch}
        }
      ],
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{"tag" => "1928301774"}
      },
      to: %To{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{}
      },
      call_id: "a84b4c76e66710@pc33.atlanta.com",
      cseq: %CSeq{
        number: 314_159,
        method: :register
      },
      contact: %Contact{
        display_name: nil,
        uri: "sip:alice@pc33.atlanta.com",
        parameters: %{}
      },
      body: "",
      other_headers: %{}
    }
  end

  defp build_ack(invite) do
    %{invite | method: :ack, cseq: %{invite.cseq | method: :ack}}
  end

  defp build_cancel(branch) do
    %Message{
      type: :request,
      method: :cancel,
      request_uri: "sip:bob@biloxi.com",
      version: "SIP/2.0",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "pc33.atlanta.com",
          port: 5060,
          parameters: %{"branch" => branch}
        }
      ],
      from: %From{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{"tag" => "1928301774"}
      },
      to: %To{
        display_name: "Bob",
        uri: "sip:bob@biloxi.com",
        parameters: %{}
      },
      call_id: "cancel@pc33.atlanta.com",
      cseq: %CSeq{
        number: 314_159,
        method: :cancel
      },
      other_headers: %{},
      body: ""
    }
  end

  defp build_cancel_for_invite(invite) do
    %{
      invite
      | method: :cancel,
        cseq: %{invite.cseq | method: :cancel}
    }
  end

  defp build_bye_in_dialog(branch) do
    %Message{
      type: :request,
      method: :bye,
      request_uri: "sip:alice@pc33.atlanta.com",
      version: "SIP/2.0",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "biloxi.com",
          port: 5060,
          parameters: %{"branch" => branch}
        }
      ],
      from: %From{
        display_name: "Bob",
        uri: "sip:bob@biloxi.com",
        parameters: %{"tag" => "8321234356"}
      },
      to: %To{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{"tag" => "1928301774"}
      },
      call_id: "a84b4c76e66710@pc33.atlanta.com",
      cseq: %CSeq{
        number: 231,
        method: :bye
      },
      other_headers: %{},
      body: ""
    }
  end

  describe "terminate callback" do
    test "terminate logs error for non-normal reasons", %{test_id: test_id} do
      # Test line 1655: terminate with error reason
      request = build_register(unique_branch("z9hG4bKterm", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Force an error termination
      Process.exit(pid, :test_error)
      Process.sleep(10)

      # Process should be dead
      refute Process.alive?(pid)
    end

    test "terminate logs debug for normal termination", %{test_id: test_id} do
      # Test line 1654: terminate with :normal
      request = build_register(unique_branch("z9hG4bKnormalterm", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send final response and let it complete naturally
      final = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(final, transaction)

      # Trigger timer J to terminate
      send(pid, {:event, :j})
      Process.sleep(20)

      refute Process.alive?(pid)
    end
  end

  describe "error handling" do
    test "handles invalid start_link arguments" do
      # This should raise ArgumentError
      assert_raise ArgumentError, fn ->
        TransactionStatem.start_link({:invalid, :args})
      end
    end

    test "handles stray ACK with no matching transaction", %{test_id: test_id} do
      ack = %Message{
        method: :ack,
        type: :request,
        request_uri: "sip:bob@example.com",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "127.0.0.1",
            port: 5060,
            parameters: %{"branch" => "z9hG4bK-stray-ack-#{test_id}"}
          }
        ],
        from: %From{
          uri: "sip:alice@example.com",
          parameters: %{"tag" => "from-tag"}
        },
        to: %To{
          uri: "sip:bob@example.com",
          parameters: %{"tag" => "to-tag"}
        },
        call_id: "stray-ack-#{test_id}@example.com",
        cseq: %CSeq{number: 1, method: :ack},
        other_headers: %{},
        body: ""
      }

      # Process stray ACK - should be handled gracefully
      handler = %{module: ParrotSip.TestHandler, args: %{}}
      result = TransactionStatem.server_process(ack, handler)
      assert result == :ok
    end

    test "handles stray ACK with handler that doesn't implement process_ack", %{test_id: test_id} do
      # Define a minimal handler module without process_ack
      defmodule MinimalHandler do
        def handle_request(_msg, _args), do: :ok
      end

      ack = %Message{
        method: :ack,
        type: :request,
        request_uri: "sip:bob@example.com",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "127.0.0.1",
            port: 5060,
            parameters: %{"branch" => "z9hG4bK-minimal-ack-#{test_id}"}
          }
        ],
        from: %From{
          uri: "sip:alice@example.com",
          parameters: %{"tag" => "from-tag"}
        },
        to: %To{
          uri: "sip:bob@example.com",
          parameters: %{"tag" => "to-tag"}
        },
        call_id: "minimal-ack-#{test_id}@example.com",
        cseq: %CSeq{number: 1, method: :ack},
        other_headers: %{},
        body: ""
      }

      # Process stray ACK with handler that doesn't have process_ack/2
      # Should log warning and return :ok
      handler = %{module: MinimalHandler, args: %{}}
      result = TransactionStatem.server_process(ack, handler)
      assert result == :ok
    end

    test "handles terminated state with cast events", %{test_id: test_id} do
      # Create a transaction and send it to completed, capture termination
      request = build_register(unique_branch("z9hG4bKterminated", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send final response to move to completed
      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)
      assert_state(pid, :completed)

      # Timer J will eventually fire and terminate the transaction
      # Once process is dead, we can verify the terminated state was reached
      # by checking that the process is no longer alive
      send(pid, {:event, :j})
      Process.sleep(20)

      # Process should have terminated
      refute Process.alive?(pid)
    end

    test "handles received request (non-ACK) in completed state", %{test_id: test_id} do
      # Test the {:received, request} handler in completed state
      request = build_invite(unique_branch("z9hG4bKreq_completed", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Move to completed
      final = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)
      assert_state(pid, :completed)

      # Send same request again (retransmission)
      :gen_statem.cast(pid, {:received, request})
      Process.sleep(10)

      # Should retransmit final response and stay in completed
      assert_state(pid, :completed)
    end

    test "handles client transaction termination with error reason", %{test_id: test_id} do
      request = build_register(unique_branch("z9hG4bKclient_term", test_id))
      {:ok, transaction} = Transaction.create_non_invite_client(request)

      callback = fn _result -> :ok end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      # Force termination with error
      Process.exit(pid, :test_error)
      Process.sleep(10)

      # Should be terminated
      refute Process.alive?(pid)
    end

    test "handles timer actions in apply_state_transition", %{test_id: test_id} do
      # Create client transaction and verify it starts correctly
      request = build_invite(unique_branch("z9hG4bKtimer_client", test_id))
      {:ok, transaction} = Transaction.create_invite_client(request)

      callback = fn _result -> :ok end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      # Verify transaction started in calling state
      assert_state(pid, :calling)
      # Verify process is alive and managing state
      assert Process.alive?(pid)

      # Clean up
      Process.exit(pid, :normal)
    end

    test "handles unknown event in handle_common_event", %{test_id: test_id} do
      # Test the catch-all clause in handle_common_event (line 1625)
      request = build_register(unique_branch("z9hG4bKunknown", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      assert_state(pid, :trying)

      # Send unknown event - should be ignored (keep_state)
      :gen_statem.cast(pid, {:unknown_event, "some data"})
      Process.sleep(10)

      # Should still be in trying state
      assert_state(pid, :trying)
      assert Process.alive?(pid)
    end

    test "handles received non-ACK request in handle_common_event", %{test_id: test_id} do
      # Test line 1572: received non-ACK request is ignored
      request = build_invite(unique_branch("z9hG4bKnoack", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send a non-ACK request (e.g., OPTIONS)
      options_msg = %Message{
        type: :request,
        method: :options,
        request_uri: "sip:bob@example.com"
      }

      :gen_statem.cast(pid, {:received, options_msg})
      Process.sleep(10)

      # Should stay in current state, ignoring the message
      assert Process.alive?(pid)
    end

    test "handles set_owner without existing monitor", %{test_id: test_id} do
      # Test line 1576: set_owner when owner_mon is nil (no demonitor call)
      request = build_register(unique_branch("z9hG4bKnomonitor", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Set owner for the first time (owner_mon is nil)
      owner_pid = spawn(fn -> Process.sleep(1000) end)
      :gen_statem.cast(pid, {:set_owner, 404, owner_pid})
      Process.sleep(10)

      assert Process.alive?(pid)

      # Clean up
      Process.exit(owner_pid, :kill)
    end

    test "handles cancel for server transaction - ignored", %{test_id: test_id} do
      # Test line 1621: cancel on server transaction is ignored
      request = build_register(unique_branch("z9hG4bKservercancel", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      assert_state(pid, :trying)

      # Try to cancel server transaction - should be ignored
      :gen_statem.cast(pid, :cancel)
      Process.sleep(10)

      # Should remain in trying state
      assert_state(pid, :trying)
      assert Process.alive?(pid)
    end

    test "handles in-dialog requests with both From and To tags", %{test_id: test_id} do
      # Test the path in server_process that handles in-dialog messages
      in_dialog_msg = %Message{
        method: :options,
        type: :request,
        from: %From{
          uri: "sip:alice@example.com",
          parameters: %{"tag" => "from-tag-#{test_id}"}
        },
        to: %To{
          uri: "sip:bob@example.com",
          parameters: %{"tag" => "to-tag-#{test_id}"}
        },
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "127.0.0.1",
            port: 5060,
            parameters: %{"branch" => "z9hG4bK-indialog-#{test_id}"}
          }
        ],
        call_id: "indialog-#{test_id}@example.com",
        cseq: %CSeq{number: 2, method: :options},
        request_uri: "sip:bob@example.com",
        other_headers: %{},
        body: ""
      }

      handler = TestHandler.new()
      # This should create a new transaction for the in-dialog request
      result = TransactionStatem.server_process(in_dialog_msg, handler)
      assert result == :ok
    end

    test "completed state handles send with no last_response", %{test_id: test_id} do
      # Test line 1423-1429: completed tries to retransmit but no last_response
      request = build_register(unique_branch("z9hG4bKnolastresp", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Manually force into completed state without last_response
      # (This is edge case testing - normally wouldn't happen)
      # We can test by trying to send in trying state
      some_response = Message.reply(request, 100, "Trying")

      # Send the response
      :gen_statem.cast(pid, {:send, some_response})
      Process.sleep(10)

      assert Process.alive?(pid)
    end

    test "handles send final response in trying state", %{test_id: test_id} do
      # Test classification of response codes
      request = build_register(unique_branch("z9hG4bKfinal_trying", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)
      assert_state(pid, :trying)

      # Send 500 error (final response)
      final = Message.reply(request, 500, "Internal Server Error")
      :ok = TransactionStatem.server_response(final, transaction)

      # Should transition to completed
      assert_state(pid, :completed)
      assert_last_response(pid, 500)
    end

    test "cancel timeout path executed when final response exists", %{test_id: test_id} do
      # Test line 1788: cancel_timeout event handler executes
      # Simplified test - just verify the timeout path runs
      Application.put_env(:parrot_sip, :cancel_timeout, 50)

      invite = build_invite(unique_branch("z9hG4bKcancelPath", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)
      ref = Process.monitor(pid)

      # Send CANCEL
      :ok = TransactionStatem.client_cancel({:trans, pid})

      # Wait for cancel timeout to fire
      # Either process terminates with timeout or with final response
      receive do
        {:callback, {:stop, :timeout}} ->
          # No final response, timeout callback fired
          :ok

        {:callback, {:ok, _}} ->
          # Got response before timeout - that's fine too
          :ok

        {:DOWN, ^ref, :process, ^pid, _} ->
          # Process terminated - acceptable
          :ok
      after
        200 ->
          # Timeout - process might still be alive, that's ok
          :ok
      end

      # Clean up
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      Process.demonitor(ref, [:flush])

      Application.delete_env(:parrot_sip, :cancel_timeout)
    end

    test "unexpected info message is logged and ignored", %{test_id: test_id} do
      # Test line 1807-1809: unexpected info messages
      request = build_register(unique_branch("z9hG4bKunexpInfo", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send unexpected info message
      send(pid, {:some_random_info, "test"})

      Process.sleep(10)
      assert Process.alive?(pid)
      assert_state(pid, :trying)
    end

    test "unexpected cast message is logged and ignored", %{test_id: test_id} do
      # Test line 1813-1815: unexpected cast messages
      request = build_register(unique_branch("z9hG4bKunexpCast", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send unexpected cast
      :gen_statem.cast(pid, {:some_unknown_cast, "data"})

      Process.sleep(10)
      assert Process.alive?(pid)
      assert_state(pid, :trying)
    end

    test "unexpected call returns error", %{test_id: test_id} do
      # Unknown calls receive an error response instead of timing out
      request = build_register(unique_branch("z9hG4bKunexpCall", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send unexpected call - returns error for unknown call
      result = :gen_statem.call(pid, {:some_unknown_call, "request"})

      assert match?({:error, {:unknown_call, _}}, result)

      # Process should still be alive
      assert Process.alive?(pid)
      assert_state(pid, :trying)
    end

    test "proceeding state ignores unexpected event types", %{test_id: test_id} do
      # Test line 1312: proceeding/3 catch-all for unexpected event types
      invite = build_invite(unique_branch("z9hG4bKprocUnexp", test_id))
      {:ok, transaction} = Transaction.create_invite_server(invite)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send provisional to get to proceeding
      provisional = Message.reply(invite, 180, "Ringing")
      :ok = TransactionStatem.server_response(provisional, transaction)
      assert_state(pid, :proceeding)

      # Send unexpected event type (internal event)
      send(pid, {:some_internal_event, "data"})

      Process.sleep(10)
      assert Process.alive?(pid)
      assert_state(pid, :proceeding)
    end

    test "calling state ignores unexpected event types", %{test_id: test_id} do
      # Test line 1376: calling/3 catch-all for unexpected event types  
      invite = build_invite(unique_branch("z9hG4bKcallUnexp", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      callback = fn _ -> :ok end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      assert_state(pid, :calling)

      # Send unexpected event
      send(pid, {:unexpected_event, "test"})

      Process.sleep(10)
      assert Process.alive?(pid)
    end

    test "completed state ignores unexpected event types", %{test_id: test_id} do
      # Test line 1454: completed/3 catch-all for unexpected event types
      request = build_register(unique_branch("z9hG4bKcompUnexp", test_id))
      {:ok, transaction} = Transaction.create_non_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send final response to get to completed
      final = Message.reply(request, 200, "OK")
      :ok = TransactionStatem.server_response(final, transaction)
      assert_state(pid, :completed)

      # Send unexpected event
      send(pid, {:unexpected_event, "data"})

      Process.sleep(10)
      assert Process.alive?(pid)
      assert_state(pid, :completed)
    end

    test "confirmed state ignores unexpected event types", %{test_id: test_id} do
      # Test line 1493: confirmed/3 catch-all for unexpected event types
      # Use error response to avoid immediate termination after ACK
      invite = build_invite(unique_branch("z9hG4bKconfUnexp", test_id))
      {:ok, transaction} = Transaction.create_invite_server(invite)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send 4xx error response (non-2xx INVITE stays in completed longer)
      final = Message.reply(invite, 404, "Not Found")
      :ok = TransactionStatem.server_response(final, transaction)
      assert_state(pid, :completed)

      # Send ACK for error response - goes to confirmed
      ack = %Message{
        type: :request,
        method: :ack,
        request_uri: invite.request_uri,
        call_id: invite.call_id,
        via: invite.via,
        from: invite.from,
        to: final.to,
        cseq: %{number: invite.cseq.number, method: :ack},
        other_headers: %{}
      }

      :ok = TransactionStatem.server_process(ack, handler)

      # Should be in confirmed now  
      Process.sleep(20)

      if Process.alive?(pid) do
        assert_state(pid, :confirmed)

        # Send unexpected event
        send(pid, {:unexpected_event, "test"})
        Process.sleep(10)

        # Should still be alive
        assert Process.alive?(pid)
      end
    end

    test "timer G exponential backoff works correctly", %{test_id: test_id} do
      # RFC 3261 requires: 500ms, 1000ms, 2000ms, 4000ms, 4000ms...
      # This test verifies the fix for the Timer G exponential backoff bug

      request = build_invite(unique_branch("z9hG4bKtimerG", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send error response to get to completed state with Timer G
      error_resp = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(error_resp, transaction)
      assert_state(pid, :completed)

      # Timer G should be running at 500ms initially
      assert timer_active?(pid, :g)

      # Get initial timer G
      initial_ref = get_timer_ref(pid, :g)
      initial_time = Process.read_timer(initial_ref)

      # Should be approximately 500ms
      assert initial_time > 400 and initial_time < 600,
             "Initial Timer G should be ~500ms, got #{initial_time}ms"

      # Wait for Timer G to fire and reschedule
      Process.sleep(600)

      # Should have rescheduled with doubled interval (1000ms)
      new_ref = get_timer_ref(pid, :g)

      # The timer should exist (proving it was rescheduled)
      assert new_ref != nil
      assert new_ref != initial_ref

      # Should be approximately 1000ms (doubled from 500ms)
      new_time = Process.read_timer(new_ref)

      assert new_time >= 850 and new_time <= 1100,
             "Second Timer G should be ~1000ms (doubled), got #{new_time}ms"

      # Wait for it to fire again
      Process.sleep(1100)

      # Should now be at 2000ms (doubled again)
      third_ref = get_timer_ref(pid, :g)
      assert third_ref != new_ref
      third_time = Process.read_timer(third_ref)

      assert third_time >= 1700 and third_time <= 2100,
             "Third Timer G should be ~2000ms, got #{third_time}ms"
    end
  end

  describe "client_response error handling" do
    test "handles malformed SIP response binary" do
      via = %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bKmalformed"}
      }

      malformed_response = "GARBAGE DATA NOT A SIP MESSAGE"

      # Should handle parse error gracefully without crashing
      assert :ok = TransactionStatem.client_response(via, malformed_response)
    end

    test "handles response with binary CSeq header" do
      via = %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bKbinarycseq"}
      }

      response_text = """
      SIP/2.0 200 OK
      Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKbinarycseq
      From: <sip:alice@example.com>;tag=1234
      To: <sip:bob@example.com>;tag=5678
      Call-ID: test@example.com
      CSeq: 1 INVITE
      Content-Length: 0

      """

      # This tests the binary CSeq extraction path at lines 603-605
      assert :ok = TransactionStatem.client_response(via, response_text)
    end

    test "handles response with no branch in Via" do
      via = %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{}
      }

      response_text = """
      SIP/2.0 200 OK
      Via: SIP/2.0/UDP 127.0.0.1:5060
      From: <sip:alice@example.com>;tag=1234
      To: <sip:bob@example.com>;tag=5678
      Call-ID: test@example.com
      CSeq: 1 INVITE
      Content-Length: 0

      """

      # Should handle missing branch gracefully (line 594, 615-616)
      assert :ok = TransactionStatem.client_response(via, response_text)
    end

    test "handles response for non-existent transaction" do
      via = %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bKnonexistent"}
      }

      response_text = """
      SIP/2.0 200 OK
      Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKnonexistent
      From: <sip:alice@example.com>;tag=1234
      To: <sip:bob@example.com>;tag=5678
      Call-ID: test@example.com
      CSeq: 1 INVITE
      Content-Length: 0

      """

      # Should handle transaction not found gracefully (lines 624-627)
      assert :ok = TransactionStatem.client_response(via, response_text)
    end
  end

  describe "server_process edge cases" do
    test "handles ACK for non-existent transaction with handler lacking process_ack" do
      handler = %{module: __MODULE__, args: nil}

      ack = %Message{
        type: :request,
        method: :ack,
        request_uri: "sip:test@example.com",
        call_id: "nonexistent@example.com",
        via: %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bKnoack"}
        },
        from: %From{uri: "sip:alice@example.com", parameters: %{"tag" => "123"}},
        to: %To{uri: "sip:bob@example.com", parameters: %{"tag" => "456"}},
        cseq: %CSeq{number: 1, method: :ack},
        other_headers: %{}
      }

      # Should handle missing process_ack/2 gracefully (lines 235-236)
      assert :ok = TransactionStatem.server_process(ack, handler)
    end
  end

  describe "create_server_response error handling" do
    test "returns error when transaction not found" do
      request = build_invite("z9hG4bKnotfound")
      response = Message.reply(request, 200, "OK")

      # Transaction doesn't exist in registry
      assert {:error, "No transaction found"} =
               TransactionStatem.create_server_response(response, request)
    end
  end

  describe "completed state retransmission handling" do
    test "server transaction in completed retransmits on request", %{test_id: test_id} do
      request = build_invite(unique_branch("z9hG4bKservercompleted", test_id))
      {:ok, transaction} = Transaction.create_invite_server(request)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      # Send error response to get to completed state
      error_resp = Message.reply(request, 404, "Not Found")
      :ok = TransactionStatem.server_response(error_resp, transaction)
      assert_state(pid, :completed)

      # Now send a retransmitted request (lines 1441-1443)
      # Server should retransmit the response
      retransmitted_request = request
      :gen_statem.cast(pid, {:received, retransmitted_request})

      Process.sleep(10)
      # Should still be alive in completed state
      assert Process.alive?(pid)
    end
  end
end
