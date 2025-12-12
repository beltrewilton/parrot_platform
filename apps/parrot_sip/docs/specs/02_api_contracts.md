# API Contracts and Type Specifications

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-03

## 1. Module Overview

This document defines the public APIs for:
- `ParrotSip.UAS` - Server entity (receives calls)
- `ParrotSip.UAC` - Client entity (makes calls)
- `ParrotSip.B2BUA.Session` - Session coordinator
- `ParrotSip.B2BUA.Handler` - Application callback behavior

---

## 2. ParrotSip.UAS

### 2.1 Module Purpose

Manages the lifecycle of an inbound call leg. Created automatically when an INVITE is received.

### 2.2 Types

```elixir
@type uas_id :: pid()
@type entity_id :: String.t()
@type state :: :incoming | :ringing | :answering | :established |
               :terminating | :terminated

@type start_opts :: [
  invite: Message.t(),
  owner: pid(),
  notify_fun: (event(), uas_id() -> :ok),
  metadata: map()
]

@type event ::
  {:uas_created, uas_id()}
  | {:uas_ringing, uas_id()}
  | {:uas_answered, uas_id()}
  | {:uas_established, uas_id()}
  | {:uas_bye, uas_id(), Message.t()}
  | {:uas_reinvite, uas_id(), Message.t()}
  | {:uas_cancelled, uas_id()}
  | {:uas_terminated, uas_id()}
  | {:uas_timeout, uas_id()}
  | {:uas_error, uas_id(), term()}

@type ring_opts :: [
  status: 180..189
]

@type answer_opts :: [
  sdp: String.t(),
  headers: map()
]

@type reject_opts :: [
  reason: String.t(),
  headers: map()
]
```

### 2.3 Public API

#### start_link/1

```elixir
@spec start_link(start_opts()) ::
  {:ok, uas_id()} | {:error, term()}
```

Create a new UAS entity from an incoming INVITE.

**Parameters:**
- `opts[:invite]` - REQUIRED. The incoming INVITE message
- `opts[:owner]` - REQUIRED. Process to notify of events (usually B2BUA.Session)
- `opts[:notify_fun]` - REQUIRED. Callback function for events
- `opts[:metadata]` - OPTIONAL. Application metadata

**Returns:**
- `{:ok, uas_id}` - UAS entity created successfully
- `{:error, :invalid_invite}` - INVITE missing required headers
- `{:error, reason}` - Other errors

**Side Effects:**
- Creates new gen_statem process
- Creates DialogStatem process (UAS role)
- Registers in ParrotSip.Registry with entity_id
- Starts handler_decision timer (10s)

**Example:**
```elixir
{:ok, uas} = UAS.start_link(
  invite: invite_msg,
  owner: self(),
  notify_fun: &handle_uas_event/2
)
```

#### ring/2

```elixir
@spec ring(uas_id(), ring_opts()) :: :ok | {:error, :invalid_state}
```

Send 180 Ringing (or other 18x) response.

**Valid States:** `:incoming`, `:ringing`

**Parameters:**
- `uas` - UAS process ID
- `opts[:status]` - Status code (default: 180)

**Returns:**
- `:ok` - Ringing sent, transitioned to :ringing
- `{:error, :invalid_state}` - Not in incoming/ringing state

**Side Effects:**
- Sends 180/18x SIP response
- Transitions to :ringing state
- Notifies owner: `{:uas_ringing, uas}`

**Example:**
```elixir
:ok = UAS.ring(uas)
:ok = UAS.ring(uas, status: 183)  # Session Progress
```

#### answer/2

```elixir
@spec answer(uas_id(), answer_opts()) :: :ok | {:error, term()}
```

Send 200 OK to accept the call.

**Valid States:** `:incoming`, `:ringing`

**Parameters:**
- `uas` - UAS process ID
- `opts[:sdp]` - REQUIRED. SDP answer body
- `opts[:headers]` - OPTIONAL. Additional headers

**Returns:**
- `:ok` - 200 OK sent, transitioned to :answering
- `{:error, :invalid_state}` - Not in valid state
- `{:error, :invalid_sdp}` - SDP validation failed

**Side Effects:**
- Sends 200 OK SIP response with SDP
- Starts Timer H (32s ACK wait)
- Transitions to :answering state
- Notifies owner: `{:uas_answered, uas}`

**Example:**
```elixir
:ok = UAS.answer(uas, sdp: answer_sdp)
```

#### reject/3

```elixir
@spec reject(uas_id(), status_code :: 300..699, reject_opts()) ::
  :ok | {:error, term()}
```

Reject the call with error response.

**Valid States:** `:incoming`, `:ringing`

**Parameters:**
- `uas` - UAS process ID
- `status_code` - HTTP-style status code (300-699)
- `opts[:reason]` - Reason phrase (inferred from code if omitted)
- `opts[:headers]` - Additional headers

**Returns:**
- `:ok` - Error response sent, transitioning to :terminated
- `{:error, :invalid_state}` - Not in valid state
- `{:error, :invalid_code}` - Code not in 300-699 range

**Side Effects:**
- Sends error SIP response
- Transitions to :terminated
- Notifies owner: `{:uas_terminated, uas}`

**Common Codes:**
- 486 - Busy Here
- 480 - Temporarily Unavailable
- 404 - Not Found
- 603 - Decline

**Example:**
```elixir
:ok = UAS.reject(uas, 486, reason: "Busy Here")
:ok = UAS.reject(uas, 404)  # Reason inferred
```

