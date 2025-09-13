# Umbrella Application Migration Plan

## Overview
Migrate Parrot Platform from monolithic structure to umbrella application with three core apps:
- `apps/parrot_transport` - Network I/O layer
- `apps/parrot_sip` - SIP protocol implementation  
- `apps/parrot_media` - RTP and media handling

## Migration Strategy
**Parallel Development**: Keep existing `lib/` structure intact while building new `apps/` structure.

## Phase 1: Convert to Umbrella Project

### Commands to Execute
```bash
# Backup current mix.exs
cp mix.exs mix.exs.monolithic

# Create apps directory
mkdir apps

# Create new umbrella mix.exs
```

### New Root mix.exs
```elixir
# mix.exs (at root)
defmodule ParrotPlatform.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.0.1-alpha.4",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: preferred_cli_env()
    ]
  end

  defp deps do
    [
      # Umbrella-wide deps only (like ex_doc)
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["test"],
      "test.sipp": &run_sipp_tests/1,
      "test.all": &run_all_tests/1
    ]
  end

  defp preferred_cli_env do
    [
      "test.sipp": :test,
      "test.all": :test
    ]
  end

  # Keep existing sipp test functions
  defp run_sipp_tests(args), do: # ... existing code
  defp run_all_tests(args), do: # ... existing code
end
```

## Phase 2: Create Transport App

### Commands
```bash
cd apps
mix new parrot_transport --sup
cd parrot_transport
```

### Unit Testing Requirements for Transport App
```bash
# Create comprehensive test structure
mkdir -p test/parrot_transport/{udp,tcp,tls,connection}

# Required test coverage:
# 1. UDP transport tests (test/parrot_transport/udp_test.exs)
#    - Socket creation and binding
#    - Packet reception and routing
#    - Send functionality
#    - Error handling (socket errors, invalid destinations)
#    - Port conflict resolution

# 2. Connection state machine tests (test/parrot_transport/connection_test.exs)
#    - State transitions
#    - Reconnection logic
#    - Timeout handling
#    - Backpressure management

# 3. Handler registration tests (test/parrot_transport/registry_test.exs)
#    - Handler registration/deregistration
#    - Multiple handlers per port
#    - Handler crash recovery
#    - Message routing accuracy

# 4. Source management tests (test/parrot_transport/source_test.exs)
#    - Source address tracking
#    - Source timeout/cleanup
#    - NAT traversal considerations

# Example test structure:
```

```elixir
# test/parrot_transport/udp_test.exs
defmodule ParrotTransport.UdpTest do
  use ExUnit.Case, async: true
  
  describe "UDP listener" do
    test "starts and binds to specified port" do
      {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15060)
      assert Process.alive?(transport)
      # Verify port is actually bound
    end
    
    test "routes packets to registered handlers" do
      {:ok, transport} = ParrotTransport.start_listener(:udp, port: 15061)
      test_pid = self()
      
      ParrotTransport.register_handler(transport, test_pid)
      
      # Send test packet
      {:ok, socket} = :gen_udp.open(0)
      :gen_udp.send(socket, {127, 0, 0, 1}, 15061, "test data")
      
      assert_receive {:packet_received, "test data", _, _}, 1000
    end
    
    test "handles multiple simultaneous connections" do
      # Test concurrent packet handling
    end
    
    test "recovers from handler crashes" do
      # Test supervisor restart strategy
    end
  end
end
```

### Update apps/parrot_transport/mix.exs
```elixir
defmodule ParrotTransport.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_transport,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ParrotTransport.Application, []}
    ]
  end

  defp deps do
    [
      # No deps on other parrot apps!
      # Transport is the bottom layer
    ]
  end
end
```

### Files to Copy and Modify
```bash
# From lib/parrot/sip/transport/ to apps/parrot_transport/lib/parrot_transport/

cp lib/parrot/sip/transport/transport_udp.ex apps/parrot_transport/lib/parrot_transport/udp.ex
cp lib/parrot/sip/transport/state_machine.ex apps/parrot_transport/lib/parrot_transport/connection.ex
cp lib/parrot/sip/transport/source.ex apps/parrot_transport/lib/parrot_transport/source.ex
cp lib/parrot/sip/transport/supervisor.ex apps/parrot_transport/lib/parrot_transport/supervisor.ex
```

