# Test Plan and Strategy

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-03

## 1. Overview

This document defines the complete testing strategy for UAS/UAC/B2BUA implementation, covering unit tests, integration tests, property-based tests, and acceptance tests.

### 1.1 Test Pyramid

```
                    ╱╲
                   ╱  ╲
                  ╱ E2E╲              10 scenarios
                 ╱──────╲
                ╱        ╲
               ╱Integration╲         ~50 tests
              ╱────────────╲
             ╱              ╲
            ╱   Property     ╲      ~20 properties
           ╱────────────────── ╲
          ╱                     ╲
         ╱        Unit           ╲   ~200 tests
        ╱─────────────────────────╲
```

**Test Distribution:**
- **Unit Tests:** 70% - Fast, isolated, comprehensive coverage
- **Property Tests:** 15% - State machine verification, edge cases
- **Integration Tests:** 10% - SIPp scenarios, real protocol
- **E2E Tests:** 5% - Complete call flows, acceptance criteria

---

## 2. Unit Tests

### 2.1 Module Coverage

**Target: 90%+ line coverage, 100% critical path coverage**

| Module | Test File | Coverage Target | Critical Paths |
|--------|-----------|-----------------|----------------|
| `ParrotSip.UAS` | `uas_test.exs` | 95% | All state transitions |
| `ParrotSip.UAC` | `uac_test.exs` | 95% | All state transitions |
| `ParrotSip.B2BUA.Session` | `session_test.exs` | 95% | Routing, forking, bridging |
| `ParrotSip.Subscription` | `subscription_test.exs` | 95% | Both roles, state transitions |
| `ParrotSip.Auth` | `auth_test.exs` | 95% | Challenge, verify, nonce mgmt |
| `ParrotSip.Presence` | `presence_test.exs` | 90% | Publish, subscribe, NOTIFY |
| `ParrotSip.MWI` | `mwi_test.exs` | 90% | Publish, parse, subscribe |
| `ParrotSip.UAS.Supervisor` | `uas_supervisor_test.exs` | 85% | Start/stop, crashes |
| `ParrotSip.UAC.Supervisor` | `uac_supervisor_test.exs` | 85% | Start/stop, crashes |
| `ParrotSip.B2BUA.SessionSupervisor` | `session_supervisor_test.exs` | 85% | Start/stop, crashes |
| `ParrotSip.Subscription.Supervisor` | `subscription_supervisor_test.exs` | 85% | Start/stop, crashes |

### 2.2 UAS Unit Tests

**File:** `test/parrot_sip/uas_test.exs`

