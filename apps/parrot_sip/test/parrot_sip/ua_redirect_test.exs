defmodule ParrotSip.UA.RedirectTest do
  @moduledoc """
  Tests for 3xx redirect handling in ParrotSip.UA.

  RFC 3261 Section 21: Redirect classes (300-399) provide alternative
  locations where the callee might be reachable.
  """
  use ExUnit.Case, async: true

  alias ParrotSip.{Message, UA}
  alias ParrotSip.Headers.{Contact, Via, From, To, CSeq}

  @moduletag :ua_redirect

  # ============================================================================
  # Test Handler Module
  # ============================================================================

  defmodule RedirectTestHandler do
    @moduledoc """
    Test handler that tracks redirect events.
    """
    use ParrotSip.UA.Handler

    @impl true
    def init(test_pid) do
      {:ok, %{test_pid: test_pid, redirects: []}}
    end

    @impl true
    def handle_redirect(_ua, status_code, _response, contacts, state) do
      send(state.test_pid, {:redirect, status_code, contacts})

      # Default: follow first redirect
      case contacts do
        [first | _] ->
          {:redirect, first, %{state | redirects: state.redirects ++ [{status_code, contacts}]}}

        [] ->
          {:stop, :no_contacts, state}
      end
    end

    @impl true
    def handle_rejected(_ua, response, _entity, state) do
      send(state.test_pid, {:rejected, response.status_code})
      {:ok, state}
    end

    @impl true
    def handle_answered(_ua, _response, _entity, state) do
      send(state.test_pid, :answered)
      {:ok, state}
    end

    @impl true
    def handle_incoming(_ua, _invite, _entity, state) do
      {:ok, state}
    end

    @impl true
    def handle_hangup(_ua, _message, _entity, state) do
      {:ok, state}
    end
  end

  defmodule RejectRedirectHandler do
    @moduledoc """
    Test handler that stops on redirect.
    """
    use ParrotSip.UA.Handler

    @impl true
    def init(test_pid) do
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_redirect(_ua, status_code, _response, contacts, state) do
      send(state.test_pid, {:redirect_stopped, status_code, contacts})
      {:stop, :redirect_declined, state}
    end

    @impl true
    def handle_rejected(_ua, response, _entity, state) do
      send(state.test_pid, {:rejected, response.status_code})
      {:ok, state}
    end

    @impl true
    def handle_incoming(_ua, _invite, _entity, state) do
      {:ok, state}
    end

    @impl true
    def handle_answered(_ua, _response, _entity, state) do
      {:ok, state}
    end

    @impl true
    def handle_hangup(_ua, _message, _entity, state) do
      {:ok, state}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp build_302_response(contact_uris) when is_list(contact_uris) do
    contacts =
      contact_uris
      |> Enum.with_index()
      |> Enum.map(fn {uri, idx} ->
        # Assign q-values in descending order (first has highest priority)
        q = 1.0 - idx * 0.1
        Contact.new(uri) |> Contact.with_q(q)
      end)

    %Message{
      type: :response,
      status_code: 302,
      reason_phrase: "Moved Temporarily",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-test-branch"}
        }
      ],
      from: %From{
        uri: "sip:alice@example.com",
        display_name: "Alice",
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %To{
        uri: "sip:bob@example.com",
        display_name: "Bob",
        parameters: %{}
      },
      call_id: "test-call-id-#{System.unique_integer([:positive])}",
      cseq: %CSeq{number: 1, method: :invite},
      contact: contacts,
      body: nil
    }
  end

  defp build_301_response(contact_uri) do
    %Message{
      type: :response,
      status_code: 301,
      reason_phrase: "Moved Permanently",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-test-branch"}
        }
      ],
      from: %From{
        uri: "sip:alice@example.com",
        display_name: "Alice",
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %To{
        uri: "sip:bob@example.com",
        display_name: "Bob",
        parameters: %{}
      },
      call_id: "test-call-id-#{System.unique_integer([:positive])}",
      cseq: %CSeq{number: 1, method: :invite},
      contact: [Contact.new(contact_uri)],
      body: nil
    }
  end

  defp build_404_response do
    %Message{
      type: :response,
      status_code: 404,
      reason_phrase: "Not Found",
      via: [
        %Via{
          protocol: "SIP",
          version: "2.0",
          transport: :udp,
          host: "127.0.0.1",
          port: 5060,
          parameters: %{"branch" => "z9hG4bK-test-branch"}
        }
      ],
      from: %From{
        uri: "sip:alice@example.com",
        display_name: "Alice",
        parameters: %{"tag" => "from-tag-123"}
      },
      to: %To{
        uri: "sip:bob@example.com",
        display_name: "Bob",
        parameters: %{}
      },
      call_id: "test-call-id-#{System.unique_integer([:positive])}",
      cseq: %CSeq{number: 1, method: :invite},
      contact: [],
      body: nil
    }
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "3xx redirect handling" do
    test "302 response invokes handle_redirect callback with contacts" do
      # Create a test entity_id
      entity_id = "test-entity-#{System.unique_integer([:positive])}"

      # Build a 302 response with multiple Contact headers
      response = build_302_response(["sip:bob@new-host.com", "sip:bob@backup.com"])

      # Simulate receiving the response via handle_cast
      # We need to test the UA module directly
      state = %{
        handler_module: RedirectTestHandler,
        handler_state: %{test_pid: self(), redirects: []},
        entities: %{
          entity_id => %{
            state: :trying,
            original_request: nil,
            redirect_count: 0
          }
        },
        registrations: %{},
        port: 5060,
        transport: nil,
        local_host: "127.0.0.1"
      }

      # Directly call handle_cast to test 3xx handling
      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      # Verify handle_redirect was called with contacts
      assert_receive {:redirect, 302, contacts}, 1000
      assert length(contacts) == 2

      # Contacts should be sorted by q-value (highest first)
      [first, second] = contacts
      assert first.uri.host == "new-host.com"
      assert second.uri.host == "backup.com"
    end

    test "301 response (Moved Permanently) invokes handle_redirect" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      response = build_301_response("sip:bob@permanent-new-location.com")

      state = %{
        handler_module: RedirectTestHandler,
        handler_state: %{test_pid: self(), redirects: []},
        entities: %{
          entity_id => %{
            state: :trying,
            original_request: nil,
            redirect_count: 0
          }
        },
        registrations: %{},
        port: 5060,
        transport: nil,
        local_host: "127.0.0.1"
      }

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      assert_receive {:redirect, 301, contacts}, 1000
      assert length(contacts) == 1
      [contact] = contacts
      assert contact.uri.host == "permanent-new-location.com"
    end

    test "4xx response still invokes handle_rejected (not redirect)" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      response = build_404_response()

      state = %{
        handler_module: RedirectTestHandler,
        handler_state: %{test_pid: self(), redirects: []},
        entities: %{
          entity_id => %{
            state: :trying,
            original_request: nil,
            redirect_count: 0
          }
        },
        registrations: %{},
        port: 5060,
        transport: nil,
        local_host: "127.0.0.1"
      }

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      # Should receive rejected, NOT redirect
      assert_receive {:rejected, 404}, 1000
      refute_receive {:redirect, _, _}, 100
    end

    test "handler returning {:stop, reason, state} terminates entity" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"
      response = build_302_response(["sip:bob@new-host.com"])

      state = %{
        handler_module: RejectRedirectHandler,
        handler_state: %{test_pid: self()},
        entities: %{
          entity_id => %{
            state: :trying,
            original_request: nil,
            redirect_count: 0
          }
        },
        registrations: %{},
        port: 5060,
        transport: nil,
        local_host: "127.0.0.1"
      }

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, new_state} = UA.handle_cast(message, state)

      assert_receive {:redirect_stopped, 302, _contacts}, 1000

      # Entity should be terminated
      entity = Map.get(new_state.entities, entity_id)
      assert entity.state == :terminated
    end

    test "contacts are sorted by q-value (highest first)" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"

      # Build contacts with explicit q-values (out of order)
      contacts = [
        Contact.new("sip:bob@low.com") |> Contact.with_q(0.3),
        Contact.new("sip:bob@high.com") |> Contact.with_q(0.9),
        Contact.new("sip:bob@medium.com") |> Contact.with_q(0.6)
      ]

      response = %Message{
        type: :response,
        status_code: 302,
        reason_phrase: "Moved Temporarily",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "127.0.0.1",
            port: 5060,
            parameters: %{"branch" => "z9hG4bK-test-branch"}
          }
        ],
        from: %From{
          uri: "sip:alice@example.com",
          display_name: "Alice",
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: "sip:bob@example.com",
          display_name: "Bob",
          parameters: %{}
        },
        call_id: "test-call-id-#{System.unique_integer([:positive])}",
        cseq: %CSeq{number: 1, method: :invite},
        contact: contacts,
        body: nil
      }

      state = %{
        handler_module: RedirectTestHandler,
        handler_state: %{test_pid: self(), redirects: []},
        entities: %{
          entity_id => %{
            state: :trying,
            original_request: nil,
            redirect_count: 0
          }
        },
        registrations: %{},
        port: 5060,
        transport: nil,
        local_host: "127.0.0.1"
      }

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      assert_receive {:redirect, 302, sorted_contacts}, 1000

      # Should be sorted: high (0.9), medium (0.6), low (0.3)
      [first, second, third] = sorted_contacts
      assert first.uri.host == "high.com"
      assert second.uri.host == "medium.com"
      assert third.uri.host == "low.com"
    end

    test "contacts without q-value default to q=1.0" do
      entity_id = "test-entity-#{System.unique_integer([:positive])}"

      # Build contacts - one with q, one without
      contacts = [
        Contact.new("sip:bob@with-q.com") |> Contact.with_q(0.5),
        Contact.new("sip:bob@no-q.com")
      ]

      response = %Message{
        type: :response,
        status_code: 302,
        reason_phrase: "Moved Temporarily",
        via: [
          %Via{
            protocol: "SIP",
            version: "2.0",
            transport: :udp,
            host: "127.0.0.1",
            port: 5060,
            parameters: %{"branch" => "z9hG4bK-test-branch"}
          }
        ],
        from: %From{
          uri: "sip:alice@example.com",
          display_name: "Alice",
          parameters: %{"tag" => "from-tag-123"}
        },
        to: %To{
          uri: "sip:bob@example.com",
          display_name: "Bob",
          parameters: %{}
        },
        call_id: "test-call-id-#{System.unique_integer([:positive])}",
        cseq: %CSeq{number: 1, method: :invite},
        contact: contacts,
        body: nil
      }

      state = %{
        handler_module: RedirectTestHandler,
        handler_state: %{test_pid: self(), redirects: []},
        entities: %{
          entity_id => %{
            state: :trying,
            original_request: nil,
            redirect_count: 0
          }
        },
        registrations: %{},
        port: 5060,
        transport: nil,
        local_host: "127.0.0.1"
      }

      message = {:uac_response, entity_id, {:response, response}}
      {:noreply, _new_state} = UA.handle_cast(message, state)

      assert_receive {:redirect, 302, sorted_contacts}, 1000

      # no-q.com should come first (defaults to q=1.0)
      [first, second] = sorted_contacts
      assert first.uri.host == "no-q.com"
      assert second.uri.host == "with-q.com"
    end
  end
end