### Critical Changes for Transport Independence

#### Remove ALL SIP Knowledge
```elixir
# OLD - apps/parrot_transport/lib/parrot_transport/udp.ex
def handle_info({:udp, socket, ip, port, data}, state) do
  message = Parrot.Sip.Parser.parse(data)  # ❌ NO! Transport doesn't know SIP
  
# NEW
def handle_info({:udp, socket, ip, port, data}, state) do
  # Just route raw data based on port or configuration
  destination = lookup_handler(port, state.handlers)
  send(destination, {:packet_received, data, {ip, port}, transport_metadata()})
```

#### Change Registration Pattern
```elixir
# OLD
def start_link(opts) do
  GenServer.start_link(__MODULE__, opts, name: Parrot.Sip.Transport)

# NEW  
def start_link(opts) do
  name = Keyword.get(opts, :name, {:via, Registry, {Parrot.Registry, {:transport, opts[:port]}}})
  GenServer.start_link(__MODULE__, opts, name: name)
end
```

#### New Transport API
```elixir
# apps/parrot_transport/lib/parrot_transport.ex
defmodule ParrotTransport do
  @moduledoc """
  Transport layer with no protocol knowledge
  """

  def start_listener(type, opts) do
    # Start UDP/TCP/TLS listener
    # Returns {:ok, transport_ref}
  end

  def register_handler(transport_ref, handler_pid, opts \\ []) do
    # Register a process to receive packets
    # handler_pid will receive: {:packet_received, data, source, metadata}
  end

  def send_packet(transport_ref, data, destination) do
    # Send raw data - no protocol knowledge
    GenServer.cast(transport_ref, {:send_packet, data, destination})
  end
end
```

## Phase 3: Create Media App

### Commands
```bash
cd apps
mix new parrot_media --sup
cd parrot_media
```

### Unit Testing Requirements for Media App
```bash
# Create comprehensive test structure
mkdir -p test/parrot_media/{rtp,codecs,pipelines,sdp}

# Required test coverage:
# 1. RTP packet handling tests (test/parrot_media/rtp_test.exs)
#    - Packet parsing and serialization
#    - Sequence number management
#    - SSRC handling
#    - Timestamp calculations
#    - Payload type mapping

# 2. SDP tests (test/parrot_media/sdp_test.exs)
#    - SDP parsing from various sources
#    - SDP generation for offers/answers
#    - Codec negotiation logic
#    - Media attribute handling
#    - ICE candidate parsing

# 3. Pipeline tests (test/parrot_media/pipelines/)
#    - OpusPipeline initialization and teardown
#    - AlawPipeline encoding/decoding
#    - PortAudioPipeline device handling
#    - Pipeline switching logic
#    - Error recovery in pipelines

# 4. MediaSession tests (test/parrot_media/media_session_test.exs)
#    - Session lifecycle management
#    - Message-driven control (play_files, stop, etc.)
#    - State transitions
#    - Resource cleanup on termination

# 5. MediaHandler behavior tests (test/parrot_media/media_handler_test.exs)
#    - Handler callback invocation
#    - State management in handlers
#    - Error handling in callbacks
#    - Message routing to handlers

# Example test structure:
```

```elixir
# test/parrot_media/rtp_test.exs
defmodule ParrotMedia.RtpTest do
  use ExUnit.Case, async: true
  
  describe "RTP packet handling" do
    test "parses RTP packets correctly" do
      # Create test RTP packet
      packet = <<0x80, 0x08, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 
                 0xDE, 0xF0, 0x12, 0x34, "payload"::binary>>
      
      {:ok, parsed} = ParrotMedia.Rtp.parse(packet)
      
      assert parsed.sequence_number == 0x1234
      assert parsed.timestamp == 0x56789ABC
      assert parsed.ssrc == 0xDEF01234
      assert parsed.payload == "payload"
    end
    
    test "builds RTP packets with correct headers" do
      packet = ParrotMedia.Rtp.build(%{
        payload_type: 8,
        sequence_number: 1000,
        timestamp: 160000,
        ssrc: 0x12345678,
        payload: "test_audio"
      })
      
      assert is_binary(packet)
      # Verify packet structure
    end
    
    test "handles packet reordering" do
      # Test jitter buffer functionality
    end
  end
end

# test/parrot_media/media_session_test.exs
defmodule ParrotMedia.MediaSessionTest do
  use ExUnit.Case, async: true
  
  describe "message-driven media control" do
    setup do
      {:ok, session} = ParrotMedia.MediaSession.start_link(
        id: "test_session",
        role: :uas,
        media_handler: TestMediaHandler,
        handler_args: %{}
      )
      
      %{session: session}
    end
    
    test "handles play_files message", %{session: session} do
      # Start media first
      ParrotMedia.MediaSession.start_media("test_session")
      
      # Send play command
      send(session, {:play_files, ["test.wav"], loop: false})
      
      # Verify handler receives appropriate callbacks
      assert_receive {:media_handler_called, :handle_info}, 1000
    end
    
    test "cleans up resources on termination", %{session: session} do
      ref = Process.monitor(session)
      
      ParrotMedia.MediaSession.stop("test_session")
      
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 1000
      # Verify ports and resources are freed
    end
  end
end
```

