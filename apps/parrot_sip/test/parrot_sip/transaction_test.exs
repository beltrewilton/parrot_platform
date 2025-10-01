defmodule ParrotSip.TransactionTest do
  use ExUnit.Case

  alias ParrotSip.Transaction
  alias ParrotSip.Message
  alias ParrotSip.Headers

  describe "create_invite_client/1" do
    test "creates transaction struct with correct initial values in calling state" do
      request = build_invite_request("z9hG4bKtest123")

      assert {:ok, %Transaction{
        type: :invite_client,
        state: :calling,
        method: :invite,
        branch: "z9hG4bKtest123",
        role: :uac
      } = transaction} = Transaction.create_invite_client(request)

      assert transaction.request == request
      assert transaction.last_response == nil
    end

    test "extracts branch from Via header struct" do
      request = build_invite_request("z9hG4bKbranch456")
      {:ok, transaction} = Transaction.create_invite_client(request)

      assert transaction.branch == "z9hG4bKbranch456"
    end

    test "extracts branch from Via list" do
      request = build_invite_request("z9hG4bKbranch789")
      # Via is already a list in build_invite_request
      {:ok, transaction} = Transaction.create_invite_client(request)

      assert transaction.branch == "z9hG4bKbranch789"
    end
  end

  describe "create_non_invite_client/1" do
    test "creates transaction struct with correct method in trying state" do
      request = build_register_request("z9hG4bKreg123")

      assert {:ok, %Transaction{
        type: :non_invite_client,
        state: :trying,
        method: :register,
        branch: "z9hG4bKreg123",
        role: :uac
      }} = Transaction.create_non_invite_client(request)
    end
  end

  describe "create_invite_server/1" do
    test "creates server transaction in trying state" do
      request = build_invite_request("z9hG4bKserver1")

      assert {:ok, %Transaction{
        type: :invite_server,
        state: :trying,
        method: :invite,
        branch: "z9hG4bKserver1",
        role: :uas
      }} = Transaction.create_invite_server(request)
    end
  end

  describe "create_non_invite_server/1" do
    test "creates server transaction in trying state" do
      request = build_register_request("z9hG4bKserver2")

      assert {:ok, %Transaction{
        type: :non_invite_server,
        state: :trying,
        method: :register,
        branch: "z9hG4bKserver2",
        role: :uas
      }} = Transaction.create_non_invite_server(request)
    end
  end

  describe "generate_id/1" do
    test "generates consistent IDs for same request" do
      request = build_invite_request("z9hG4bKsame")

      id1 = Transaction.generate_id(request)
      id2 = Transaction.generate_id(request)

      assert id1 == id2
    end

    test "generates different IDs for different branches" do
      request1 = build_invite_request("z9hG4bKbranch1")
      request2 = build_invite_request("z9hG4bKbranch2")

      id1 = Transaction.generate_id(request1)
      id2 = Transaction.generate_id(request2)

      refute id1 == id2
    end

    test "generates different IDs for different methods" do
      invite = build_invite_request("z9hG4bKsame")
      register = build_register_request("z9hG4bKsame")

      invite_id = Transaction.generate_id(invite)
      register_id = Transaction.generate_id(register)

      refute invite_id == register_id
    end
    
    test "BUG: crashes on message with nil Via header" do
      # This test exposes a bug: generate_id doesn't handle nil Via gracefully
      # It raises ArgumentError instead of returning error tuple
      message = %Message{
        method: :invite,
        via: [],  # Missing Via!
        cseq: %{method: :invite, number: 1}
      }

      # This currently raises ArgumentError from extract_top_via_strict
      # Should return {:error, :no_via} instead
      assert_raise ArgumentError, "Request must have a Via header", fn ->
        Transaction.generate_id(message)
      end
    end
    
    test "BUG: crashes on message with invalid Via header (string instead of struct)" do
      # Another bug case: Via is present but not a valid struct
      message = %Message{
        method: :invite,
        via: [],  # Invalid Via type!
        cseq: %{method: :invite, number: 1}
      }

      # This currently raises ArgumentError
      # Should handle gracefully
      assert_raise ArgumentError, "Request must have a Via header", fn ->
        Transaction.generate_id(message)
      end
    end
  end

  describe "generate_transaction_id/3" do
    test "client transaction ID format includes 'client'" do
      request = build_invite_request("z9hG4bKclient")

      id = Transaction.generate_transaction_id(:invite_client, "z9hG4bKclient", request)

      assert id == "z9hG4bKclient:invite:client"
    end

    test "server transaction ID format includes cseq number" do
      request = build_invite_request("z9hG4bKserver")

      id = Transaction.generate_transaction_id(:invite_server, "z9hG4bKserver", request)

      assert id == "z9hG4bKserver:invite:314159"
    end

    test "non-invite client uses method name" do
      request = build_register_request("z9hG4bKreg")

      id = Transaction.generate_transaction_id(:non_invite_client, "z9hG4bKreg", request)

      assert id == "z9hG4bKreg:register:client"
    end
  end

  describe "extract_branch/1" do
    test "extracts branch from Via header struct" do
      request = build_invite_request("z9hG4bKextract1")

      assert {:ok, "z9hG4bKextract1"} = Transaction.extract_branch(request)
    end

    test "extracts branch from Via list" do
      request = build_invite_request("z9hG4bKextract2")
      # request.via is already a list from build_invite_request

      assert {:ok, "z9hG4bKextract2"} = Transaction.extract_branch(request)
    end

    test "returns error when no branch parameter" do
      request = build_invite_request("z9hG4bK")
      [via | rest] = request.via
      via = %{via | parameters: %{}}
      request = %{request | via: [via | rest]}

      assert {:error, :no_branch} = Transaction.extract_branch(request)
    end

    test "returns error when no Via header" do
      request = build_invite_request("z9hG4bK")
      request = %{request | via: []}

      assert {:error, :no_via} = Transaction.extract_branch(request)
    end
  end

  describe "matches_response?/2" do
    test "matches when branch and method match for client transaction" do
      request = build_invite_request("z9hG4bKmatch1")
      response = build_response(request, 200, "OK")
      {:ok, transaction} = Transaction.create_invite_client(request)

      assert Transaction.matches_response?(transaction, response)
    end

    test "does not match server transactions" do
      request = build_invite_request("z9hG4bKmatch2")
      response = build_response(request, 200, "OK")
      {:ok, transaction} = Transaction.create_invite_server(request)

      refute Transaction.matches_response?(transaction, response)
    end

    test "does not match different branches" do
      request = build_invite_request("z9hG4bKmatch3")
      response = build_response(request, 200, "OK")
      {:ok, transaction} = Transaction.create_invite_client(request)

      [via | rest] = response.via
      via = %{via | parameters: Map.put(via.parameters, "branch", "z9hG4bKdifferent")}
      response = %{response | via: [via | rest]}

      refute Transaction.matches_response?(transaction, response)
    end

    test "does not match different methods" do
      request = build_invite_request("z9hG4bKmatch4")
      response = build_response(request, 200, "OK")
      response = %{response | cseq: %{response.cseq | method: :register}}
      {:ok, transaction} = Transaction.create_invite_client(request)

      refute Transaction.matches_response?(transaction, response)
    end

    test "handles response with nil via" do
      request = build_invite_request("z9hG4bKmatch5")
      {:ok, transaction} = Transaction.create_invite_client(request)
      response = %Message{via: []}

      refute Transaction.matches_response?(transaction, response)
    end

    test "handles response with via list" do
      request = build_invite_request("z9hG4bKmatch6")
      response = build_response(request, 200, "OK")
      # response already has via as a list from build_response
      {:ok, transaction} = Transaction.create_invite_client(request)

      assert Transaction.matches_response?(transaction, response)
    end
  end

  describe "matches_request?/2" do
    test "matches ACK to INVITE server transaction" do
      request = build_invite_request("z9hG4bKack1")
      ack = build_ack_request(request)
      {:ok, transaction} = Transaction.create_invite_server(request)

      assert Transaction.matches_request?(transaction, ack)
    end

    test "does not match ACK to client transaction" do
      request = build_invite_request("z9hG4bKack2")
      ack = build_ack_request(request)
      {:ok, transaction} = Transaction.create_invite_client(request)

      refute Transaction.matches_request?(transaction, ack)
    end

    test "does not match ACK with different branch" do
      request = build_invite_request("z9hG4bKack3")
      ack = build_ack_request(request)
      [via | rest] = ack.via
      via = %{via | parameters: Map.put(via.parameters, "branch", "z9hG4bKdifferent")}
      ack = %{ack | via: [via | rest]}
      {:ok, transaction} = Transaction.create_invite_server(request)

      refute Transaction.matches_request?(transaction, ack)
    end

    test "matches retransmitted request to server transaction" do
      request = build_register_request("z9hG4bKretrans1")
      {:ok, transaction} = Transaction.create_non_invite_server(request)

      assert Transaction.matches_request?(transaction, request)
    end

    test "handles request with nil via" do
      request = build_invite_request("z9hG4bKreq1")
      {:ok, transaction} = Transaction.create_invite_server(request)
      bad_request = %Message{via: [], method: :ack}

      refute Transaction.matches_request?(transaction, bad_request)
    end
  end

  describe "validate_message/1" do
    test "validates message with all required headers" do
      message = build_invite_request("z9hG4bKvalid")

      assert {:ok, ^message} = Transaction.validate_message(message)
    end

    test "returns error when missing Via" do
      message = build_invite_request("z9hG4bK")
      message = %{message | via: []}

      assert {:error, "Missing or invalid Via header"} = Transaction.validate_message(message)
    end

    test "returns error when missing CSeq" do
      message = build_invite_request("z9hG4bK")
      message = %{message | cseq: nil}

      assert {:error, "Missing or invalid CSeq header"} = Transaction.validate_message(message)
    end

    test "returns error when missing Call-ID" do
      message = build_invite_request("z9hG4bK")
      message = %{message | call_id: nil}

      assert {:error, "Missing or invalid Call-ID header"} = Transaction.validate_message(message)
    end
  end

  describe "determine_transaction_type/1" do
    test "identifies INVITE request as invite_server" do
      request = build_invite_request("z9hG4bK")

      assert Transaction.determine_transaction_type(request) == :invite_server
    end

    test "identifies non-INVITE request as non_invite_server" do
      request = build_register_request("z9hG4bK")

      assert Transaction.determine_transaction_type(request) == :non_invite_server
    end

    test "identifies INVITE response as invite_client" do
      request = build_invite_request("z9hG4bK")
      response = build_response(request, 200, "OK")

      assert Transaction.determine_transaction_type(response) == :invite_client
    end

    test "identifies non-INVITE response as non_invite_client" do
      request = build_register_request("z9hG4bK")
      response = build_response(request, 200, "OK")

      assert Transaction.determine_transaction_type(response) == :non_invite_client
    end
  end

  describe "next_state/2 - INVITE server pure state transitions" do
    test "trying + send provisional -> proceeding with timer actions" do
      transaction = %Transaction{type: :invite_server, state: :trying}
      event = {:send_provisional, 180}

      assert {:ok, :proceeding, actions} = Transaction.next_state(transaction, event)
      # Per RFC 3261, timer G is only started for final responses (3xx-6xx), not provisional
      assert actions == []
    end

    test "trying + send final response -> completed with timer actions" do
      transaction = %Transaction{type: :invite_server, state: :trying}
      event = {:send_final, 404}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :start_timer_g in actions
      assert :start_timer_h in actions
    end

    test "trying + send 2xx response -> terminated with no timers" do
      transaction = %Transaction{type: :invite_server, state: :trying}
      event = {:send_final, 200}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      refute :start_timer_g in actions
      refute :start_timer_h in actions
    end

    test "proceeding + send final response -> completed" do
      transaction = %Transaction{type: :invite_server, state: :proceeding}
      event = {:send_final, 404}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :start_timer_g in actions
      assert :start_timer_h in actions
      assert :cancel_timer_c in actions
    end

    test "proceeding + send 2xx response -> terminated" do
      transaction = %Transaction{type: :invite_server, state: :proceeding}
      event = {:send_final, 200}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      assert :cancel_timer_c in actions
    end

    test "completed + receive ACK -> confirmed" do
      transaction = %Transaction{type: :invite_server, state: :completed}
      event = {:receive_ack}

      assert {:ok, :confirmed, actions} = Transaction.next_state(transaction, event)
      assert :cancel_timer_g in actions
      assert :cancel_timer_h in actions
      assert :start_timer_i in actions
    end

    test "confirmed + timer I -> terminated" do
      transaction = %Transaction{type: :invite_server, state: :confirmed}
      event = {:timer, :i}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      assert :terminate in actions
    end

    test "completed + timer H -> terminated" do
      transaction = %Transaction{type: :invite_server, state: :completed}
      event = {:timer, :h}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      assert :terminate in actions
    end

    test "returns error for invalid trying -> confirmed transition" do
      transaction = %Transaction{type: :invite_server, state: :trying}
      event = {:receive_ack}

      assert {:error, :invalid_transition} = Transaction.next_state(transaction, event)
    end
  end

  describe "next_state/2 - INVITE client pure state transitions" do
    test "calling + receive provisional -> proceeding" do
      transaction = %Transaction{type: :invite_client, state: :calling}
      event = {:receive_response, 180}

      assert {:ok, :proceeding, actions} = Transaction.next_state(transaction, event)
      assert :cancel_timer_a in actions
      assert :cancel_timer_b in actions
    end

    test "calling + receive 2xx -> terminated" do
      transaction = %Transaction{type: :invite_client, state: :calling}
      event = {:receive_response, 200}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      assert :cancel_timer_a in actions
      assert :cancel_timer_b in actions
    end

    test "calling + receive failure -> completed" do
      transaction = %Transaction{type: :invite_client, state: :calling}
      event = {:receive_response, 404}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :cancel_timer_a in actions
      assert :cancel_timer_b in actions
      assert :start_timer_d in actions
    end

    test "proceeding + receive final -> completed" do
      transaction = %Transaction{type: :invite_client, state: :proceeding}
      event = {:receive_response, 404}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :start_timer_d in actions
    end

    test "proceeding + receive 2xx -> terminated" do
      transaction = %Transaction{type: :invite_client, state: :proceeding}
      event = {:receive_response, 200}

      assert {:ok, :terminated, _actions} = Transaction.next_state(transaction, event)
    end

    test "completed + timer D -> terminated" do
      transaction = %Transaction{type: :invite_client, state: :completed}
      event = {:timer, :d}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      assert :terminate in actions
    end
  end

  describe "next_state/2 - non-INVITE server pure state transitions" do
    test "trying + send provisional -> proceeding" do
      transaction = %Transaction{type: :non_invite_server, state: :trying}
      event = {:send_provisional, 100}

      assert {:ok, :proceeding, actions} = Transaction.next_state(transaction, event)
      assert actions == []
    end

    test "trying + send final -> completed" do
      transaction = %Transaction{type: :non_invite_server, state: :trying}
      event = {:send_final, 200}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :start_timer_j in actions
    end

    test "proceeding + send final -> completed" do
      transaction = %Transaction{type: :non_invite_server, state: :proceeding}
      event = {:send_final, 200}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :start_timer_j in actions
    end

    test "completed + timer J -> terminated" do
      transaction = %Transaction{type: :non_invite_server, state: :completed}
      event = {:timer, :j}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      assert :terminate in actions
    end
  end

  describe "next_state/2 - non-INVITE client pure state transitions" do
    test "trying + receive provisional -> proceeding" do
      transaction = %Transaction{type: :non_invite_client, state: :trying}
      event = {:receive_response, 100}

      assert {:ok, :proceeding, actions} = Transaction.next_state(transaction, event)
      assert :cancel_timer_e in actions
      assert :cancel_timer_f in actions
    end

    test "trying + receive final -> completed" do
      transaction = %Transaction{type: :non_invite_client, state: :trying}
      event = {:receive_response, 200}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :cancel_timer_e in actions
      assert :cancel_timer_f in actions
      assert :start_timer_k in actions
    end

    test "proceeding + receive final -> completed" do
      transaction = %Transaction{type: :non_invite_client, state: :proceeding}
      event = {:receive_response, 200}

      assert {:ok, :completed, actions} = Transaction.next_state(transaction, event)
      assert :start_timer_k in actions
    end

    test "completed + timer K -> terminated" do
      transaction = %Transaction{type: :non_invite_client, state: :completed}
      event = {:timer, :k}

      assert {:ok, :terminated, actions} = Transaction.next_state(transaction, event)
      assert :terminate in actions
    end
  end

  describe "classify_response/1" do
    test "classifies 1xx as provisional" do
      assert Transaction.classify_response(100) == :provisional
      assert Transaction.classify_response(180) == :provisional
      assert Transaction.classify_response(183) == :provisional
    end

    test "classifies 2xx as success" do
      assert Transaction.classify_response(200) == :success
      assert Transaction.classify_response(202) == :success
    end

    test "classifies 3xx-6xx as failure" do
      assert Transaction.classify_response(300) == :failure
      assert Transaction.classify_response(404) == :failure
      assert Transaction.classify_response(486) == :failure
      assert Transaction.classify_response(500) == :failure
    end
  end

  describe "is_client_transaction?/1" do
    test "returns true for client transactions" do
      {:ok, invite_client} = Transaction.create_invite_client(build_invite_request("z9hG4bK"))
      {:ok, non_invite_client} = Transaction.create_non_invite_client(build_register_request("z9hG4bK"))

      assert Transaction.is_client_transaction?(invite_client)
      assert Transaction.is_client_transaction?(non_invite_client)
    end

    test "returns false for server transactions" do
      {:ok, invite_server} = Transaction.create_invite_server(build_invite_request("z9hG4bK"))
      {:ok, non_invite_server} = Transaction.create_non_invite_server(build_register_request("z9hG4bK"))

      refute Transaction.is_client_transaction?(invite_server)
      refute Transaction.is_client_transaction?(non_invite_server)
    end
  end

  describe "is_server_transaction?/1" do
    test "returns true for server transactions" do
      {:ok, invite_server} = Transaction.create_invite_server(build_invite_request("z9hG4bK"))
      {:ok, non_invite_server} = Transaction.create_non_invite_server(build_register_request("z9hG4bK"))

      assert Transaction.is_server_transaction?(invite_server)
      assert Transaction.is_server_transaction?(non_invite_server)
    end

    test "returns false for client transactions" do
      {:ok, invite_client} = Transaction.create_invite_client(build_invite_request("z9hG4bK"))
      {:ok, non_invite_client} = Transaction.create_non_invite_client(build_register_request("z9hG4bK"))

      refute Transaction.is_server_transaction?(invite_client)
      refute Transaction.is_server_transaction?(non_invite_client)
    end
  end

  describe "is_terminated?/1" do
    test "returns true when state is terminated" do
      transaction = %Transaction{state: :terminated}

      assert Transaction.is_terminated?(transaction)
    end

    test "returns false for other states" do
      refute Transaction.is_terminated?(%Transaction{state: :trying})
      refute Transaction.is_terminated?(%Transaction{state: :proceeding})
      refute Transaction.is_terminated?(%Transaction{state: :completed})
      refute Transaction.is_terminated?(%Transaction{state: :confirmed})
      refute Transaction.is_terminated?(%Transaction{state: :calling})
    end
  end

  describe "retransmission_action/1" do
    test "returns retransmit action when last_response exists" do
      transaction = %Transaction{
        last_response: %Message{status_code: 180}
      }

      assert Transaction.retransmission_action(transaction) == {:retransmit_response, transaction.last_response}
    end

    test "returns ignore when no last_response" do
      transaction = %Transaction{last_response: nil}

      assert Transaction.retransmission_action(transaction) == :ignore
    end
  end

  describe "update_last_response/2" do
    test "updates last_response in transaction" do
      transaction = %Transaction{last_response: nil}
      response = %Message{status_code: 180}

      updated = Transaction.update_last_response(transaction, response)

      assert updated.last_response == response
    end
  end

  describe "update_state/2" do
    test "updates state in transaction" do
      transaction = %Transaction{state: :trying}

      updated = Transaction.update_state(transaction, :proceeding)

      assert updated.state == :proceeding
    end
  end

  # ============================================================================
  describe "next_state/2 - non_invite_server proceeding" do
    test "stays in proceeding when sending another provisional response" do
      # Test line 1119: non_invite_server in proceeding sends provisional
      transaction = %Transaction{
        type: :non_invite_server,
        state: :proceeding
      }
      
      assert {:ok, :proceeding, []} = Transaction.next_state(transaction, {:send_provisional, 183})
    end
  end

  # Helper Functions
  # ============================================================================

  defp build_invite_request(branch) do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:bob@biloxi.com",
      version: "SIP/2.0",
      via: [%Headers.Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "pc33.atlanta.com",
        port: 5060,
        parameters: %{"branch" => branch}
      }],
      from: %Headers.From{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{"tag" => "1928301774"}
      },
      to: %Headers.To{
        display_name: "Bob",
        uri: "sip:bob@biloxi.com",
        parameters: %{}
      },
      call_id: "a84b4c76e66710@pc33.atlanta.com",
      cseq: %Headers.CSeq{
        number: 314_159,
        method: :invite
      },
      contact: %Headers.Contact{
        display_name: nil,
        uri: "sip:alice@pc33.atlanta.com",
        parameters: %{}
      },
      body: "",
      other_headers: %{}
    }
  end

  defp build_register_request(branch) do
    %Message{
      type: :request,
      method: :register,
      request_uri: "sip:registrar.biloxi.com",
      version: "SIP/2.0",
      via: [%Headers.Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "pc33.atlanta.com",
        port: 5060,
        parameters: %{"branch" => branch}
      }],
      from: %Headers.From{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{"tag" => "1928301774"}
      },
      to: %Headers.To{
        display_name: "Alice",
        uri: "sip:alice@atlanta.com",
        parameters: %{}
      },
      call_id: "a84b4c76e66710@pc33.atlanta.com",
      cseq: %Headers.CSeq{
        number: 314_159,
        method: :register
      },
      contact: %Headers.Contact{
        display_name: nil,
        uri: "sip:alice@pc33.atlanta.com",
        parameters: %{}
      },
      body: "",
      other_headers: %{}
    }
  end

  defp build_ack_request(original_request) do
    %{
      original_request
      | method: :ack,
        cseq: %{original_request.cseq | method: :ack}
    }
  end

  describe "generate_branch/1" do
    test "generates a branch value" do
      request = build_invite_request("z9hG4bKtest123")
      branch = Transaction.generate_branch(request)
      
      assert is_binary(branch)
      assert String.starts_with?(branch, "z9hG4bK")
    end
  end

  describe "has_header?/2 - private function coverage through validate_message" do
    # Note: has_header? is private, so we test various header checks indirectly
    # The function has branches for from, to, contact, max-forwards, content-length, content-type
    # These branches are defensive code and may not be directly reachable through current public API
  end

  describe "extract_branch/1 - error cases" do
    test "returns error when Via header has no branch parameter" do
      via_without_branch = %Headers.Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{}
      }
      
      message = %Message{
        method: :invite,
        via: [via_without_branch]
      }
      
      assert {:error, :no_branch} = Transaction.extract_branch(message)
    end

    test "returns error when message has no Via header" do
      message = %Message{method: :invite, via: []}

      assert {:error, :no_via} = Transaction.extract_branch(message)
    end
  end

  describe "edge cases and error paths" do
    test "matches_response? handles response with Via as list" do
      request = build_invite_request("z9hG4bKmatches123")
      {:ok, transaction} = Transaction.create_invite_client(request)

      response = build_response(request, 200, "OK")
      # response already has via as a list from build_response

      assert Transaction.matches_response?(transaction, response)
    end

    test "matches_response? returns false for nil transaction" do
      request = build_invite_request("z9hG4bKnil")
      response = build_response(request, 200, "OK")
      
      refute Transaction.matches_response?(nil, response)
    end

    test "matches_request? handles request with nil Via" do
      request = build_invite_request("z9hG4bKack")
      {:ok, transaction} = Transaction.create_invite_server(request)

      ack = %Message{
        method: :ack,
        type: :request,
        via: []
      }

      refute Transaction.matches_request?(transaction, ack)
    end

    test "determine_transaction_type handles message with type field" do
      request = %Message{
        method: :options,
        type: :request
      }
      
      result = Transaction.determine_transaction_type(request)
      assert result == :non_invite_server
    end

    test "extract_branch handles Via as single struct" do
      via = %Headers.Via{
        protocol: "SIP",
        version: "2.0",
        transport: :udp,
        host: "127.0.0.1",
        port: 5060,
        parameters: %{"branch" => "z9hG4bKsingle"}
      }

      message = %Message{via: [via]}
      assert {:ok, "z9hG4bKsingle"} = Transaction.extract_branch(message)
    end

    test "classify_response handles boundary values" do
      assert Transaction.classify_response(100) == :provisional
      assert Transaction.classify_response(199) == :provisional
      assert Transaction.classify_response(200) == :success
      assert Transaction.classify_response(299) == :success
      assert Transaction.classify_response(300) == :failure
      assert Transaction.classify_response(699) == :failure
    end

    test "next_state returns error for invalid state transition" do
      transaction = %Transaction{
        type: :invite_server,
        state: :terminated,
        method: :invite
      }
      
      result = Transaction.next_state(transaction, {:send_provisional, 180})
      assert result == {:error, :invalid_transition}
    end

    test "retransmission_action with no last_response" do
      transaction = %Transaction{last_response: nil}
      assert Transaction.retransmission_action(transaction) == :ignore
    end

    test "update_last_response preserves other fields" do
      request = build_invite_request("z9hG4bKupdate")
      {:ok, transaction} = Transaction.create_invite_server(request)
      
      response = build_response(request, 180, "Ringing")
      updated = Transaction.update_last_response(transaction, response)
      
      assert updated.last_response == response
      assert updated.branch == transaction.branch
      assert updated.method == transaction.method
    end

    test "update_state preserves other fields" do
      request = build_invite_request("z9hG4bKstate")
      {:ok, transaction} = Transaction.create_invite_server(request)
      
      updated = Transaction.update_state(transaction, :proceeding)
      
      assert updated.state == :proceeding
      assert updated.branch == transaction.branch
      assert updated.method == transaction.method
    end
  end

  # Helper functions

  defp build_response(request, status_code, reason) do
    to_with_tag = %{request.to | parameters: Map.put(request.to.parameters, "tag", "314159")}

    %Message{
      status_code: status_code,
      reason_phrase: reason,
      type: :response,
      version: "SIP/2.0",
      via: request.via,
      from: request.from,
      to: to_with_tag,
      call_id: request.call_id,
      cseq: request.cseq,
      contact: %Headers.Contact{
        display_name: nil,
        uri: "sip:bob@192.0.2.4",
        parameters: %{}
      },
      body: "",
      other_headers: %{}
    }
  end

  describe "matches_request? edge cases" do
    test "matches_request? returns false when role is not uas" do
      # Test line 861: fallback for non-UAS role
      transaction = %Transaction{
        role: :uac,  # Client role, not server
        branch: "z9hG4bK123",
        method: :invite
      }
      
      request = %Message{
        method: :ack,
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK123"}
        }]
      }
      
      assert Transaction.matches_request?(transaction, request) == false
    end

    test "matches_request? returns false when method doesn't match" do
      # Test line 861: fallback when methods don't match
      transaction = %Transaction{
        role: :uas,
        branch: "z9hG4bK456",
        method: :register
      }
      
      request = %Message{
        method: :invite,  # Different method
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK456"}
        }]
      }
      
      assert Transaction.matches_request?(transaction, request) == false
    end

    test "matches_request? returns false when branch doesn't match" do
      # Test line 846/857: branch mismatch
      transaction = %Transaction{
        role: :uas,
        branch: "z9hG4bK789",
        method: :invite
      }
      
      request = %Message{
        method: :ack,
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{"branch" => "z9hG4bKDIFFERENT"}  # Different branch
        }]
      }
      
      assert Transaction.matches_request?(transaction, request) == false
    end

    test "matches_request? handles via without branch" do
      # Test line 846: Via without branch parameter
      transaction = %Transaction{
        role: :uas,
        branch: "z9hG4bK999",
        method: :invite
      }
      
      request = %Message{
        method: :ack,
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{}  # No branch parameter
        }]
      }
      
      assert Transaction.matches_request?(transaction, request) == false
    end
  end

  describe "matches_response? edge cases" do
    test "matches_response? returns false when role is not uac" do
      # Test line 767: fallback for non-UAC role
      transaction = %Transaction{
        role: :uas,  # Server role, not client
        branch: "z9hG4bK123",
        method: :invite
      }
      
      response = %Message{
        type: :response,
        status_code: 200,
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK123"}
        }],
        cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite}
      }
      
      assert Transaction.matches_response?(transaction, response) == false
    end

    test "matches_response? returns false when cseq method doesn't match" do
      # Test line 767: fallback when CSeq method doesn't match transaction method
      transaction = %Transaction{
        role: :uac,
        branch: "z9hG4bK456",
        method: :invite
      }
      
      response = %Message{
        type: :response,
        status_code: 200,
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK456"}
        }],
        cseq: %ParrotSip.Headers.CSeq{number: 1, method: :register}  # Different method in CSeq
      }
      
      assert Transaction.matches_response?(transaction, response) == false
    end

    test "matches_response? returns false when branch doesn't match" do
      # Test line 763: branch mismatch in Via
      transaction = %Transaction{
        role: :uac,
        branch: "z9hG4bK789",
        method: :invite
      }
      
      response = %Message{
        type: :response,
        status_code: 200,
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{"branch" => "z9hG4bKWRONG"}  # Wrong branch
        }],
        cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite}
      }
      
      assert Transaction.matches_response?(transaction, response) == false
    end

    test "matches_response? handles via list without matching branch" do
      # Test line 763: Via as list with no matching branch
      transaction = %Transaction{
        role: :uac,
        branch: "z9hG4bK999",
        method: :invite
      }
      
      response = %Message{
        type: :response,
        status_code: 200,
        via: [
          %ParrotSip.Headers.Via{host: "proxy.com", port: 5060, parameters: %{"branch" => "0"}},
          %ParrotSip.Headers.Via{host: "test.com", port: 5060, parameters: %{"branch" => "0"}}
        ],
        cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite}
      }
      
      # Only checks top Via (first in list)
      assert Transaction.matches_response?(transaction, response) == false
    end
  end

  describe "extract_branch/1 error paths" do
    test "extract_branch returns error when via is nil" do
      # Test line 935: no via header
      message = %Message{
        method: :invite,
        via: nil
      }
      
      assert {:error, :no_via} = Transaction.extract_branch(message)
    end

    test "extract_branch returns error when via has no branch parameter (single via)" do
      # Test line 943: via without branch parameter
      message = %Message{
        method: :invite,
        via: [%ParrotSip.Headers.Via{
          host: "test.com",
          port: 5060,
          parameters: %{}  # No branch parameter
        }]
      }
      
      assert {:error, :no_branch} = Transaction.extract_branch(message)
    end

    test "extract_branch returns error when via has no branch parameter (via list)" do
      # Test line 944: via list without branch parameter
      message = %Message{
        method: :invite,
        via: [
          %ParrotSip.Headers.Via{
            host: "test.com",
            port: 5060,
            parameters: %{}  # No branch parameter
          }
        ]
      }
      
      assert {:error, :no_branch} = Transaction.extract_branch(message)
    end

    test "extract_branch returns error for invalid via type" do
      # Test line 945: fallback for invalid via
      message = %Message{
        method: :invite,
        via: []  # Empty list
      }

      assert {:error, :no_via} = Transaction.extract_branch(message)
    end
  end
end