# Claude AI Context for Parrot Platform

## Project Overview

Parrot Platform is an **RFC 3261-compliant SIP stack** with media handling via Membrane Framework.

**Architecture:** Umbrella application with 3 apps:
- **parrot_sip** - SIP protocol stack (transactions, dialogs, UA layer)
- **parrot_transport** - Protocol-agnostic transport layer (UDP/TCP/TLS/WebSocket)
- **parrot_media** - RTP streaming and SDP negotiation via Membrane

**Philosophy:** No shortcuts, complete RFC-compliant implementation, TDD-first approach

**Key Patterns:** `gen_statem` state machines, `DynamicSupervisor`, `Registry`, Behaviors

---

## Critical Rules

### From AGENTS.md

1. **TDD Policy:** Write tests BEFORE implementation - no exceptions
2. **No Shortcuts:** Complete RFC-compliant implementation only, no TODOs in production code
3. **Media Handler Pattern:** Use message-passing for media control (not function calls)
4. **State Machines:** Use `gen_statem` for transactions, dialogs, and connections
5. **RFC References:** All SIP code must reference relevant RFC 3261 sections in comments

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
- SDP negotiation via `Ex SDP` library only
- Audio chunking required for encoder frame alignment

#### parrot_transport
- Protocol-agnostic design (no SIP/RTP knowledge at transport layer)
- Unified `IncomingPacket` message format for all transports
- Content-Length framing for stream transports (TCP/TLS)
- Never inspect packet contents at transport layer

### Testing Requirements

- See: `usage-rules/testing.md`
- **SIPp integration tests required** for all SIP protocol changes
- Use `receive_final_response/1` helper for async response handling
- `async: false` for integration tests (port binding, hardware resources)
- Property-based tests with StreamData for parsers and state machines
- Test files must mirror source file structure

---

## Current Work Status

- **Phase:** Alpha (v0.0.1-alpha.4)
- **Last Major Work:**
  - Fixed serialization bugs (MethodSet, Uri formatting)
  - Fixed transaction state machine (client completed state)
  - All SIPP tests passing (1073 tests, 0 failures)
- **Next Priorities:**
  1. RTP implementation (most critical gap)
  2. Additional codecs (G.711 A-law, Opus)
  3. UAC completion
  4. RTCP support

---

## Where to Find Information

### Architecture & Design
- **Architecture:** `guides/architecture.md`
- **SIP Basics:** `guides/sip-basics.md`
- **Media Handling:** `guides/media-handler.md`
- **State Machines:** `guides/state-machines.md`
- **Message Architecture:** `guides/MESSAGE_ARCHITECTURE.md`

### Implementation Guides
- **SIP Implementation:** `PARROT_IMPLEMENTATION_GUIDE.md`
- **Production Roadmap:** `docs/PRODUCTION_ROADMAP.md`
- **Project Status:** `docs/PROJECT_STATUS.md`
- **SIPp Testing:** `SIPP_INTEGRATION_TESTING_IMPLEMENTATION_GUIDE.md`

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

## Common Tasks

### Running Tests
```bash
# All tests
mix test

# SIPP integration tests only
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

# Type checking (when Dialyzer enabled)
mix dialyzer

# Static analysis (when Credo enabled)
mix credo --strict

# Coverage (when ExCoveralls configured)
mix coveralls.html
```

### Documentation
```bash
# Generate docs
mix docs

# View docs locally
open doc/index.html
```

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

4. **Don't skip SIPP scenario pauses**
   - Add `Process.sleep/1` to wait for SIPP timing
   - See `test/sipp/ua_test.exs:203` for example

5. **Don't mix protocol layers**
   - SIP layer never touches RTP
   - Transport layer never inspects payloads
   - Media layer independent of SIP

---

## When Making Changes

### Before Implementing
1. Check if RFC 3261 defines the behavior
2. Look for existing patterns in codebase
3. Write failing test first (TDD)
4. Reference relevant RFC section in code comments

### After Implementing
1. Run formatter: `mix format`
2. Run compiler: `mix compile --warnings-as-errors`
3. Run tests: `mix test`
4. Run SIPP tests if SIP changes: `mix test --only sipp`
5. Update documentation if API changed

### Debugging Tips
- Use `LOG_LEVEL=debug` for detailed state machine logs
- Use `SIP_TRACE=true` to see wire format messages
- Check Registry for process lookup issues: `Registry.lookup(ParrotSip.Registry, {:transaction, id})`
- State machines log all transitions at debug level

---

## Sub-Agent Specializations

- **sip-expert** - RFC 3261 compliance, transaction/dialog logic
- **media-expert** - Membrane pipelines, SDP negotiation, audio processing
- **transport-expert** - Socket management, framing, protocol-agnostic design
- **test-generator** - SIPp scenarios, property-based tests, edge cases
- **doc-writer** - Guides, API documentation, code examples

---

## Key Modules by Layer

### SIP Layer (parrot_sip)
- `ParrotSip.TransactionStatem` - Transaction state machine (2,778 lines)
- `ParrotSip.DialogStatem` - Dialog state machine (877 lines)
- `ParrotSip.UA` - High-level User Agent API (731 lines)
- `ParrotSip.Parser` - NimbleParsec-based SIP message parser (655 lines)
- `ParrotSip.Serializer` - Message struct to wire format (960+ lines)

### Transport Layer (parrot_transport)
- `ParrotTransport.UdpListener` - UDP transport (252 lines)
- `ParrotTransport.TcpListener` - TCP transport with acceptor pool (260 lines)
- `ParrotTransport.TlsListener` - TLS transport (279 lines)
- `ParrotTransport.Connection` - Connection state machine (426 lines)
- `ParrotTransport.Framing.ContentLength` - Stream message framing (181 lines)

### Media Layer (parrot_media)
- `ParrotMedia.MediaSession` - Media session lifecycle (1,407 lines)
- `ParrotMedia.Handler` - Media handler behavior (570 lines)
- `ParrotMedia.PortAudioPipeline` - Audio device integration (555 lines)
- `ParrotMedia.AudioChunker` - Buffer normalization (284 lines)

---

## Version Information

- **Current Version:** 0.0.1-alpha.4
- **Elixir:** ~> 1.16
- **OTP:** 26+
- **Status:** Alpha - not production ready
- **Missing:** RTP headers, RTCP, multiple codecs, full UAC, authentication

---

*This file is automatically synced with usage-rules by Claude package.*
