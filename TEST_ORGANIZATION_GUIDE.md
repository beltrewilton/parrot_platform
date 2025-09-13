# Test Organization Guide for Umbrella Structure

## Test Categories and Where They Belong

### 1. Unit Tests (Inside Each App)
**Location**: `apps/<app_name>/test/`

These tests should:
- Test individual modules in isolation
- Use mocks/stubs for external dependencies
- Never require other apps to be running
- Run fast and independently

**Examples**:
- `apps/parrot_transport/test/` - Test UDP socket creation, packet handling
- `apps/parrot_media/test/` - Test SDP parsing, RTP packet handling
- `apps/parrot_sip/test/` - Test message parsing, header manipulation

### 2. Integration Tests (Root Level)
**Location**: `test/integration/`

These tests should:
- Test interaction between apps
- Verify message passing between apps
- Test complete workflows (e.g., full SIP call flow)
- Require multiple apps to be running

**Examples**:
```elixir
# test/integration/sip_call_flow_test.exs
defmodule Integration.SipCallFlowTest do
  use ExUnit.Case
  
  test "complete INVITE-200-ACK flow through all apps" do
    # Start transport
    {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15060)
    
    # Start SIP handler that uses transport
    {:ok, sip_handler} = ParrotSip.UAC.start_link(transport: transport)
    
    # Start media session
    {:ok, media} = ParrotMedia.start_session(id: "test")
    
    # Test the complete flow
    # ...
  end
end
```

### 3. System Tests (Root Level)
**Location**: `test/sipp/`

These tests:
- Use external tools (SIPp) to test the complete system
- Verify the platform works as a real SIP endpoint
- Test performance and compliance
- Must remain at root level

## Recommended Test Migration Strategy

### Step 1: Identify Test Types

Go through failing tests and categorize them:

```elixir
# Unit test - stays in app
defmodule ParrotSip.MessageTest do
  test "parses INVITE request" do
    # Only tests message parsing, no external deps
  end
end

# Integration test - move to root
defmodule Integration.UacUasTest do
  test "UAC sends INVITE to UAS through transport" do
    # Needs transport + SIP apps working together
  end
end
```

### Step 2: Create Test Structure

```bash
# Root level test structure
test/
├── integration/          # Inter-app integration tests
│   ├── call_flow_test.exs
│   ├── media_negotiation_test.exs
│   ├── transport_sip_test.exs
│   └── sip_media_test.exs
├── system/              # Full system tests
│   └── compliance_test.exs
├── sipp/                # SIPp tests (already here)
│   ├── scenarios/
│   └── test_scenarios.exs
└── support/             # Shared test helpers
    └── test_case.ex

# App level test structure (example for parrot_sip)
apps/parrot_sip/test/
├── parrot_sip/
│   ├── message_test.exs      # Unit test
│   ├── parser_test.exs       # Unit test
│   └── headers/
│       └── via_test.exs      # Unit test
└── support/
    └── sip_test_helper.ex    # App-specific helpers
```

### Step 3: Fix Failing Tests

For each failing test, determine the fix:

#### Option A: Convert to Unit Test (Mock Dependencies)

**Before** (expects real transport):
```elixir
defmodule ParrotSip.UACTest do
  test "sends INVITE through transport" do
    {:ok, uac} = ParrotSip.UAC.start_link()
    # This fails because it expects Transport.Udp to exist
    assert :ok = ParrotSip.UAC.send_invite(uac, request)
  end
end
```

**After** (mocked transport):
```elixir
defmodule ParrotSip.UACTest do
  test "sends INVITE through transport" do
    # Mock the transport interaction
    transport_mock = spawn(fn ->
      receive do
        {:send_packet, _data, _dest} -> :ok
      end
    end)
    
    {:ok, uac} = ParrotSip.UAC.start_link(transport: transport_mock)
    assert :ok = ParrotSip.UAC.send_invite(uac, request)
  end
end
```

#### Option B: Move to Integration Tests

**Move from**: `apps/parrot_sip/test/parrot_sip/uas_test.exs`
**Move to**: `test/integration/uas_integration_test.exs`

