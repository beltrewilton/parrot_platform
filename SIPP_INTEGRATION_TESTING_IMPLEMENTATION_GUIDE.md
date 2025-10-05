# SIPp Integration Testing Implementation Guide

**CRITICAL**: This document provides a complete, production-ready implementation plan for SIPp-based integration testing of the Parrot Platform. Follow this guide exactly to create a professional-grade testing infrastructure.

---

## Overview

Create a comprehensive SIPp integration testing framework at `test/sipp/` in the Parrot Platform umbrella project to validate ParrotTransport and ParrotSip against real-world SIP scenarios. This is **NOT** a proof-of-concept - this is a **production-grade integration testing infrastructure** that will be used to verify RFC compliance, stress test the platform, and catch regressions.

---

## Project Context

### Parrot Platform Architecture

**Umbrella Project Structure:**
```
parrot_platform/
├── apps/
│   ├── parrot_transport/    # Protocol-agnostic transport layer
│   ├── parrot_sip/          # SIP protocol implementation (RFC 3261)
│   └── parrot_media/        # Media handling (RTP, codecs)
├── test/                    # Umbrella-level tests
│   └── sipp/               # SIPp integration tests (EXISTING)
├── examples/                # Example applications
├── mix.exs                  # Umbrella project config
└── README.md
```

**ParrotTransport** (apps/parrot_transport):
- Protocol-agnostic transport layer (bottom of the stack)
- Supports UDP, TCP, TLS, and WebSocket
- Delivers raw binary packets via `IncomingPacket` struct
- Public API: `ParrotTransport.start_listener/1`, `ParrotTransport.start_tcp_listener/2`, etc.
- Content-Length framing for stream-based transports (TCP, TLS, WebSocket)
- Current status: 108 tests passing, production-ready

**ParrotSip** (apps/parrot_sip):
- Full RFC 3261 compliant SIP implementation
- Transaction layer (INVITE, non-INVITE, CANCEL handling)
- Dialog management with gen_statem
- UAC (User Agent Client) and UAS (User Agent Server) modules
- Handler behavior with method-specific callbacks:
  - `handle_invite/3`, `handle_bye/3`, `handle_cancel/3`, `handle_ack/3`, etc.
  - Transaction state callbacks: `handle_transaction_trying/3`, `handle_transaction_proceeding/3`, etc.
  - Dialog state callbacks: `handle_dialog_early/3`, `handle_dialog_confirmed/3`, etc.
- **CRITICAL**: `handle_ack/3` callback to handle ACK completion of INVITE transaction
- Required callbacks: `transp_request/2`, `transaction/3`, `transaction_stop/3`, `uas_request/3`, `uas_cancel/2`, `process_ack/2`
- Public API: `ParrotSip.send_request/2`, `ParrotSip.send_response/2`
- Current status: 47 tests passing (1 skipped), production-ready

**Key Integration Points:**
- ParrotSip uses ParrotTransport via `ParrotSip.TransportHandler`
- Handlers receive `{:incoming_packet, %IncomingPacket{}}` messages
- All transports deliver packets in consistent format
- SIP messages are Content-Length framed on stream transports

---

## Existing SIPp Infrastructure

**IMPORTANT**: There is already a basic SIPp testing setup at `test/sipp/`:

```
test/sipp/
├── scenarios/
│   ├── basic/
│   │   ├── uac_invite.xml
│   │   ├── uac_invite_long.xml
│   │   ├── uac_invite_pcma.xml
│   │   ├── uac_options.xml
│   │   └── uas_invite.xml
│   └── advanced/
├── pcap/                    # PCAP reference files
├── logs/                    # Generated logs (gitignored)
└── test_scenarios.exs       # ExUnit test runner
```

**Current test_scenarios.exs pattern:**
- Uses ExUnit with `@moduletag :sipp`
- Defines test handler module inline (SippTestHandler)
- Uses `setup_all` to start Parrot application and transport
- Each test calls `run_sipp/2` helper function
- `run_sipp/2` uses `System.cmd/3` to execute SIPp with proper arguments
- Logs saved to `test/sipp/logs/` with timestamps
- All SIPp orchestration is **pure Elixir** - NO bash scripts

**.gitignore already configured:**
```
test/sipp/logs/*
!test/sipp/logs/.gitkeep
```

---

## Testing Goals

### Primary Objectives

1. **RFC 3261 Compliance Verification**
   - Validate SIP transaction state machines against RFC requirements
   - Test INVITE, CANCEL, BYE, OPTIONS, REGISTER flows
   - Verify Via, Route, Record-Route header handling
   - Validate response code handling (1xx, 2xx, 3xx, 4xx, 5xx, 6xx)

2. **Transport Layer Validation**
   - Test UDP, TCP, TLS, and WebSocket transports
   - Verify Content-Length framing on stream transports
   - Test message fragmentation and reassembly
   - Validate concurrent connection handling

3. **Real-World Scenario Testing**
   - Basic call flows (INVITE → 180 → 200 → ACK → BYE)
   - Call forwarding (302 Moved Temporarily)
   - Authentication challenges (401/407 with digest auth)
   - Early media (183 Session Progress)
   - Forking scenarios (multiple 18x responses)
   - Re-INVITE (call hold/resume, codec changes)
   - CANCEL during call setup
   - Network failures and retransmissions
   - Out-of-order message handling