#### hangup/1

```elixir
@spec hangup(uas_id()) :: :ok | {:error, :invalid_state}
```

Send BYE to terminate established call.

**Valid States:** `:established`

**Returns:**
- `:ok` - BYE sent, transitioning to :terminating
- `{:error, :invalid_state}` - Not in established state

**Side Effects:**
- Sends BYE request
- Transitions to :terminating
- Notifies owner when 200 OK received

**Example:**
```elixir
:ok = UAS.hangup(uas)
```

#### send_reinvite/2

```elixir
@spec send_reinvite(uas_id(), sdp :: String.t()) ::
  :ok | {:error, term()}
```

Send re-INVITE for hold, resume, codec change, etc.

**Valid States:** `:established`

**Example:**
```elixir
:ok = UAS.send_reinvite(uas, hold_sdp)
```

#### get_state/1

```elixir
@spec get_state(uas_id()) ::
  {:ok, state(), data :: map()} | {:error, :not_found}
```

Get current state and data (for debugging).

**Returns:**
- `{:ok, state, data}` - Current state machine state
- `{:error, :not_found}` - UAS process not found

**Example:**
```elixir
{:ok, :established, %{dialog: dialog_pid}} = UAS.get_state(uas)
```

---

## 3. ParrotSip.UAC

### 3.1 Module Purpose

Manages the lifecycle of an outbound call leg. Created by application or B2BUA.

### 3.2 Types

```elixir
@type uac_id :: pid()
@type state :: :initiating | :calling | :ringing | :answered |
               :established | :terminating | :terminated

@type start_opts :: [
  dest_uri: String.t(),
  sdp: String.t(),
  owner: pid(),
  notify_fun: (event(), uac_id() -> :ok),
  from_uri: String.t() | nil,
  headers: map(),
  metadata: map()
]

@type event ::
  {:uac_created, uac_id()}
  | {:uac_trying, uac_id()}
  | {:uac_ringing, uac_id(), status :: 180..189, Message.t()}
  | {:uac_progress, uac_id(), status :: 180..189, Message.t()}
  | {:uac_answered, uac_id(), sdp :: String.t()}
  | {:uac_established, uac_id()}
  | {:uac_rejected, uac_id(), status :: 300..699, Message.t()}
  | {:uac_bye, uac_id(), Message.t()}
  | {:uac_reinvite, uac_id(), Message.t()}
  | {:uac_timeout, uac_id()}
  | {:uac_terminated, uac_id()}
  | {:uac_error, uac_id(), term()}
```

### 3.3 Public API

#### start_link/1

```elixir
@spec start_link(start_opts()) :: {:ok, uac_id()} | {:error, term()}
```

Create a new UAC entity and send INVITE.

**Parameters:**
- `opts[:dest_uri]` - REQUIRED. Destination SIP URI
- `opts[:sdp]` - REQUIRED. SDP offer body
- `opts[:owner]` - REQUIRED. Process to notify
- `opts[:notify_fun]` - REQUIRED. Callback function
- `opts[:from_uri]` - OPTIONAL. From URI (defaults to local)
- `opts[:headers]` - OPTIONAL. Additional headers
- `opts[:metadata]` - OPTIONAL. Application metadata

**Returns:**
- `{:ok, uac_id}` - UAC created, INVITE sent
- `{:error, :invalid_uri}` - Destination URI invalid
- `{:error, :invalid_sdp}` - SDP validation failed

**Side Effects:**
- Creates gen_statem process
- Creates DialogStatem (UAC role)
- Sends INVITE via Transaction.Client
- Starts Timer B (32s timeout)
- Registers in ParrotSip.Registry

**Example:**
```elixir
{:ok, uac} = UAC.start_link(
  dest_uri: "sip:bob@example.com",
  sdp: offer_sdp,
  owner: self(),
  notify_fun: &handle_uac_event/2
)
```

#### cancel/1

```elixir
@spec cancel(uac_id()) :: :ok | {:error, :invalid_state}
```

Cancel outbound call before it's answered.

**Valid States:** `:calling`, `:ringing`

**Returns:**
- `:ok` - CANCEL sent
- `{:error, :invalid_state}` - Not in valid state

**Side Effects:**
- Sends CANCEL request
- Eventually receives 487 Request Terminated
- Transitions to :terminated

**Example:**
```elixir
:ok = UAC.cancel(uac)
```

#### hangup/1

```elixir
@spec hangup(uac_id()) :: :ok | {:error, :invalid_state}
```

Send BYE to terminate established call.

**Valid States:** `:established`

**Example:**
```elixir
:ok = UAC.hangup(uac)
```

#### send_reinvite/2

```elixir
@spec send_reinvite(uac_id(), sdp :: String.t()) ::
  :ok | {:error, term()}
```

Send re-INVITE.

**Valid States:** `:established`

---

## 4. ParrotSip.B2BUA.Session

### 4.1 Module Purpose

Coordinates a B2BUA call session: one UAS (A-leg) + one or more UACs (B-legs).

### 4.2 Types

```elixir
@type session_id :: pid()
@type state :: :routing | :forking | :connecting | :established |
               :terminating | :terminated

@type start_opts :: [
  invite: Message.t(),
  handler: module(),
  handler_state: term()
]

@type session_info :: %{
  session_id: session_id(),
  a_leg: %{uas: pid(), uri: String.t()},
  b_leg: %{uac: pid(), uri: String.t()} | nil,
  start_time: DateTime.t(),
  duration: non_neg_integer() | nil
}
```