```elixir
defmodule ParrotSip.UASTest do
  use ExUnit.Case, async: true

  alias ParrotSip.UAS
  alias ParrotSip.Test.Helpers

  describe "start_link/1" do
    test "creates UAS entity from INVITE" do
      invite = Helpers.build_invite()

      {:ok, uas} = UAS.start_link(
        invite: invite,
        owner: self(),
        notify_fun: fn event, pid -> send(self(), {event, pid}) end
      )

      assert Process.alive?(uas)
      assert_receive {:uas_created, ^uas}
    end

    test "returns error for invalid INVITE" do
      invalid_invite = %{}

      assert {:error, :invalid_invite} = UAS.start_link(
        invite: invalid_invite,
        owner: self(),
        notify_fun: fn _, _ -> :ok end
      )
    end
  end

  describe "ring/2" do
    setup do
      {:ok, uas} = start_test_uas()
      {:ok, uas: uas}
    end

    test "sends 180 Ringing", %{uas: uas} do
      assert :ok = UAS.ring(uas)

      # Verify SIP message sent
      assert_receive {:sip_sent, %{status_code: 180}}
    end

    test "transitions to :ringing state", %{uas: uas} do
      UAS.ring(uas)

      {:ok, state, _data} = UAS.get_state(uas)
      assert state == :ringing
    end

    test "returns error when already answered", %{uas: uas} do
      UAS.answer(uas, sdp: "v=0...")

      assert {:error, :invalid_state} = UAS.ring(uas)
    end
  end

  describe "answer/2" do
    test "sends 200 OK with SDP" do
      {:ok, uas} = start_test_uas()
      sdp = Helpers.build_sdp()

      assert :ok = UAS.answer(uas, sdp: sdp)

      assert_receive {:sip_sent, %{status_code: 200, body: ^sdp}}
    end

    test "starts Timer H (ACK wait)" do
      {:ok, uas} = start_test_uas()

      UAS.answer(uas, sdp: "v=0...")

      # Verify timer started (check process state)
      {:ok, :answering, data} = UAS.get_state(uas)
      assert data.timers.timer_h != nil
    end

    test "validates SDP" do
      {:ok, uas} = start_test_uas()

      assert {:error, :invalid_sdp} = UAS.answer(uas, sdp: "invalid")
    end
  end

  describe "reject/3" do
    test "sends error response" do
      {:ok, uas} = start_test_uas()

      assert :ok = UAS.reject(uas, 486, "Busy Here")

      assert_receive {:sip_sent, %{status_code: 486, reason_phrase: "Busy Here"}}
    end

    test "transitions to :terminated" do
      {:ok, uas} = start_test_uas()

      UAS.reject(uas, 486, "Busy Here")

      assert_down(uas, timeout: 1000)
    end
  end

  describe "state machine transitions" do
    test "incoming → ringing → answering → established" do
      {:ok, uas} = start_test_uas()

      # incoming
      {:ok, :incoming, _} = UAS.get_state(uas)

      # → ringing
      UAS.ring(uas)
      {:ok, :ringing, _} = UAS.get_state(uas)

      # → answering
      UAS.answer(uas, sdp: "v=0...")
      {:ok, :answering, _} = UAS.get_state(uas)

      # → established (after ACK)
      send_ack_to_uas(uas)
      {:ok, :established, _} = UAS.get_state(uas)
    end

    test "incoming → answering → established (no ringing)" do
      {:ok, uas} = start_test_uas()

      UAS.answer(uas, sdp: "v=0...")
      send_ack_to_uas(uas)

      {:ok, :established, _} = UAS.get_state(uas)
    end

    test "incoming → terminated (reject)" do
      {:ok, uas} = start_test_uas()

      UAS.reject(uas, 603, "Decline")

      assert_down(uas)
    end
  end

  describe "CANCEL handling" do
    test "CANCEL in incoming state" do
      {:ok, uas} = start_test_uas()

      send_cancel_to_uas(uas)

      assert_receive {:sip_sent, %{status_code: 487}}  # INVITE
      assert_receive {:sip_sent, %{status_code: 200}}  # CANCEL
      assert_receive {:uas_cancelled, _}
    end

    test "CANCEL in ringing state" do
      {:ok, uas} = start_test_uas()
      UAS.ring(uas)

      send_cancel_to_uas(uas)

      assert_receive {:uas_cancelled, _}
      assert_down(uas)
    end

    test "CANCEL after answered (no effect)" do
      {:ok, uas} = start_test_uas()
      UAS.answer(uas, sdp: "v=0...")

      send_cancel_to_uas(uas)

      # UAS ignores CANCEL after 200 OK sent
      {:ok, :answering, _} = UAS.get_state(uas)
    end
  end

  describe "Timer H (ACK timeout)" do
    @tag :timers
    test "fires after 32 seconds without ACK" do
      {:ok, uas} = start_test_uas()
      UAS.answer(uas, sdp: "v=0...")

      # Wait for Timer H (32s, but use 100ms for testing)
      # Note: Override timer in test config
      assert_receive {:uas_timeout, ^uas}, 150
    end

    test "cancelled when ACK received" do
      {:ok, uas} = start_test_uas()
      UAS.answer(uas, sdp: "v=0...")

      send_ack_to_uas(uas)

      # Timer H should be cancelled
      {:ok, :established, data} = UAS.get_state(uas)
      assert data.timers.timer_h == nil
    end
  end

  describe "BYE handling" do
    test "receives BYE in established state" do
      {:ok, uas} = start_established_uas()

      send_bye_to_uas(uas)

      assert_receive {:sip_sent, %{status_code: 200}}  # 200 OK to BYE
      assert_receive {:uas_bye, _, _}
      assert_down(uas)
    end

    test "sends BYE via hangup/1" do
      {:ok, uas} = start_established_uas()

      UAS.hangup(uas)

      assert_receive {:sip_sent, %{method: :bye}}
      assert_down(uas)
    end
  end

  describe "re-INVITE handling" do
    test "receives re-INVITE for hold" do
      {:ok, uas} = start_established_uas()

      hold_sdp = build_hold_sdp()
      send_reinvite_to_uas(uas, hold_sdp)

      assert_receive {:uas_reinvite, ^uas, invite}
      assert invite.body == hold_sdp
    end
  end

  describe "error cases" do
    test "handler decision timeout" do
      {:ok, uas} = start_test_uas()

      # Don't call ring/answer/reject
      # Wait for timeout (10s, overridden in test)

      assert_receive {:sip_sent, %{status_code: 408}}, 150
      assert_down(uas)
    end

    test "invalid SDP rejected" do
      {:ok, uas} = start_test_uas()

      assert {:error, :invalid_sdp} = UAS.answer(uas, sdp: "")
      assert {:error, :invalid_sdp} = UAS.answer(uas, sdp: nil)
      assert {:error, :invalid_sdp} = UAS.answer(uas, sdp: "v=invalid")
    end

    test "owner process dies" do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, uas} = UAS.start_link(
        invite: build_invite(),
        owner: owner,
        notify_fun: fn _, _ -> :ok end
      )

      # Kill owner
      Process.exit(owner, :kill)

      # UAS should terminate
      assert_down(uas, timeout: 1000)
    end
  end
end
```

**Total UAS Tests:** ~50 tests

### 2.3 UAC Unit Tests

**Similar structure to UAS tests:**
- start_link/1 tests
- cancel/1 tests
- hangup/1 tests
- State machine transitions
- Response handling (1xx, 2xx, 3xx-6xx)
- Timer B (INVITE timeout)
- CANCEL race conditions
- Error cases

**Total UAC Tests:** ~50 tests

### 2.4 Session Unit Tests

**File:** `test/parrot_sip/b2bua/session_test.exs`