4. **Stress and Load Testing**
   - Concurrent call handling (100s of simultaneous dialogs)
   - Call rate testing (calls per second)
   - Long-running stability tests (hours/days)
   - Memory leak detection
   - Connection pool exhaustion

5. **Regression Prevention**
   - Automated testing in CI/CD pipeline
   - Quick feedback on breaking changes
   - Historical performance tracking

---

## Implementation Requirements

### Directory Structure

**EXPAND the existing `test/sipp/` structure:**

```
test/sipp/
├── scenarios/
│   ├── basic/                      # EXISTING - basic scenarios
│   │   ├── uac_invite.xml
│   │   ├── uac_invite_long.xml
│   │   ├── uac_invite_pcma.xml
│   │   ├── uac_options.xml
│   │   └── uas_invite.xml
│   ├── advanced/                   # EXISTING - advanced scenarios
│   ├── cancel/                     # NEW - CANCEL scenarios
│   │   ├── uac_cancel_early.xml
│   │   ├── uac_cancel_proceeding.xml
│   │   └── uas_handle_cancel.xml
│   ├── auth/                       # NEW - Authentication scenarios
│   │   ├── uac_register_auth.xml
│   │   └── uac_invite_auth.xml
│   ├── re_invite/                  # NEW - Re-INVITE scenarios
│   │   ├── uac_hold_resume.xml
│   │   └── uac_codec_change.xml
│   ├── redirect/                   # NEW - Redirect scenarios
│   │   └── uas_302_redirect.xml
│   ├── early_media/                # NEW - Early media scenarios
│   │   └── uas_183_progress.xml
│   ├── tcp/                        # NEW - TCP transport scenarios
│   │   ├── uac_invite_tcp.xml
│   │   └── uac_invite_tcp_long.xml
│   ├── tls/                        # NEW - TLS transport scenarios
│   │   └── uac_invite_tls.xml
│   ├── websocket/                  # NEW - WebSocket scenarios (future)
│   │   └── uac_invite_ws.xml
│   └── stress/                     # NEW - Stress test scenarios
│       ├── concurrent_calls.xml
│       └── high_rate.xml
├── pcap/                           # EXISTING - PCAP reference files
├── logs/                           # EXISTING - Generated logs (gitignored)
├── fixtures/                       # NEW - Test fixtures
│   ├── certs/                      # TLS certificates
│   │   ├── ca-cert.pem
│   │   ├── server-cert.pem
│   │   ├── server-key.pem
│   │   ├── client-cert.pem
│   │   └── client-key.pem
│   └── sdp/                        # SDP templates
│       ├── pcma.sdp
│       ├── opus.sdp
│       └── multi_codec.sdp
├── support/                        # NEW - Test support modules
│   ├── sipp_runner.ex              # SIPp execution helper
│   ├── test_handler.ex             # Reusable test handler
│   └── transport_helper.ex         # Transport start/stop helpers
├── test_scenarios.exs              # EXISTING - Update/expand
├── test_cancel.exs                 # NEW - CANCEL tests
├── test_auth.exs                   # NEW - Authentication tests
├── test_re_invite.exs              # NEW - Re-INVITE tests
├── test_transports.exs             # NEW - Multi-transport tests
├── test_stress.exs                 # NEW - Stress tests
└── README.md                       # NEW - Documentation
```

---

## Detailed Implementation Steps

### Phase 1: Setup and Infrastructure

#### 1.1 Create Directory Structure

```bash
cd parrot_platform/test/sipp

# Create new scenario directories
mkdir -p scenarios/{cancel,auth,re_invite,redirect,early_media,tcp,tls,websocket,stress}

# Create support modules
mkdir -p support

# Create fixtures
mkdir -p fixtures/{certs,sdp}
```

#### 1.2 Generate TLS Certificates

Create `test/sipp/fixtures/certs/generate_certs.sh`:

```bash
#!/bin/bash
set -e

CERT_DIR="$(dirname "$0")"

echo "Generating TLS certificates for SIPp testing..."

# Generate CA certificate
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/ca-key.pem" \
  -out "$CERT_DIR/ca-cert.pem" \
  -days 3650 \
  -subj "/C=US/ST=Test/L=Test/O=ParrotPlatform/CN=ParrotCA"

# Generate server certificate
openssl req -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/server-key.pem" \
  -out "$CERT_DIR/server-req.pem" \
  -subj "/C=US/ST=Test/L=Test/O=ParrotPlatform/CN=localhost"

openssl x509 -req -in "$CERT_DIR/server-req.pem" \
  -CA "$CERT_DIR/ca-cert.pem" \
  -CAkey "$CERT_DIR/ca-key.pem" \
  -CAcreateserial \
  -out "$CERT_DIR/server-cert.pem" \
  -days 3650

# Generate client certificate
openssl req -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/client-key.pem" \
  -out "$CERT_DIR/client-req.pem" \
  -subj "/C=US/ST=Test/L=Test/O=ParrotPlatform/CN=sipp-client"

openssl x509 -req -in "$CERT_DIR/client-req.pem" \
  -CA "$CERT_DIR/ca-cert.pem" \
  -CAkey "$CERT_DIR/ca-key.pem" \
  -CAcreateserial \
  -out "$CERT_DIR/client-cert.pem" \
  -days 3650

echo "TLS certificates generated in $CERT_DIR"
```