### 4.3 Public API

#### start_link/1

```elixir
@spec start_link(start_opts()) :: {:ok, session_id()} | {:error, term()}
```

Create new B2BUA session from incoming INVITE.

**Parameters:**
- `opts[:invite]` - REQUIRED. Incoming INVITE
- `opts[:handler]` - REQUIRED. Handler module
- `opts[:handler_state]` - OPTIONAL. Initial handler state

**Returns:**
- `{:ok, session_id}` - Session created
- `{:error, reason}` - Creation failed

**Side Effects:**
- Creates Session gen_statem
- Creates UAS for A-leg
- Calls handler.route_call/2
- Based on handler response: creates UAC(s) for B-leg(s)

**Example:**
```elixir
{:ok, session} = Session.start_link(
  invite: invite_msg,
  handler: MySwitch,
  handler_state: %{}
)
```

#### get_info/1

```elixir
@spec get_info(session_id()) :: {:ok, session_info()} | {:error, :not_found}
```

Get session information.

**Example:**
```elixir
{:ok, info} = Session.get_info(session)
IO.inspect(info.duration)  # seconds
```

#### hangup/1

```elixir
@spec hangup(session_id()) :: :ok
```

Terminate session (ends both legs).

---

## 5. ParrotSip.B2BUA.Handler Behaviour

### 5.1 Purpose

Callback behaviour for B2BUA applications to implement routing and bridging logic.

### 5.2 Callbacks

#### init/1

```elixir
@callback init(init_arg :: term()) :: {:ok, state :: term()}
```

Initialize handler state.

**Example:**
```elixir
def init(_config) do
  {:ok, %{call_count: 0, routes: load_routes()}}
end
```

#### route_call/2

```elixir
@callback route_call(invite :: Message.t(), state) ::
  {:route, dest_uri :: String.t(), state}
  | {:fork, [dest_uri :: String.t()], state}
  | {:reject, status :: 300..699, reason :: String.t(), state}
```

Make routing decision for incoming call.

**Returns:**
- `{:route, uri, state}` - Route to single destination
- `{:fork, uris, state}` - Fork to multiple destinations (parallel ring)
- `{:reject, code, reason, state}` - Reject the call

**Example:**
```elixir
def route_call(invite, state) do
  case lookup_user(invite.to.uri) do
    {:ok, endpoints} when length(endpoints) > 1 ->
      # Parallel forking - ring all endpoints
      {:fork, endpoints, state}

    {:ok, [endpoint]} ->
      # Single destination
      {:route, endpoint, state}

    {:error, :not_found} ->
      {:reject, 404, "Not Found", state}
  end
end
```

#### modify_sdp/3

```elixir
@callback modify_sdp(
  direction :: :a_to_b | :b_to_a,
  sdp :: String.t(),
  state
) :: {:ok, modified_sdp :: String.t(), state} | {:reject, status, reason, state}
```

Modify SDP when forwarding between legs.

**Directions:**
- `:a_to_b` - Forwarding A-leg (caller) SDP to B-leg (callee)
- `:b_to_a` - Forwarding B-leg (callee) SDP to A-leg (caller)

**Use Cases:**
- Change codec order
- Remove unsupported codecs
- Insert media proxy address
- Add/remove encryption

**Example:**
```elixir
def modify_sdp(:a_to_b, sdp, state) do
  # Insert media proxy for recording
  modified = insert_media_proxy(sdp, state.proxy_ip)
  {:ok, modified, state}
end

def modify_sdp(:b_to_a, sdp, state) do
  # Pass through unchanged
  {:ok, sdp, state}
end
```

#### handle_established/2

```elixir
@callback handle_established(session_info(), state) :: {:ok, state}
```

Called when both legs are established and bridged.

**Example:**
```elixir
def handle_established(session_info, state) do
  Logger.info("Call connected: #{session_info.a_leg.uri} → #{session_info.b_leg.uri}")
  start_recording(session_info.session_id)
  {:ok, state}
end
```

#### handle_hangup/3

```elixir
@callback handle_hangup(
  leg :: :a_leg | :b_leg,
  session_info(),
  state
) :: {:ok, state}
```

Called when either leg hangs up.

**Example:**
```elixir
def handle_hangup(:a_leg, session_info, state) do
  Logger.info("Caller hung up")
  stop_recording(session_info.session_id)
  {:ok, state}
end
```

#### handle_failed/3

```elixir
@callback handle_failed(
  reason :: {:rejected, status, Message.t()} | {:timeout} | {:error, term()},
  session_info(),
  state
) :: {:ok, state}
```

Called when session fails to establish.

**Example:**
```elixir
def handle_failed({:rejected, 486, _msg}, _session, state) do
  # Try voicemail
  {:ok, state}
end

def handle_failed({:timeout}, _session, state) do
  Logger.warn("Call setup timeout")
  {:ok, state}
end
```

### 5.3 Optional Callbacks

All callbacks with default implementations:

```elixir
@optional_callbacks [
  modify_sdp: 3,
  handle_established: 2,
  handle_hangup: 3,
  handle_failed: 3
]
```

---

## 6. Error Handling

### 6.1 Error Return Values

All functions follow Elixir conventions:

**Success:**
- `:ok`
- `{:ok, value}`

**Errors:**
- `{:error, :invalid_state}` - Operation not valid in current state
- `{:error, :not_found}` - Process not found
- `{:error, :timeout}` - Operation timed out
- `{:error, reason}` - Other errors

### 6.2 Process Crashes