### Update apps/parrot_media/mix.exs
```elixir
defmodule ParrotMedia.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_media,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ParrotMedia.Application, []}
    ]
  end

  defp deps do
    [
      # Move all media deps here
      {:membrane_core, "~> 1.0"},
      {:membrane_rtp_plugin, "~> 0.31.0"},
      {:membrane_rtp_format, "~> 0.11.0"},
      {:membrane_file_plugin, "~> 0.17"},
      {:membrane_udp_plugin, "~> 0.14"},
      {:membrane_g711_plugin, "~> 0.1"},
      {:membrane_rtp_g711_plugin, github: "byoungdale/membrane_rtp_g711_plugin", branch: "byoungdale/update-rtp-format"},
      {:ex_sdp, "~> 0.17.0"},
      {:membrane_wav_plugin, "~> 0.10"},
      {:membrane_mp3_mad_plugin, "~> 0.18"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.20"},
      {:membrane_realtimer_plugin, "~> 0.10.1"},
      {:membrane_portaudio_plugin, "~> 0.19.2"},
      {:membrane_opus_plugin, "~> 0.20.3"},
      {:membrane_rtp_opus_plugin, "~> 0.10.1"}
      # NO dependency on :parrot_sip or :parrot_transport!
    ]
  end
end
```

### Files to Copy
```bash
# Create directory structure
mkdir -p apps/parrot_media/lib/parrot_media/{rtp,codecs,pipelines}

# Copy media files
cp -r lib/parrot/media/* apps/parrot_media/lib/parrot_media/
cp lib/parrot/sip/sdp.ex apps/parrot_media/lib/parrot_media/sdp.ex  # SDP belongs to media!
```

### Critical Changes for Media Independence

#### Remove SIP Dependencies
```elixir
# OLD - media_session.ex
def handle_call({:generate_offer, dialog_id}, _from, state) do
  sdp = Parrot.Sip.Sdp.build(...)  # ❌ NO! Media owns SDP

# NEW
def handle_call(:generate_offer, _from, state) do
  sdp = ParrotMedia.Sdp.build(...)  # ✅ Media owns SDP
```

#### Communication via Messages
```elixir
# OLD - Direct SIP dependency
def process_offer(sdp, dialog) do
  Parrot.Sip.Dialog.update_media(dialog, sdp)  # ❌ NO! Media shouldn't know about SIP

# NEW - Message passing for SDP exchange
def process_offer(sdp, session_id) do
  # Send result back to SIP via message
  {:ok, sip_handler} = Registry.lookup(Parrot.Registry, {:sip_dialog, session_id})
  send(sip_handler, {:sdp_answer_ready, session_id, generate_answer(sdp)})  # ✅ Message passing
end
```

#### Remove Handler Behavior Dependency
```elixir
# OLD
defmodule MyMediaHandler do
  @behaviour Parrot.MediaHandler  # From core

# NEW - Define own behavior
defmodule ParrotMedia.StreamHandler do
  @callback handle_rtp_packet(packet :: binary(), state :: term()) :: {:ok, state}
  @callback handle_rtcp(data :: binary(), state :: term()) :: {:ok, state}
end
```

## Phase 4: Create SIP App

### Commands
```bash
cd apps
mix new parrot_sip --sup
cd parrot_sip
```