Run it:
```bash
chmod +x test/sipp/fixtures/certs/generate_certs.sh
./test/sipp/fixtures/certs/generate_certs.sh
```

Update `.gitignore`:
```
# Add to existing .gitignore
test/sipp/fixtures/certs/*.pem
test/sipp/fixtures/certs/*.srl
```

---

### Phase 2: Support Modules

#### 2.1 SIPp Runner Helper

Create `test/sipp/support/sipp_runner.ex`:

```elixir
defmodule SippTest.SippRunner do
  @moduledoc """
  Helper module for running SIPp scenarios from ExUnit tests.

  Provides a clean Elixir API for executing SIPp with proper
  logging, error handling, and result parsing.
  """

  require Logger

  @logs_path Path.expand("../logs", __DIR__)

  @doc """
  Run a SIPp scenario file.

  ## Options

  - `:scenario_file` - Path to SIPp XML scenario (required)
  - `:remote_host` - Target SIP server (default: "127.0.0.1:5060")
  - `:local_port` - SIPp local port (default: 5080)
  - `:transport` - Transport protocol: :udp, :tcp, :tls, :ws (default: :udp)
  - `:calls` - Number of calls (default: 1)
  - `:rate` - Call rate in CPS (default: 1)
  - `:duration` - Max test duration in seconds (default: 30)
  - `:timeout` - Timeout for each call (default: 20)
  - `:extra_args` - Additional SIPp arguments (list)

  ## Returns

  - `:ok` if SIPp exits with status 0
  - `{:error, status}` if SIPp fails
  - `{:error, :not_installed}` if SIPp is not found
  """
  def run_scenario(opts \\ []) do
    scenario_file = Keyword.fetch!(opts, :scenario_file)
    remote_host = Keyword.get(opts, :remote_host, "127.0.0.1:5060")
    local_port = Keyword.get(opts, :local_port, 5080)
    transport = Keyword.get(opts, :transport, :udp)
    calls = Keyword.get(opts, :calls, 1)
    rate = Keyword.get(opts, :rate, 1)
    duration = Keyword.get(opts, :duration, 30)
    timeout = Keyword.get(opts, :timeout, 20)
    extra_args = Keyword.get(opts, :extra_args, [])

    unless File.exists?(scenario_file) do
      raise "Scenario file not found: #{scenario_file}"
    end

    case System.find_executable("sipp") do
      nil ->
        Logger.error("SIPp is not installed. Please install SIPp first.")
        {:error, :not_installed}

      sipp_path ->
        run_sipp(sipp_path, scenario_file, remote_host, local_port, transport, calls, rate, duration, timeout, extra_args)
    end
  end

  defp run_sipp(sipp_path, scenario_file, remote_host, local_port, transport, calls, rate, duration, timeout, extra_args) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    scenario_name = Path.basename(scenario_file, ".xml")

    File.mkdir_p!(@logs_path)

    # Build SIPp arguments
    args = [
      "-sf", scenario_file,
      "-m", to_string(calls),
      "-r", to_string(rate),
      "-l", to_string(calls),
      "-d", to_string(duration * 1000),  # SIPp expects milliseconds
      "-timeout", to_string(timeout),
      "-timeout_error",
      "-trace_err",
      "-trace_msg",
      "-trace_logs",
      "-p", to_string(local_port),
      "-error_file", Path.join(@logs_path, "#{scenario_name}_#{timestamp}_errors.log"),
      "-message_file", Path.join(@logs_path, "#{scenario_name}_#{timestamp}_messages.log"),
      "-log_file", Path.join(@logs_path, "#{scenario_name}_#{timestamp}.log")
    ]

    # Add transport flag
    transport_flag = transport_to_flag(transport)
    args = args ++ transport_flag

    # Add TLS certificate arguments if needed
    args = if transport == :tls do
      certs_path = Path.expand("../fixtures/certs", __DIR__)
      args ++ [
        "-tls_cert", Path.join(certs_path, "client-cert.pem"),
        "-tls_key", Path.join(certs_path, "client-key.pem")
      ]
    else
      args
    end

    # Add extra arguments
    args = args ++ extra_args

    # Add remote host
    args = args ++ [remote_host]

    Logger.info("Running SIPp scenario: #{scenario_name}")
    Logger.debug("SIPp command: #{sipp_path} #{Enum.join(args, " ")}")

    # Execute SIPp
    {output, status} = System.cmd(sipp_path, args, stderr_to_stdout: true)

    if status == 0 do
      Logger.info("SIPp scenario passed: #{scenario_name}")
      :ok
    else
      Logger.error("SIPp scenario failed: #{scenario_name} (status: #{status})")
      Logger.error("SIPp output:\n#{output}")
      {:error, status}
    end
  end

  defp transport_to_flag(:udp), do: ["-t", "un"]
  defp transport_to_flag(:tcp), do: ["-t", "tn"]
  defp transport_to_flag(:tls), do: ["-t", "l"]
  defp transport_to_flag(:ws), do: ["-t", "ws"]
end
```

