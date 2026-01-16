# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Parrot Platform provides Elixir libraries and OTP behaviours for building telecom applications, implementing the SIP (Session Initiation Protocol) stack. **"Putting the 'T' back in OTP."**

**Architecture:** Umbrella application with 3 apps:
- **parrot_sip** - SIP protocol stack (transactions, dialogs, UA layer)
- **parrot_transport** - Protocol-agnostic transport layer (UDP/TCP/TLS/WebSocket)
- **parrot_media** - RTP streaming and SDP negotiation via Membrane

**Philosophy:** No shortcuts, complete RFC-compliant implementation, TDD-first approach

**Key Patterns:** `gen_statem` state machines, `DynamicSupervisor`, `Registry`, Behaviors

---

## Current Development Priority

1. Add B2BUA state machine and handler capabilities
2. Adding more complex sipp scenarios
   - retransmissions
   - re-invites
   - hold/unhold
   - UPDATE message to modify media mid-call
3. Add TCP and TLS transport support
4. Add registration client and server capabilities with authentication
   - Add sipp scenarios for testing:
     - Basic REGISTER / 200 OK
     - REGISTER with authentication (401 Unauthorized challenge)
     - REGISTER with expiry 0 (unregister)
     - Multiple contacts in a single REGISTER
   - Server registrar should make the storage of the registration handled by user handlers
5. Authentication & Security
   - INVITE with Digest Authentication (401 / 407 challenge + re-INVITE)
   - Wrong password (should reject)
   - OPTIONS with authentication

---

## Critical Rules

### Core Policies

1. **TDD Policy:** Write tests BEFORE implementation - no exceptions
2. **No Shortcuts:** Complete RFC-compliant implementation only, no TODOs in production code
3. **Media Handler Pattern:** Use message-passing for media control (not function calls)
4. **State Machines:** Use `gen_statem` for transactions, dialogs, and connections
5. **RFC References:** All SIP code must reference relevant RFC 3261 sections in comments
6. **Commit Messages:** Always write single-line commit messages - no multi-line descriptions
7. **Production-Grade Engineering:** Never take the easy way or cut corners. Always choose the best-engineered, most professional solution even if it requires more work. This is production VoIP software - prefer clean APIs, proper abstractions, and maintainable architecture over quick fixes. If a solution requires changing an existing API to be cleaner, do it.

### App-Specific Rules

#### parrot_sip
- See: `usage-rules/sip.md`
- RFC 3261 Section references required in all transaction/dialog code
- Transaction/Dialog ID generation via existing helpers (never manual strings)
- Timer values must match RFC specifications exactly
- Pattern match on message types, never use dynamic dispatch

#### parrot_media
- See: `usage-rules/media.md`
- **NO SIP dependencies** - media layer is completely independent
- Membrane Framework patterns for all pipelines
- SDP negotiation via `ExSDP` library only
- Audio chunking required for encoder frame alignment

#### parrot_transport
- Protocol-agnostic design (no SIP/RTP knowledge at transport layer)
- Unified `IncomingPacket` message format for all transports
- Content-Length framing for stream transports (TCP/TLS)
- Never inspect packet contents at transport layer

#### parrot (DSL Layer)
- High-level DSL for building VoIP applications
- Use `Parrot.InviteHandler` behaviour for call handling
- Use `Parrot.Router` for request routing with pattern matching
- `Bridge.Handler` connects ParrotSip to DSL handlers
- `Call.Server` manages call lifecycle and executes operations via `ActionExecutor`
- Pipeline operations: `answer()`, `reject(status)`, `hangup()`, `play(file)`
- Media events received via `{:media_event, session_id, event}` messages to Call.Server

---

## Media Handler Pattern (IMPORTANT)

**The MediaHandler system is message-driven. Files are NEVER configured at initialization and NEVER played automatically.**

### Correct Implementation Pattern:

1. **Create MediaSession with handler** (no audio_file parameter):
   ```elixir
   {:ok, media_pid} = MediaSessionSupervisor.start_session(
     id: session_id,
     dialog_id: dialog_id,
     role: :uas,
     media_handler: MyMediaHandler,
     handler_args: %{}  # No files here!
   )
   ```