Entities and Sessions are supervised:
- UAS crash → Session gets `{:DOWN, ref, :process, uas_pid, reason}`
- UAC crash → Session gets `{:DOWN, ref, :process, uac_pid, reason}`
- Session crash → Supervisor restarts or terminates all child processes

### 6.3 Invalid State Transitions

Attempting invalid operations returns `{:error, :invalid_state}`:

```elixir
# UAS in :terminated, can't answer
UAS.answer(dead_uas, sdp: sdp)
# => {:error, :invalid_state}
```

---

## 6. ParrotSip.Auth

### 6.1 Module Purpose

Provides SIP Digest Authentication (RFC 2617) as middleware. Not a process - pure functions for challenge generation and credential verification.

### 6.2 Types

```elixir
@type realm :: String.t()
@type nonce :: String.t()
@type username :: String.t()
@type password :: String.t()

@type challenge :: %{
  realm: realm(),
  nonce: nonce(),
  algorithm: String.t(),    # "MD5" or "SHA-256"
  qop: String.t() | nil,    # "auth" or "auth-int"
  opaque: String.t() | nil
}

@type credentials :: %{
  username: username(),
  password: password() | :lookup_needed
}

@type authorization_header :: String.t()

@type challenge_opts :: [
  algorithm: String.t(),
  qop: String.t(),
  opaque: String.t(),
  stale: boolean()
]

@type verification_result ::
  :valid
  | {:invalid, :bad_response}
  | {:invalid, :stale_nonce}
  | {:invalid, :wrong_credentials}
```

### 6.3 Public API

#### challenge/2

```elixir
@spec challenge(realm(), challenge_opts()) :: challenge()
```

Generate authentication challenge for 401/407 response.

**Parameters:**
- `realm` - REQUIRED. Authentication realm (e.g., "example.com")
- `opts[:algorithm]` - OPTIONAL. "MD5" (default) or "SHA-256"
- `opts[:qop]` - OPTIONAL. "auth" (default) or "auth-int"
- `opts[:opaque]` - OPTIONAL. Opaque value (generated if not provided)
- `opts[:stale]` - OPTIONAL. Mark previous nonce as stale

**Returns:**
- Challenge map with nonce, realm, algorithm, etc.

**Side Effects:**
- Stores nonce in ETS for later verification (with TTL)

**Example:**
```elixir
challenge = Auth.challenge("example.com", qop: "auth")
# %{realm: "example.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093", ...}

# Add to 401 response:
header = Auth.challenge_header(challenge)
# "Digest realm=\"example.com\", nonce=\"dcd...\", algorithm=MD5, qop=\"auth\""
```

#### challenge_header/1

```elixir
@spec challenge_header(challenge()) :: String.t()
```

Convert challenge map to WWW-Authenticate header value.

**Example:**
```elixir
header = Auth.challenge_header(challenge)
Message.add_header(response, "WWW-Authenticate", header)
```

#### verify_credentials/4

```elixir
@spec verify_credentials(
  authorization_header(),
  credentials(),
  method :: String.t(),
  uri :: String.t()
) :: verification_result()
```

Verify Authorization header from authenticated request.

**Parameters:**
- `authorization_header` - Value of Authorization header from request
- `credentials` - Username/password map
- `method` - SIP method ("INVITE", "REGISTER", etc.)
- `uri` - Request-URI

**Returns:**
- `:valid` - Credentials verified successfully
- `{:invalid, :bad_response}` - Malformed Authorization header
- `{:invalid, :stale_nonce}` - Nonce expired or not found
- `{:invalid, :wrong_credentials}` - Response digest doesn't match

**Side Effects:**
- Checks nonce in ETS (ensures not reused for nc value)

**Example:**
```elixir
case Auth.verify_credentials(auth_header, %{username: "alice", password: "secret"}, "INVITE", "sip:bob@example.com") do
  :valid ->
    # Allow call
    {:ok, :authenticated}

  {:invalid, reason} ->
    # Send new 401 challenge
    {:error, :auth_failed}
end
```

#### verify_credentials_async/5

```elixir
@spec verify_credentials_async(
  authorization_header(),
  username(),
  password_lookup_fun :: (username() -> {:ok, password()} | :error),
  method :: String.t(),
  uri :: String.t(),
  timeout :: pos_integer()
) :: verification_result() | {:error, :timeout}
```

Verify credentials with async password lookup (e.g., database query).

**Parameters:**
- `timeout` - OPTIONAL. Timeout in milliseconds (default: 5000)

**Returns:**
- Same as verify_credentials/4
- `{:error, :timeout}` - Password lookup timed out

**Implementation:**
Uses `Task.async/1` with `Task.yield/2` and timeout. On timeout, calls `Task.shutdown/2` and returns `{:error, :timeout}`. The UAS should send 503 Service Unavailable on timeout.

**Example:**
```elixir
case Auth.verify_credentials_async(
  auth_header,
  "alice",
  fn username -> Repo.get_password(username) end,
  "INVITE",
  "sip:bob@example.com",
  5000  # 5 second timeout
) do
  :valid ->
    # Proceed
    :ok
  {:error, :timeout} ->
    # Database slow, send 503
    UAS.reject(uas, 503, "Service Unavailable")
  {:invalid, reason} ->
    # Wrong credentials
    send_new_challenge()
end
```

#### add_authorization/4

```elixir
@spec add_authorization(
  request :: Message.t(),
  username(),
  password(),
  challenge()
) :: Message.t()
```

Add Authorization header to outgoing request (UAC role).