```elixir
defmodule ParrotSip.B2BUA.SessionTest do
  use ExUnit.Case, async: true

  describe "routing" do
    test "handler returns single destination" do
      defmodule SingleRoute do
        use B2BUA.Handler
        def init(_), do: {:ok, %{}}
        def route_call(_invite, state) do
          {:route, "sip:dest@example.com", state}
        end
      end

      {:ok, session} = Session.start_link(
        invite: build_invite(),
        handler: SingleRoute,
        handler_state: %{}
      )

      # Verify UAS created
      assert_receive {:uas_created, uas_pid}

      # Verify UAC created with correct destination
      assert_receive {:uac_created, uac_pid, "sip:dest@example.com"}
    end

    test "handler returns fork destinations" do
      defmodule ForkRoute do
        use B2BUA.Handler
        def init(_), do: {:ok, %{}}
        def route_call(_invite, state) do
          dests = ["sip:phone@...", "sip:mobile@...", "sip:desk@..."]
          {:fork, dests, state}
        end
      end

      {:ok, session} = Session.start_link(
        invite: build_invite(),
        handler: ForkRoute
      )

      # Verify 3 UACs created
      assert_receive {:uac_created, uac1, "sip:phone@..."}
      assert_receive {:uac_created, uac2, "sip:mobile@..."}
      assert_receive {:uac_created, uac3, "sip:desk@..."}
    end

    test "handler rejects call" do
      defmodule RejectRoute do
        use B2BUA.Handler
        def init(_), do: {:ok, %{}}
        def route_call(_invite, state) do
          {:reject, 404, "Not Found", state}
        end
      end

      {:ok, session} = Session.start_link(
        invite: build_invite(),
        handler: RejectRoute
      )

      # Verify 404 sent to A-leg
      assert_receive {:sip_sent, %{status_code: 404}}

      # Session terminates
      assert_down(session)
    end
  end

  describe "forking" do
    test "first answer wins" do
      {:ok, session} = start_forking_session(3)  # 3 destinations

      # Simulate B-leg 2 answers first
      send_uac_answer(session, :uac_2, "sdp2")

      # Verify other UACs cancelled
      assert_receive {:uac_cancelled, :uac_1}
      assert_receive {:uac_cancelled, :uac_3}

      # Verify A-leg answered with SDP from UAC 2
      assert_receive {:uas_answered, "sdp2"}
    end

    test "all forks fail" do
      {:ok, session} = start_forking_session(3)

      # All reject
      send_uac_reject(session, :uac_1, 486)
      send_uac_reject(session, :uac_2, 480)
      send_uac_reject(session, :uac_3, 404)

      # A-leg gets failure response
      assert_receive {:sip_sent, %{status_code: code}}
      assert code in [480, 486, 404]  # One of the failures

      assert_down(session)
    end
  end

  describe "SDP modification" do
    test "modifies SDP when forwarding A→B" do
      defmodule SDPModifier do
        use B2BUA.Handler
        def init(_), do: {:ok, %{}}
        def route_call(_i, s), do: {:route, "sip:dest", s}

        def modify_sdp(:a_to_b, sdp, state) do
          modified = String.replace(sdp, "RTP/AVP", "RTP/SAVP")
          {:ok, modified, state}
        end

        def modify_sdp(:b_to_a, sdp, state) do
          {:ok, sdp, state}  # Pass through
        end
      end

      {:ok, session} = Session.start_link(
        invite: build_invite(sdp: "m=audio 1234 RTP/AVP"),
        handler: SDPModifier
      )

      # Verify B-leg INVITE has modified SDP
      assert_receive {:uac_invite_sent, invite}
      assert invite.body =~ "RTP/SAVP"
    end
  end

  describe "established call" do
    test "both legs established" do
      {:ok, session} = start_simple_session()

      simulate_call_establishment(session)

      assert_receive {:session_established, ^session}

      # Verify handler callback called
      assert_receive {:handler_established, session_info}
    end

    test "A-leg hangs up" do
      {:ok, session} = start_established_session()

      send_uas_bye(session)

      # B-leg should receive BYE
      assert_receive {:uac_bye_sent}

      assert_down(session)
    end

    test "B-leg hangs up" do
      {:ok, session} = start_established_session()

      send_uac_bye(session)

      # A-leg should receive BYE
      assert_receive {:uas_bye_sent}

      assert_down(session)
    end
  end

  describe "error handling" do
    test "UAS crashes" do
      {:ok, session} = start_test_session()
      {:ok, uas} = get_session_uas(session)

      Process.exit(uas, :kill)

      # Session should terminate UAC and exit
      assert_down(session, timeout: 1000)
    end

    test "UAC crashes" do
      {:ok, session} = start_test_session()
      {:ok, uac} = get_session_uac(session)

      Process.exit(uac, :kill)

      # Session should reject A-leg and exit
      assert_receive {:sip_sent, %{status_code: code}}
      assert code >= 500

      assert_down(session)
    end

    test "handler crashes during routing" do
      defmodule CrashHandler do
        use B2BUA.Handler
        def init(_), do: {:ok, %{}}
        def route_call(_i, _s), do: raise("crash")
      end

      {:ok, session} = Session.start_link(
        invite: build_invite(),
        handler: CrashHandler
      )

      # Should send 500
      assert_receive {:sip_sent, %{status_code: 500}}

      assert_down(session)
    end
  end
end
```

**Total Session Tests:** ~40 tests

### 2.5 Auth Unit Tests

**File:** `test/parrot_sip/auth_test.exs`