2. **Store the media PID** for later use (e.g., in Registry)

3. **After media starts** (e.g., after ACK in SIP), send messages:
   ```elixir
   # Start the media pipeline
   MediaSession.start_media(session_id)

   # Then send control messages
   send(media_pid, {:play_files, ["welcome.wav"], loop: false})
   ```

### MediaHandler Rules:

- **NEVER** put audio files in init/1 state
- **NEVER** automatically play files in handle_stream_start/3
- **ONLY** play files when receiving explicit messages
- The handler should return actions like `{:play_sequence, files}` or `{:play_loop, files}`
- Use pattern matching in handle_info/2 for different message types

### Anti-patterns to avoid:
- ❌ Passing welcome_file or any audio files during initialization
- ❌ Playing files automatically when stream starts
- ❌ Configuring media behavior through init args
- ❌ Using audio_file parameter in MediaSession.start_link

---

## Coding Style Principles

### Pattern Matching Over Conditionals

**Use extensive pattern matching on data structures, especially the SIP message struct.** Prefer multiple function clauses with pattern matching over conditionals:

```elixir
# GOOD - Multiple function clauses with pattern matching
def handle_message(%Message{type: :request, method: "INVITE"} = msg), do: handle_invite(msg)
def handle_message(%Message{type: :request, method: "BYE"} = msg), do: handle_bye(msg)
def handle_message(%Message{type: :response, status: status} = msg) when status >= 200, do: handle_final_response(msg)

# BAD - Conditionals inside function
def handle_message(msg) do
  if msg.type == :request do
    case msg.method do
      "INVITE" -> handle_invite(msg)
      "BYE" -> handle_bye(msg)
    end
  else
    if msg.status >= 200 do
      handle_final_response(msg)
    end
  end
end
```

This approach:
- Makes code more readable and declarative
- Leverages Elixir's strengths
- Allows the compiler to optimize better
- Makes it easier to add new cases

---

## Test-Driven Development (TDD) Policy

**IMPORTANT: All new features and bug fixes MUST follow TDD principles:**

1. **Write Tests First**: Before implementing any new functionality or fixing bugs, write failing tests that specify the expected behavior
2. **Red-Green-Refactor Cycle**:
   - RED: Write a failing test
   - GREEN: Write the minimum code to make the test pass
   - REFACTOR: Improve the code while keeping tests green
3. **Test Coverage**: Aim for comprehensive test coverage, especially for:
   - SIP protocol handling (transactions, dialogs, messages)
   - State machine transitions
   - Error handling paths
   - Edge cases
4. **Integration Tests**: Always verify changes don't break SIPp integration tests
5. **Unit Test Quality**: Tests should be:
   - Fast and isolated (use `async: true` where possible)
   - Descriptive in their naming
   - Testing behavior, not implementation details
   - Properly isolated with appropriate setup/teardown
6. **SIPp Scenario Testing**: When new features are added, new SIPp scenarios should be added to the functional test suite

### Testing Requirements
- See: `usage-rules/testing.md`
- **SIPp integration tests required** for all SIP protocol changes
- Use `receive_final_response/1` helper for async response handling
- `async: false` for integration tests (port binding, hardware resources)
- Property-based tests with StreamData for parsers and state machines
- Test files must mirror source file structure

---

## Common Development Commands

### Testing
```bash
# All tests
mix test

# SIPp integration tests only
mix test --only sipp

# Specific test file/line
mix test test/sipp/client_test.exs:115

# With debug logging
LOG_LEVEL=debug SIP_TRACE=true mix test test/sipp/client_test.exs:115 --only sipp
```

### Code Quality
```bash
# Format code
mix format

# Compile with warnings as errors
mix compile --warnings-as-errors

# Type checking (when Dialyzer enabled)
mix dialyzer

# Static analysis (when Credo enabled)
mix credo --strict

# Coverage (when ExCoveralls configured)
mix coveralls.html
```

### Development
```bash
# Start interactive shell
iex -S mix

# Compile project
mix compile

# Get dependencies
mix deps.get

# Generate docs
mix docs
```