### Unit Testing Requirements for SIP App
```bash
# Create comprehensive test structure
mkdir -p test/parrot_sip/{headers,transaction,dialog,parser}

# Required test coverage:
# 1. Parser tests (test/parrot_sip/parser_test.exs)
#    - Request parsing (all methods: INVITE, BYE, ACK, etc.)
#    - Response parsing (all status codes)
#    - Header parsing edge cases
#    - Malformed message handling
#    - Large message handling

# 2. Transaction state machine tests (test/parrot_sip/transaction_test.exs)
#    - Client transaction states (calling, proceeding, completed, terminated)
#    - Server transaction states (trying, proceeding, completed, confirmed, terminated)
#    - Timer tests (A, B, D, E, F, G, H, I, J, K)
#    - Retransmission logic
#    - Transaction matching by branch

# 3. Dialog state tests (test/parrot_sip/dialog_test.exs)
#    - Dialog creation from INVITE
#    - Dialog state transitions
#    - Route set management
#    - CSeq tracking
#    - Early dialog vs confirmed dialog
#    - Dialog termination

# 4. Header tests (test/parrot_sip/headers/)
#    - Via header manipulation
#    - Contact header parsing
#    - Route/Record-Route handling
#    - Authorization/WWW-Authenticate
#    - Custom header support

# 5. UAC/UAS tests (test/parrot_sip/uac_test.exs, test/parrot_sip/uas_test.exs)
#    - Request generation
#    - Response handling
#    - Handler callback invocation
#    - Error scenarios

# 6. B2BUA tests (test/parrot_sip/b2bua_test.exs)
#    - Call bridging
#    - State synchronization between legs
#    - Media negotiation passthrough
#    - Failure handling on either leg

# Example test structure:
```

```elixir
# test/parrot_sip/transaction_test.exs
defmodule ParrotSip.TransactionTest do
  use ExUnit.Case, async: true
  
  describe "client transaction state machine" do
    test "transitions from calling to proceeding on provisional response" do
      {:ok, tx} = ParrotSip.Transaction.start_client(
        branch: "z9hG4bK776asdhds",
        method: "INVITE",
        handler: self()
      )
      
      # Send provisional response
      ParrotSip.Transaction.receive_response(tx, %{status: 100})
      
      assert ParrotSip.Transaction.get_state(tx) == :proceeding
    end
    
    test "retransmits INVITE on timer A expiry" do
      {:ok, tx} = ParrotSip.Transaction.start_client(
        branch: "z9hG4bK776asdhds",
        method: "INVITE",
        handler: self()
      )
      
      # Wait for timer A
      assert_receive {:retransmit_request, _}, 600
    end
    
    test "handles timeout (timer B) correctly" do
      {:ok, tx} = ParrotSip.Transaction.start_client(
        branch: "z9hG4bK776asdhds",
        method: "INVITE",
        handler: self(),
        timer_b: 100  # Short timeout for testing
      )
      
      assert_receive {:transaction_timeout, _}, 150
    end
  end
  
  describe "server transaction state machine" do
    test "automatically sends 100 Trying for INVITE" do
      {:ok, tx} = ParrotSip.Transaction.start_server(
        branch: "z9hG4bK776asdhds",
        method: "INVITE",
        handler: self()
      )
      
      assert_receive {:send_response, %{status: 100}}, 100
    end
    
    test "transitions to confirmed state after ACK for 2xx" do
      {:ok, tx} = ParrotSip.Transaction.start_server(
        branch: "z9hG4bK776asdhds",
        method: "INVITE",
        handler: self()
      )
      
      # Send 200 OK
      ParrotSip.Transaction.send_response(tx, %{status: 200})
      
      # Receive ACK
      ParrotSip.Transaction.receive_request(tx, %{method: "ACK"})
      
      assert ParrotSip.Transaction.get_state(tx) == :confirmed
    end
  end
end

# test/parrot_sip/dialog_test.exs
defmodule ParrotSip.DialogTest do
  use ExUnit.Case, async: true
  
  describe "dialog management" do
    test "creates dialog from INVITE with proper IDs" do
      invite = %ParrotSip.Message{
        type: :request,
        method: "INVITE",
        headers: %{
          "Call-ID" => "abc123@example.com",
          "From" => "<sip:alice@example.com>;tag=1234",
          "To" => "<sip:bob@example.com>"
        }
      }
      
      {:ok, dialog} = ParrotSip.Dialog.create_from_invite(invite, :uas)
      
      assert dialog.call_id == "abc123@example.com"
      assert dialog.local_tag != nil
      assert dialog.remote_tag == "1234"
    end
    
    test "maintains route set from Record-Route headers" do
      # Test route set establishment
    end
    
    test "increments CSeq for new requests in dialog" do
      # Test CSeq management
    end
  end
end
```