```elixir
defmodule ParrotSip.AuthTest do
  use ExUnit.Case, async: true

  alias ParrotSip.Auth

  describe "challenge/2" do
    test "generates valid challenge" do
      challenge = Auth.challenge("example.com", qop: "auth")

      assert challenge.realm == "example.com"
      assert challenge.algorithm == "MD5"
      assert challenge.qop == "auth"
      assert is_binary(challenge.nonce)
      assert byte_size(challenge.nonce) > 0
    end

    test "supports SHA-256 algorithm" do
      challenge = Auth.challenge("example.com", algorithm: "SHA-256")

      assert challenge.algorithm == "SHA-256"
    end
  end

  describe "challenge_header/1" do
    test "generates valid WWW-Authenticate header" do
      challenge = Auth.challenge("example.com", qop: "auth")
      header = Auth.challenge_header(challenge)

      assert header =~ ~r/Digest realm="example\.com"/
      assert header =~ ~r/nonce="/
      assert header =~ ~r/algorithm=MD5/
      assert header =~ ~r/qop="auth"/
    end
  end

  describe "verify_credentials/4" do
    setup do
      challenge = Auth.challenge("example.com", qop: "auth")
      {:ok, challenge: challenge}
    end

    test "accepts valid credentials", %{challenge: challenge} do
      # Build request with Authorization header
      request = build_invite()
      auth_request = Auth.add_authorization(
        request,
        "alice",
        "secret",
        challenge
      )

      auth_header = auth_request.headers["Authorization"]

      assert :valid = Auth.verify_credentials(
        auth_header,
        %{username: "alice", password: "secret"},
        "INVITE",
        "sip:bob@example.com"
      )
    end

    test "rejects wrong password", %{challenge: challenge} do
      request = build_invite()
      auth_request = Auth.add_authorization(request, "alice", "wrong", challenge)
      auth_header = auth_request.headers["Authorization"]

      assert {:invalid, :wrong_credentials} = Auth.verify_credentials(
        auth_header,
        %{username: "alice", password: "secret"},
        "INVITE",
        "sip:bob@example.com"
      )
    end

    test "rejects stale nonce" do
      # Use nonce that doesn't exist
      auth_header = """
      Digest username="alice", realm="example.com", \
      nonce="invalid_nonce", uri="sip:bob@example.com", \
      response="deadbeef"
      """

      assert {:invalid, :stale_nonce} = Auth.verify_credentials(
        auth_header,
        %{username: "alice", password: "secret"},
        "INVITE",
        "sip:bob@example.com"
      )
    end

    test "rejects malformed Authorization header" do
      assert {:invalid, :bad_response} = Auth.verify_credentials(
        "malformed",
        %{username: "alice", password: "secret"},
        "INVITE",
        "sip:bob@example.com"
      )
    end
  end

  describe "nonce expiration" do
    test "nonce expires after TTL" do
      challenge = Auth.challenge("example.com")

      # Fast-forward time (requires time mocking)
      advance_time(:minutes, 6)

      request = build_invite()
      auth_request = Auth.add_authorization(request, "alice", "secret", challenge)
      auth_header = auth_request.headers["Authorization"]

      assert {:invalid, :stale_nonce} = Auth.verify_credentials(
        auth_header,
        %{username: "alice", password: "secret"},
        "INVITE",
        "sip:bob@example.com"
      )
    end
  end
end
```

**Total Auth Tests:** ~15 tests

### 2.6 Subscription Unit Tests

**File:** `test/parrot_sip/subscription_test.exs`

```elixir
defmodule ParrotSip.SubscriptionTest do
  use ExUnit.Case, async: true

  alias ParrotSip.Subscription

  describe "subscribe/1 (subscriber role)" do
    test "creates subscription and sends SUBSCRIBE" do
      {:ok, sub} = Subscription.subscribe(
        event_package: "presence",
        resource_uri: "sip:alice@example.com",
        expires: 3600,
        owner: self(),
        notify_fun: fn event, pid -> send(self(), {event, pid}) end
      )

      assert Process.alive?(sub)
      assert_receive {:sip_sent, %{method: :subscribe}}
    end

    test "handles 200 OK response" do
      {:ok, sub} = start_subscriber()

      # Simulate 200 OK from notifier
      send_response(sub, 200, %{expires: 3600})

      assert_receive {:subscription_active, ^sub}
    end

    test "handles rejection" do
      {:ok, sub} = start_subscriber()

      send_response(sub, 403, %{})

      assert_receive {:subscription_rejected, ^sub, 403}
    end

    test "receives NOTIFY" do
      {:ok, sub} = start_active_subscriber()

      # Simulate NOTIFY from notifier
      send_notify(sub, "open", "<presence>...</presence>")

      assert_receive {:notify, ^sub, "open", "<presence>...</presence>"}
    end

    test "refreshes subscription automatically" do
      {:ok, sub} = start_active_subscriber(expires: 1)

      # Wait for refresh
      :timer.sleep(800)

      assert_receive {:sip_sent, %{method: :subscribe, expires: 1}}
    end
  end

  describe "start_notifier/1 (notifier role)" do
    test "creates notifier from SUBSCRIBE" do
      subscribe_msg = build_subscribe()

      {:ok, notifier} = Subscription.start_notifier(
        subscribe: subscribe_msg,
        owner: self(),
        notify_fun: fn event, pid -> send(self(), {event, pid}) end
      )

      assert Process.alive?(notifier)
    end

    test "accept/2 sends 200 OK and initial NOTIFY" do
      {:ok, notifier} = start_notifier()

      :ok = Subscription.accept(notifier,
        initial_state: "open",
        initial_body: "<presence>...</presence>"
      )

      assert_receive {:sip_sent, %{status_code: 200}}
      assert_receive {:sip_sent, %{method: :notify, subscription_state: "active"}}
    end

    test "reject/3 sends error response" do
      {:ok, notifier} = start_notifier()

      :ok = Subscription.reject(notifier, 403, "Forbidden")

      assert_receive {:sip_sent, %{status_code: 403}}
    end

    test "notify/3 sends NOTIFY" do
      {:ok, notifier} = start_accepted_notifier()

      :ok = Subscription.notify(notifier, "closed", "<presence>...</presence>")

      assert_receive {:sip_sent, %{method: :notify}}
    end

    test "handles refresh SUBSCRIBE" do
      {:ok, notifier} = start_accepted_notifier()

      # Simulate refresh SUBSCRIBE
      send_subscribe_refresh(notifier)

      assert_receive {:sip_sent, %{status_code: 200}}
    end

    test "handles unsubscribe (Expires: 0)" do
      {:ok, notifier} = start_accepted_notifier()

      send_subscribe_unsubscribe(notifier)

      assert_receive {:sip_sent, %{status_code: 200}}
      assert_receive {:sip_sent, %{method: :notify, subscription_state: "terminated"}}
    end
  end

  describe "state transitions" do
    test "subscriber: pending -> active -> terminated" do
      {:ok, sub} = start_subscriber()
      assert :pending = get_state(sub)

      send_response(sub, 200, %{})
      assert :active = get_state(sub)

      Subscription.unsubscribe(sub)
      assert_eventually(fn -> :terminated = get_state(sub) end)
    end
  end
end
```