#### 2.2 Reusable Test Handler

Create `test/sipp/support/test_handler.ex`:

```elixir
defmodule SippTest.TestHandler do
  @moduledoc """
  Configurable test handler for SIPp integration tests.

  This handler can be configured to respond with different
  behaviors for testing various SIP scenarios.
  """

  @behaviour ParrotSip.Handler

  require Logger

  defstruct [
    :response_code,
    :auth_required,
    :early_media,
    :redirect_to,
    :delay_ms,
    stats: %{
      invites: 0,
      acks: 0,
      byes: 0,
      cancels: 0,
      options: 0
    }
  ]

  # ParrotSip.Handler required callbacks

  @impl true
  def transp_request(_msg, state), do: {:process_transaction, state}

  @impl true
  def transaction(_trans, _sip_msg, state), do: {:process_uas, state}

  @impl true
  def transaction_stop(_trans, _result, state), do: {:ok, state}

  @impl true
  def uas_request(uas, request, state) do
    # Generic fallback - will be overridden by method-specific callbacks
    Logger.debug("UAS request: #{request.method}")
    {:ok, state}
  end

  @impl true
  def uas_cancel(_uas_id, state) do
    new_state = update_in(state.stats.cancels, &(&1 + 1))
    {:ok, new_state}
  end

  @impl true
  def process_ack(_sip_msg, state) do
    new_state = update_in(state.stats.acks, &(&1 + 1))
    Logger.debug("ACK received (total: #{new_state.stats.acks})")
    {:ok, new_state}
  end

  # Method-specific callbacks (optional)

  def handle_invite(uas, request, state) do
    Logger.info("INVITE received from #{inspect(request.uri)}")
    new_state = update_in(state.stats.invites, &(&1 + 1))

    # Send early media if configured
    if state.early_media do
      ParrotSip.UAS.respond(uas, 183, "Session Progress", %{}, build_sdp())
      Process.sleep(100)
    end

    # Delay if configured
    if state.delay_ms && state.delay_ms > 0 do
      Process.sleep(state.delay_ms)
    end

    # Send final response
    response_code = state.response_code || 200
    ParrotSip.UAS.respond(uas, response_code, "OK", %{}, build_sdp())

    {:ok, new_state}
  end

  def handle_ack(_uas, request, state) do
    Logger.debug("ACK received via handle_ack/3")
    new_state = update_in(state.stats.acks, &(&1 + 1))
    {:ok, new_state}
  end

  def handle_bye(uas, _request, state) do
    Logger.info("BYE received")
    new_state = update_in(state.stats.byes, &(&1 + 1))

    ParrotSip.UAS.respond(uas, 200, "OK", %{}, "")

    {:ok, new_state}
  end

  def handle_cancel(uas, _request, state) do
    Logger.info("CANCEL received")
    new_state = update_in(state.stats.cancels, &(&1 + 1))

    ParrotSip.UAS.respond(uas, 200, "OK", %{}, "")

    {:ok, new_state}
  end

  def handle_options(uas, _request, state) do
    Logger.debug("OPTIONS received")
    new_state = update_in(state.stats.options, &(&1 + 1))

    ParrotSip.UAS.respond(uas, 200, "OK", %{}, "")

    {:ok, new_state}
  end

  # Helper functions

  defp build_sdp do
    """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio 4000 RTP/AVP 0 8 111
    a=rtpmap:0 PCMU/8000
    a=rtpmap:8 PCMA/8000
    a=rtpmap:111 OPUS/48000/2
    """
  end

  @doc """
  Create a new test handler with default configuration.
  """
  def new(opts \\ []) do
    %__MODULE__{
      response_code: Keyword.get(opts, :response_code, 200),
      auth_required: Keyword.get(opts, :auth_required, false),
      early_media: Keyword.get(opts, :early_media, false),
      redirect_to: Keyword.get(opts, :redirect_to),
      delay_ms: Keyword.get(opts, :delay_ms, 0)
    }
  end

  @doc """
  Get statistics from the handler.
  """
  def get_stats(%__MODULE__{stats: stats}), do: stats
end
```

#### 2.3 Transport Helper

Create `test/sipp/support/transport_helper.ex`:

```elixir
defmodule SippTest.TransportHelper do
  @moduledoc """
  Helper functions for starting and stopping transports in tests.
  """

  require Logger

  alias ParrotTransport.Types.ListenerConfig

  @doc """
  Start a listener for the given transport.

  ## Options

  - `:transport` - Transport type (:udp, :tcp, :tls, :websocket)
  - `:port` - Port to listen on (default: 5060)
  - `:handler` - Handler PID (required for TCP/TLS/WebSocket)
  - `:certfile` - Path to certificate (required for TLS)
  - `:keyfile` - Path to private key (required for TLS)
  """
  def start_listener(opts \\ []) do
    transport = Keyword.fetch!(opts, :transport)
    port = Keyword.get(opts, :port, 5060)
    handler = Keyword.get(opts, :handler)

    config = %ListenerConfig{
      transport: transport,
      port: port,
      certfile: Keyword.get(opts, :certfile),
      keyfile: Keyword.get(opts, :keyfile)
    }

    case transport do
      :udp ->
        {:ok, listener} = ParrotTransport.start_listener(config)
        if handler do
          :ok = ParrotTransport.register_handler(listener, handler)
        end
        {:ok, listener}

      :tcp ->
        unless handler, do: raise("Handler required for TCP transport")
        ParrotTransport.start_tcp_listener(config, handler)

      :tls ->
        unless handler, do: raise("Handler required for TLS transport")
        unless config.certfile, do: raise("certfile required for TLS transport")
        unless config.keyfile, do: raise("keyfile required for TLS transport")
        ParrotTransport.start_tls_listener(config, handler)

      :websocket ->
        unless handler, do: raise("Handler required for WebSocket transport")
        ParrotTransport.start_websocket_listener(config, handler)
    end
  end

  @doc """
  Stop a listener.
  """
  def stop_listener(listener) when is_pid(listener) do
    ParrotTransport.UdpListener.stop(listener)
  end

  @doc """
  Kill any process using the given port.
  """
  def kill_port(port) do
    case System.cmd("lsof", ["-ti:#{port}"], stderr_to_stdout: true) do
      {pids_str, 0} ->
        pids_str
        |> String.split("\n", trim: true)
        |> Enum.each(fn pid ->
          System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
          Logger.debug("Killed process #{pid} on port #{port}")
        end)

      _ ->
        :ok
    end
  end
end
```

---

### Phase 3: Test Files

#### 3.1 Update test_scenarios.exs

Update `test/sipp/test_scenarios.exs` to use new support modules:

```elixir
defmodule SippTest.BasicScenarios do
  use ExUnit.Case, async: false

  @moduletag :sipp
  @moduletag timeout: 60_000

  require Logger

  alias SippTest.{SippRunner, TestHandler, TransportHelper}

  @scenarios_path Path.expand("scenarios/basic", __DIR__)
  @sipp_port 5080
  @uas_port 5060

  setup_all do
    # Kill any stray SIPp processes
    System.cmd("pkill", ["-9", "sipp"], stderr_to_stdout: true)

    # Kill any process on UAS port
    TransportHelper.kill_port(@uas_port)

    # Ensure Parrot application is started
    {:ok, _} = Application.ensure_all_started(:parrot_platform)

    # Create test handler
    handler_state = TestHandler.new()

    # Create SIP handler
    test_log_level = Application.get_env(:parrot_platform, :test_log_level, :warning)
    test_sip_trace = Application.get_env(:parrot_platform, :test_sip_trace, false)

    sip_handler = ParrotSip.Handler.new(
      TestHandler,
      handler_state,
      log_level: test_log_level,
      sip_trace: test_sip_trace
    )

    # Start UDP transport
    opts = %{
      listen_port: @uas_port,
      handler: sip_handler
    }

    Logger.info("Starting UDP transport on port #{@uas_port}...")
    :ok = ParrotSip.Transport.StateMachine.start_udp(opts)

    on_exit(fn ->
      Logger.info("Stopping UDP transport...")
      ParrotSip.Transport.StateMachine.stop_udp()
    end)

    :ok
  end

  describe "Basic UAC Scenarios - UDP" do
    test "INVITE call flow" do
      scenario_file = Path.join(@scenarios_path, "uac_invite.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp,
        calls: 1,
        timeout: 20
      )
    end

    test "INVITE with longer duration" do
      scenario_file = Path.join(@scenarios_path, "uac_invite_long.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp,
        calls: 1,
        timeout: 30
      )
    end

    test "INVITE with PCMA codec" do
      scenario_file = Path.join(@scenarios_path, "uac_invite_pcma.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp,
        calls: 1
      )
    end

    test "OPTIONS ping" do
      scenario_file = Path.join(@scenarios_path, "uac_options.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp,
        calls: 1,
        timeout: 10
      )
    end
  end
end
```

#### 3.2 Create test_cancel.exs

Create `test/sipp/test_cancel.exs`:

```elixir
defmodule SippTest.CancelScenarios do
  use ExUnit.Case, async: false

  @moduletag :sipp
  @moduletag timeout: 60_000

  require Logger

  alias SippTest.{SippRunner, TestHandler, TransportHelper}

  @scenarios_path Path.expand("scenarios/cancel", __DIR__)
  @sipp_port 5080
  @uas_port 5060

  setup_all do
    # Setup similar to test_scenarios.exs
    # ... (same setup code)
    :ok
  end

  describe "CANCEL Scenarios" do
    test "CANCEL during early state" do
      scenario_file = Path.join(@scenarios_path, "uac_cancel_early.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp
      )
    end

    test "CANCEL during proceeding state" do
      scenario_file = Path.join(@scenarios_path, "uac_cancel_proceeding.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp
      )
    end
  end
end
```

#### 3.3 Create test_transports.exs

Create `test/sipp/test_transports.exs`:

