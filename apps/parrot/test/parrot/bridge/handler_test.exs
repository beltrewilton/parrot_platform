defmodule Parrot.Bridge.HandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.Bridge.Handler
  alias Parrot.Call
  alias ParrotSip.Message

  defmodule TestRouter do
    @moduledoc false
    use Parrot.Router
    invite "*", SomeHandler
  end

  # Test handler that rejects with 486 Busy Here
  defmodule BusyHandler do
    @moduledoc false
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      reject(call, 486)
    end
  end

  # Test handler that rejects with 403 Forbidden
  defmodule ForbiddenHandler do
    @moduledoc false
    use Parrot.InviteHandler

    @impl true
    def handle_invite(call) do
      reject(call, 403)
    end
  end

  # Test router that routes to BusyHandler
  defmodule BusyRouter do
    @moduledoc false
    use Parrot.Router
    invite "*", Parrot.Bridge.HandlerTest.BusyHandler
  end

  # Test router that routes to ForbiddenHandler
  defmodule ForbiddenRouter do
    @moduledoc false
    use Parrot.Router
    invite "*", Parrot.Bridge.HandlerTest.ForbiddenHandler
  end

  # Helper to create a minimal test SIP INVITE message
  defp create_test_invite do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:100@127.0.0.1:5060",
      version: "SIP/2.0",
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5080,
          host_type: :ipv4,
          parameters: %{"branch" => "z9hG4bK-test-branch"}
        }
      ],
      from: %ParrotSip.Headers.From{
        display_name: nil,
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "127.0.0.1", port: 5080, host_type: :ipv4, parameters: %{}, headers: %{}},
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %ParrotSip.Headers.To{
        display_name: nil,
        uri: %ParrotSip.Uri{scheme: "sip", user: "100", host: "127.0.0.1", port: 5060, host_type: :ipv4, parameters: %{}, headers: %{}},
        parameters: %{}
      },
      call_id: "test-call-id-123@127.0.0.1",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite},
      max_forwards: 70,
      body: "",
      source: %{ip: {127, 0, 0, 1}, port: 5080}
    }
  end

  describe "transp_request/2" do
    test "returns :process_transaction for any message" do
      msg = %{type: :request, method: :invite}
      args = %{router: TestRouter}

      assert :process_transaction = Handler.transp_request(msg, args)
    end
  end

  describe "transaction/3" do
    test "returns :process_uas for server transactions" do
      trans = %{id: "test-tx"}
      msg = %{type: :request, method: :invite}
      args = %{router: TestRouter}

      assert :process_uas = Handler.transaction(trans, msg, args)
    end
  end

  describe "transaction_stop/3" do
    test "returns :ok" do
      trans = %{id: "test-tx"}
      result = :normal
      args = %{router: TestRouter}

      assert :ok = Handler.transaction_stop(trans, result, args)
    end
  end

  describe "uas_cancel/2" do
    test "returns :ok" do
      uas_id = "test-uas-id"
      args = %{router: TestRouter}

      assert :ok = Handler.uas_cancel(uas_id, args)
    end
  end

  describe "process_ack/2" do
    test "returns :ok for ACK messages" do
      ack_msg = %{type: :request, method: :ack}
      args = %{router: TestRouter}

      assert :ok = Handler.process_ack(ack_msg, args)
    end
  end

  describe "behaviour implementation" do
    test "implements ParrotSip.Handler behaviour" do
      behaviours = Parrot.Bridge.Handler.__info__(:attributes)[:behaviour]
      assert ParrotSip.Handler in behaviours
    end

    test "exports all required callbacks" do
      # Required callbacks from ParrotSip.Handler
      assert function_exported?(Handler, :transp_request, 2)
      assert function_exported?(Handler, :transaction, 3)
      assert function_exported?(Handler, :transaction_stop, 3)
      assert function_exported?(Handler, :uas_request, 3)
      assert function_exported?(Handler, :uas_cancel, 2)
      assert function_exported?(Handler, :process_ack, 2)
    end

    test "exports optional method-specific callbacks" do
      # Optional method-specific callbacks
      assert function_exported?(Handler, :handle_invite, 3)
      assert function_exported?(Handler, :handle_bye, 3)
      assert function_exported?(Handler, :handle_register, 3)
      assert function_exported?(Handler, :handle_options, 3)
      assert function_exported?(Handler, :handle_cancel, 3)
    end
  end

  describe "call rejection (US3)" do
    test "sends 486 Busy Here when handler returns reject(call, 486)" do
      # Setup: test process captures the response via callback
      test_pid = self()
      invite = create_test_invite()

      # Mock UAS and callback to capture responses
      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: BusyRouter, response_fn: response_fn}

      # Act: handle_invite should route to BusyHandler and send rejection
      :ok = Handler.handle_invite(uas, invite, args)

      # Assert: should receive a 486 response (not 100 Trying)
      # First we may get 100 Trying, then the rejection
      responses = collect_responses(2)

      # Find the final (rejection) response
      rejection = Enum.find(responses, fn r -> r.status_code >= 400 end)
      assert rejection != nil, "Expected a rejection response (4xx/5xx)"
      assert rejection.status_code == 486
      assert rejection.reason_phrase == "Busy Here"
    end

    test "sends 403 Forbidden when handler returns reject(call, 403)" do
      test_pid = self()
      invite = create_test_invite()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: ForbiddenRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      responses = collect_responses(2)

      rejection = Enum.find(responses, fn r -> r.status_code >= 400 end)
      assert rejection != nil, "Expected a rejection response (4xx/5xx)"
      assert rejection.status_code == 403
      assert rejection.reason_phrase == "Forbidden"
    end

    test "does not start media session when call is rejected" do
      test_pid = self()
      invite = create_test_invite()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: BusyRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      # Collect responses (may include 100 Trying + rejection)
      responses = collect_responses(2)

      # Verify rejection was sent
      assert Enum.any?(responses, fn r -> r.status_code >= 400 end)

      # Verify no media session was started (no :media_started message)
      refute_receive {:media_started, _}, 100
    end

    test "rejection response includes correct headers from request" do
      test_pid = self()
      invite = create_test_invite()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: BusyRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      responses = collect_responses(2)
      rejection = Enum.find(responses, fn r -> r.status_code >= 400 end)

      # Response should have same Call-ID, From, CSeq as request
      assert rejection.call_id == invite.call_id
      assert rejection.from == invite.from
      assert rejection.cseq == invite.cseq
    end
  end

  # Helper to collect multiple responses with timeout
  defp collect_responses(max_count, timeout \\ 500) do
    collect_responses([], max_count, timeout)
  end

  defp collect_responses(acc, 0, _timeout), do: acc

  defp collect_responses(acc, remaining, timeout) do
    receive do
      {:sip_response, response} ->
        collect_responses([response | acc], remaining - 1, timeout)
    after
      timeout -> acc
    end
  end
end
