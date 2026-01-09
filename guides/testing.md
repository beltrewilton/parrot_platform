# Testing Guide

This guide covers testing strategies for applications using the Parrot Framework, including unit tests, integration tests, and testing with real SIP clients.

## Prerequisites

- Elixir 1.16 or later
- SIPp (Session Initiation Protocol performance testing tool)
- ffmpeg (for audio file conversions)
- A SIP client for manual testing (e.g., Linphone, MicroSIP, Zoiper)

---

## Testing Parrot DSL Handlers

The `Parrot.Test` module provides a comprehensive testing framework for Parrot-based VoIP applications. It supports three levels of testing:

1. **Unit Tests** - Direct handler function testing
2. **Flow Tests** - Simulated call sequences
3. **SIPp Integration Tests** - Real SIP protocol testing

### Quick Start

```elixir
defmodule MyApp.IVRHandlerTest do
  use ExUnit.Case
  use Parrot.Test

  test "plays welcome message on answer" do
    call = call_fixture(assigns: %{menu: :main})
    result = MyApp.IVRHandler.handle_dtmf("1", call)

    assert_played(result, "sales-menu.wav")
    assert_assign(result, :menu, :sales)
  end
end
```

### Creating Test Fixtures

Use `call_fixture/1` to create test call structures:

```elixir
# Basic fixture with defaults
call = call_fixture()

# Custom configuration
call = call_fixture(
  from: "sip:alice@example.com",
  to: "sip:sales@company.com",
  assigns: %{menu: :main, retries: 0},
  handler: MyApp.IVRHandler
)
```

### Assertion Helpers

Import assertions with `use Parrot.Test`:

```elixir
# Assert file was played (exact match)
assert_played(call, "welcome.wav")

# Assert file was played (regex match)
assert_played(call, ~r/menu/)

# Assert call was bridged
assert_bridged(call, "sip:sales@internal")
assert_bridged(call, ~r/sales/)

# Assert call state
assert_answered(call)
assert_rejected(call, 486)
assert_hung_up(call)

# Assert assigns
assert_assign(call, :menu, :main)

# Assert other actions
assert_collecting_dtmf(call)
assert_prompted(call, "enter-pin.wav")
assert_recording(call, "recording.wav")
```

### Simulation Helpers

Simulate events during a call flow:

```elixir
# Simulate DTMF input
call = simulate_dtmf(call, "1")
call = simulate_dtmf(call, :timeout)

# Simulate playback completion
call = simulate_play_complete(call, "welcome.wav")

# Simulate bridge results
call = simulate_bridge_result(call, :answered)
call = simulate_bridge_result(call, {:failed, :busy})
call = simulate_bridge_result(call, {:failed, :no_answer})

# Simulate other events
call = simulate_prompt_complete(call, "enter-pin.wav", "1234")
call = simulate_record_complete(call, "recording.wav", 30_000)
call = simulate_hangup(call)
```

### Complete Flow Test Example

```elixir
defmodule MyApp.IVRFlowTest do
  use ExUnit.Case
  use Parrot.Test

  test "complete IVR flow to sales" do
    # Start with a call fixture and handler
    call = call_fixture(handler: MyApp.IVRHandler)

    # Invoke the initial INVITE handler
    call = invoke_handle_invite(call)
    assert_played(call, "welcome.wav")

    # Simulate welcome message completing
    call = simulate_play_complete(call, "welcome.wav")
    assert_played(call, "main-menu.wav")

    # Simulate user pressing 1 for sales
    call = simulate_dtmf(call, "1")
    assert_bridged(call, ~r/sales/)

    # Simulate successful bridge
    call = simulate_bridge_result(call, :answered)
    assert_assign(call, :bridge_answered, true)
  end

  test "handles DTMF timeout" do
    call = call_fixture(handler: MyApp.IVRHandler)
    call = invoke_handle_invite(call)
    call = simulate_play_complete(call, "welcome.wav")

    # Simulate timeout (no DTMF received)
    call = simulate_dtmf(call, :timeout)
    assert_played(call, "goodbye.wav")
  end
end
```