---

## Debugging Guidelines

### Root Cause Analysis
**IMPORTANT: Always fix the root cause, not symptoms:**
- If you encounter duplicate messages or invalid state transitions, trace back to find WHY they're happening
- Don't add defensive handlers for bad situations - fix the source of the problem
- State machines should enforce proper transitions and crash on invalid ones to expose bugs

### Handler Architecture
When working with SIP handlers and media handlers:
- **Clear naming**: Use descriptive names like `SipHandler` vs `MediaHandler` to clarify responsibilities
- **Single responsibility**: Each handler should have one clear purpose
- **Avoid duplication**: Don't have multiple handlers sending the same messages
- Example: UAC callback handles SIP responses, SipHandler just consumes to prevent duplicates

### Audio Device Configuration
**Critical timing issue**: Audio devices MUST be configured BEFORE pipeline selection:
- Configure `input_device_id` and `output_device_id` when creating MediaSession
- Set `audio_source: :device` and/or `audio_sink: :device` upfront
- This ensures `PortAudioPipeline` is selected instead of `OpusPipeline`/`AlawPipeline`
- Wrong: Sending `:use_audio_devices` message after media session starts
- Right: Pass device configuration in MediaSessionSupervisor.start_session opts

### Debugging Tips
- Use `LOG_LEVEL=debug` for detailed state machine logs
- Use `SIP_TRACE=true` to see wire format messages
- Check Registry for process lookup issues: `Registry.lookup(ParrotSip.Registry, {:transaction, id})`
- State machines log all transitions at debug level

---

## Anti-Patterns to Avoid

1. **Don't use `to_string/1` on `ParrotSip.Uri` structs**
   - Use `ParrotSip.Uri.to_string/1` instead

2. **Don't send responses from client transactions**
   - Only server transactions send responses
   - Client transactions only send requests

3. **Don't use `inspect/1` in serialization**
   - Always pattern match on known types
   - Use dedicated format functions for headers

4. **Don't skip SIPp scenario pauses**
   - Add `Process.sleep/1` to wait for SIPp timing
   - See `test/sipp/ua_test.exs:203` for example

5. **Don't mix protocol layers**
   - SIP layer never touches RTP
   - Transport layer never inspects payloads
   - Media layer independent of SIP

---

## Architecture Overview

### Critical: gen_statem Usage

**Parrot uses Erlang's gen_statem (state machine) behavior extensively, NOT just GenServer.** This is a key architectural decision that differs from most Elixir libraries:

- **Transaction State Machines**: `ParrotSip.TransactionStatem` uses gen_statem to implement proper SIP transaction state machines
- **Dialog State Management**: Dialog lifecycle is managed through gen_statem states
- **Transport Layer**: Connection state management uses gen_statem

When working with these modules, understand gen_statem concepts:
- State functions (not just handle_* callbacks)
- State transitions with `{:next_state, new_state, data}`
- State enter calls
- Complex state data management

### Core Components

1. **SIP Stack Architecture**
   - **Transport Layer**: Handles UDP/TCP/TLS transport, connection management using gen_statem
   - **Transaction Layer**: Implements RFC 3261 transaction state machines using gen_statem
   - **Dialog Layer**: Manages SIP dialog lifecycle with gen_statem
   - **Message Layer**: Core SIP message representation and manipulation

2. **Handler Pattern**
   - Central to Parrot is the handler pattern
   - Handlers implement callbacks for SIP events (requests, responses, errors)
   - Handler adapters convert between different handler implementations

3. **Supervision Tree**
   The application starts multiple supervisors:
   - Transport Supervisor: Manages transport processes
   - Transaction Supervisor: Manages transaction state machines
   - Dialog Supervisor: Manages dialog state machines
   - Handler Adapter Supervisor: Manages handler adapters

4. **Header System**
   - All SIP headers are in dedicated modules
   - Each header has parsing and serialization logic
   - Headers use behavior pattern

5. **Key Patterns**
   - **State Machines (gen_statem)**: Core pattern for transactions, dialogs, and transport
   - **GenServer**: Used for simpler components without complex state transitions
   - **Registry**: Used for process discovery
   - **ETS**: Used for caching and fast lookups