### Update apps/parrot_sip/mix.exs
```elixir
defmodule ParrotSip.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrot_sip,
      version: "0.0.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {ParrotSip.Application, []}
    ]
  end

  defp deps do
    [
      {:nimble_parsec, "~> 1.3"}
      # NO dependency on :parrot_transport or :parrot_media!
    ]
  end
end
```

### Files to Copy
```bash
# Create directory structure
mkdir -p apps/parrot_sip/lib/parrot_sip/{headers,dialog,transaction}

# Copy SIP files (excluding transport and sdp)
cp lib/parrot/sip/*.ex apps/parrot_sip/lib/parrot_sip/
cp -r lib/parrot/sip/headers apps/parrot_sip/lib/parrot_sip/
cp -r lib/parrot/sip/dialog apps/parrot_sip/lib/parrot_sip/
cp -r lib/parrot/sip/transaction apps/parrot_sip/lib/parrot_sip/

# Remove transport and sdp files from copy
rm -rf apps/parrot_sip/lib/parrot_sip/transport
rm apps/parrot_sip/lib/parrot_sip/sdp.ex
```

### Critical Changes for SIP Independence

#### Remove Transport Dependencies
```elixir
# OLD - uac.ex
def send_request(message) do
  Parrot.Sip.Transport.send(message, destination)  # ❌ NO!

# NEW
def send_request(message) do
  # Find transport via registry
  {:ok, transport} = Registry.lookup(Parrot.Registry, :sip_transport)
  send(transport, {:send_sip_message, serialize(message), destination})
end
```

#### Remove Media Dependencies
```elixir
# OLD - dialog.ex
def handle_sdp(sdp) do
  Parrot.Media.MediaSession.process_sdp(sdp)  # ❌ NO!

# NEW
def handle_sdp(sdp, dialog_id) do
  # Send SDP to media via message
  {:ok, media_session} = Registry.lookup(Parrot.Registry, {:media_session, dialog_id})
  send(media_session, {:process_sdp, sdp})
end
```

#### Receive Transport Messages
```elixir
# NEW - transaction.ex
def handle_info({:packet_received, data, source, _metadata}, state) do
  # Parse and process SIP message
  case ParrotSip.Parser.parse(data) do
    {:ok, message} -> 
      process_sip_message(message, source, state)
    {:error, _} ->
      {:noreply, state}
  end
end
```

## Phase 5: Inter-App Communication Patterns

### Registry Setup (in each app's Application module)
```elixir
defmodule ParrotTransport.Application do
  def start(_type, _args) do
    children = [
      # Each app registers in the shared registry
      {Registry, keys: :unique, name: Parrot.Registry},
      ParrotTransport.Supervisor
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### Message Contracts Between Apps

#### Transport → SIP
```elixir
# Transport sends to SIP
send(sip_handler, {:packet_received, binary_data, {ip, port}, metadata})

# SIP receives
def handle_info({:packet_received, data, source, metadata}, state)
```

#### SIP → Transport
```elixir
# SIP sends to Transport
send(transport, {:send_packet, binary_data, {dest_ip, dest_port}})

# Transport receives
def handle_info({:send_packet, data, destination}, state)
```

#### SIP → Media (SDP Exchange)
```elixir
# SIP sends to Media
send(media_session, {:process_sdp_offer, sdp_binary})
send(media_session, {:process_sdp_answer, sdp_binary})

# Media responds via message
send(sip_process, {:sdp_answer_ready, session_id, sdp_binary})
```


## Phase 6: Shared Registry Configuration

### Root config/config.exs
```elixir
# This is the ONLY place where apps know about each other
import Config

# Tell each app where to find others via registry keys
config :parrot_transport,
  registry: Parrot.Registry,
  sip_handler_key: :sip_receiver

config :parrot_sip,
  registry: Parrot.Registry,
  transport_key: :sip_transport,
  media_key_prefix: :media_session