```elixir
defmodule SippTest.TransportScenarios do
  use ExUnit.Case, async: false

  @moduletag :sipp
  @moduletag timeout: 60_000

  require Logger

  alias SippTest.{SippRunner, TestHandler, TransportHelper}

  @scenarios_path_tcp Path.expand("scenarios/tcp", __DIR__)
  @scenarios_path_tls Path.expand("scenarios/tls", __DIR__)
  @certs_path Path.expand("fixtures/certs", __DIR__)
  @sipp_port 5080
  @tcp_port 5061
  @tls_port 5062

  setup_all do
    {:ok, _} = Application.ensure_all_started(:parrot_platform)
    :ok
  end

  describe "TCP Transport" do
    setup do
      TransportHelper.kill_port(@tcp_port)

      handler_state = TestHandler.new()
      sip_handler = ParrotSip.Handler.new(TestHandler, handler_state)

      {:ok, listener} = TransportHelper.start_listener(
        transport: :tcp,
        port: @tcp_port,
        handler: sip_handler
      )

      on_exit(fn ->
        if Process.alive?(listener) do
          ParrotTransport.TcpListener.stop(listener)
        end
      end)

      :ok
    end

    test "INVITE over TCP" do
      scenario_file = Path.join(@scenarios_path_tcp, "uac_invite_tcp.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@tcp_port}",
        local_port: @sipp_port,
        transport: :tcp
      )
    end
  end

  describe "TLS Transport" do
    setup do
      TransportHelper.kill_port(@tls_port)

      handler_state = TestHandler.new()
      sip_handler = ParrotSip.Handler.new(TestHandler, handler_state)

      {:ok, listener} = TransportHelper.start_listener(
        transport: :tls,
        port: @tls_port,
        handler: sip_handler,
        certfile: Path.join(@certs_path, "server-cert.pem"),
        keyfile: Path.join(@certs_path, "server-key.pem")
      )

      on_exit(fn ->
        if Process.alive?(listener) do
          ParrotTransport.TlsListener.stop(listener)
        end
      end)

      :ok
    end

    test "INVITE over TLS" do
      scenario_file = Path.join(@scenarios_path_tls, "uac_invite_tls.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@tls_port}",
        local_port: @sipp_port,
        transport: :tls
      )
    end
  end
end
```

#### 3.4 Create test_stress.exs

Create `test/sipp/test_stress.exs`:

```elixir
defmodule SippTest.StressScenarios do
  use ExUnit.Case, async: false

  @moduletag :sipp
  @moduletag :stress
  @moduletag timeout: 300_000  # 5 minutes

  require Logger

  alias SippTest.{SippRunner, TestHandler, TransportHelper}

  @scenarios_path Path.expand("scenarios/stress", __DIR__)
  @sipp_port 5080
  @uas_port 5060

  setup_all do
    # Setup similar to test_scenarios.exs
    :ok
  end

  describe "Stress Tests" do
    @tag :slow
    test "100 concurrent calls" do
      scenario_file = Path.join(@scenarios_path, "concurrent_calls.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp,
        calls: 100,
        rate: 10,
        duration: 120
      )
    end

    @tag :slow
    test "High call rate - 50 CPS" do
      scenario_file = Path.join(@scenarios_path, "high_rate.xml")

      assert :ok = SippRunner.run_scenario(
        scenario_file: scenario_file,
        remote_host: "127.0.0.1:#{@uas_port}",
        local_port: @sipp_port,
        transport: :udp,
        calls: 500,
        rate: 50,
        duration: 60
      )
    end
  end
end
```

---

### Phase 4: SIPp Scenario Files

#### 4.1 CANCEL Scenarios

Create `test/sipp/scenarios/cancel/uac_cancel_early.xml`:

```xml
<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE scenario SYSTEM "sipp.dtd">

<!-- CANCEL during early state (before any provisional response) -->
<scenario name="UAC CANCEL Early">

  <!-- Send INVITE -->
  <send retrans="500">
    <![CDATA[
      INVITE sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
      From: sipp <sip:sipp@[local_ip]:[local_port]>;tag=[call_number]
      To: sut <sip:[service]@[remote_ip]:[remote_port]>
      Call-ID: [call_id]
      CSeq: 1 INVITE
      Contact: sip:sipp@[local_ip]:[local_port]
      Max-Forwards: 70
      Content-Type: application/sdp
      Content-Length: [len]

      v=0
      o=user1 53655765 2353687637 IN IP[local_ip_type] [local_ip]
      s=-
      c=IN IP[media_ip_type] [media_ip]
      t=0 0
      m=audio [media_port] RTP/AVP 0
      a=rtpmap:0 PCMU/8000
    ]]>
  </send>

  <!-- Wait a bit, then send CANCEL -->
  <pause milliseconds="100"/>

  <send>
    <![CDATA[
      CANCEL sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
      From: sipp <sip:sipp@[local_ip]:[local_port]>;tag=[call_number]
      To: sut <sip:[service]@[remote_ip]:[remote_port]>
      Call-ID: [call_id]
      CSeq: 1 CANCEL
      Max-Forwards: 70
      Content-Length: 0
    ]]>
  </send>

  <!-- Receive 200 OK for CANCEL -->
  <recv response="200" crlf="true"/>

  <!-- Receive 487 Request Terminated for INVITE -->
  <recv response="487" crlf="true"/>

  <!-- Send ACK for 487 -->
  <send>
    <![CDATA[
      ACK sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
      From: sipp <sip:sipp@[local_ip]:[local_port]>;tag=[call_number]
      To: sut <sip:[service]@[remote_ip]:[remote_port]>[peer_tag_param]
      Call-ID: [call_id]
      CSeq: 1 ACK
      Max-Forwards: 70
      Content-Length: 0
    ]]>
  </send>

</scenario>
```