### Using simulate_call/1

For simpler flow tests, use `simulate_call/1` to create a call and invoke `handle_invite` in one step:

```elixir
test "simple flow test" do
  {:ok, call} = Parrot.Test.simulate_call(
    handler: MyApp.IVRHandler,
    to: "sip:100@local"
  )

  assert_played(call, "welcome.wav")
end
```

---

## Running Tests

### Unit Tests

Run all unit tests:
```bash
mix test
```

Run tests for a specific module:
```bash
mix test test/parrot/sip/transaction_test.exs
```

Run a specific test:
```bash
mix test test/parrot/sip/transaction_test.exs:42
```

Run tests with coverage:
```bash
mix test --cover
```

### Integration Tests with SIPp

The framework includes SIPp scenarios for testing SIP protocol compliance:

```bash
# Run all SIPp tests
mix test test/sipp/test_scenarios.exs

# Run specific scenario
mix test test/sipp/test_scenarios.exs --only uac_invite
```

#### Available SIPp Scenarios

1. **Basic INVITE** (`uac_invite.xml`)
   - Tests basic call setup and teardown
   - Validates SIP transaction handling

2. **Long INVITE** (`uac_invite_long.xml`)
   - Tests longer duration calls
   - Validates dialog state management

3. **INVITE with RTP** (`uac_invite_rtp.xml`)
   - Tests calls with RTP media
   - Validates SDP negotiation

4. **OPTIONS** (`uac_options.xml`)
   - Tests OPTIONS method handling
   - Validates capability queries

## Manual Testing with SIP Clients

### Starting the Test Server

```bash
# Start the server with IEx
iex -S mix

# In IEx, start a UAS (User Agent Server)
{:ok, _pid} = Parrot.Sip.UAS.start_link(
  port: 5060,
  handler: YourApp.SipHandler
)
```

### Configuring SIP Clients

Configure your SIP client with:
- **Server/Proxy**: Your machine's IP address
- **Port**: 5060 (or your configured port)
- **Username**: Any value (authentication not required for testing)
- **Transport**: UDP

### Testing Call Flows

1. **Basic Call**
   - Register your SIP client (if required)
   - Make a call to any number
   - Verify INVITE is received and processed
   - Verify RTP streams if media is enabled

2. **DTMF Testing**
   - During a call, press digits
   - Verify DTMF events are received

3. **Hold/Resume**
   - Place call on hold
   - Verify re-INVITE with appropriate SDP

### Testing with gophone

