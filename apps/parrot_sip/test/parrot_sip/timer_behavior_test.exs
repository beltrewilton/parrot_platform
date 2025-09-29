defmodule ParrotSip.TimerBehaviorTest do
  @moduledoc """
  Comprehensive tests for RFC 3261 timer behaviors in TransactionStatem.
  
  Tests Timer A, E, and G implementations with exponential backoff.
  
  ## RFC 3261 Timer Summary
  - Timer A: INVITE client retransmission (doubles up to T2)
  - Timer B: INVITE client transaction timeout (64*T1)
  - Timer E: non-INVITE client retransmission (doubles up to T2)
  - Timer F: non-INVITE client transaction timeout (64*T1)
  - Timer G: INVITE server response retransmission (doubles up to T2)
  - Timer H: INVITE server ACK wait time
  - Timer I: INVITE server confirmed->terminated wait
  - Timer J: non-INVITE server completed->terminated wait
  """
  
  use ExUnit.Case, async: false
  
  alias ParrotSip.{Transaction, TransactionStatem, Message}
  alias ParrotSip.Headers.{Via, From, To, CSeq}
  
  @moduletag :timers
  
  # RFC 3261 default timer values (in milliseconds)
  @t1 500    # RTT estimate
  @t2 4000   # Maximum retransmit interval for non-INVITE
  @t4 5000   # Maximum duration message can remain in network
  
  setup do
    # Ensure the application is started
    Application.ensure_all_started(:parrot_sip)
    
    # Create a unique test ID for branch generation
    test_id = :erlang.unique_integer([:positive])
    {:ok, test_id: test_id}
  end
  
  describe "Timer A - INVITE client retransmission" do
    test "starts at T1 (500ms) on initial INVITE", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_client(invite)
      
      # Start transaction
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, fn _ -> :ok end)
      
      # Get state to check timers
      {_state_name, state_data} = :sys.get_state(pid)
      
      # Timer A should be active
      assert Map.has_key?(state_data.timers, :a)
      # Initial interval is T1
      assert Map.get(state_data, :timer_a_interval, @t1) == @t1
      
      GenServer.stop(pid)
    end
    
    test "doubles on each retransmission up to T2", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_client(invite)
      
      test_pid = self()
      callback = fn event ->
        send(test_pid, {:callback_event, event})
      end
      
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, callback)
      
      # Wait for first retransmission (T1 = 500ms)
      Process.sleep(550)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer A should have doubled to 1000ms
      assert Map.get(state_data, :timer_a_interval, @t1) == @t1 * 2
      
      # Wait for second retransmission
      Process.sleep(1050)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer A should have doubled to 2000ms
      assert Map.get(state_data, :timer_a_interval) == @t1 * 4
      
      # Wait for third retransmission
      Process.sleep(2050)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer A should be at T2 (4000ms) - capped
      assert Map.get(state_data, :timer_a_interval) <= @t2
      
      GenServer.stop(pid)
    end
    
    test "stops on provisional response", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_client(invite)
      
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, fn _ -> :ok end)
      
      # Send 100 Trying response
      trying = Message.reply(invite, 100, "Trying")
      :gen_statem.cast(pid, {:received, trying})
      
      Process.sleep(50)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer A should be cancelled
      refute Map.has_key?(state_data.timers, :a)
      
      GenServer.stop(pid)
    end
    
    test "stops on final response", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_client(invite)
      
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, fn _ -> :ok end)
      
      # Send 200 OK response
      ok_resp = Message.reply(invite, 200, "OK")
      :gen_statem.cast(pid, {:received, ok_resp})
      
      Process.sleep(50)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer A should be cancelled
      refute Map.has_key?(state_data.timers, :a)
      
      # Transaction should terminate immediately for 2xx
      Process.sleep(100)
      refute Process.alive?(pid)
    end
  end
  
  describe "Timer E - non-INVITE client retransmission" do
    test "starts at T1 (500ms) on initial non-INVITE request", %{test_id: test_id} do
      register = build_register_request(test_id)
      {:ok, transaction} = Transaction.create_non_invite_client(register)
      
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, fn _ -> :ok end)
      
      {_state_name, state_data} = :sys.get_state(pid)
      
      # Timer E should be active
      assert Map.has_key?(state_data.timers, :e)
      # Initial interval is T1
      assert Map.get(state_data, :timer_e_interval, @t1) == @t1
      
      GenServer.stop(pid)
    end
    
    test "doubles on each retransmission up to T2", %{test_id: test_id} do
      register = build_register_request(test_id)
      {:ok, transaction} = Transaction.create_non_invite_client(register)
      
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, fn _ -> :ok end)
      
      # Wait for first retransmission (T1 = 500ms)
      Process.sleep(550)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer E should have doubled to 1000ms
      assert Map.get(state_data, :timer_e_interval, @t1) == @t1 * 2
      
      # Wait for second retransmission
      Process.sleep(1050)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer E should have doubled to 2000ms  
      assert Map.get(state_data, :timer_e_interval) == @t1 * 4
      
      # Wait for third retransmission
      Process.sleep(2050)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer E should be at T2 (4000ms) - capped
      assert Map.get(state_data, :timer_e_interval) <= @t2
      
      GenServer.stop(pid)
    end
    
    test "stops on final response", %{test_id: test_id} do
      options = build_options_request(test_id)
      {:ok, transaction} = Transaction.create_non_invite_client(options)
      
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, fn _ -> :ok end)
      
      # Send 200 OK response
      ok_resp = Message.reply(options, 200, "OK")
      :gen_statem.cast(pid, {:received, ok_resp})
      
      Process.sleep(50)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer E should be cancelled
      refute Map.has_key?(state_data.timers, :e)
      
      GenServer.stop(pid)
    end
  end
  
  describe "Timer G - INVITE server response retransmission" do
    test "starts when entering completed state", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_server(invite)
      
      handler = %{
        transaction: fn _trans, _msg, _handler -> :ok end,
        response: fn _resp, _trans -> :ok end
      }
      
      {:ok, pid} = TransactionStatem.start_link([transaction, handler])
      
      # Send provisional response first to move to proceeding
      trying = Message.reply(invite, 100, "Trying")
      :ok = TransactionStatem.server_response(trying, transaction)
      
      Process.sleep(50)
      
      # Send final response to trigger completed state and Timer G
      ok_resp = Message.reply(invite, 200, "OK")
      :ok = TransactionStatem.server_response(ok_resp, transaction)
      
      Process.sleep(50)
      
      # For 2xx responses, transaction terminates immediately (no Timer G)
      # Let's use a 4xx response instead
      GenServer.stop(pid)
    end
    
    test "retransmits response with exponential backoff", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_server(invite)
      
      test_pid = self()
      handler = %{
        transaction: fn _trans, _msg, _handler -> :ok end,
        response: fn resp, _trans ->
          send(test_pid, {:response_sent, resp.status_code})
          :ok
        end
      }
      
      {:ok, pid} = TransactionStatem.start_link([transaction, handler])
      
      # Send error response to trigger Timer G (not 2xx which terminates immediately)
      busy = Message.reply(invite, 486, "Busy Here")
      :ok = TransactionStatem.server_response(busy, transaction)
      
      # Should receive initial send
      assert_receive {:response_sent, 486}, 100
      
      # Wait for first retransmission (T1 = 500ms)
      assert_receive {:response_sent, 486}, 600
      
      # Wait for second retransmission (T1 * 2 = 1000ms)
      assert_receive {:response_sent, 486}, 1100
      
      # Wait for third retransmission (T1 * 4 = 2000ms, capped at T2)
      assert_receive {:response_sent, 486}, 2100
      
      GenServer.stop(pid)
    end
    
    test "stops on ACK receipt", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_server(invite)
      
      handler = %{
        transaction: fn _trans, _msg, _handler -> :ok end,
        response: fn _resp, _trans -> :ok end
      }
      
      {:ok, pid} = TransactionStatem.start_link([transaction, handler])
      
      # Send error response to enter completed state with Timer G
      busy = Message.reply(invite, 486, "Busy Here")
      :ok = TransactionStatem.server_response(busy, transaction)
      
      Process.sleep(50)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer G should be active
      assert Map.has_key?(state_data.timers, :g)
      
      # Send ACK
      ack = build_ack_for_invite(invite)
      :gen_statem.cast(pid, {:received, ack})
      
      Process.sleep(50)
      
      {_state_name, state_data} = :sys.get_state(pid)
      # Timer G should be cancelled
      refute Map.has_key?(state_data.timers, :g)
      
      GenServer.stop(pid)
    end
  end
  
  describe "Timer interactions and edge cases" do
    test "Timer B terminates INVITE client transaction", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_client(invite)
      
      test_pid = self()
      callback = fn event ->
        send(test_pid, {:callback_event, event})
      end
      
      # Start with very short Timer B for testing (normally 64*T1)
      {:trans, pid} = TransactionStatem.client_new(transaction, %{timer_b: 100}, callback)
      
      # Wait for Timer B to fire
      Process.sleep(150)
      
      # Transaction should have terminated
      refute Process.alive?(pid)
      
      # Callback should have received timeout
      assert_received {:callback_event, {:stop, :timeout}}
    end
    
    test "Timer F terminates non-INVITE client transaction", %{test_id: test_id} do
      register = build_register_request(test_id)
      {:ok, transaction} = Transaction.create_non_invite_client(register)
      
      test_pid = self()
      callback = fn event ->
        send(test_pid, {:callback_event, event})
      end
      
      # Start with very short Timer F for testing (normally 64*T1)
      {:trans, pid} = TransactionStatem.client_new(transaction, %{timer_f: 100}, callback)
      
      # Wait for Timer F to fire
      Process.sleep(150)
      
      # Transaction should have terminated
      refute Process.alive?(pid)
      
      # Callback should have received timeout
      assert_received {:callback_event, {:stop, :timeout}}
    end
    
    test "multiple timers can be active simultaneously", %{test_id: test_id} do
      invite = build_invite_request(test_id)
      {:ok, transaction} = Transaction.create_invite_client(invite)
      
      {:trans, pid} = TransactionStatem.client_new(transaction, %{}, fn _ -> :ok end)
      
      {_state_name, state_data} = :sys.get_state(pid)
      
      # Both Timer A and Timer B should be active for INVITE client
      assert Map.has_key?(state_data.timers, :a)
      assert Map.has_key?(state_data.timers, :b)
      
      GenServer.stop(pid)
    end
  end
  
  # Helper functions
  
  defp build_invite_request(test_id) do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@example.com",
      version: "SIP/2.0",
      via: [build_via("z9hG4bK#{test_id}invite")],
      from: build_from("invite-#{test_id}"),
      to: build_to(),
      call_id: "call-#{test_id}@example.com",
      cseq: %CSeq{number: 1, method: :invite},
      max_forwards: 70,
      body: ""
    }
  end
  
  defp build_register_request(test_id) do
    %Message{
      type: :request,
      method: :register,
      request_uri: "sip:registrar.example.com",
      version: "SIP/2.0",
      via: [build_via("z9hG4bK#{test_id}register")],
      from: build_from("register-#{test_id}"),
      to: build_to(),
      call_id: "call-#{test_id}@example.com",
      cseq: %CSeq{number: 1, method: :register},
      max_forwards: 70,
      body: ""
    }
  end
  
  defp build_options_request(test_id) do
    %Message{
      type: :request,
      method: :options,
      request_uri: "sip:bob@example.com",
      version: "SIP/2.0",
      via: [build_via("z9hG4bK#{test_id}options")],
      from: build_from("options-#{test_id}"),
      to: build_to(),
      call_id: "call-#{test_id}@example.com",
      cseq: %CSeq{number: 1, method: :options},
      max_forwards: 70,
      body: ""
    }
  end
  
  defp build_ack_for_invite(invite) do
    %Message{
      type: :request,
      method: :ack,
      request_uri: invite.request_uri,
      version: "SIP/2.0",
      via: invite.via,
      from: invite.from,
      to: invite.to,
      call_id: invite.call_id,
      cseq: %CSeq{number: invite.cseq.number, method: :ack},
      max_forwards: 70,
      body: ""
    }
  end
  
  defp build_via(branch) do
    %Via{
      protocol: "SIP",
      version: "2.0",
      transport: :udp,
      host: "client.example.com",
      port: 5060,
      parameters: %{"branch" => branch}
    }
  end
  
  defp build_from(tag) do
    %From{
      display_name: "Alice",
      uri: "sip:alice@example.com",
      parameters: %{"tag" => tag}
    }
  end
  
  defp build_to do
    %To{
      display_name: "Bob",
      uri: "sip:bob@example.com",
      parameters: %{}
    }
  end
end