**Example:**
```elixir
# Received 401 with challenge
challenge = Auth.parse_challenge(response.headers["WWW-Authenticate"])

# Add credentials and retry
authenticated_request = Auth.add_authorization(
  original_request,
  "alice",
  "secret",
  challenge
)
```

#### parse_challenge/1

```elixir
@spec parse_challenge(www_authenticate_header :: String.t()) ::
  {:ok, challenge()} | {:error, :invalid_header}
```

Parse WWW-Authenticate or Proxy-Authenticate header.

**Example:**
```elixir
{:ok, challenge} = Auth.parse_challenge(response.headers["WWW-Authenticate"])
```

### 6.4 Nonce Management

Nonces are stored in ETS with TTL:

```elixir
# Internal - not public API
defmodule ParrotSip.Auth.NonceStore do
  use GenServer

  # Stores: {nonce, realm, timestamp, nc_values}
  # TTL: 5 minutes default
  # Prevents replay attacks by tracking nc (nonce count)
end
```

---

## 7. ParrotSip.Subscription

### 7.1 Module Purpose

Manages SIP event subscription lifecycle (RFC 3265). Supports both subscriber and notifier roles.

### 7.2 Types

```elixir
@type subscription_id :: pid()
@type role :: :subscriber | :notifier
@type event_package :: String.t()  # "presence", "message-summary", etc.
@type state :: :pending | :active | :terminated

@type subscriber_opts :: [
  event_package: event_package(),
  resource_uri: String.t(),
  from_uri: String.t() | nil,
  expires: pos_integer(),
  owner: pid(),
  notify_fun: (event(), subscription_id() -> :ok),
  metadata: map()
]

@type notifier_opts :: [
  subscribe: Message.t(),
  owner: pid(),
  notify_fun: (event(), subscription_id() -> :ok),
  metadata: map()
]

@type event ::
  {:subscription_active, subscription_id()}
  | {:subscription_rejected, subscription_id(), status :: 300..699}
  | {:notify, subscription_id(), event_state :: String.t(), body :: String.t()}
  | {:subscription_terminated, subscription_id()}
  | {:subscription_expired, subscription_id()}
  | {:subscription_ended, subscription_id()}

@type accept_opts :: [
  expires: pos_integer(),
  initial_state: String.t(),
  initial_body: String.t()
]
```

### 7.3 Public API - Subscriber Role

#### subscribe/1

```elixir
@spec subscribe(subscriber_opts()) ::
  {:ok, subscription_id()} | {:error, term()}
```

Create subscription to a resource (send SUBSCRIBE).

**Parameters:**
- `opts[:event_package]` - REQUIRED. Event package (e.g., "presence")
- `opts[:resource_uri]` - REQUIRED. URI of resource to subscribe to
- `opts[:from_uri]` - OPTIONAL. From URI (defaults to local)
- `opts[:expires]` - OPTIONAL. Subscription duration in seconds (default: 3600)
- `opts[:owner]` - REQUIRED. Process to notify
- `opts[:notify_fun]` - REQUIRED. Callback function

**Returns:**
- `{:ok, subscription_id}` - SUBSCRIBE sent
- `{:error, :invalid_uri}` - Resource URI invalid

**Side Effects:**
- Creates Subscription gen_statem
- Sends SUBSCRIBE request
- Creates dialog for subscription

**Example:**
```elixir
{:ok, sub} = Subscription.subscribe(
  event_package: "presence",
  resource_uri: "sip:alice@example.com",
  expires: 3600,
  owner: self(),
  notify_fun: &handle_notify/2
)

# Later, receive NOTIFY:
# {:notify, ^sub, "open", "<presence xmlns=...>"}
```

#### unsubscribe/1

```elixir
@spec unsubscribe(subscription_id()) :: :ok
```

End subscription (send SUBSCRIBE with Expires: 0).

**Valid States:** `:active`

**Example:**
```elixir
:ok = Subscription.unsubscribe(sub)
```

#### refresh/1

```elixir
@spec refresh(subscription_id()) :: :ok | {:error, term()}
```

Manually refresh subscription (normally automatic).

**Example:**
```elixir
:ok = Subscription.refresh(sub)
```

### 7.4 Public API - Notifier Role

#### start_notifier/1

```elixir
@spec start_notifier(notifier_opts()) ::
  {:ok, subscription_id()} | {:error, term()}
```

Create notifier from incoming SUBSCRIBE.

**Parameters:**
- `opts[:subscribe]` - REQUIRED. Incoming SUBSCRIBE message
- `opts[:owner]` - REQUIRED. Process to notify
- `opts[:notify_fun]` - REQUIRED. Callback function

**Returns:**
- `{:ok, subscription_id}` - Notifier created (pending acceptance)

**Example:**
```elixir
# In handler when SUBSCRIBE received:
{:ok, notifier} = Subscription.start_notifier(
  subscribe: subscribe_msg,
  owner: self(),
  notify_fun: &handle_subscription_event/2
)

# Handler decides to accept:
Subscription.accept(notifier,
  expires: 3600,
  initial_state: "open",
  initial_body: presence_pidf_xml
)
```

#### accept/2

```elixir
@spec accept(subscription_id(), accept_opts()) :: :ok | {:error, term()}
```

Accept subscription and send initial NOTIFY.

**Valid States:** `:pending`

**Parameters:**
- `subscription` - Subscription ID
- `opts[:expires]` - OPTIONAL. Override requested expiration
- `opts[:initial_state]` - REQUIRED. Initial event state
- `opts[:initial_body]` - REQUIRED. Initial NOTIFY body