Create similar files for other CANCEL scenarios...

#### 4.2 TCP Transport Scenario

Create `test/sipp/scenarios/tcp/uac_invite_tcp.xml`:

```xml
<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE scenario SYSTEM "sipp.dtd">

<!-- Basic INVITE over TCP -->
<scenario name="UAC INVITE TCP">

  <!-- Send INVITE -->
  <send retrans="500">
    <![CDATA[
      INVITE sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/TCP [local_ip]:[local_port];branch=[branch]
      From: sipp <sip:sipp@[local_ip]:[local_port]>;tag=[call_number]
      To: sut <sip:[service]@[remote_ip]:[remote_port]>
      Call-ID: [call_id]
      CSeq: 1 INVITE
      Contact: sip:sipp@[local_ip]:[local_port];transport=tcp
      Max-Forwards: 70
      Content-Type: application/sdp
      Content-Length: [len]

      v=0
      o=user1 53655765 2353687637 IN IP[local_ip_type] [local_ip]
      s=-
      c=IN IP[media_ip_type] [media_ip]
      t=0 0
      m=audio [media_port] RTP/AVP 0
      a=rtpmap:0 PCMU/8000
    ]]>
  </send>

  <!-- Receive 100 Trying (optional) -->
  <recv response="100" optional="true"/>

  <!-- Receive 180 Ringing (optional) -->
  <recv response="180" optional="true"/>

  <!-- Receive 200 OK -->
  <recv response="200" crlf="true"/>

  <!-- Send ACK -->
  <send>
    <![CDATA[
      ACK sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/TCP [local_ip]:[local_port];branch=[branch]
      From: sipp <sip:sipp@[local_ip]:[local_port]>;tag=[call_number]
      To: sut <sip:[service]@[remote_ip]:[remote_port]>[peer_tag_param]
      Call-ID: [call_id]
      CSeq: 1 ACK
      Contact: sip:sipp@[local_ip]:[local_port];transport=tcp
      Max-Forwards: 70
      Content-Length: 0
    ]]>
  </send>

  <!-- Pause for call duration -->
  <pause milliseconds="2000"/>

  <!-- Send BYE -->
  <send retrans="500">
    <![CDATA[
      BYE sip:[service]@[remote_ip]:[remote_port] SIP/2.0
      Via: SIP/2.0/TCP [local_ip]:[local_port];branch=[branch]
      From: sipp <sip:sipp@[local_ip]:[local_port]>;tag=[call_number]
      To: sut <sip:[service]@[remote_ip]:[remote_port]>[peer_tag_param]
      Call-ID: [call_id]
      CSeq: 2 BYE
      Contact: sip:sipp@[local_ip]:[local_port];transport=tcp
      Max-Forwards: 70
      Content-Length: 0
    ]]>
  </send>

  <!-- Receive 200 OK for BYE -->
  <recv response="200" crlf="true"/>

</scenario>
```

---

### Phase 5: Documentation

Create `test/sipp/README.md`:

```markdown
# SIPp Integration Tests

Comprehensive SIPp-based integration testing for Parrot Platform SIP stack.

## Overview

These tests validate ParrotTransport and ParrotSip against real-world SIP scenarios using SIPp (SIP performance testing tool).

## Prerequisites

**Install SIPp:**

```bash
# macOS
brew install sipp

# Linux
sudo apt-get install sipp
```

**Generate TLS certificates:**

```bash
cd test/sipp/fixtures/certs
./generate_certs.sh
```

## Running Tests

**All SIPp tests:**
```bash
mix test --only sipp
```

**Specific test file:**
```bash
mix test test/sipp/test_scenarios.exs
mix test test/sipp/test_cancel.exs
mix test test/sipp/test_transports.exs
```

**Exclude stress tests:**
```bash
mix test --only sipp --exclude stress
```

**Only stress tests:**
```bash
mix test --only sipp --only stress
```

**Single test:**
```bash
mix test test/sipp/test_scenarios.exs:107
```

## Test Structure

```
test/sipp/
├── scenarios/          # SIPp XML scenario files
│   ├── basic/          # Basic call flows
│   ├── cancel/         # CANCEL scenarios
│   ├── auth/           # Authentication
│   ├── tcp/            # TCP transport
│   ├── tls/            # TLS transport
│   └── stress/         # Load tests
├── support/            # Test helper modules
│   ├── sipp_runner.ex      # SIPp execution
│   ├── test_handler.ex     # Reusable handler
│   └── transport_helper.ex # Transport helpers
├── fixtures/           # Test data
│   ├── certs/          # TLS certificates
│   └── sdp/            # SDP templates
├── logs/               # Test logs (gitignored)
├── test_scenarios.exs  # Basic scenarios
├── test_cancel.exs     # CANCEL tests
├── test_transports.exs # Multi-transport tests
└── test_stress.exs     # Stress tests
```

## Test Organization

### Basic Scenarios (`test_scenarios.exs`)
- Basic INVITE call flows
- OPTIONS ping
- Different codec scenarios

### CANCEL Scenarios (`test_cancel.exs`)
- CANCEL during early state
- CANCEL during proceeding state
- UAS CANCEL handling

### Transport Scenarios (`test_transports.exs`)
- UDP (default)
- TCP with Content-Length framing
- TLS with SSL certificates
- WebSocket (future)

### Stress Tests (`test_stress.exs`)
- 100+ concurrent calls
- High call rates (50+ CPS)
- Long-running stability tests

## Writing New Tests

1. **Create scenario XML** in appropriate subdirectory
2. **Add test case** using `SippRunner.run_scenario/1`:

```elixir
test "my new scenario" do
  scenario_file = Path.join(@scenarios_path, "my_scenario.xml")

  assert :ok = SippRunner.run_scenario(
    scenario_file: scenario_file,
    remote_host: "127.0.0.1:5060",
    local_port: 5080,
    transport: :udp,
    calls: 10,
    rate: 5
  )