### Important Implementation Details

1. **Message Direction**: Explicit message direction (inbound/outbound) and type structure
2. **Transaction Keys**: Transactions are identified by branch, method, and direction
3. **Branch Management**: Proper Via branch parameter handling is critical for transaction matching
4. **DNS Resolution**: Built-in DNS resolver for SIP URI resolution
5. **Connection Pooling**: Transport layer manages connection pools for efficiency
6. **State Machine Design**: Transaction and dialog modules implement proper SIP state machines as defined in RFC 3261

---

## Key Modules by Layer

### SIP Layer (parrot_sip)
- `ParrotSip.TransactionStatem` - Transaction state machine
- `ParrotSip.DialogStatem` - Dialog state machine
- `ParrotSip.UA` - High-level User Agent API
- `ParrotSip.Parser` - NimbleParsec-based SIP message parser
- `ParrotSip.Serializer` - Message struct to wire format

### Transport Layer (parrot_transport)
- `ParrotTransport.UdpListener` - UDP transport
- `ParrotTransport.TcpListener` - TCP transport with acceptor pool
- `ParrotTransport.TlsListener` - TLS transport
- `ParrotTransport.Connection` - Connection state machine
- `ParrotTransport.Framing.ContentLength` - Stream message framing

### Media Layer (parrot_media)
- `ParrotMedia.MediaSession` - Media session lifecycle
- `ParrotMedia.Handler` - Media handler behavior
- `ParrotMedia.PortAudioPipeline` - Audio device integration
- `ParrotMedia.AudioChunker` - Buffer normalization

---

## Where to Find Information

### Architecture & Design
- **Architecture:** `guides/architecture.md`
- **SIP Basics:** `guides/sip-basics.md`
- **Media Handling:** `guides/media-handler.md`
- **State Machines:** `guides/state-machines.md`
- **Message Architecture:** `guides/MESSAGE_ARCHITECTURE.md`

### Implementation Guides
- **Production Roadmap:** `docs/PRODUCTION_ROADMAP.md`
- **Project Status:** `docs/PROJECT_STATUS.md`
- **Ad-hoc SIP Testing (pjsua):** `docs/pjsua-testing.md`

### Usage Rules (AI Agent Context)
- **SIP Rules:** `usage-rules/sip.md`
- **Media Rules:** `usage-rules/media.md`
- **Testing Rules:** `usage-rules/testing.md`

### API Documentation
- **Main README:** `README.md`
- **Transport Integration:** `apps/parrot_transport/CORRECT_INTEGRATION.md`
- **Media Handler API:** `apps/parrot_media/lib/parrot_media/handler.ex` (moduledoc)
- **UA API:** `apps/parrot_sip/lib/parrot_sip/ua.ex` (moduledoc)

---

## Sub-Agent Specializations

- **sip-expert** - RFC 3261 compliance, transaction/dialog logic
- **media-expert** - Membrane pipelines, SDP negotiation, audio processing
- **transport-expert** - Socket management, framing, protocol-agnostic design
- **test-generator** - SIPp scenarios, property-based tests, edge cases
- **doc-writer** - Guides, API documentation, code examples

---

## Version Information

- **Current Version:** 0.0.1-alpha.4
- **Elixir:** ~> 1.16
- **OTP:** 26+
- **Status:** Alpha - not production ready
- **Missing:** RTP headers, RTCP, multiple codecs, full UAC, authentication

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

## Active Technologies
- Elixir ~> 1.16 with OTP 26+ + ParrotSip (SIP stack), ParrotTransport (UDP/TCP), ParrotMedia (MediaSession, pipelines) (001-dsl-sip-bridge)
- In-memory process state, ETS for call/dialog lookups via Registry (001-dsl-sip-bridge)

## Recent Changes
- 001-dsl-sip-bridge: Added Elixir ~> 1.16 with OTP 26+ + ParrotSip (SIP stack), ParrotTransport (UDP/TCP), ParrotMedia (MediaSession, pipelines)