**Total Subscription Tests:** ~25 tests

### 2.7 Presence Unit Tests

**File:** `test/parrot_sip/presence_test.exs`

```elixir
defmodule ParrotSip.PresenceTest do
  use ExUnit.Case, async: false  # GenServer shared state

  alias ParrotSip.Presence

  setup do
    {:ok, presence} = Presence.start_link([])
    {:ok, presence: presence}
  end

  describe "publish/2" do
    test "publishes presence state" do
      :ok = Presence.publish("sip:alice@example.com",
        state: :online,
        note: "Available"
      )

      {:ok, presence} = Presence.get_presence("sip:alice@example.com")

      assert presence.entity == "sip:alice@example.com"
      assert presence.state == :online
      assert presence.note == "Available"
    end

    test "updates existing presence" do
      :ok = Presence.publish("sip:alice@example.com", state: :online)
      :ok = Presence.publish("sip:alice@example.com", state: :away)

      {:ok, presence} = Presence.get_presence("sip:alice@example.com")
      assert presence.state == :away
    end

    test "notifies subscribers when state changes" do
      # Subscribe first
      {:ok, _sub} = Presence.subscribe(
        "sip:bob@example.com",
        "sip:alice@example.com",
        callback: fn presence ->
          send(self(), {:presence_changed, presence.state})
        end
      )

      # Publish presence
      :ok = Presence.publish("sip:alice@example.com", state: :online)

      assert_receive {:presence_changed, :online}
    end
  end

  describe "subscribe/3" do
    test "creates subscription to presence" do
      # Publish initial state
      :ok = Presence.publish("sip:alice@example.com", state: :online)

      {:ok, sub} = Presence.subscribe(
        "sip:bob@example.com",
        "sip:alice@example.com"
      )

      assert is_pid(sub)
      # Should receive initial NOTIFY
      assert_receive {:sip_sent, %{method: :notify}}
    end

    test "returns error for non-existent presentity" do
      assert {:error, :not_found} = Presence.subscribe(
        "sip:bob@example.com",
        "sip:nonexistent@example.com"
      )
    end
  end

  describe "get_presence/1" do
    test "returns current presence" do
      :ok = Presence.publish("sip:alice@example.com", state: :busy)

      {:ok, presence} = Presence.get_presence("sip:alice@example.com")

      assert presence.state == :busy
    end

    test "returns error for unknown entity" do
      assert {:error, :not_found} = Presence.get_presence("sip:unknown@example.com")
    end
  end

  describe "unpublish/1" do
    test "removes presence (sets to offline)" do
      :ok = Presence.publish("sip:alice@example.com", state: :online)
      :ok = Presence.unpublish("sip:alice@example.com")

      {:ok, presence} = Presence.get_presence("sip:alice@example.com")
      assert presence.state == :offline
    end

    test "notifies subscribers of offline state" do
      :ok = Presence.publish("sip:alice@example.com", state: :online)

      {:ok, _sub} = Presence.subscribe(
        "sip:bob@example.com",
        "sip:alice@example.com",
        callback: fn p -> send(self(), {:state, p.state}) end
      )

      :ok = Presence.unpublish("sip:alice@example.com")

      assert_receive {:state, :offline}
    end
  end

  describe "to_pidf/1" do
    test "generates PIDF XML" do
      presence = %{
        entity: "sip:alice@example.com",
        state: :online,
        note: "Available",
        contact: "sip:alice@192.168.1.100"
      }

      xml = Presence.to_pidf(presence)

      assert xml =~ ~r/<presence.*entity="sip:alice@example\.com"/
      assert xml =~ ~r/<basic>open<\/basic>/
      assert xml =~ ~r/<note>Available<\/note>/
      assert xml =~ ~r/<contact>sip:alice@192\.168\.1\.100<\/contact>/
    end

    test "uses 'closed' for offline state" do
      presence = %{entity: "sip:alice@example.com", state: :offline}
      xml = Presence.to_pidf(presence)

      assert xml =~ ~r/<basic>closed<\/basic>/
    end
  end
end
```

**Total Presence Tests:** ~15 tests

### 2.8 MWI Unit Tests

**File:** `test/parrot_sip/mwi_test.exs`

