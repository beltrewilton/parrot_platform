# SIPp Integration Testing Framework

This directory contains a comprehensive SIPp-based integration testing framework for the Parrot Platform.

## Overview

The SIPp integration testing setup provides:
- **Support Modules**: Reusable helpers for running SIPp tests
- **SIPp Scenarios**: XML test scenarios for various SIP flows
- **Test Files**: ExUnit tests that orchestrate SIPp and ParrotSip

## Directory Structure

```
test/sipp/
├── README.md                    # This file
├── support/                     # Helper modules (loaded via Code.require_file)
│   ├── sipp_runner.ex          # SIPp execution wrapper
│   ├── test_handler.ex         # Configurable ParrotSip.Handler implementation
│   └── transport_helper.ex     # Transport lifecycle management
├── scenarios/                   # SIPp XML scenario files
│   ├── basic/                  # Basic UAC/UAS scenarios (existing)
│   ├── cancel/                 # CANCEL request scenarios
│   ├── tcp/                    # TCP transport scenarios
│   ├── tls/                    # TLS transport scenarios
│   └── ...                     # Other scenario categories
├── fixtures/                    # Test data and certificates
│   ├── certs/                  # TLS certificates for secure transport testing
│   └── sdp/                    # SDP bodies for testing
├── logs/                        # SIPp execution logs (gitignored)
├── test_scenarios.exs           # Original SIPp tests (working)
├── test_basic.exs               # Basic UDP scenario tests (needs API updates)
├── test_cancel.exs              # CANCEL scenario tests (needs API updates)
└── test_transports.exs          # Transport tests (needs API updates)
```

## Support Modules

### SippRunner (`support/sipp_runner.ex`)

Elixir wrapper for executing SIPp via `System.cmd/3`.

**Features:**
- All transport types (UDP, TCP, TLS, WebSocket)
- Configurable timeouts, call rates, tracing
- Automatic TLS certificate handling
- Returns `:ok` or `{:error, reason}`

**Usage:**
```elixir
:ok = SippRunner.run_scenario(
  scenario_file: "test/sipp/scenarios/basic/uac_invite.xml",
  remote_host: "127.0.0.1",
  remote_port: 5060,
  calls: 1,
  timeout: 5_000
)
```

### TestHandler (`support/test_handler.ex`)

Configurable `ParrotSip.Handler` implementation for testing.

**Features:**
- Implements all required `ParrotSip.Handler` callbacks
- Auto-response configuration per method
- Statistics tracking (invites, acks, byes, etc.)
- Spawns background process for state management

**Usage:**
```elixir
handler = TestHandler.new(
  auto_respond: true,
  invite_response: {200, "OK"},
  track_stats: true
)

# Later...
stats = TestHandler.get_stats(handler.args)
assert stats.invites == 10
```

### TransportHelper (`support/transport_helper.ex`)

Helper functions for ParrotTransport listener management.

**Features:**
- Start UDP, TCP, TLS, WebSocket listeners
- Automatic port discovery (port 0 support)
- TLS certificate path management
- Graceful shutdown

**Usage:**
```elixir
{:ok, listener, port} = TransportHelper.start_udp_listener(handler_pid)
:ok = TransportHelper.stop_listener(listener, :udp)
```

## SIPp Scenarios

### Basic Scenarios (`scenarios/basic/`)
- `uac_invite.xml` - UAC INVITE → 200 OK → ACK → BYE
- `uas_invite.xml` - UAS responding to INVITE
- `uac_options.xml` - OPTIONS ping/pong
- More scenarios from original implementation

### CANCEL Scenarios (`scenarios/cancel/`)
- `uac_cancel.xml` - INVITE → CANCEL → 487 → ACK

### Transport Scenarios
- `tcp/uac_invite_tcp.xml` - INVITE over TCP
- `tls/uac_invite_tls.xml` - INVITE over TLS (requires certs)

## TLS Certificates

Self-signed certificates for testing are generated in `fixtures/certs/`:

```bash
cd test/sipp/fixtures/certs
./generate_certs.sh
```

Generated files:
- `ca-cert.pem`, `ca-key.pem` - Certificate Authority
- `server-cert.pem`, `server-key.pem` - Server certificates
- `client-cert.pem`, `client-key.pem` - Client certificates

**Note:** Certificate files are gitignored (`*.pem`, `*.srl`).

## Running Tests

### Run all SIPp tests:
```bash
mix test.sipp
```

### Run specific test file:
```bash
mix test test/sipp/test_scenarios.exs --include sipp
```

### Run with SIP trace logging:
```bash
SIP_TRACE=true LOG_LEVEL=info mix test.sipp
```

## Current Status

### ✅ Complete
- Directory structure with all scenario categories
- TLS certificate generation script
- SippRunner module (370 lines, fully documented)
- TestHandler module (495 lines, implements ParrotSip.Handler)
- TransportHelper module (390 lines, all transports)
- SIPp scenarios for CANCEL, TCP, TLS
- `.gitignore` entries for certificates and logs
- `mix test.sipp` alias properly configured for umbrella project

### ⚠️ Needs Work
The new test files (`test_basic.exs`, `test_cancel.exs`, `test_transports.exs`) were written against an assumed API that doesn't match the actual ParrotSip implementation. They need to be rewritten to follow the pattern in `test_scenarios.exs`:

**Current Issue:**
Tests call `ParrotSip.start_core/1` which doesn't exist.

**Actual API Pattern** (from `test_scenarios.exs`):
```elixir
# 1. Define handler using Parrot.UasHandler behavior
defmodule MyHandler do
  use Parrot.UasHandler
  
  def handle_invite(_request, _state) do
    {:respond, 200, "OK", %{}, sdp}
  end
  
  def handle_ack(_request, _state), do: :noreply
  def handle_bye(_request, _state), do: {:respond, 200, "OK", %{}, ""}
end

# 2. Create handler adapter
sip_handler = Parrot.Sip.Handler.new(
  Parrot.Sip.HandlerAdapter.Core,
  {MyHandler, %{}},
  log_level: :warning,
  sip_trace: false
)

# 3. Start transport
opts = %{
  listen_port: 5060,
  handler: sip_handler
}
:ok = Parrot.Sip.Transport.StateMachine.start_udp(opts)
```

### Next Steps

1. **Rewrite Test Files**: Update `test_basic.exs`, `test_cancel.exs`, and `test_transports.exs` to use the actual Parrot API pattern from `test_scenarios.exs`

2. **Update TestHandler**: Modify `TestHandler` to use `Parrot.UasHandler` behavior instead of `ParrotSip.Handler` directly

3. **Add More Scenarios**: Create scenarios for:
   - Re-INVITE
   - Early media (183 Session Progress)
   - Authentication (401/407 challenges)
   - Redirects (3xx responses)
   - Stress/load testing

4. **Integration with CI/CD**: Add SIPp tests to continuous integration pipeline

## References

- **SIPp Documentation**: http://sipp.sourceforge.net/
- **RFC 3261**: SIP: Session Initiation Protocol
- **Existing Tests**: `test/sipp/test_scenarios.exs` for working examples

## Contributing

When adding new scenarios or tests:
1. Follow the existing pattern in `test_scenarios.exs`
2. Document new scenarios with clear comments
3. Add statistics assertions to verify correct behavior
4. Use descriptive test names that explain the scenario
