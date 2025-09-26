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

      state_before = get_transaction_state(pid)

      :gen_statem.cast(pid, {:received, request})
      Process.sleep(50)

      assert_state(pid, :proceeding)
      assert_last_response(pid, 180)

      state_after = get_transaction_state(pid)
      assert state_before.last_response == state_after.last_response
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

    @tag :skip
    test "cancel timeout terminates client transaction", %{test_id: test_id} do
      # TODO: This test needs to be rewritten to either wait for the actual 32s timeout
      # or we need to make the timeout configurable for testing purposes
      invite = build_invite(unique_branch("z9hG4bKcancelTimeout", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      test_pid = self()
      callback = fn result -> send(test_pid, {:callback, result}) end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)
      ref = Process.monitor(pid)

      :ok = TransactionStatem.client_cancel({:trans, pid})

      # The state_timeout is set to 32_000ms which is too long for a test
      # We need a way to trigger it artificially or make it configurable
      
      assert_receive {:callback, {:stop, :timeout}}, 33_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    test "server transaction processes CANCEL", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKcancelServer", test_id))
      {:ok, transaction} = Transaction.create_invite_server(invite)
      handler = TestHandler.new()

      {:ok, pid} = start_transaction(transaction, handler)

      :gen_statem.cast(pid, :cancel)

      # INVITE server transactions automatically send 100 Trying and move to proceeding
      assert_state(pid, :proceeding)
      assert Process.alive?(pid)
    end

    test "already cancelled client ignores second cancel", %{test_id: test_id} do
      invite = build_invite(unique_branch("z9hG4bKdoubleCancel", test_id))
      {:ok, transaction} = Transaction.create_invite_client(invite)

      callback = fn _ -> :ok end
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)

      :ok = TransactionStatem.client_cancel({:trans, pid})
      Process.sleep(50)
      assert get_cancelled_flag(pid)

      :ok = TransactionStatem.client_cancel({:trans, pid})
      Process.sleep(50)

      assert get_cancelled_flag(pid)
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

      owner = spawn(fn -> receive do end end)
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

      owner = spawn(fn -> receive do end end)
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

      owner = spawn(fn -> receive do end end)

      # Use proper API to set owner
      :ok = TransactionStatem.client_set_owner(owner, transaction)

      refute get_cancelled_flag(pid)

      assert Process.alive?(pid), "Transaction process should be alive before owner death"
      
      Process.exit(owner, :kill)
      Process.sleep(100)

      assert Process.alive?(pid), "Transaction process should be alive after owner death"
      assert get_cancelled_flag(pid)
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

      state_before = get_transaction_state(pid)

      :ok = TransactionStatem.server_process(register, handler)
      Process.sleep(50)

      state_after = get_transaction_state(pid)
      assert state_before.last_response == state_after.last_response
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

  defp get_transaction_state(pid) do
    state = :sys.get_state(pid)
    data = elem(state, 1)
    data.data.transaction
  end

  defp get_timer_ref(pid, timer_name) do
    state = :sys.get_state(pid)
    data = elem(state, 1)
    timers = data.timers || %{}
    Map.get(timers, timer_name)
  end

  defp timer_active?(pid, timer_name) do
    case get_timer_ref(pid, timer_name) do
      nil -> false
      ref -> Process.read_timer(ref) != false
    end
  end

  defp get_cancelled_flag(pid) do
    state = :sys.get_state(pid)
    data = elem(state, 1)
    get_in(data, [:data, :cancelled]) || false
  end

  defp get_owner_monitor(pid) do
    state = :sys.get_state(pid)
    data = elem(state, 1)
    data.owner_mon
  end

  defp get_auto_resp_code(pid) do
    state = :sys.get_state(pid)
    data = elem(state, 1)
    get_in(data, [:data, :auto_resp])
  end

  defp get_last_response(pid) do
    trans = get_transaction_state(pid)
    trans.last_response
  end

  defp assert_last_response(pid, status_code) do
    trans = get_transaction_state(pid)
    assert trans.last_response.status_code == status_code
  end

  defp assert_state(pid, expected_state) do
    state = :sys.get_state(pid)
    actual_state = elem(state, 0)
    
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
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "pc33.atlanta.com",
        port: 5060,
        parameters: %{"branch" => branch}
      },
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
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "pc33.atlanta.com",
        port: 5060,
        parameters: %{"branch" => branch}
      },
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
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "pc33.atlanta.com",
        port: 5060,
        parameters: %{"branch" => branch}
      },
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
      via: %Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "biloxi.com",
        port: 5060,
        parameters: %{"branch" => branch}
      },
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
end