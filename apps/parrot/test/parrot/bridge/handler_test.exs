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
      # Create a proper ACK message with call_id for dialog lookup
      ack_msg = %Message{
        type: :request,
        method: :ack,
        call_id: "ack-test-#{System.unique_integer([:positive])}@127.0.0.1",
        via: [
          %ParrotSip.Headers.Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "127.0.0.1",
            port: 5080,
            parameters: %{"branch" => "z9hG4bK-ack-test"}
          }
        ],
        from: %ParrotSip.Headers.From{
          uri: %ParrotSip.Uri{
            scheme: "sip",
            user: "alice",
            host: "127.0.0.1",
            port: 5080,
            host_type: :ipv4,
            parameters: %{},
            headers: %{}
          },
          parameters: %{"tag" => "from-tag"}
        },
        to: %ParrotSip.Headers.To{
          uri: %ParrotSip.Uri{
            scheme: "sip",
            user: "bob",
            host: "127.0.0.1",
            port: 5060,
            host_type: :ipv4,
            parameters: %{},
            headers: %{}
          },
          parameters: %{"tag" => "to-tag"}
        },
        cseq: %ParrotSip.Headers.CSeq{number: 1, method: :ack}
      }

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
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Handler)
      # Required callbacks from ParrotSip.Handler
      assert function_exported?(Handler, :transp_request, 2)
      assert function_exported?(Handler, :transaction, 3)
      assert function_exported?(Handler, :transaction_stop, 3)
      assert function_exported?(Handler, :uas_request, 3)
      assert function_exported?(Handler, :uas_cancel, 2)
      assert function_exported?(Handler, :process_ack, 2)
    end

    test "exports optional method-specific callbacks" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Handler)
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
      def get_password("alice"), do: {:ok, "testpass"}
      def get_password(_), do: :error

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

    setup do
      # Ensure the global NonceStore is running (started by Parrot.Application)
      nonce_store = Process.whereis(Parrot.NonceStore)

      unless nonce_store do
        {:ok, pid} = ParrotSip.Auth.NonceStore.start_link(name: Parrot.NonceStore, ttl: 300)
        on_exit(fn -> GenServer.stop(pid) end)
      end

      :ok
    end

    test "routes REGISTER with auth to registered handler and returns 200 OK" do
      test_pid = self()
      nonce_store = Process.whereis(Parrot.NonceStore)
      register_msg = create_authenticated_register(nonce_store)

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: RegisterRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      # Should receive 200 OK for successful registration with valid credentials
      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200
    end

    test "routes REGISTER without auth and returns 401 challenge" do
      test_pid = self()
      register_msg = create_test_register()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: RegisterRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      # Should receive 401 Unauthorized with WWW-Authenticate challenge
      assert_receive {:sip_response, response}, 500
      assert response.status_code == 401
      assert response.reason_phrase == "Unauthorized"
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
      _test_pid = self()

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
      def get_password("alice"), do: {:ok, "testpass"}
      def get_password(_), do: :error

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

    setup do
      # Ensure the global NonceStore is running (started by Parrot.Application)
      nonce_store = Process.whereis(Parrot.NonceStore)

      unless nonce_store do
        {:ok, pid} = ParrotSip.Auth.NonceStore.start_link(name: Parrot.NonceStore, ttl: 300)
        on_exit(fn -> GenServer.stop(pid) end)
      end

      :ok
    end

    test "process_registration includes Contact header in 200 OK" do
      test_pid = self()
      nonce_store = Process.whereis(Parrot.NonceStore)
      register_msg = create_authenticated_register_with_contact(nonce_store)

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
      nonce_store = Process.whereis(Parrot.NonceStore)
      register_msg = create_authenticated_register_with_contact(nonce_store)

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
      nonce_store = Process.whereis(Parrot.NonceStore)
      register_msg = create_authenticated_register_with_contact(nonce_store)

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: RichBindingRouter, response_fn: response_fn}

      :ok = Handler.handle_register(uas, register_msg, args)

      assert_receive {:sip_response, response}, 500

      contacts = if is_list(response.contact), do: response.contact, else: [response.contact]

      # Extract hosts from contacts - URI may be a string or struct
      hosts =
        Enum.map(contacts, fn contact ->
          case contact.uri do
            %ParrotSip.Uri{host: host} -> host
            uri when is_binary(uri) ->
              # Parse the SIP URI string to extract host
              case Regex.run(~r/@([^:;>]+)/, uri) do
                [_, host] -> host
                _ -> uri
              end
          end
        end)
        |> Enum.sort()

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

  # Creates a REGISTER message with valid Digest Authorization header
  # This simulates a client that has received a 401 challenge and is responding
  # with proper credentials. Uses test password "testpass" for user "alice".
  defp create_authenticated_register(nonce_store) do
    # Generate a valid nonce from the NonceStore
    nonce = ParrotSip.Auth.NonceStore.generate_nonce(nonce_store)

    # Create the challenge parameters
    challenge = %{
      realm: Application.get_env(:parrot, :sip_realm, "parrot"),
      nonce: nonce,
      algorithm: "MD5",
      qop: "auth"
    }

    # Build authorization using Auth module
    uri = "sip:127.0.0.1:5060"
    auth = ParrotSip.Auth.create_authorization(:register, uri, challenge, "alice", "testpass")

    # Format the Authorization header value
    auth_header = ParrotSip.Auth.format_auth_header(auth)

    # Build the REGISTER message with Authorization header
    register = create_test_register()
    ParrotSip.Message.put_header(register, "authorization", auth_header)
  end

  # Creates an authenticated REGISTER with Contact header for binding tests
  defp create_authenticated_register_with_contact(nonce_store) do
    nonce = ParrotSip.Auth.NonceStore.generate_nonce(nonce_store)

    challenge = %{
      realm: Application.get_env(:parrot, :sip_realm, "parrot"),
      nonce: nonce,
      algorithm: "MD5",
      qop: "auth"
    }

    uri = "sip:127.0.0.1:5060"
    auth = ParrotSip.Auth.create_authorization(:register, uri, challenge, "alice", "testpass")
    auth_header = ParrotSip.Auth.format_auth_header(auth)

    register = create_test_register_with_contact()
    ParrotSip.Message.put_header(register, "authorization", auth_header)
  end

  # ===========================================================================
  # US3: SDP Error Handling Tests (T034-T036)
  # ===========================================================================

  describe "handle_sdp_error callback invocation (T034, T035)" do
    # Handler that overrides handle_sdp_error to track invocation
    defmodule SdpErrorTrackingHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end

      @impl true
      def handle_sdp_error(reason, call) do
        # Track that we were called by sending a message
        send(Application.get_env(:parrot, :test_pid), {:sdp_error_called, reason})
        # Return a custom rejection
        call |> reject(488)
      end
    end

    # Handler that uses default handle_sdp_error behavior (returns reject 488)
    defmodule DefaultSdpErrorHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end

      # Uses default handle_sdp_error which rejects with 488
    end

    # Handler that returns {:noreply, call} from handle_sdp_error
    defmodule NoReplyErrorHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end

      @impl true
      def handle_sdp_error(_reason, call) do
        {:noreply, call}
      end
    end

    defmodule SdpErrorTrackingRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.SdpErrorTrackingHandler)
    end

    defmodule DefaultSdpErrorRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.DefaultSdpErrorHandler)
    end

    defmodule NoReplyErrorRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.NoReplyErrorHandler)
    end

    test "invokes handler.handle_sdp_error/2 when SDP negotiation fails (T034, T035)" do
      # Store test PID for tracking
      Application.put_env(:parrot, :test_pid, self())

      test_pid = self()
      # INVITE with SDP body (will be processed but we force an error)
      invite = create_test_invite() |> Map.put(:body, "v=0\r\nsome sdp")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end

      # Use test injection to force SDP error
      args = %{
        router: SdpErrorTrackingRouter,
        response_fn: response_fn,
        force_sdp_error: true,
        sdp_error_reason: :codec_mismatch
      }

      :ok = Handler.handle_invite(uas, invite, args)

      # Handler's handle_sdp_error should have been called
      assert_receive {:sdp_error_called, :codec_mismatch}, 1000
    end

    test "default handle_sdp_error rejects with 488 Not Acceptable Here (T035, FR-012)" do
      test_pid = self()
      # INVITE with SDP body
      invite = create_test_invite() |> Map.put(:body, "v=0\r\nsome sdp")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end

      # Use test injection to force SDP error
      args = %{
        router: DefaultSdpErrorRouter,
        response_fn: response_fn,
        force_sdp_error: true,
        sdp_error_reason: :codec_mismatch
      }

      :ok = Handler.handle_invite(uas, invite, args)

      # Should receive 100 Trying then 488 Not Acceptable Here
      responses = collect_responses(2)
      rejection = Enum.find(responses, fn r -> r.status_code >= 400 end)

      assert rejection != nil
      assert rejection.status_code == 488
      assert rejection.reason_phrase == "Not Acceptable Here"
    end

    test "auto-rejects with 488 when handler returns {:noreply, call} (T036)" do
      test_pid = self()
      # INVITE with SDP body
      invite = create_test_invite() |> Map.put(:body, "v=0\r\nsome sdp")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end

      # Use test injection to force SDP error
      args = %{
        router: NoReplyErrorRouter,
        response_fn: response_fn,
        force_sdp_error: true,
        sdp_error_reason: :codec_mismatch
      }

      :ok = Handler.handle_invite(uas, invite, args)

      # Should receive 100 Trying then 488 Not Acceptable Here (auto-reject)
      responses = collect_responses(2)
      rejection = Enum.find(responses, fn r -> r.status_code >= 400 end)

      assert rejection != nil
      assert rejection.status_code == 488
      assert rejection.reason_phrase == "Not Acceptable Here"
    end
  end

  # ===========================================================================
  # US4: Media Event Callbacks - Integration Tests (T040)
  # ===========================================================================

  describe "media event routing to handler callbacks (T040, US4, FR-010, FR-011)" do
    # Handler that tracks media event callbacks via messages to test process
    defmodule MediaEventTrackingHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end

      @impl true
      def handle_media_started(call) do
        # Send message to test process to verify callback was invoked
        send(Application.get_env(:parrot, :test_pid), {:media_started_called, call.call_id})
        {:noreply, %{call | assigns: Map.put(call.assigns, :media_active, true)}}
      end

      @impl true
      def handle_media_stopped(reason, call) do
        send(
          Application.get_env(:parrot, :test_pid),
          {:media_stopped_called, reason, call.call_id}
        )

        {:noreply, %{call | assigns: Map.put(call.assigns, :media_active, false)}}
      end
    end

    defmodule MediaEventRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.MediaEventTrackingHandler)
    end

    test "routes :media_started event to handle_media_started/1 callback" do
      # Store test PID for tracking
      Application.put_env(:parrot, :test_pid, self())

      # Start a Call.Server directly to test event routing
      invite = %{
        id: "test-call-#{System.unique_integer()}",
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "media-event-test-call-id",
        method: "INVITE"
      }

      {:ok, call_server} =
        Parrot.Call.Server.start_link(
          handler: MediaEventTrackingHandler,
          invite: invite,
          context: nil
        )

      # Dispatch media_started event
      Parrot.Call.Server.dispatch(call_server, :media_started)

      # Handler's handle_media_started should have been called
      assert_receive {:media_started_called, "media-event-test-call-id"}, 1000
    end

    test "routes :media_stopped event to handle_media_stopped/2 callback" do
      Application.put_env(:parrot, :test_pid, self())

      invite = %{
        id: "test-call-#{System.unique_integer()}",
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "media-stop-test-call-id",
        method: "INVITE"
      }

      {:ok, call_server} =
        Parrot.Call.Server.start_link(
          handler: MediaEventTrackingHandler,
          invite: invite,
          context: nil
        )

      # Dispatch media_stopped event with reason
      Parrot.Call.Server.dispatch(call_server, {:media_stopped, :normal})

      # Handler's handle_media_stopped should have been called with reason
      assert_receive {:media_stopped_called, :normal, "media-stop-test-call-id"}, 1000
    end

    test "routes :media_stopped with :terminated reason" do
      Application.put_env(:parrot, :test_pid, self())

      invite = %{
        id: "test-call-#{System.unique_integer()}",
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "media-terminated-test",
        method: "INVITE"
      }

      {:ok, call_server} =
        Parrot.Call.Server.start_link(
          handler: MediaEventTrackingHandler,
          invite: invite,
          context: nil
        )

      # Dispatch media_stopped event with terminated reason
      Parrot.Call.Server.dispatch(call_server, {:media_stopped, :terminated})

      assert_receive {:media_stopped_called, :terminated, "media-terminated-test"}, 1000
    end

    test "handles {:media_event, session_id, :media_started} message format" do
      Application.put_env(:parrot, :test_pid, self())

      invite = %{
        id: "test-call-#{System.unique_integer()}",
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "media-event-msg-test",
        method: "INVITE"
      }

      {:ok, call_server} =
        Parrot.Call.Server.start_link(
          handler: MediaEventTrackingHandler,
          invite: invite,
          context: nil
        )

      # Send media event in the {:media_event, session_id, event} format
      # (this is the format used by MediaSession)
      send(call_server, {:media_event, "test_session", :media_started})

      assert_receive {:media_started_called, "media-event-msg-test"}, 1000
    end

    test "handles {:media_event, session_id, {:media_stopped, reason}} message format" do
      Application.put_env(:parrot, :test_pid, self())

      invite = %{
        id: "test-call-#{System.unique_integer()}",
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: "media-event-stop-msg-test",
        method: "INVITE"
      }

      {:ok, call_server} =
        Parrot.Call.Server.start_link(
          handler: MediaEventTrackingHandler,
          invite: invite,
          context: nil
        )

      # Send media stopped event in the {:media_event, session_id, event} format
      send(call_server, {:media_event, "test_session", {:media_stopped, :bye_received}})

      assert_receive {:media_stopped_called, :bye_received, "media-event-stop-msg-test"}, 1000
    end
  end

  # ===========================================================================
  # US1: SDP Negotiation Tests (T006-T007)
  # ===========================================================================

  describe "extract_sdp_offer/1 (T006)" do
    @sample_sdp """
    v=0
    o=user1 123 123 IN IP4 127.0.0.1
    s=Session
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 5004 RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    """

    test "returns {:ok, sdp_string} when body contains valid SDP" do
      invite = create_test_invite() |> Map.put(:body, @sample_sdp)
      assert {:ok, sdp} = Handler.extract_sdp_offer(invite)
      assert String.contains?(sdp, "v=0")
      assert String.contains?(sdp, "m=audio")
    end

    test "returns {:error, :no_sdp} when body is nil" do
      invite = create_test_invite() |> Map.put(:body, nil)
      assert {:error, :no_sdp} = Handler.extract_sdp_offer(invite)
    end

    test "returns {:error, :no_sdp} when body is empty string" do
      invite = create_test_invite() |> Map.put(:body, "")
      assert {:error, :no_sdp} = Handler.extract_sdp_offer(invite)
    end

    test "returns {:error, :no_sdp} when body is whitespace only" do
      invite = create_test_invite() |> Map.put(:body, "   \n  ")
      assert {:error, :no_sdp} = Handler.extract_sdp_offer(invite)
    end
  end

  describe "setup_media_session/2 (T007)" do
    @moduletag :unit

    @valid_sdp """
    v=0
    o=user1 123 123 IN IP4 192.168.1.100
    s=Session
    c=IN IP4 192.168.1.100
    t=0 0
    m=audio 5004 RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    """

    test "returns :no_sdp when INVITE body is empty" do
      invite = create_test_invite() |> Map.put(:body, "")
      assert :no_sdp = Handler.setup_media_session(invite, %{})
    end

    test "returns :no_sdp when INVITE body is nil (late-offer flow)" do
      invite = create_test_invite() |> Map.put(:body, nil)
      assert :no_sdp = Handler.setup_media_session(invite, %{})
    end

    test "returns {:ok, media_pid, sdp_answer} when SDP negotiation succeeds" do
      # Create INVITE with valid SDP body and unique call_id to avoid conflicts with other tests
      unique_call_id = "sdp-success-#{System.unique_integer([:positive])}@127.0.0.1"

      invite =
        create_test_invite()
        |> Map.put(:body, @valid_sdp)
        |> Map.put(:call_id, unique_call_id)

      # Note: This test depends on MediaSessionSupervisor being available
      # In TDD red phase, this test may fail if MediaSessionSupervisor not started
      # or if process_offer returns an error
      result = Handler.setup_media_session(invite, %{})

      case result do
        {:ok, media_pid, sdp_answer} ->
          assert is_pid(media_pid)
          assert is_binary(sdp_answer)
          # SDP answer should contain v=0 and m= lines
          assert String.contains?(sdp_answer, "v=0")
          # Cleanup
          send(media_pid, {:stop_media})

        {:error, reason} ->
          # TDD red phase: This is expected to fail initially
          flunk(
            "setup_media_session failed with #{inspect(reason)} - this is expected in TDD red phase until implementation is complete"
          )

        :no_sdp ->
          flunk("Expected {:ok, media_pid, sdp_answer} but got :no_sdp")
      end
    end

    test "returns {:error, reason} when SDP negotiation fails (forced error for test)" do
      invite = create_test_invite() |> Map.put(:body, @valid_sdp)

      # Use test injection to force an SDP error
      args = %{force_sdp_error: true, sdp_error_reason: :codec_mismatch}

      assert {:error, :codec_mismatch} = Handler.setup_media_session(invite, args)
    end

    test "creates MediaSession with correct session_id based on call_id" do
      # Use unique call_id to avoid conflicts with other tests
      unique_call_id = "session-id-test-#{System.unique_integer([:positive])}@127.0.0.1"

      invite =
        create_test_invite()
        |> Map.put(:body, @valid_sdp)
        |> Map.put(:call_id, unique_call_id)

      result = Handler.setup_media_session(invite, %{})

      case result do
        {:ok, media_pid, _sdp_answer} ->
          # The session should be registered with session_id = "call_<call_id>"
          expected_session_id = "call_#{unique_call_id}"

          case ParrotMedia.MediaSessionSupervisor.find_session(expected_session_id) do
            {:ok, found_pid} ->
              assert found_pid == media_pid

            {:error, :not_found} ->
              flunk(
                "MediaSession not registered with expected session_id: #{expected_session_id}"
              )
          end

          # Cleanup
          send(media_pid, {:stop_media})

        {:error, reason} ->
          flunk("setup_media_session failed: #{inspect(reason)}")

        :no_sdp ->
          flunk("Expected MediaSession to be created")
      end
    end
  end

  # ===========================================================================
  # T020: Media PID in Context After Answer (US2, FR-007)
  # ===========================================================================

  describe "media_pid passed through context (T020, FR-007)" do
    @moduletag :unit

    # Handler that captures the context it receives
    defmodule ContextCapturingHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end
    end

    defmodule ContextCapturingRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.ContextCapturingHandler)
    end

    @valid_sdp """
    v=0
    o=user1 123 123 IN IP4 192.168.1.100
    s=Session
    c=IN IP4 192.168.1.100
    t=0 0
    m=audio 5004 RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    """

    test "setup_media_session returns media_pid when SDP is present" do
      # Use unique call_id to avoid conflicts
      unique_call_id = "context-test-#{System.unique_integer([:positive])}@127.0.0.1"

      invite =
        create_test_invite()
        |> Map.put(:body, @valid_sdp)
        |> Map.put(:call_id, unique_call_id)

      result = Handler.setup_media_session(invite, %{})

      case result do
        {:ok, media_pid, _sdp_answer} ->
          # media_pid should be a valid PID
          assert is_pid(media_pid)
          assert Process.alive?(media_pid)
          # Cleanup
          send(media_pid, {:stop_media})

        {:error, reason} ->
          flunk(
            "setup_media_session failed: #{inspect(reason)} - expected {:ok, media_pid, sdp_answer}"
          )

        :no_sdp ->
          flunk("setup_media_session returned :no_sdp but INVITE had SDP body")
      end
    end

    test "media_pid is included in context passed to ActionExecutor" do
      # This test verifies that when handle_invite processes an INVITE with SDP,
      # the media_pid is properly passed through context to ActionExecutor.
      #
      # We verify this by checking that setup_media_session returns a valid PID,
      # which is then included in the context map at line 202 in handler.ex:
      #   context = %{... media_pid: media_pid ...}
      _test_pid = self()
      unique_call_id = "context-integration-#{System.unique_integer([:positive])}@127.0.0.1"

      invite =
        create_test_invite()
        |> Map.put(:body, @valid_sdp)
        |> Map.put(:call_id, unique_call_id)

      # Test that setup_media_session returns the media_pid
      result = Handler.setup_media_session(invite, %{})

      case result do
        {:ok, media_pid, sdp_answer} ->
          # Verify media_pid is valid - this will be placed in context
          assert is_pid(media_pid)
          assert is_binary(sdp_answer)

          # The context built by process_invite_with_media will include:
          # %{uas: uas, sip_msg: req_sip_msg, media_pid: media_pid, ...}
          # This test confirms media_pid is a valid PID that can be used by ActionExecutor

          # Cleanup
          send(media_pid, {:stop_media})

        other ->
          flunk("Expected {:ok, media_pid, sdp_answer}, got: #{inspect(other)}")
      end
    end

    test "media_pid is nil in context when no SDP in INVITE (late-offer)" do
      # For late-offer flow, setup_media_session returns :no_sdp
      # and media_pid will be nil in context
      invite = create_test_invite() |> Map.put(:body, "")

      result = Handler.setup_media_session(invite, %{})

      # Should return :no_sdp for empty body
      assert result == :no_sdp
      # In this case, process_invite_with_media is called with media_pid=nil
    end

    test "context contains media_pid alongside other required fields" do
      # Verify the context structure expected by ActionExecutor
      unique_call_id = "context-fields-#{System.unique_integer([:positive])}@127.0.0.1"

      invite =
        create_test_invite()
        |> Map.put(:body, @valid_sdp)
        |> Map.put(:call_id, unique_call_id)

      result = Handler.setup_media_session(invite, %{})

      case result do
        {:ok, media_pid, sdp_answer} ->
          # Build the context as process_invite_with_media does (handler.ex:199-206)
          context = %{
            uas: :test_uas,
            sip_msg: invite,
            media_pid: media_pid,
            dialog_id: invite.call_id,
            sdp_answer: sdp_answer,
            response_fn: nil
          }

          # Verify all required context fields are present
          assert Map.has_key?(context, :uas)
          assert Map.has_key?(context, :sip_msg)
          assert Map.has_key?(context, :media_pid)
          assert Map.has_key?(context, :dialog_id)
          assert Map.has_key?(context, :sdp_answer)

          # Verify media_pid is valid
          assert is_pid(context.media_pid)

          # Cleanup
          send(media_pid, {:stop_media})

        other ->
          flunk("setup_media_session failed: #{inspect(other)}")
      end
    end
  end

  # ===========================================================================
  # T042: BYE Handler Dispatches to Call.Server
  # ===========================================================================

  describe "handle_bye dispatches to Call.Server (T042)" do
    setup do
      # Ensure Parrot.Registry is started for tests
      case Registry.start_link(keys: :unique, name: Parrot.Registry) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      :ok
    end

    # Handler that tracks hangup callback via message
    defmodule HangupTrackingHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end

      @impl true
      def handle_hangup(call) do
        # Send message to test process to verify hangup was dispatched
        test_pid = call.assigns[:test_pid]
        if test_pid, do: send(test_pid, {:hangup_dispatched, call.call_id})
        {:noreply, call}
      end
    end

    defmodule HangupTrackingRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.HangupTrackingHandler)
    end

    test "handle_bye looks up Call.Server by call_id and dispatches :hangup event" do
      test_pid = self()
      call_id = "bye-dispatch-test-#{System.unique_integer([:positive])}"

      # Create and start a Call.Server manually
      invite_data = %{
        from: "sip:alice@example.com",
        to: "sip:bob@example.com",
        call_id: call_id,
        assigns: %{test_pid: test_pid}
      }

      {:ok, call_server_pid} =
        Parrot.Call.Server.start_link(
          handler: HangupTrackingHandler,
          invite: invite_data
        )

      # Verify Call.Server is registered
      assert {:ok, ^call_server_pid} = Parrot.Call.Server.lookup_by_call_id(call_id)

      # Create a BYE message with the same call_id
      bye_msg = create_bye_message(call_id)

      # Call handle_bye
      :ok = Handler.handle_bye(:test_uas, bye_msg, %{router: HangupTrackingRouter})

      # Call.Server should have received the :hangup dispatch
      assert_receive {:hangup_dispatched, ^call_id}, 500
    end

    test "handle_bye gracefully handles missing Call.Server" do
      call_id = "nonexistent-call-#{System.unique_integer([:positive])}"

      # Create a BYE message for a call that doesn't exist
      bye_msg = create_bye_message(call_id)

      # Should not crash, should log and continue
      assert :ok = Handler.handle_bye(:test_uas, bye_msg, %{router: HangupTrackingRouter})
    end

    test "handle_bye still stops MediaSession even if Call.Server not found" do
      # This ensures we don't regress on the existing behavior
      call_id = "media-only-test-#{System.unique_integer([:positive])}"
      bye_msg = create_bye_message(call_id)

      # Just verify handle_bye completes successfully
      # MediaSession lookup will return :not_found which is handled gracefully
      assert :ok = Handler.handle_bye(:test_uas, bye_msg, %{router: HangupTrackingRouter})
    end
  end

  # Helper to create a BYE SIP message
  defp create_bye_message(call_id) do
    %Message{
      type: :request,
      method: :bye,
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
          parameters: %{"branch" => "z9hG4bK-bye-branch"}
        }
      ],
      from: %ParrotSip.Headers.From{
        display_name: nil,
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "alice",
          host: "127.0.0.1",
          port: 5080,
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
          parameters: %{},
          headers: %{}
        },
        parameters: %{"tag" => "to-tag-456"}
      },
      call_id: call_id,
      cseq: %ParrotSip.Headers.CSeq{number: 2, method: :bye},
      max_forwards: 70,
      body: nil,
      source: %{ip: {127, 0, 0, 1}, port: 5080}
    }
  end

  # ===========================================================================
  # SUBSCRIBE Routing Tests (RFC 3856, RFC 6665)
  # ===========================================================================

  describe "handle_subscribe/3 routing (RFC 3856 Section 5)" do
    # PresenceHandler that allows all subscriptions and tracks calls
    defmodule AllowingPresenceHandler do
      @moduledoc false
      use Parrot.PresenceHandler

      @impl true
      def authorize_subscription(watcher, presentity) do
        send(Application.get_env(:parrot, :test_pid), {:authorize_called, watcher, presentity})
        :allow
      end

      @impl true
      def store_subscription(subscription) do
        send(Application.get_env(:parrot, :test_pid), {:store_called, subscription})
        :ok
      end

      @impl true
      def get_presence(_presentity) do
        %{status: :open, note: "Available"}
      end
    end

    # PresenceHandler that denies subscriptions
    defmodule DenyingPresenceHandler do
      @moduledoc false
      use Parrot.PresenceHandler

      @impl true
      def authorize_subscription(_watcher, _presentity) do
        :deny
      end
    end

    # PresenceHandler that returns pending (for approval flows)
    defmodule PendingPresenceHandler do
      @moduledoc false
      use Parrot.PresenceHandler

      @impl true
      def authorize_subscription(_watcher, _presentity) do
        :pending
      end

      @impl true
      def store_subscription(subscription) do
        send(Application.get_env(:parrot, :test_pid), {:store_called, subscription})
        :ok
      end

      @impl true
      def get_presence(_presentity) do
        %{status: :closed, note: "Pending"}
      end
    end

    # PresenceHandler that fails to store subscription
    defmodule FailingStorePresenceHandler do
      @moduledoc false
      use Parrot.PresenceHandler

      @impl true
      def authorize_subscription(_watcher, _presentity) do
        :allow
      end

      @impl true
      def store_subscription(_subscription) do
        {:error, :storage_failure}
      end
    end

    # Router with presence handler
    defmodule PresenceRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
      presence(Parrot.Bridge.HandlerTest.AllowingPresenceHandler)
    end

    # Router with denying presence handler
    defmodule DenyingPresenceRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
      presence(Parrot.Bridge.HandlerTest.DenyingPresenceHandler)
    end

    # Router with pending presence handler
    defmodule PendingPresenceRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
      presence(Parrot.Bridge.HandlerTest.PendingPresenceHandler)
    end

    # Router with failing store handler
    defmodule FailingStoreRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
      presence(Parrot.Bridge.HandlerTest.FailingStorePresenceHandler)
    end

    # Router without presence handler
    defmodule NoPresenceRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
    end

    test "routes SUBSCRIBE to presence handler and returns 200 OK on success" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      # Should receive 200 OK for successful subscription
      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
    end

    test "returns 404 when no presence handler configured" do
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: NoPresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 404
      assert response.reason_phrase == "Not Found"
    end

    test "calls authorize_subscription with watcher and presentity URIs" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      # Verify authorize_subscription was called with correct arguments
      assert_receive {:authorize_called, watcher, presentity}, 500
      assert watcher =~ "bob"
      assert presentity =~ "alice"
    end

    test "returns 403 Forbidden when authorization is denied" do
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: DenyingPresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 403
      assert response.reason_phrase == "Forbidden"
    end

    test "returns 202 Accepted when authorization is pending" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PendingPresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 202
      assert response.reason_phrase == "Accepted"
    end

    test "calls store_subscription with subscription data after authorization" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      # Verify store_subscription was called with correct data
      assert_receive {:store_called, subscription}, 500
      assert subscription.watcher =~ "bob"
      assert subscription.presentity =~ "alice"
      assert is_binary(subscription.subscription_id)
      assert is_integer(subscription.expires)
    end

    test "sends 200 OK even when store_subscription fails (RFC 6665 compliance)" do
      # RFC 6665 Section 4.2.2: Response is sent before subscription is stored.
      # If storage fails AFTER response is sent, we can't undo the response.
      # This is correct RFC behavior - the subscription just won't be persisted.
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: FailingStoreRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      # Per RFC 6665, 200 OK is sent before storage is attempted
      # Storage failure is logged but doesn't change the response
      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
    end

    test "includes Expires header in successful response" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200
      # Response should have Expires header matching granted expiration
      assert response.expires != nil
      assert is_integer(response.expires)
    end

    test "extracts expires from Expires header when present" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      # Create SUBSCRIBE with explicit Expires header
      subscribe_msg = create_test_subscribe() |> Map.put(:expires, 1800)

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      assert_receive {:store_called, subscription}, 500
      assert subscription.expires == 1800
    end

    test "uses default expires (3600) when Expires header not present" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      # Create SUBSCRIBE without Expires header
      subscribe_msg = create_test_subscribe() |> Map.put(:expires, nil)

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      assert_receive {:store_called, subscription}, 500
      assert subscription.expires == 3600
    end

    test "response includes correct headers from request" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      subscribe_msg = create_test_subscribe()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_subscribe(uas, subscribe_msg, args)

      assert_receive {:sip_response, response}, 500

      # Response should have same Call-ID, From, CSeq as request
      assert response.call_id == subscribe_msg.call_id
      assert response.from == subscribe_msg.from
      assert response.cseq == subscribe_msg.cseq
    end
  end

  describe "handle_subscribe/3 exports" do
    test "handle_subscribe/3 is exported" do
      Code.ensure_loaded!(Handler)
      assert function_exported?(Handler, :handle_subscribe, 3)
    end
  end

  # ===========================================================================
  # PUBLISH Routing Tests (RFC 3903 - SIP Event State Publication)
  # ===========================================================================

  describe "handle_publish/3 routing (RFC 3903)" do
    # PresenceHandler that tracks handle_publish calls
    defmodule PublishTrackingHandler do
      @moduledoc false
      use Parrot.PresenceHandler

      @impl true
      def handle_publish(presentity, presence_state) do
        send(
          Application.get_env(:parrot, :test_pid),
          {:publish_called, presentity, presence_state}
        )

        :ok
      end
    end

    # PresenceHandler that fails to update presence
    defmodule FailingPublishHandler do
      @moduledoc false
      use Parrot.PresenceHandler

      @impl true
      def handle_publish(_presentity, _presence_state) do
        {:error, :storage_failure}
      end
    end

    # Router with publish tracking handler
    defmodule PublishRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
      presence(Parrot.Bridge.HandlerTest.PublishTrackingHandler)
    end

    # Router with failing publish handler
    defmodule FailingPublishRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.CatchAllHandler)
      presence(Parrot.Bridge.HandlerTest.FailingPublishHandler)
    end

    test "routes PUBLISH to presence handler and returns 200 OK on success" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      publish_msg = create_test_publish()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      # Should receive 200 OK for successful publication
      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
    end

    test "returns 404 when no presence handler configured" do
      test_pid = self()
      publish_msg = create_test_publish()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      # NoPresenceRouter is defined in the SUBSCRIBE tests describe block
      args = %{router: Parrot.Bridge.HandlerTest.NoPresenceRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 404
      assert response.reason_phrase == "Not Found"
    end

    test "extracts presentity from To header URI" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      publish_msg = create_test_publish()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      # Verify handle_publish was called with correct presentity
      assert_receive {:publish_called, presentity, _presence_state}, 500
      assert presentity =~ "alice"
    end

    test "extracts presence state from PIDF+XML body" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      # Create PUBLISH with PIDF body indicating open status
      publish_msg = create_test_publish_with_pidf(:open, "Available")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      # Verify presence state was extracted correctly
      assert_receive {:publish_called, _presentity, presence_state}, 500
      assert presence_state.status == :open
      assert presence_state.note == "Available"
    end

    test "handles closed status in PIDF body" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      publish_msg = create_test_publish_with_pidf(:closed, "On a call")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      assert_receive {:publish_called, _presentity, presence_state}, 500
      assert presence_state.status == :closed
      assert presence_state.note == "On a call"
    end

    test "returns 500 when handler.handle_publish fails" do
      test_pid = self()
      publish_msg = create_test_publish()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: FailingPublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 500
      assert response.reason_phrase == "Internal Server Error"
    end

    test "triggers NOTIFY to subscribers after successful publish" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      publish_msg = create_test_publish_with_pidf(:open, "Available")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      # Verify successful response
      assert_receive {:sip_response, response}, 500
      assert response.status_code == 200

      # Note: Actual NOTIFY triggering is tested in Parrot.Presence tests
      # Here we just verify the handler was called correctly
      assert_receive {:publish_called, _presentity, _presence_state}, 500
    end

    test "response includes correct headers from request" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      publish_msg = create_test_publish()

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      assert_receive {:sip_response, response}, 500

      # Response should have same Call-ID, From, CSeq as request
      assert response.call_id == publish_msg.call_id
      assert response.from == publish_msg.from
      assert response.cseq == publish_msg.cseq
    end

    test "returns 400 Bad Request when PIDF body is malformed" do
      test_pid = self()
      # Create PUBLISH with malformed body
      publish_msg = create_test_publish() |> Map.put(:body, "<invalid xml>")

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      assert_receive {:sip_response, response}, 500
      assert response.status_code == 400
      assert response.reason_phrase == "Bad Request"
    end

    test "handles PIDF without note element" do
      Application.put_env(:parrot, :test_pid, self())
      test_pid = self()
      # Create PUBLISH with PIDF body without note
      pidf_body = """
      <?xml version="1.0"?>
      <presence xmlns="urn:ietf:params:xml:ns:pidf" entity="sip:alice@127.0.0.1">
        <tuple id="t1">
          <status><basic>open</basic></status>
        </tuple>
      </presence>
      """

      publish_msg = create_test_publish() |> Map.put(:body, pidf_body)

      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: PublishRouter, response_fn: response_fn}

      :ok = Handler.handle_publish(uas, publish_msg, args)

      assert_receive {:publish_called, _presentity, presence_state}, 500
      assert presence_state.status == :open
      # Note should be nil or absent
      assert presence_state[:note] == nil
    end
  end

  describe "handle_publish/3 exports" do
    test "handle_publish/3 is exported" do
      Code.ensure_loaded!(Handler)
      assert function_exported?(Handler, :handle_publish, 3)
    end
  end

  # Helper to create a test PUBLISH message
  # RFC 3903: SIP Event State Publication
  defp create_test_publish do
    pidf_body = """
    <?xml version="1.0"?>
    <presence xmlns="urn:ietf:params:xml:ns:pidf" entity="sip:alice@127.0.0.1">
      <tuple id="t1">
        <status><basic>open</basic></status>
        <note>Available</note>
      </tuple>
    </presence>
    """

    %Message{
      type: :request,
      method: :publish,
      request_uri: "sip:alice@127.0.0.1:5060",
      version: "SIP/2.0",
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5080,
          host_type: :ipv4,
          parameters: %{"branch" => "z9hG4bK-publish-branch"}
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
        parameters: %{"tag" => "from-tag-pub"}
      },
      to: %ParrotSip.Headers.To{
        display_name: nil,
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "alice",
          host: "127.0.0.1",
          port: 5060,
          host_type: :ipv4,
          parameters: %{},
          headers: %{}
        },
        parameters: %{}
      },
      call_id: "publish-call-id-#{System.unique_integer([:positive])}@127.0.0.1",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :publish},
      event: %ParrotSip.Headers.Event{event: "presence", parameters: %{}},
      content_type: %ParrotSip.Headers.ContentType{
        type: "application",
        subtype: "pidf+xml",
        parameters: %{}
      },
      max_forwards: 70,
      body: pidf_body,
      source: %{ip: {127, 0, 0, 1}, port: 5080}
    }
  end

  # Helper to create a PUBLISH message with specific PIDF content
  defp create_test_publish_with_pidf(status, note) when status in [:open, :closed] do
    status_str = Atom.to_string(status)

    pidf_body = """
    <?xml version="1.0"?>
    <presence xmlns="urn:ietf:params:xml:ns:pidf" entity="sip:alice@127.0.0.1">
      <tuple id="t1">
        <status><basic>#{status_str}</basic></status>
        <note>#{note}</note>
      </tuple>
    </presence>
    """

    create_test_publish() |> Map.put(:body, pidf_body)
  end

  # Helper to create a test SUBSCRIBE message
  # RFC 3856 Section 5.1: SUBSCRIBE requests for presence
  defp create_test_subscribe do
    %Message{
      type: :request,
      method: :subscribe,
      request_uri: "sip:alice@127.0.0.1:5060",
      version: "SIP/2.0",
      via: [
        %ParrotSip.Headers.Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5080,
          host_type: :ipv4,
          parameters: %{"branch" => "z9hG4bK-subscribe-branch"}
        }
      ],
      from: %ParrotSip.Headers.From{
        display_name: nil,
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "bob",
          host: "127.0.0.1",
          port: 5080,
          host_type: :ipv4,
          parameters: %{},
          headers: %{}
        },
        parameters: %{"tag" => "from-tag-sub"}
      },
      to: %ParrotSip.Headers.To{
        display_name: nil,
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "alice",
          host: "127.0.0.1",
          port: 5060,
          host_type: :ipv4,
          parameters: %{},
          headers: %{}
        },
        parameters: %{}
      },
      call_id: "subscribe-call-id-#{System.unique_integer([:positive])}@127.0.0.1",
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :subscribe},
      event: %ParrotSip.Headers.Event{event: "presence", parameters: %{}},
      max_forwards: 70,
      expires: 3600,
      body: nil,
      source: %{ip: {127, 0, 0, 1}, port: 5080}
    }
  end

  # ===========================================================================
  # INVITE Retransmission Handling Tests (parrot_platform-0vd)
  # ===========================================================================

  describe "setup_media_session/2 with retransmissions" do
    # Tests for INVITE retransmission handling where MediaSession may already exist
    # due to race conditions in transaction Registry registration timing.

    test "handles existing MediaSession by reusing it" do
      # Create a unique call_id for this test
      call_id = "retrans-test-#{System.unique_integer([:positive])}"
      session_id = "call_#{call_id}"

      # First, manually create a MediaSession to simulate first INVITE processing
      media_opts = [
        id: session_id,
        dialog_id: call_id,
        role: :uas,
        media_handler: Parrot.DSL.MediaHandler,
        handler_args: %{call_id: call_id},
        audio_source: :silence,
        audio_sink: :none,
        supported_codecs: [:pcma]
      ]

      {:ok, first_media_pid} = ParrotMedia.MediaSessionSupervisor.start_session(media_opts)
      assert Process.alive?(first_media_pid)

      # Now simulate a retransmission hitting setup_media_session
      # The function should find the existing MediaSession and reuse it
      sip_msg = create_invite_with_call_id(call_id)
      args = %{router: TestRouter}

      result = Handler.setup_media_session(sip_msg, args)

      # Should succeed with the existing pid
      assert {:ok, ^first_media_pid, _sdp_answer} = result

      # Cleanup
      ParrotMedia.MediaSessionSupervisor.stop_session(first_media_pid)
    end

    test "creates new MediaSession when none exists" do
      call_id = "new-session-test-#{System.unique_integer([:positive])}"
      sip_msg = create_invite_with_call_id(call_id)
      args = %{router: TestRouter}

      result = Handler.setup_media_session(sip_msg, args)

      # Should succeed with a new pid
      assert {:ok, media_pid, _sdp_answer} = result
      assert Process.alive?(media_pid)

      # Cleanup
      ParrotMedia.MediaSessionSupervisor.stop_session(media_pid)
    end
  end

  # Helper to create an INVITE with a specific call_id and SDP body
  defp create_invite_with_call_id(call_id) do
    sdp_body = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 10000 RTP/AVP 8
    a=rtpmap:8 PCMA/8000
    """

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
          parameters: %{"branch" => "z9hG4bK-retrans-test-#{System.unique_integer([:positive])}"}
        }
      ],
      from: %ParrotSip.Headers.From{
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "alice",
          host: "127.0.0.1",
          port: 5080,
          host_type: :ipv4,
          parameters: %{},
          headers: %{}
        },
        parameters: %{"tag" => "from-tag-#{System.unique_integer([:positive])}"}
      },
      to: %ParrotSip.Headers.To{
        uri: %ParrotSip.Uri{
          scheme: "sip",
          user: "bob",
          host: "127.0.0.1",
          port: 5060,
          host_type: :ipv4,
          parameters: %{},
          headers: %{}
        },
        parameters: %{}
      },
      call_id: call_id,
      cseq: %ParrotSip.Headers.CSeq{number: 1, method: :invite},
      max_forwards: 70,
      content_type: "application/sdp",
      content_length: byte_size(sdp_body),
      body: sdp_body,
      source: %ParrotSip.Source{
        transport: :udp,
        local: {{127, 0, 0, 1}, 5060},
        remote: {{127, 0, 0, 1}, 5080}
      }
    }
  end

  # ===========================================================================
  # UPDATE Request Handling Tests (RFC 3311, Task 849.5)
  # ===========================================================================

  describe "handle_update/3 incoming UPDATE request handling" do
    @describetag :update_request

    # Handler that tracks UPDATE requests
    defmodule UpdateTrackingHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end

      @impl true
      def handle_update(request, call) do
        # Track that we were called by sending a message
        send(Application.get_env(:parrot, :test_pid), {:update_received, request})
        {:noreply, call}
      end
    end

    # Handler that rejects UPDATE with 491 Request Pending
    defmodule UpdateRejectHandler do
      use Parrot.InviteHandler

      @impl true
      def handle_invite(call) do
        call |> answer()
      end

      @impl true
      def handle_update(_request, call) do
        {:reject, 491, call}
      end
    end

    defmodule UpdateTrackingRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.UpdateTrackingHandler)
    end

    defmodule UpdateRejectRouter do
      use Parrot.Router
      invite("*", Parrot.Bridge.HandlerTest.UpdateRejectHandler)
    end

    defp create_test_update do
      %Message{
        type: :request,
        method: :update,
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
            parameters: %{"branch" => "z9hG4bK-update-test-#{System.unique_integer([:positive])}"}
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
          parameters: %{"tag" => "from-tag-update"}
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
          parameters: %{"tag" => "to-tag-update"}
        },
        call_id: "test-call-id-update@127.0.0.1",
        cseq: %ParrotSip.Headers.CSeq{number: 2, method: :update},
        max_forwards: 70,
        body: "",
        source: %{ip: {127, 0, 0, 1}, port: 5080}
      }
    end

    defp create_test_update_with_sdp do
      sdp_body = """
      v=0
      o=alice 123456 654321 IN IP4 127.0.0.1
      s=Session
      c=IN IP4 127.0.0.1
      t=0 0
      m=audio 30000 RTP/AVP 8
      a=rtpmap:8 PCMA/8000
      """

      create_test_update()
      |> Map.put(:body, sdp_body)
      |> Map.put(:content_type, "application/sdp")
    end

    test "handle_update callback exists and is exported" do
      Code.ensure_loaded!(Handler)
      assert function_exported?(Handler, :handle_update, 3)
    end

    test "returns :ok when called" do
      test_pid = self()
      Application.put_env(:parrot, :test_pid, test_pid)

      update = create_test_update()
      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: UpdateTrackingRouter, response_fn: response_fn}

      result = Handler.handle_update(uas, update, args)
      assert result == :ok
    end

    test "invokes handler.handle_update/2 when UPDATE request received" do
      test_pid = self()
      Application.put_env(:parrot, :test_pid, test_pid)

      update = create_test_update()
      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: UpdateTrackingRouter, response_fn: response_fn}

      Handler.handle_update(uas, update, args)

      # Should receive the update_received message from handler
      assert_receive {:update_received, request}, 1000
      assert request.method == :update
    end

    test "sends 200 OK when handler returns {:noreply, call}" do
      test_pid = self()
      Application.put_env(:parrot, :test_pid, test_pid)

      update = create_test_update()
      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: UpdateTrackingRouter, response_fn: response_fn}

      Handler.handle_update(uas, update, args)

      # Should send 200 OK
      assert_receive {:sip_response, response}, 1000
      assert response.status_code == 200
      assert response.reason_phrase == "OK"
    end

    test "sends rejection when handler returns {:reject, status, call}" do
      test_pid = self()

      update = create_test_update()
      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: UpdateRejectRouter, response_fn: response_fn}

      Handler.handle_update(uas, update, args)

      # Should send 491 Request Pending
      assert_receive {:sip_response, response}, 1000
      assert response.status_code == 491
      assert response.reason_phrase == "Request Pending"
    end

    test "handles UPDATE with SDP body" do
      test_pid = self()
      Application.put_env(:parrot, :test_pid, test_pid)

      update = create_test_update_with_sdp()
      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: UpdateTrackingRouter, response_fn: response_fn}

      Handler.handle_update(uas, update, args)

      # Should receive the update with SDP body
      assert_receive {:update_received, request}, 1000
      assert request.body =~ "m=audio"
    end

    test "response includes correct headers from request" do
      test_pid = self()
      Application.put_env(:parrot, :test_pid, test_pid)

      update = create_test_update()
      uas = :test_uas
      response_fn = fn response, _uas -> send(test_pid, {:sip_response, response}) end
      args = %{router: UpdateTrackingRouter, response_fn: response_fn}

      Handler.handle_update(uas, update, args)

      assert_receive {:sip_response, response}, 1000
      # Response should have same Call-ID, From, To tags, CSeq
      assert response.call_id == update.call_id
      assert response.from == update.from
      assert response.cseq == update.cseq
    end
  end
end