config :parrot_media,
  registry: Parrot.Registry,
  sip_key_prefix: :sip_dialog
```

## Phase 7: Testing the Separation

### Create Integration Test
```elixir
# test/integration/inter_app_test.exs
defmodule InterAppTest do
  use ExUnit.Case

  test "apps communicate only via messages" do
    # Start transport
    {:ok, transport} = ParrotTransport.start_listener(:udp, port: 5060)
    
    # Register SIP handler
    sip_handler = spawn(fn ->
      receive do
        {:packet_received, data, source, _} ->
          assert is_binary(data)
          assert source == {127, 0, 0, 1, 5060}
      end
    end)
    
    Registry.register(Parrot.Registry, :sip_receiver, sip_handler)
    
    # Send data through transport
    :gen_udp.send(transport.socket, {127, 0, 0, 1}, 5060, "SIP/2.0...")
    
    # Verify message passing works
    Process.sleep(100)
  end
end
```

## Phase 8: Update Examples and Generators

### Update Generator Templates
```elixir
# installer/parrot_new/lib/mix/tasks/parrot.gen.uac.ex
# Change deps from:
{:parrot_platform, "~> 0.0.1-alpha.3"}
# To:
{:parrot_sip, in_umbrella: true},
{:parrot_media, in_umbrella: true},
{:parrot_transport, in_umbrella: true}
```

## Phase 9: Verification Checklist

Run these commands to verify separation:
```bash
# Each app should compile independently
cd apps/parrot_transport && mix compile
cd apps/parrot_sip && mix compile  
cd apps/parrot_media && mix compile

# Check for cross-dependencies (should show none)
cd apps/parrot_transport && mix xref graph
cd apps/parrot_sip && mix xref graph
cd apps/parrot_media && mix xref graph

# Run tests for each app
cd apps/parrot_transport && mix test
cd apps/parrot_sip && mix test
cd apps/parrot_media && mix test

# Run integration tests from root
mix test test/integration
```

## Phase 10: Integration Testing Strategy

### SIPp Integration Tests Remain at Root Level
**IMPORTANT**: The SIPp integration tests (`test/sipp/`) must remain in the main directory, NOT in individual apps. These tests validate the complete system behavior using all three apps working together.

```bash
# SIPp tests stay at root level
test/
├── sipp/
│   ├── scenarios/          # All SIPp XML scenarios
│   │   ├── uac_invite.xml
│   │   ├── uas_answer.xml
│   │   ├── b2bua_bridge.xml
│   │   └── ...
│   ├── test_scenarios.exs  # Main SIPp test runner
│   └── sipp_helper.ex      # SIPp test utilities
└── integration/            # New inter-app integration tests
    ├── transport_sip_test.exs
    ├── sip_media_test.exs
    └── full_stack_test.exs
```

### Rationale for Root-Level SIPp Tests
1. **End-to-end validation**: SIPp tests verify complete call flows across all apps
2. **External perspective**: Tests the system as an external SIP endpoint would see it
3. **No app isolation**: Requires transport, SIP, and media working in concert
4. **Regression prevention**: Catches integration issues between apps
5. **Performance testing**: Can measure complete system performance metrics

### Running Tests Post-Migration
```bash
# Unit tests for each app (fast, isolated)
mix test apps/parrot_transport/test
mix test apps/parrot_sip/test
mix test apps/parrot_media/test

# Integration tests (inter-app communication)
mix test test/integration

# SIPp functional tests (complete system validation)
mix test.sipp

# All tests
mix test.all
```

## Phase 11: Additional Migration Considerations

### Breaking Changes - No Backwards Compatibility Required
**CRITICAL**: This migration is a complete overhaul, NOT an incremental update. We are NOT maintaining backwards compatibility with the current monolithic structure. This gives us freedom to:

1. **Rename modules**: Use cleaner namespaces (ParrotTransport.Udp instead of Parrot.Sip.Transport.TransportUdp)
2. **Change APIs**: Design better inter-app contracts without legacy constraints
3. **Restructure state**: Each app can have its own optimal state management
4. **Remove technical debt**: Don't carry forward any workarounds or hacks
5. **Optimize for the future**: Make decisions based on the target architecture, not the current one

### Migration-Specific Considerations

#### 1. Process Registry Strategy
```elixir
# Create a shared registry supervisor that starts before all apps
defmodule Parrot.RegistrySupervisor do
  use Supervisor
  
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end
  
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Parrot.Registry, partitions: System.schedulers_online()},
      {Registry, keys: :duplicate, name: Parrot.PubSub, partitions: System.schedulers_online()}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