```elixir
defmodule ParrotSip.MWITest do
  use ExUnit.Case, async: true

  alias ParrotSip.MWI

  describe "subscribe_mwi/2" do
    test "subscribes to message-summary" do
      {:ok, sub} = MWI.subscribe_mwi("sip:alice@example.com",
        owner: self(),
        notify_fun: fn event, pid -> send(self(), {event, pid}) end
      )

      assert Process.alive?(sub)
      # Verify SUBSCRIBE sent with Event: message-summary
      assert_receive {:sip_sent, %{
        method: :subscribe,
        event: "message-summary"
      }}
    end

    test "receives MWI NOTIFY" do
      {:ok, sub} = start_mwi_subscriber()

      # Simulate NOTIFY
      send_notify(sub, "active", """
      Messages-Waiting: yes
      Voice-Message: 3/8
      Fax-Message: 1/0
      """)

      assert_receive {:notify, ^sub, "active", body}
      assert body =~ "Voice-Message: 3/8"
    end
  end

  describe "publish_mwi/2" do
    test "publishes MWI state" do
      :ok = MWI.publish_mwi("sip:alice@example.com", %{
        new_voice: 3,
        old_voice: 8,
        new_fax: 1,
        old_fax: 0,
        new_video: 0,
        old_video: 0
      })

      # Should send NOTIFY to subscribers
      assert_receive {:sip_sent, %{method: :notify}}
    end
  end

  describe "parse_mwi_body/1" do
    test "parses message-summary body" do
      body = """
      Messages-Waiting: yes
      Voice-Message: 3/8
      Fax-Message: 1/0
      Video-Message: 0/2
      """

      {:ok, counts} = MWI.parse_mwi_body(body)

      assert counts.new_voice == 3
      assert counts.old_voice == 8
      assert counts.new_fax == 1
      assert counts.old_fax == 0
      assert counts.new_video == 0
      assert counts.old_video == 2
    end

    test "handles Messages-Waiting: no" do
      body = "Messages-Waiting: no\n"

      {:ok, counts} = MWI.parse_mwi_body(body)

      assert counts.new_voice == 0
    end

    test "returns error for invalid format" do
      assert {:error, :invalid_format} = MWI.parse_mwi_body("invalid")
    end
  end
end
```

**Total MWI Tests:** ~8 tests

### 2.9 Test Helpers

**File:** `test/support/helpers.ex`

```elixir
defmodule ParrotSip.Test.Helpers do
  def build_invite(opts \\ []) do
    %Message{
      type: :request,
      method: :invite,
      request_uri: opts[:uri] || "sip:bob@example.com",
      from: build_from(opts),
      to: build_to(opts),
      call_id: generate_call_id(),
      cseq: %CSeq{number: 1, method: :invite},
      via: [build_via()],
      contact: [build_contact()],
      body: opts[:sdp] || build_sdp(),
      content_type: "application/sdp"
    }
  end

  def build_sdp do
    """
    v=0
    o=- #{:rand.uniform(1000000)} #{:rand.uniform(1000000)} IN IP4 127.0.0.1
    s=Test
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 10000 RTP/AVP 0 8
    a=rtpmap:0 PCMU/8000
    a=rtpmap:8 PCMA/8000
    """
  end

  def assert_down(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> flunk("Process #{inspect(pid)} did not terminate")
    end
  end

  # ... more helpers
end
```

---

## 3. Property-Based Tests

### 3.1 State Machine Properties

**File:** `test/parrot_sip/uas_property_test.exs`

```elixir
defmodule ParrotSip.UASPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  property "UAS eventually reaches terminated state" do
    check all events <- list_of(uas_event_generator(), max_length: 50) do
      {:ok, uas} = start_uas()

      # Send events
      Enum.each(events, fn event ->
        send_event_to_uas(uas, event)
        Process.sleep(10)
      end)

      # Eventually terminates
      assert eventually(fn ->
        not Process.alive?(uas)
      end, timeout: 5000)
    end
  end

  property "state transitions are deterministic" do
    check all event <- uas_event_generator() do
      {:ok, uas1} = start_uas()
      {:ok, uas2} = start_uas()

      send_event_to_uas(uas1, event)
      send_event_to_uas(uas2, event)

      Process.sleep(50)

      {:ok, state1, _} = UAS.get_state(uas1)
      {:ok, state2, _} = UAS.get_state(uas2)

      assert state1 == state2
    end
  end

  property "invalid events return error" do
    check all state <- uas_state_generator(),
              invalid_event <- filter(uas_event_generator(), &invalid_for_state?(&1, state)) do

      {:ok, uas} = start_uas_in_state(state)

      result = send_event_to_uas(uas, invalid_event)

      assert match?({:error, _}, result)
    end
  end

  defp uas_event_generator do
    one_of([
      constant({:ring}),
      constant({:answer, build_sdp()}),
      tuple({constant(:reject), integer(300..699), string(:alphanumeric)}),
      constant(:cancel),
      constant(:bye),
      constant(:ack)
    ])
  end

  defp uas_state_generator do
    member_of([:incoming, :ringing, :answering, :established, :terminating, :terminated])
  end
end
```

**Total Property Tests:** ~20 properties

---

## 4. Integration Tests (SIPp)

### 4.1 SIPp Scenarios

**Location:** `test/sipp/scenarios/`

**Test Organization:**
```
test/sipp/scenarios/
├── basic/
│   ├── uac_invite.xml         # Simple outbound call
│   ├── uas_invite.xml         # Simple inbound call
│   ├── uac_bye.xml            # UAC hangs up
│   ├── uas_bye.xml            # UAS hangs up
│   └── uas_busy.xml           # 486 Busy
├── cancel/
│   ├── uac_cancel.xml         # Cancel before answer
│   └── uas_cancel.xml         # Receive CANCEL
├── forking/
│   ├── fork_3_destinations.xml
│   └── fork_first_wins.xml
└── reinvite/
    ├── hold_resume.xml
    └── codec_change.xml
```

### 4.2 Integration Test Suite

**File:** `test/sipp/integration_test.exs`