**Returns:**
- `:ok` - 200 OK sent, initial NOTIFY sent
- `{:error, :invalid_state}` - Already accepted/rejected

**Side Effects:**
- Sends 200 OK to SUBSCRIBE
- Sends initial NOTIFY with Subscription-State: active
- Transitions to :active

**Example:**
```elixir
:ok = Subscription.accept(notifier,
  initial_state: "open",
  initial_body: PresenceBuilder.build_pidf("alice@example.com", :online)
)
```

#### reject/3

```elixir
@spec reject(subscription_id(), status :: 300..699, reason :: String.t()) ::
  :ok | {:error, term()}
```

Reject subscription.

**Valid States:** `:pending`

**Example:**
```elixir
:ok = Subscription.reject(notifier, 403, "Forbidden")
```

#### notify/3

```elixir
@spec notify(subscription_id(), event_state :: String.t(), body :: String.t()) ::
  :ok | {:error, term()}
```

Send NOTIFY when subscribed resource state changes.

**Valid States:** `:active`

**Parameters:**
- `subscription` - Subscription ID
- `event_state` - Current state of resource
- `body` - Event body (format depends on event package)

**Example:**
```elixir
# User went offline
:ok = Subscription.notify(notifier, "closed",
  PresenceBuilder.build_pidf("alice@example.com", :offline)
)
```

#### terminate/2

```elixir
@spec terminate(subscription_id(), reason :: String.t()) :: :ok
```

Terminate subscription and send final NOTIFY.

**Example:**
```elixir
:ok = Subscription.terminate(notifier, "noresource")
```

---

## 8. ParrotSip.Presence

### 8.1 Module Purpose

Manages presence state for SIP entities. GenServer that maintains presence tuples and coordinates NOTIFY delivery to subscribers.

### 8.2 Types

```elixir
@type presentity_uri :: String.t()
@type watcher_uri :: String.t()
@type presence_state :: :online | :offline | :away | :busy | :dnd
@type presence_note :: String.t() | nil

@type presence_tuple :: %{
  entity: presentity_uri(),
  state: presence_state(),
  note: presence_note(),
  contact: String.t() | nil,
  priority: float(),
  timestamp: DateTime.t()
}

@type publish_opts :: [
  state: presence_state(),
  note: presence_note(),
  contact: String.t(),
  priority: float(),
  expires: pos_integer()
]

@type subscribe_opts :: [
  expires: pos_integer(),
  callback: (presence_tuple() -> :ok)
]
```

### 8.3 Public API

#### start_link/1

```elixir
@spec start_link(opts :: keyword()) :: GenServer.on_start()
```

Start presence server.

**Example:**
```elixir
{:ok, _pid} = Presence.start_link([])
```

#### publish/2

```elixir
@spec publish(presentity_uri(), publish_opts()) :: :ok | {:error, term()}
```

Publish presence state for an entity.

**Parameters:**
- `presentity_uri` - URI of entity publishing presence
- `opts[:state]` - REQUIRED. Presence state
- `opts[:note]` - OPTIONAL. Status note/message
- `opts[:contact]` - OPTIONAL. Contact URI
- `opts[:priority]` - OPTIONAL. Priority (0.0 - 1.0, default 0.5)
- `opts[:expires]` - OPTIONAL. Publication expiration (default: 3600)

**Returns:**
- `:ok` - Presence published
- `{:error, :invalid_uri}` - URI invalid

**Side Effects:**
- Updates presence tuple in state
- Sends NOTIFY to all active subscribers
- Schedules expiration cleanup

**Example:**
```elixir
:ok = Presence.publish("sip:alice@example.com",
  state: :online,
  note: "Available",
  contact: "sip:alice@192.168.1.100:5060"
)
```

#### subscribe/3

```elixir
@spec subscribe(watcher_uri(), presentity_uri(), subscribe_opts()) ::
  {:ok, subscription_id()} | {:error, term()}
```

Subscribe to presence updates for an entity.

**Parameters:**
- `watcher_uri` - URI of entity subscribing
- `presentity_uri` - URI of entity to watch
- `opts[:expires]` - OPTIONAL. Subscription duration (default: 3600)
- `opts[:callback]` - OPTIONAL. Callback when presence changes

**Returns:**
- `{:ok, subscription_id}` - Subscription created
- `{:error, :not_found}` - Presentity not found

**Side Effects:**
- Creates Subscription notifier
- Sends initial NOTIFY with current state
- Registers watcher for future NOTIFYs

**Example:**
```elixir
{:ok, sub} = Presence.subscribe(
  "sip:bob@example.com",
  "sip:alice@example.com",
  callback: fn presence ->
    IO.puts("Alice is now #{presence.state}")
  end
)
```

#### get_presence/1

```elixir
@spec get_presence(presentity_uri()) ::
  {:ok, presence_tuple()} | {:error, :not_found}
```

Get current presence state (without subscribing).

**Example:**
```elixir
{:ok, presence} = Presence.get_presence("sip:alice@example.com")
IO.inspect(presence.state)  # :online
```

#### unpublish/1

```elixir
@spec unpublish(presentity_uri()) :: :ok
```

Remove presence publication (sets state to offline).

**Example:**
```elixir
:ok = Presence.unpublish("sip:alice@example.com")
```

### 8.4 PIDF XML Generation

```elixir
@spec to_pidf(presence_tuple()) :: String.t()
```