[gophone](https://github.com/pion/gophone) is a command-line SIP client ideal for testing Parrot applications.

#### Installation

```bash
go install github.com/pion/gophone@latest
```

#### Testing the DSL Examples

**1. Echo Server**
```bash
# Start the echo server (in one terminal)
mix run -e "Parrot.Examples.EchoServer.start(port: 15060)"

# Make a test call (in another terminal)
gophone dial sip:test@127.0.0.1:15060

# Expected: Call answers with 200 OK, then terminates on hangup
```

**2. Simple IVR**
```bash
# Start the IVR server
mix run -e "Parrot.Examples.SimpleIVR.start(port: 15061)"

# Make a call
gophone dial sip:welcome@127.0.0.1:15061

# Make a call with DTMF
gophone dial -dtmf=1 -dtmf_delay=2s sip:welcome@127.0.0.1:15061

# Expected: Answers, plays welcome audio, handles DTMF
```

**3. Registrar**
```bash
# Start the registrar
mix run -e "Parrot.Examples.Registrar.start(port: 15062)"

# Register a user
gophone register -username=alice sip:127.0.0.1:15062

# Expected: 200 OK response, registration stored
```

#### gophone Common Options

| Option | Description | Example |
|--------|-------------|---------|
| `-username` | SIP username | `-username=alice` |
| `-password` | SIP password | `-password=secret` |
| `-dtmf` | Send DTMF digits | `-dtmf=1234` |
| `-dtmf_delay` | Delay before DTMF | `-dtmf_delay=2s` |
| `-duration` | Call duration | `-duration=10s` |

#### Troubleshooting gophone

1. **"Connection refused"** - Server not running or wrong port
2. **"No route to host"** - Check firewall, try `127.0.0.1` instead of `localhost`
3. **No audio** - gophone supports PCMU/PCMA codecs, verify SDP negotiation

## Testing Media Handlers

### Creating Test Media Handlers

```elixir
defmodule TestMediaHandler do
  use Parrot.MediaHandler

  @impl true
  def init(config) do
    {:ok, %{config: config, events: []}}
  end

  @impl true
  def handle_audio(audio_data, format, state) do
    # Store or process audio for testing
    {:ok, %{state | events: [{:audio, byte_size(audio_data)} | state.events]}}
  end

  @impl true
  def handle_dtmf(digit, state) do
    {:ok, %{state | events: [{:dtmf, digit} | state.events]}}
  end
end
```

### Testing RTP Streams

Use the provided test scripts:

```bash
# Generate test audio
./scripts/generate_test_audio.sh

# Test RTP streaming
mix run scripts/test_rtp_flow.exs

# Debug RTP packets
mix run scripts/debug_rtp_stream.exs
```

## Troubleshooting Test Failures

### Common Issues

1. **Port Already in Use**
   ```bash
   # Find process using port 5060
   lsof -i :5060
   # Kill the process if needed
   kill -9 <PID>
   ```

2. **SIPp Test Timeouts**
   - Check firewall settings
   - Verify localhost resolves correctly
   - Increase timeout in test configuration

3. **RTP Media Issues**
   - Verify audio files are in correct format (8kHz, mono)
   - Check RTP port range is available (10000-20000)
   - Enable RTP packet logging for debugging

### Debugging Tips

1. **Enable Verbose Logging**
   ```elixir
   # In config/test.exs
   config :logger, level: :debug
   ```

2. **Capture SIP Traffic**
   ```bash
   # Using tcpdump
   sudo tcpdump -i any -w sip_capture.pcap port 5060
   
   # Using ngrep
   sudo ngrep -d any -W byline port 5060
   ```

3. **Inspect State Machines**
   ```elixir
   # Get transaction state
   {:ok, state} = Parrot.Sip.Transaction.get_state(transaction_pid)
   
   # Get dialog state
   {:ok, dialog} = Parrot.Sip.Dialog.get_state(dialog_id)
   ```

## Performance Testing

For load testing, use SIPp with higher call rates:

```bash
# 10 calls per second, maximum 100 concurrent
sipp -sf scenarios/uac_invite.xml -r 10 -l 100 -m 1000 localhost:5060
```

Monitor performance metrics:
- Memory usage: `:erlang.memory()`
- Process count: `length(:erlang.processes())`
- Message queue lengths

## Writing Your Own Tests

### Testing SIP Handlers

```elixir
defmodule YourApp.SipHandlerTest do
  use ExUnit.Case
  alias Parrot.Sip.Message

  test "handles INVITE request" do
    handler = YourApp.SipHandler
    invite = Message.build_request("INVITE", "sip:user@example.com")
    
    assert {:ok, response} = handler.handle_request(invite, %{})
    assert response.status == 200
  end
end
```

### Testing Media Processing

```elixir
defmodule YourApp.MediaTest do
  use ExUnit.Case

  test "processes G.711 audio" do
    audio_data = File.read!("test/fixtures/sample.pcmu")
    format = %{encoding: :pcmu, sample_rate: 8000}
    
    {:ok, processed} = YourApp.MediaProcessor.process(audio_data, format)
    assert byte_size(processed) == byte_size(audio_data)
  end
end
```

## Continuous Integration

Example GitHub Actions workflow:

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.15'
          otp-version: '26.0'
      - run: mix deps.get
      - run: mix test
      - run: mix format --check-formatted
```