```elixir
defmodule ParrotSip.SIPPIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :sipp

  describe "basic call flows" do
    test "UAC makes call, UAS answers, UAC hangs up" do
      # Start UAS SIPp (server)
      uas_task = start_sipp_uas("basic/uas_invite.xml", port: 5061)

      # Start UAC SIPp (client)
      uac_task = start_sipp_uac("basic/uac_bye.xml", dest_port: 5061)

      # Both should complete successfully
      assert :ok = Task.await(uac_task, 10_000)
      assert :ok = Task.await(uas_task, 10_000)
    end

    test "UAS rejects with 486 Busy" do
      uas_task = start_sipp_uas("basic/uas_busy.xml", port: 5061)
      uac_task = start_sipp_uac("basic/uac_invite.xml", dest_port: 5061)

      assert :ok = Task.await(uac_task)
      assert :ok = Task.await(uas_task)
    end
  end

  describe "B2BUA integration" do
    test "simple bridged call" do
      # Start B2BUA
      {:ok, _b2bua} = start_test_b2bua(port: 5060)

      # Start callee (B-leg)
      callee_task = start_sipp_uas("basic/uas_invite.xml", port: 5061)

      # Start caller (A-leg)
      caller_task = start_sipp_uac("basic/uac_bye.xml", dest_port: 5060)

      # Both complete
      assert :ok = Task.await(caller_task, 15_000)
      assert :ok = Task.await(callee_task, 15_000)
    end

    test "forking B2BUA" do
      {:ok, _b2bua} = start_forking_b2bua()

      # Start 3 callees
      callee1 = start_sipp_uas("forking/slow_answer.xml", port: 5061)
      callee2 = start_sipp_uas("forking/fast_answer.xml", port: 5062)
      callee3 = start_sipp_uas("forking/no_answer.xml", port: 5063)

      # Start caller
      caller = start_sipp_uac("basic/uac_bye.xml", dest_port: 5060)

      # Callee 2 should answer (fast), others cancelled
      assert :ok = Task.await(callee2)
      assert :ok = Task.await(caller)

      # Callee 1 and 3 should receive CANCEL
      # (verified in their SIPp scenarios)
    end
  end

  describe "CANCEL scenarios" do
    test "UAC cancels before answer" do
      uas_task = start_sipp_uas("cancel/uas_cancel.xml", port: 5061)
      uac_task = start_sipp_uac("cancel/uac_cancel.xml", dest_port: 5061)

      assert :ok = Task.await(uac_task)
      assert :ok = Task.await(uas_task)
    end
  end

  describe "re-INVITE scenarios" do
    test "hold and resume" do
      uas_task = start_sipp_uas("reinvite/uas_reinvite_hold.xml", port: 5061)
      uac_task = start_sipp_uac("reinvite/uac_reinvite_hold.xml", dest_port: 5061)

      assert :ok = Task.await(uac_task, 30_000)
      assert :ok = Task.await(uas_task, 30_000)
    end
  end

  # Helper functions
  defp start_sipp_uas(scenario, opts) do
    port = opts[:port]

    Task.async(fn ->
      SippRunner.run_scenario(
        scenario_file: "test/sipp/scenarios/#{scenario}",
        mode: :uas,
        local_port: port,
        timeout: 15_000
      )
    end)
  end

  defp start_sipp_uac(scenario, opts) do
    dest_port = opts[:dest_port]

    Task.async(fn ->
      SippRunner.run_scenario(
        scenario_file: "test/sipp/scenarios/#{scenario}",
        mode: :uac,
        remote_host: "127.0.0.1",
        remote_port: dest_port,
        timeout: 15_000
      )
    end)
  end
end
```

**Total SIPp Tests:** ~25 scenarios

---

## 5. End-to-End Tests

### 5.1 Acceptance Tests

**File:** `test/acceptance/b2bua_acceptance_test.exs`

```elixir
defmodule ParrotSip.AcceptanceTest do
  use ExUnit.Case, async: false

  @moduletag :acceptance
  @moduletag timeout: :infinity

  test "complete call lifecycle" do
    # Start B2BUA server
    {:ok, _} = start_production_b2bua()

    # Make real SIP call using SIPp
    # Verify all phases complete

    phases = [
      :invite_sent,
      :trying_received,
      :ringing_received,
      :answered,
      :media_flowing,
      :call_active,
      :bye_sent,
      :terminated
    ]

    results = run_complete_call_test()

    Enum.each(phases, fn phase ->
      assert results[phase] == :ok, "Phase #{phase} failed"
    end)
  end

  test "handle 1000 concurrent calls" do
    {:ok, _} = start_production_b2bua()

    # Start 1000 simultaneous calls
    tasks = Enum.map(1..1000, fn i ->
      Task.async(fn ->
        run_single_call(call_id: i)
      end)
    end)

    # All should complete
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    success_count = Enum.count(results, &(&1 == :ok))

    assert success_count >= 990  # 99% success rate
  end
end
```

---

## 6. Test Infrastructure

### 6.1 Test Configuration

**File:** `config/test.exs`

```elixir
import Config

config :parrot_sip,
  # Use shorter timers for tests
  timer_h_duration: 100,  # 100ms instead of 32s
  timer_b_duration: 500,  # 500ms instead of 32s
  handler_decision_timeout: 100,

  # Logging
  log_level: :warn,

  # Test mode
  test_mode: true

config :logger, level: :warn
```

### 6.2 Test Helpers