end
```

3. **Run and verify** the test passes

## Debugging

**Check logs:**
```bash
ls -la test/sipp/logs/
```

**View SIPp messages:**
```bash
tail -f test/sipp/logs/*_messages.log
```

**View SIPp errors:**
```bash
tail -f test/sipp/logs/*_errors.log
```

**Increase logging:**
```elixir
# In config/test.exs
config :parrot_platform,
  test_log_level: :debug,
  test_sip_trace: true
```

## CI/CD

Tests run automatically on:
- Push to main/develop
- Pull requests
- Nightly builds

See `.github/workflows/ci.yml`

## Performance Benchmarks

Target metrics:
- Call setup latency: < 50ms (p95)
- Concurrent calls: > 1000
- Call rate: > 100 CPS
- Memory: < 100MB for 1000 calls

## Troubleshooting

**SIPp not found:**
```bash
which sipp
# If empty, install SIPp
```

**Port already in use:**
```bash
lsof -ti:5060 | xargs kill -9
```

**Test hangs:**
- Check SIPp logs for errors
- Verify handler is responding
- Check transport is running

**TLS tests fail:**
- Regenerate certificates
- Check certificate paths
- Verify server is using correct certs
```

---

## Success Criteria

### Must Have (MVP)
- ✅ SIPp installed and verified
- ✅ TLS certificates generated
- ✅ Support modules implemented (SippRunner, TestHandler, TransportHelper)
- ✅ At least 10 scenarios across basic, CANCEL, auth, transports
- ✅ All tests pass on UDP, TCP, TLS
- ✅ ExUnit integration complete
- ✅ Pure Elixir orchestration (no bash scripts)
- ✅ Logs properly gitignored
- ✅ Documentation complete

### Should Have
- ✅ Stress test scenarios (100+ concurrent calls)
- ✅ Re-INVITE scenarios
- ✅ Redirect scenarios
- ✅ Early media scenarios
- ✅ Performance benchmarks documented

### Nice to Have
- WebSocket transport scenarios
- B2BUA test scenarios
- PCAP file generation/comparison
- Performance regression tracking
- Visual test reports

---

## Key Differences from Original Guide

### ✅ Fixed Issues:

1. **Pure Elixir Orchestration**
   - NO bash scripts for running tests
   - All test execution via ExUnit and `System.cmd/3`
   - `SippRunner` module provides clean Elixir API

2. **Existing Infrastructure**
   - Expanded existing `test/sipp/` structure
   - Kept existing scenario organization
   - Enhanced existing patterns

3. **Handler Implementation**
   - Added `handle_ack/3` callback (CRITICAL)
   - Proper `process_ack/2` implementation
   - All required ParrotSip.Handler callbacks

4. **Logs and Git**
   - Logs already gitignored properly
   - No screenshots directory
   - Clean separation of fixtures and logs

5. **ExUnit Output**
   - All tests run through ExUnit
   - Standard test output format
   - Tags for selective running (`:sipp`, `:stress`, `:slow`)

---

## Implementation Timeline

**Phase 1 (Day 1)**: Infrastructure
- Create directory structure
- Generate TLS certificates
- Create support modules

**Phase 2 (Day 2-3)**: Support Modules
- Implement SippRunner
- Implement TestHandler with all callbacks
- Implement TransportHelper

**Phase 3 (Day 4-5)**: Test Files
- Update test_scenarios.exs
- Create test_cancel.exs
- Create test_transports.exs
- Create test_stress.exs

**Phase 4 (Day 5-6)**: Scenarios
- Create CANCEL scenarios
- Create TCP scenarios
- Create TLS scenarios
- Create stress scenarios

**Phase 5 (Day 7)**: Documentation
- Write README.md
- Document patterns
- Add troubleshooting guide

**Phase 6 (Day 8)**: Polish
- Run all tests
- Fix any failures
- Performance tuning
- Final review

---

## Final Notes

**CRITICAL REMINDERS:**

1. This is **NOT** a prototype - build it production-ready
2. **ALL orchestration is pure Elixir** - no bash scripts
3. Use existing `test/sipp/` structure and patterns
4. **Include `handle_ack/3`** in test handlers
5. All logs are gitignored
6. Tests output via ExUnit (standard format)
7. Use small, focused commits
8. Follow existing code patterns
9. Test thoroughly at each step
10. Document as you go

**This is a professional integration testing framework. Build it right.** 🚀