Convert presence tuple to PIDF XML (RFC 3863).

**Example:**
```elixir
presence = %{
  entity: "sip:alice@example.com",
  state: :online,
  note: "Available",
  contact: "sip:alice@192.168.1.100"
}

xml = Presence.to_pidf(presence)
# <?xml version="1.0"?>
# <presence xmlns="urn:ietf:params:xml:ns:pidf" entity="sip:alice@example.com">
#   <tuple id="alice-1">
#     <status><basic>open</basic></status>
#     <contact>sip:alice@192.168.1.100</contact>
#     <note>Available</note>
#   </tuple>
# </presence>
```

---

## 9. ParrotSip.MWI

### 9.1 Module Purpose

Message Waiting Indication (RFC 3842). Thin wrapper around Subscription with "message-summary" event package.

### 9.2 Types

```elixir
@type mailbox_uri :: String.t()
@type message_counts :: %{
  new_voice: non_neg_integer(),
  old_voice: non_neg_integer(),
  new_video: non_neg_integer(),
  old_video: non_neg_integer(),
  new_fax: non_neg_integer(),
  old_fax: non_neg_integer()
}
```

### 9.3 Public API

#### subscribe_mwi/2

```elixir
@spec subscribe_mwi(mailbox_uri(), opts :: keyword()) ::
  {:ok, subscription_id()} | {:error, term()}
```

Subscribe to message waiting indication.

**Example:**
```elixir
{:ok, sub} = MWI.subscribe_mwi("sip:alice@example.com",
  owner: self(),
  notify_fun: &handle_mwi/2
)

# Receive NOTIFY:
# {:notify, ^sub, "active", "Messages-Waiting: yes\nVoice-Message: 3/8\n"}
```

#### publish_mwi/2

```elixir
@spec publish_mwi(mailbox_uri(), message_counts()) :: :ok
```

Publish MWI state (triggers NOTIFY to subscribers).

**Example:**
```elixir
:ok = MWI.publish_mwi("sip:alice@example.com", %{
  new_voice: 3,
  old_voice: 8,
  new_video: 0,
  old_video: 0,
  new_fax: 1,
  old_fax: 0
})
```

#### parse_mwi_body/1

```elixir
@spec parse_mwi_body(body :: String.t()) ::
  {:ok, message_counts()} | {:error, :invalid_format}
```

Parse message-summary body from NOTIFY.

**Example:**
```elixir
body = "Messages-Waiting: yes\nVoice-Message: 3/8\nFax-Message: 1/0\n"
{:ok, counts} = MWI.parse_mwi_body(body)
# %{new_voice: 3, old_voice: 8, new_fax: 1, old_fax: 0, ...}
```

---

## 10. Dialog Discovery and Ownership

### 10.1 Overview

Dialog processes are created automatically by the Transaction layer and discover their owning entity (UAS/UAC) via deterministic Registry-based lookup. This pattern is **already implemented** in the existing ParrotSip codebase.

### 10.2 Dialog ID Construction (Deterministic)

Dialog IDs are constructed deterministically from SIP message fields:

**UAS Dialog (Server):**
```elixir
# From dialog_statem.ex line 286-297
dialog_id = build_dialog_id(:uas, Call-ID, local_tag, remote_tag)
# Example: "dialog:uas:abc123@host:local-tag:remote-tag"
```

**UAC Dialog (Client):**
```elixir
dialog_id = build_dialog_id(:uac, Call-ID, local_tag, remote_tag)
# Example: "dialog:uac:abc123@host:local-tag:remote-tag"
```

**Properties:**
- Same inputs always produce same ID
- Both Dialog and Entity can compute the same ID independently
- Enables Registry-based discovery without message passing

### 10.3 Dialog Self-Creation Pattern

**Existing Implementation** (from `dialog_statem.ex:792-799`):

```elixir
# Dialog creates itself when UAS sends 200 OK
defp uas_maybe_create_dialog(%Message{} = resp_sip_msg, %Message{} = req_sip_msg) do
  if should_create_dialog?(resp_sip_msg, req_sip_msg) do
    case ParrotSip.Dialog.Supervisor.start_child({:uas, resp_sip_msg, req_sip_msg}) do
      {:ok, pid} ->
        Logger.info("Dialog created successfully with PID: #{inspect(pid)}")
        resp_sip_msg
      {:error, reason} ->
        Logger.error("Failed to create dialog: #{inspect(reason)}")
        resp_sip_msg
    end
  end
end
```

**Key Points:**
- Dialog creates itself via `Dialog.Supervisor.start_child/1`
- Happens when TransactionStatem sends 200 OK (UAS) or receives 200 OK (UAC)
- Dialog registers in Registry with deterministic ID
- No race conditions - Dialog exists before entity needs it

### 10.4 Entity Discovery of Dialog

**Existing Implementation** (from `dialog_statem.ex:286-297`):

```elixir
# UAS discovers dialog by constructing same ID
def uas_find(dialog_id) do
  case Registry.lookup(ParrotSip.Registry, dialog_id) do
    [{pid, _}] -> {:ok, pid}
    [] -> {:error, :not_found}
  end
end
```

**Usage in UAS:**
```elixir
# In UAS :answering state :enter callback
def handle_enter(:answering, _old_state, data) do
  dialog_id = construct_dialog_id(data.invite)
  case Dialog.uas_find(dialog_id) do
    {:ok, dialog_pid} ->
      Dialog.set_owner(dialog_pid, dialog_id)
      {:keep_state, %{data | dialog: dialog_pid}}
    {:error, :not_found} ->
      # Dialog will be created by Transaction layer
      :erlang.send_after(100, self(), :retry_find_dialog)
      :keep_state_and_data
  end
end
```

