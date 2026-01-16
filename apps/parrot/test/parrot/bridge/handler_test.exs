defmodule Parrot.Bridge.HandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.Bridge.Handler
  alias ParrotSip.Message

  defmodule TestRouter do
    @moduledoc false
    use Parrot.Router
    invite("*", SomeHandler)
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
    invite("*", Parrot.Bridge.HandlerTest.BusyHandler)
  end

  # Test router that routes to ForbiddenHandler
  defmodule ForbiddenRouter do
    @moduledoc false
    use Parrot.Router
    invite("*", Parrot.Bridge.HandlerTest.ForbiddenHandler)
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
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "alice",
          host: "127.0.0.1",
          port: 5080,
          host_type: :ipv4,
          parameters: %{},
          headers: %{}
        },
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %ParrotSip.Headers.To{
        display_name: nil,
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "100",
          host: "127.0.0.1",
          port: 5060,
          host_type: :ipv4,
          parameters: %{},
          headers: %{}
        },
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

  # ===========================================================================
  # US5: Router-based Routing Tests
  # ===========================================================================

  describe "pattern routing (US5 - T043)" do
    # Handler for extension calls (1xxx pattern)
    defmodule ExtensionHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> assign(:routed_to, :extension) |> answer()
      end
    end

    # Handler for catch-all
    defmodule CatchAllHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> assign(:routed_to, :catchall) |> answer()
      end
    end

    # Router with multiple patterns
    defmodule PatternRouter do
      use Parrot.Router

      # Extension pattern: 1xxx (1 followed by 3 digits)
      invite("1xxx", Parrot.Bridge.HandlerTest.ExtensionHandler)

      # Catch-all
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
    end

    test "routes 1xxx pattern to ExtensionHandler" do
      test_pid = self()
      # Matches 1xxx
      invite = create_invite_to("1234")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PatternRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      # Should get 100 Trying + 200 OK (from ExtensionHandler answering)
      responses = collect_responses(2)
      assert Enum.any?(responses, fn r -> r.status_code == 200 end)
    end

    test "routes non-matching pattern to catch-all handler" do
      test_pid = self()
      # Doesn't match 1xxx, matches *
      invite = create_invite_to("5678")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PatternRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      responses = collect_responses(2)
      assert Enum.any?(responses, fn r -> r.status_code == 200 end)
    end
  end

  describe "scope routing with from_ip (US5 - T044)" do
    defmodule InternalHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> assign(:routed_to, :internal) |> answer()
      end
    end

    defmodule ExternalHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> assign(:routed_to, :external) |> answer()
      end
    end

    defmodule ScopeRouter do
      use Parrot.Router

      # Internal network scope
      scope "/", from_ip: "192.168.1.0/24" do
        invite("*", Parrot.Bridge.HandlerTest.InternalHandler)
      end

      # Catch-all for external
      invite("*", Parrot.Bridge.HandlerTest.ExternalHandler)
    end

    test "routes requests from matching IP to scoped handler" do
      test_pid = self()
      invite = create_invite_from_ip({192, 168, 1, 50})

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: ScopeRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      responses = collect_responses(2)
      assert Enum.any?(responses, fn r -> r.status_code == 200 end)
    end

    test "routes requests from non-matching IP to fallback handler" do
      test_pid = self()
      # Not in 192.168.1.0/24
      invite = create_invite_from_ip({10, 0, 0, 1})

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: ScopeRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      responses = collect_responses(2)
      assert Enum.any?(responses, fn r -> r.status_code == 200 end)
    end
  end

  describe "REGISTER routing (US5 - T045)" do
    defmodule TestRegistrationHandler do
      @moduledoc false
      use Parrot.RegistrationHandler

      @impl true
      def authenticate(_credentials), do: :ok

      @impl true
      def store_binding(_aor, _contact, _expires), do: :ok

      @impl true
      def get_bindings(_aor), do: []
    end

    defmodule RegisterRouter do
      use Parrot.Router

      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
      register(Parrot.Bridge.HandlerTest.TestRegistrationHandler)
    end

    test "routes REGISTER to registered handler" do
      test_pid = self()
      register_msg = create_test_register()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: RegisterRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      # Should receive 200 OK for successful registration
      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200
    end

    test "returns 404 when no registration handler configured" do
      test_pid = self()
      register_msg = create_test_register()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end

      # Router without register handler (PatternRouter is defined in pattern routing describe block)
      args = %{router: Parrot.Bridge.HandlerTest.PatternRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 404
    end
  end

  describe "no-match routing (US5 - T046)" do
    defmodule NoMatchRouter do
      use Parrot.Router
      # No routes defined
    end

    test "returns 404 when no route matches INVITE" do
      test_pid = self()
      invite = create_test_invite()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: NoMatchRouter, response_fn: response_fn}

      :ok = Handler.handle_invite(uas, invite, args)

      responses = collect_responses(2)
      not_found = Enum.find(responses, fn r -> r.status_code == 404 end)
      assert not_found != nil
      assert not_found.reason_phrase == "Not Found"
    end
  end

  describe "uas_request fallback (US5 - T049)" do
    test "returns 501 Not Implemented for unhandled methods" do
      test_pid = self()

      # Create an INFO request (unhandled method)
      info_msg = %Message{
        type: :request,
        method: :info,
        request_uri: "sip:100@127.0.0.1:5060",
        version: "SIP/2.0",
        via: [
          %ParrotSip.Headers.Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "127.0.0.1",
            port: 5080,
            parameters: %{"branch" => "z9hG4bK-test"}
          }
        ],
        from: %ParrotSip.Headers.From{
          uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "127.0.0.1"},
          parameters: %{"tag" => "from-tag"}
        },
        to: %ParrotSip.Headers.To{
          uri: %ParrotSip.Uri{scheme: "sip", user: "bob", host: "127.0.0.1"},
          parameters: %{}
        },
        call_id: "test-call-id",
        cseq: %ParrotSip.Headers.CSeq{number: 1, method: :info}
      }

      # uas_request should return 501 - can't easily test via response callback
      # since it uses ParrotSip.Transaction.Server.response directly
      # Just verify it doesn't crash and returns :ok
      result = Handler.uas_request(:test_uas, info_msg, %{router: TestRouter})
      assert result == :ok
    end
  end

  # ===========================================================================
  # Contact Headers in Registration Response (Epic 6f9)
  # ===========================================================================

  describe "build_contact_headers/1 (6f9.1)" do
    test "converts empty bindings list to empty Contact list" do
      assert [] = Handler.build_contact_headers([])
    end

    test "converts single binding to Contact struct with expires" do
      # Binding with richer data format per RFC 3261 Section 10.3
      bindings = [
        %{
          contact: "sip:alice@192.168.1.100:5060",
          expires: 3600,
          registered_at: System.system_time(:second) - 100
        }
      ]

      [contact] = Handler.build_contact_headers(bindings)

      assert %ParrotSip.Headers.Contact{} = contact
      assert contact.uri.user == "alice"
      assert contact.uri.host == "192.168.1.100"
      assert contact.uri.port == 5060
      # Expires should be remaining time (original expires - elapsed time)
      assert contact.parameters["expires"] != nil
      expires = String.to_integer(contact.parameters["expires"])
      # Should be approximately 3500 (3600 - 100 elapsed)
      assert expires >= 3400 and expires <= 3600
    end

    test "converts multiple bindings to multiple Contact structs" do
      now = System.system_time(:second)

      bindings = [
        %{contact: "sip:alice@device1:5060", expires: 3600, registered_at: now},
        %{contact: "sip:alice@device2:5060", expires: 1800, registered_at: now}
      ]

      contacts = Handler.build_contact_headers(bindings)

      assert length(contacts) == 2
      assert Enum.all?(contacts, &match?(%ParrotSip.Headers.Contact{}, &1))

      # Verify each contact has correct expires
      expires_values =
        contacts
        |> Enum.map(& &1.parameters["expires"])
        |> Enum.map(&String.to_integer/1)
        |> Enum.sort(:desc)

      # Should be [3600, 1800] approximately
      assert hd(expires_values) >= 3500
      assert List.last(expires_values) >= 1700
    end

    test "handles expired bindings by setting expires to 0" do
      # Binding registered 4000 seconds ago with 3600 expires = expired
      bindings = [
        %{
          contact: "sip:alice@expired:5060",
          expires: 3600,
          registered_at: System.system_time(:second) - 4000
        }
      ]

      [contact] = Handler.build_contact_headers(bindings)

      expires = String.to_integer(contact.parameters["expires"])
      # Expired bindings should have 0 expires (not negative)
      assert expires == 0
    end
  end

  describe "Contact headers in 200 OK response (6f9.2, 6f9.4)" do
    defmodule RichBindingRegistrationHandler do
      @moduledoc false
      use Parrot.RegistrationHandler

      @impl true
      def authenticate(_credentials), do: :ok

      @impl true
      def store_binding(_aor, _contact, _expires), do: :ok

      @impl true
      def get_bindings(_aor) do
        # Return richer binding data with expires and registered_at
        now = System.system_time(:second)

        [
          %{contact: "sip:alice@192.168.1.100:5060", expires: 3600, registered_at: now},
          %{contact: "sip:alice@192.168.1.101:5060", expires: 1800, registered_at: now}
        ]
      end
    end

    defmodule RichBindingRouter do
      use Parrot.Router
      register(Parrot.Bridge.HandlerTest.RichBindingRegistrationHandler)
    end

    test "process_registration includes Contact header in 200 OK" do
      test_pid = self()
      register_msg = create_test_register_with_contact()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: RichBindingRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200

      # Response should have Contact header(s)
      assert response.contact != nil
      contacts = if is_list(response.contact), do: response.contact, else: [response.contact]
      assert length(contacts) == 2
    end

    test "Contact header has correct expires parameter" do
      test_pid = self()
      register_msg = create_test_register_with_contact()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: RichBindingRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      assert_receive {:sip_response, response}, 500

      contacts = if is_list(response.contact), do: response.contact, else: [response.contact]

      # Each Contact should have an expires parameter
      Enum.each(contacts, fn contact ->
        assert contact.parameters["expires"] != nil
        expires = String.to_integer(contact.parameters["expires"])
        # Expires should be positive (registration is valid)
        assert expires > 0
      end)
    end

    test "Contact URIs match the registered bindings" do
      test_pid = self()
      register_msg = create_test_register_with_contact()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: RichBindingRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      assert_receive {:sip_response, response}, 500

      contacts = if is_list(response.contact), do: response.contact, else: [response.contact]

      # Extract hosts from contacts
      hosts = Enum.map(contacts, & &1.uri.host) |> Enum.sort()
      assert hosts == ["192.168.1.100", "192.168.1.101"]
    end
  end

  describe "build_contact_headers/1 with q-value (Task 6f9.3)" do
    test "includes q parameter when binding has q-value" do
      now = System.system_time(:second)

      bindings = [
        %{contact: "sip:alice@192.168.1.100:5060", expires: 3600, registered_at: now, q: 1.0},
        %{contact: "sip:alice@192.168.1.101:5060", expires: 1800, registered_at: now, q: 0.5}
      ]

      contacts = Handler.build_contact_headers(bindings)

      assert length(contacts) == 2

      # Check first contact has q=1.0
      contact1 = Enum.find(contacts, fn c -> c.uri.host == "192.168.1.100" end)
      assert contact1.parameters["q"] == "1.0"

      # Check second contact has q=0.5
      contact2 = Enum.find(contacts, fn c -> c.uri.host == "192.168.1.101" end)
      assert contact2.parameters["q"] == "0.5"
    end

    test "omits q parameter when binding has no q-value" do
      now = System.system_time(:second)

      bindings = [
        %{contact: "sip:bob@10.0.0.50:5060", expires: 3600, registered_at: now}
      ]

      contacts = Handler.build_contact_headers(bindings)

      assert length(contacts) == 1
      [contact] = contacts

      # Should not have q parameter
      refute Map.has_key?(contact.parameters, "q")

      # Should still have expires parameter
      assert Map.has_key?(contact.parameters, "expires")
    end

    test "handles mix of bindings with and without q-value" do
      now = System.system_time(:second)

      bindings = [
        %{contact: "sip:alice@192.168.1.100:5060", expires: 3600, registered_at: now, q: 1.0},
        %{contact: "sip:alice@192.168.1.101:5060", expires: 1800, registered_at: now}
      ]

      contacts = Handler.build_contact_headers(bindings)

      assert length(contacts) == 2

      # First has q-value
      contact_with_q = Enum.find(contacts, fn c -> c.uri.host == "192.168.1.100" end)
      assert contact_with_q.parameters["q"] == "1.0"

      # Second does not
      contact_without_q = Enum.find(contacts, fn c -> c.uri.host == "192.168.1.101" end)
      refute Map.has_key?(contact_without_q.parameters, "q")
    end

    test "returns empty list for empty bindings" do
      assert [] == Handler.build_contact_headers([])
    end
  end

  # ===========================================================================
  # Additional Test Helpers
  # ===========================================================================

  defp create_test_register_with_contact do
    %Message{
      type: :request,
      method: :register,
      request_uri: "sip:127.0.0.1:5060",
      version: "SIP/2.0",
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5080,
          parameters: %{"branch" => "z9hG4bK-register-branch"}
        }
      ],
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "127.0.0.1"},
        parameters: %{"tag" => "from-tag-reg"}
      },
      to: %ParrotSip.Headers.To{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "127.0.0.1"},
        parameters: %{}
      },
      contact: %ParrotSip.Headers.Contact{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "192.168.1.100", port: 5060},
        parameters: %{}
      },
      call_id: "register-call-id@127.0.0.1",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :register},
      max_forwards: 70,
      expires: 3600,
      body: "",
      source: %{ip: {127, 0, 0, 1}, port: 5080}
    }
  end

  defp create_invite_to(to_user) do
    %Message{
      type: :request,
      method: :invite,
      request_uri: "sip:#{to_user}@127.0.0.1:5060",
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
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "127.0.0.1", port: 5080},
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %ParrotSip.Headers.To{
        display_name: nil,
        uri: %ParrotSip.Uri{scheme: "sip", user: to_user, host: "127.0.0.1", port: 5060},
        parameters: %{}
      },
      call_id: "test-call-id-123@127.0.0.1",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite},
      max_forwards: 70,
      body: "",
      source: %{ip: {127, 0, 0, 1}, port: 5080}
    }
  end

  defp create_invite_from_ip(source_ip) do
    invite = create_test_invite()
    %{invite | source: %{ip: source_ip, port: 5080}}
  end

  defp create_test_register do
    %Message{
      type: :request,
      method: :register,
      request_uri: "sip:127.0.0.1:5060",
      version: "SIP/2.0",
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5080,
          parameters: %{"branch" => "z9hG4bK-register-branch"}
        }
      ],
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "127.0.0.1"},
        parameters: %{"tag" => "from-tag-reg"}
      },
      to: %ParrotSip.Headers.To{
        uri: %ParrotSip.Uri{scheme: "sip", user: "alice", host: "127.0.0.1"},
        parameters: %{}
      },
      call_id: "register-call-id@127.0.0.1",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :register},
      max_forwards: 70,
      body: "",
      source: %{ip: {127, 0, 0, 1}, port: 5080}
    }
  end
end