**Shared test setup:**
```elixir
defmodule ParrotSip.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import ParrotSip.Test.Helpers
      import ParrotSip.TestCase

      alias ParrotSip.{UAS, UAC, B2BUA}
      alias ParrotSip.Test.{SippRunner, MessageBuilder}
    end
  end

  setup tags do
    # Start supervision tree for each test
    {:ok, _apps} = Application.ensure_all_started(:parrot_sip)

    # Clean registry
    clean_registry()

    # Conditional setup based on tags
    cond do
      tags[:sipp] ->
        ensure_sipp_installed()

      tags[:performance] ->
        configure_for_performance()

      true ->
        :ok
    end

    :ok
  end
end
```

### 6.3 Mock Handlers

```elixir
defmodule ParrotSip.Test.MockHandler do
  use ParrotSip.B2BUA.Handler

  def init(test_pid) do
    {:ok, %{test_pid: test_pid, calls: []}}
  end

  def route_call(invite, state) do
    send(state.test_pid, {:route_call, invite})

    # Wait for test to provide routing decision
    receive do
      {:route_decision, decision} -> decision
    after
      5000 -> {:reject, 500, "Test timeout", state}
    end
  end

  def modify_sdp(direction, sdp, state) do
    send(state.test_pid, {:modify_sdp, direction, sdp})

    receive do
      {:sdp_decision, modified_sdp} -> {:ok, modified_sdp, state}
    after
      1000 -> {:ok, sdp, state}  # Pass through
    end
  end

  def handle_established(session_info, state) do
    send(state.test_pid, {:established, session_info})
    {:ok, state}
  end
end
```

---

## 7. Continuous Integration

### 7.1 CI Pipeline

```yaml
# .github/workflows/test.yml
name: Tests

on: [push, pull_request]

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: erlef/setup-beam@v1
        with:
          otp-version: 26
          elixir-version: 1.15

      - name: Install dependencies
        run: mix deps.get

      - name: Compile
        run: mix compile --warnings-as-errors

      - name: Run unit tests
        run: mix test --exclude sipp --exclude performance

      - name: Coverage
        run: mix coveralls.json

      - name: Upload coverage
        uses: codecov/codecov-action@v1

  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: erlef/setup-beam@v1

      - name: Install SIPp
        run: sudo apt-get install -y sipp

      - name: Run integration tests
        run: mix test --only sipp

  property:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: erlef/setup-beam@v1

      - name: Run property tests
        run: mix test --only property

  dialyzer:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: erlef/setup-beam@v1

      - name: Restore PLT cache
        uses: actions/cache@v2
        with:
          path: priv/plts
          key: ${{ runner.os }}-plt-${{ hashFiles('mix.lock') }}

      - name: Run Dialyzer
        run: mix dialyzer
```

### 7.2 Test Coverage

**Target: 90%+ coverage**

**Exclusions:**
- Generated code
- Test helpers
- Debug functions

**Coverage Report:**
```bash
mix coveralls.html
open cover/excoveralls.html
```

**Per-module targets:**
- Core modules (UAS, UAC, Session): 95%+
- Supervisors: 85%+
- Helpers: 80%+

---

## 8. Test Execution

### 8.1 Running Tests

```bash
# All tests
mix test

# Only unit tests
mix test --exclude sipp --exclude performance

# Only integration tests
mix test --only sipp

# Only property tests
mix test --only property

# Single file
mix test test/parrot_sip/uas_test.exs

# Specific test
mix test test/parrot_sip/uas_test.exs:42

# With coverage
mix coveralls

# Watch mode (auto-run on file change)
mix test.watch
```

### 8.2 Test Organization

**Tags:**
```elixir
@moduletag :unit          # Unit tests (default)
@moduletag :sipp          # SIPp integration tests
@moduletag :property      # Property-based tests
@moduletag :performance   # Performance tests
@moduletag :acceptance    # Acceptance tests
@moduletag :slow          # Slow tests (> 1s)
```

**Run specific tags:**
```bash
mix test --only sipp
mix test --exclude slow
mix test --only property --only acceptance
```

---

## 9. Test Metrics

### 9.1 Success Criteria

| Metric | Target | Status |
|--------|--------|--------|
| Total tests | 300+ | ⬜ |
| Unit test coverage | 90%+ | ⬜ |
| Integration tests | 25+ scenarios | ⬜ |
| Property tests | 20+ properties | ⬜ |
| Acceptance tests | 10+ scenarios | ⬜ |
| CI passing | All jobs green | ⬜ |
| Test execution time | < 5 minutes (unit) | ⬜ |
| Test execution time | < 15 minutes (all) | ⬜ |

### 9.2 Test Quality Metrics

**Mutation Testing:**
```bash
# Use mutation testing to verify test quality
mix mutant
```

**Flaky Test Detection:**
- Run tests 100x: `for i in {1..100}; do mix test || break; done`
- Track failures, identify flaky tests
- Fix or mark as `:flaky`

**Test Performance:**
- Profile slow tests: `mix test --profile`
- Optimize tests > 100ms
- Parallelize where possible

---

## 10. Documentation Testing

### 10.1 Doctests

```elixir
defmodule ParrotSip.UAS do
  @doc """
  Answers an incoming call.

  ## Examples

      iex> {:ok, uas} = UAS.start_link(...)
      iex> UAS.answer(uas, sdp: "v=0...")
      :ok
  """
  def answer(uas, opts) do
    # ...
  end
end

# Run doctests
mix test --only doctest
```

### 10.2 Example Code Testing

**Verify all examples in docs/ actually run:**
```bash
# Extract code from markdown
elixir scripts/extract_examples.exs docs/

# Run extracted examples
mix test test/extracted_examples/
```

---

**Review Status:**
- [ ] Test plan approved
- [ ] Test infrastructure ready
- [ ] All tests implemented
- [ ] CI configured
- [ ] Coverage targets met
- [ ] Approved by: _____________