```elixir
defmodule Integration.UasIntegrationTest do
  use ExUnit.Case
  
  setup do
    # Start all required apps
    {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15061)
    {:ok, uas} = ParrotSip.UAS.start_link(transport: transport)
    
    %{transport: transport, uas: uas}
  end
  
  test "UAS receives INVITE and sends response", %{transport: transport, uas: uas} do
    # Test with real transport and SIP interaction
    ParrotTransport.register_handler(transport, uas)
    
    # Send INVITE through transport
    :gen_udp.send(socket, {127, 0, 0, 1}, 15061, invite_message)
    
    # Verify response
    assert_receive {:udp, _, _, _, response}, 1000
    assert response =~ "SIP/2.0 200 OK"
  end
end
```

#### Option C: Remove Obsolete Tests

Some tests might be testing implementation details that no longer exist:
- Tests for `Parrot.Sip.Transport.Udp` (now in ParrotTransport)
- Tests for direct module calls between apps
- Tests for monolithic handler patterns

### Step 4: Create Test Helpers

Create shared test helpers at root level:

```elixir
# test/support/integration_case.ex
defmodule IntegrationCase do
  use ExUnit.CaseTemplate
  
  setup do
    # Start registries
    {:ok, _} = Registry.start_link(keys: :unique, name: TestRegistry)
    
    # Helper to start all apps
    on_exit(fn ->
      # Cleanup
    end)
    
    :ok
  end
  
  def start_sip_stack(opts \\ []) do
    port = opts[:port] || 15060
    
    {:ok, transport} = ParrotTransport.start_listener(:udp, port: port)
    {:ok, sip} = ParrotSip.Transport.start_link(transport: transport)
    
    %{transport: transport, sip: sip}
  end
end
```

## Specific Recommendations for Current Failing Tests

Based on the 51 failing tests out of 136:

### 1. Media Session Tests
**Current location**: `apps/parrot_media/test/parrot_media/media_session_*_test.exs`
**Issue**: These tests expect SIP components to exist
**Fix**: 
- Keep unit tests for media-only functionality in the app
- Move integration tests that need SIP to `test/integration/media_integration_test.exs`

### 2. UAC/UAS Integration Tests  
**Current location**: `apps/parrot_media/test/parrot_media/uac_uas_integration_test.exs`
**Issue**: Obviously needs both SIP and Media
**Fix**: Move to `test/integration/uac_uas_integration_test.exs`

### 3. Handler Tests
**Current location**: Various handler tests in apps
**Issue**: Handlers often coordinate between apps
**Fix**: 
- Mock dependencies for unit testing the handler logic
- Create integration tests for end-to-end handler flows

### 4. Transport Tests in SIP
**Current location**: `apps/parrot_sip/test/parrot_sip/transport_test.exs`
**Issue**: SIP transport tests expect real UDP transport
**Fix**: 
- Remove these tests (transport is tested in ParrotTransport)
- Or convert to integration tests that use real ParrotTransport

## Test Execution Strategy

```bash
# Run unit tests for each app (should be fast and all pass)
mix test apps/parrot_transport/test --exclude integration
mix test apps/parrot_media/test --exclude integration  
mix test apps/parrot_sip/test --exclude integration

# Run integration tests (some setup required)
mix test test/integration --only integration

# Run system tests
mix test test/sipp --only sipp

# Run everything
mix test.all
```

## Benefits of This Approach

1. **Clear separation of concerns**: Unit tests stay with their apps
2. **Fast feedback**: Unit tests run quickly without dependencies
3. **Comprehensive coverage**: Integration tests verify inter-app communication
4. **Maintainable**: Changes to one app don't break other apps' unit tests
5. **Realistic testing**: Integration tests verify actual message passing patterns

## Implementation Priority

1. **First**: Move obvious integration tests to root level (like uac_uas_integration_test.exs)
2. **Second**: Add mocks to unit tests that have minor external dependencies
3. **Third**: Create new integration tests for critical paths
4. **Fourth**: Remove obsolete tests that test old patterns
5. **Finally**: Add GitHub Actions to run tests in correct order

This approach ensures each app can be developed and tested independently while still maintaining confidence that the complete system works correctly.