### 10.5 Ownership Registration

**Existing Implementation** (from `dialog_statem.ex:501-510`):

```elixir
@spec set_owner(pid(), String.t()) :: :ok
def set_owner(pid, dialog_id) when is_pid(pid) do
  case Registry.lookup(ParrotSip.Registry, dialog_id) do
    [{dialog_pid, _}] ->
      :gen_statem.cast(dialog_pid, {:set_owner, pid})
    [] ->
      :ok
  end
end
```

**What set_owner/2 does:**
1. Entity calls `Dialog.set_owner(dialog_pid, dialog_id)`
2. Dialog receives `{:set_owner, entity_pid}` cast
3. Dialog sets owner field: `%{data | owner: entity_pid}`
4. Dialog monitors entity: `Process.monitor(entity_pid)`

**Existing Implementation** (from `dialog_statem.ex:656-667`):

```elixir
def process_set_owner(data, pid) do
  ref = Process.monitor(pid)
  data
  |> Map.put(:owner, pid)
  |> Map.put(:owner_ref, ref)
end
```

### 10.6 Crash Recovery

**If Entity Crashes:**
- Dialog receives `{:DOWN, ref, :process, entity_pid, reason}`
- Dialog can terminate or wait for new owner
- Existing code: Dialog terminates (let-it-crash)

**If Dialog Crashes:**
- Entity receives `{:DOWN, ref, :process, dialog_pid, reason}`
- Entity can terminate or recreate dialog
- Existing code: Entity terminates (call ends)

### 10.7 Event Propagation

Events flow up the stack:
```
Transaction → Dialog → Entity (UAS/UAC)
```

**Example - ACK Received:**
```
1. TransactionStatem receives ACK
2. TransactionStatem sends {:dialog_event, :ack_received} to Dialog
3. Dialog processes ACK, updates state
4. Dialog sends {:dialog_event, :ack_received} to UAS (owner)
5. UAS transitions :answering → :established
```

**Example - Timer H Timeout:**
```
1. TransactionStatem Timer H fires (32s, no ACK)
2. TransactionStatem sends {:dialog_event, :timer_h_timeout} to Dialog
3. Dialog sends {:dialog_event, :timer_h_timeout} to UAS (owner)
4. UAS transitions :answering → :terminated
```

---

## 11. Error Handling

### 11.1 Error Return Values

All functions follow Elixir conventions:

**Success:**
- `:ok`
- `{:ok, value}`

**Errors:**
- `{:error, :invalid_state}` - Operation not valid in current state
- `{:error, :not_found}` - Process not found
- `{:error, :timeout}` - Operation timed out
- `{:error, reason}` - Other errors

### 11.2 Process Crashes

Entities and Sessions are supervised:
- UAS crash → Session gets `{:DOWN, ref, :process, uas_pid, reason}`
- UAC crash → Session gets `{:DOWN, ref, :process, uac_pid, reason}`
- Session crash → Supervisor restarts or terminates all child processes

### 11.3 Invalid State Transitions

Attempting invalid operations returns `{:error, :invalid_state}`:

```elixir
# UAS in :terminated, can't answer
UAS.answer(dead_uas, sdp: sdp)
# => {:error, :invalid_state}
```

### 11.4 Authentication Errors

```elixir
# Invalid credentials
Auth.verify_credentials(auth_header, wrong_creds, "INVITE", uri)
# => {:invalid, :wrong_credentials}

# Stale nonce
Auth.verify_credentials(auth_header, creds, "INVITE", uri)
# => {:invalid, :stale_nonce}
```

---

## 12. Supervision Tree

### 12.1 Structure

```
ParrotSip.Application
└─ ParrotSip.Supervisor
   ├─ ParrotSip.Auth.NonceStore (GenServer)
   │  # Stores nonces for authentication
   │
   ├─ ParrotSip.Presence (GenServer)
   │  # Manages presence state
   │
   ├─ ParrotSip.B2BUA.Supervisor
   │  ├─ ParrotSip.B2BUA.SessionSupervisor (DynamicSupervisor)
   │  │  └─ [Sessions...]
   │  │
   │  ├─ ParrotSip.UAS.Supervisor (DynamicSupervisor)
   │  │  └─ [UAS entities...]
   │  │
   │  ├─ ParrotSip.UAC.Supervisor (DynamicSupervisor)
   │  │  └─ [UAC entities...]
   │  │
   │  └─ ParrotSip.Subscription.Supervisor (DynamicSupervisor)
   │     └─ [Subscription entities...]
   │
   └─ [Other ParrotSip components...]
```

### 12.2 Supervision Strategy

**Session Supervisor:**
- Type: DynamicSupervisor
- Strategy: `:one_for_one`
- Restart: `:temporary` (don't restart crashed sessions)

**Entity Supervisors (UAS, UAC, Subscription):**
- Type: DynamicSupervisor
- Strategy: `:one_for_one`
- Restart: `:temporary` (don't restart crashed entities)

**Singleton Services (Auth.NonceStore, Presence):**
- Type: GenServer under main Supervisor
- Strategy: `:one_for_one`
- Restart: `:permanent` (restart if crashed)

---

**Review Status:**
- [ ] APIs reviewed
- [ ] Types verified
- [ ] Examples tested
- [ ] Approved by: _____________