#### 2. Configuration Migration
```elixir
# Move from monolithic config to app-specific configs
# OLD: config/config.exs
config :parrot_platform,
  sip_port: 5060,
  rtp_port_range: 10000..20000,
  media_codecs: [:opus, :alaw]

# NEW: config/config.exs delegates to apps
import_config "../apps/*/config/config.exs"

# NEW: apps/parrot_transport/config/config.exs
config :parrot_transport,
  default_sip_port: 5060,
  port_reuse: true

# NEW: apps/parrot_media/config/config.exs
config :parrot_media,
  rtp_port_range: 10000..20000,
  supported_codecs: [:opus, :alaw, :ulaw]
```

#### 3. Supervision Tree Restructuring
```elixir
# Root application starts registry and app supervisors
defmodule Parrot.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      Parrot.RegistrySupervisor,  # Shared registry
      # Apps will auto-start via their own application callbacks
    ]
    
    opts = [strategy: :one_for_one, name: Parrot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

#### 4. Development Workflow Changes
```bash
# Developers need new commands for umbrella development
# Add to README or developer docs:

# Start individual app in isolation for development
cd apps/parrot_sip && iex -S mix

# Start all apps together
iex -S mix  # from root

# Run specific app tests with coverage
cd apps/parrot_transport && mix test --cover

# Generate docs for all apps
mix docs  # from root generates unified docs
```

#### 5. CI/CD Pipeline Updates
```yaml
# .github/workflows/ci.yml updates needed
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        app: [parrot_transport, parrot_sip, parrot_media]
    steps:
      - uses: actions/checkout@v2
      - name: Test ${{ matrix.app }}
        run: |
          cd apps/${{ matrix.app }}
          mix deps.get
          mix test
  
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Integration Tests
        run: |
          mix deps.get
          mix test test/integration
          mix test.sipp
```

#### 6. Error Boundary Definitions
Each app should define clear error boundaries and recovery strategies:

```elixir
# apps/parrot_transport/lib/parrot_transport/error_boundary.ex
defmodule ParrotTransport.ErrorBoundary do
  @moduledoc """
  Defines how transport errors are communicated to other apps
  """
  
  def notify_transport_failure(reason, metadata) do
    # Send standardized error message
    Registry.dispatch(Parrot.PubSub, :transport_errors, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:transport_error, reason, metadata})
      end
    end)
  end
end
```

#### 7. Deployment Considerations
```elixir
# mix.exs (root) - Add release configuration
def project do
  [
    # ... other config
    releases: [
      parrot_platform: [
        applications: [
          parrot_transport: :permanent,
          parrot_sip: :permanent,
          parrot_media: :permanent
        ],
        cookie: "your-secure-cookie-here"
      ]
    ]
  ]
end
```

## Common Pitfalls to Avoid

1. **Direct Module Calls**: Never call another app's modules directly
2. **Shared Structs**: Each app defines its own structs, convert at boundaries
3. **Circular Dependencies**: Transport at bottom, no upward dependencies
4. **Synchronous Calls**: Prefer async messages over GenServer.call between apps
5. **Shared State**: Each app manages its own state, no shared ETS tables
6. **Test Coupling**: Unit tests should never depend on other apps running
7. **Config Leakage**: Each app's config should be self-contained

## Migration Success Metrics

Track these metrics to ensure successful migration:

1. **Zero cross-app compilation dependencies** (verified by `mix xref graph`)
2. **All unit tests pass in isolation** (each app's tests run without others)
3. **SIPp integration tests maintain 100% pass rate**
4. **Message passing latency < 1ms** between apps (measure in integration tests)
5. **No shared ETS tables or processes** between apps
6. **Clean supervisor tree** with proper isolation

## Rollback Plan
If critical issues arise during migration:
1. The original monolithic code remains untouched in `lib/`
2. Can continue using monolithic version while fixing umbrella issues
3. Git branches preserve both structures during transition
4. No production deployment until umbrella structure is fully validated
