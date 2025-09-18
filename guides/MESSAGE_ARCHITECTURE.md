# Message-Based Architecture Between Apps

## Overview

The Parrot Platform uses a clean message-passing architecture between its three umbrella apps:
- **parrot_transport**: Handles raw network I/O (UDP/TCP/TLS)
- **parrot_sip**: Implements SIP protocol logic
- **parrot_media**: Manages RTP media sessions

**Key Principle**: Apps communicate only through messages, never through direct function calls. This ensures:
- Clean separation of concerns
- No compile-time dependencies between apps
- Easy to distribute across nodes if needed
- Clear API boundaries

## Transport ↔ SIP Communication

### Architecture

```
┌─────────────────────┐         Messages          ┌─────────────────────┐
│  parrot_transport   │ ◄────────────────────────► │    parrot_sip       │
├─────────────────────┤                            ├─────────────────────┤
│ ParrotTransport.Udp │                            │ TransportHandler    │
│   - UDP socket      │                            │   - Message router  │
│   - Raw packets     │                            │   - SIP parser      │
└─────────────────────┘                            └─────────────────────┘
         ▲                                                   ▲
         │                                                   │
         │ {:packet_received,                               │ {:send_packet,
         │  raw_data,                                       │  raw_data,
         │  {ip, port},                                     │  {ip, port}}
         │  metadata}                                       │
         │                                                   │
         ▼                                                   ▼
    Raw Network I/O                                   SIP Protocol Logic
```

### Message Flow

#### Incoming SIP Messages (Network → SIP)

1. **UDP receives packet**
   ```elixir
   # In ParrotTransport.Udp
   def handle_info({:udp, socket, ip, port, data}, state) do
     # Send to all registered handlers
     for handler <- state.handlers do
       send(handler, {:packet_received, data, {ip, port}, metadata})
     end
   end
   ```

2. **TransportHandler receives and parses**
   ```elixir
   # In ParrotSip.TransportHandler
   def handle_info({:packet_received, raw_data, source, metadata}, state) do
     case Parser.parse_message(raw_data) do
       {:ok, sip_message} ->
         # Add source, route to transaction layer
         Transaction.process_message(sip_message)
     end
   end
   ```

3. **Transaction/Dialog processes SIP message**
   - Creates/updates transaction state
   - Invokes user callbacks
   - Generates responses

#### Outgoing SIP Messages (SIP → Network)

1. **SIP layer needs to send message**
   ```elixir
   # In ParrotSip.TransactionStatem
   defp send_via_transport_handler(:send_response, response, source) do
     transport_handler = Process.whereis(ParrotSip.TransportHandler)
     ParrotSip.TransportHandler.send_response(transport_handler, response, source)
   end
   ```

2. **TransportHandler serializes and forwards**
   ```elixir
   # In ParrotSip.TransportHandler
   def handle_cast({:send_sip_response, response, source}, state) do
     raw_data = Serializer.serialize(response)
     destination = {source.host, source.port}
     GenServer.cast(state.transport_ref, {:send_packet, raw_data, destination})
   end
   ```

3. **Transport sends via UDP**
   ```elixir
   # In ParrotTransport.Udp
   def handle_cast({:send_packet, data, {ip, port}}, state) do
     :gen_udp.send(state.socket, ip, port, data)
   end
   ```

## SIP ↔ Media Communication

Similar pattern for SIP and Media apps:

```
┌─────────────────────┐         Messages          ┌─────────────────────┐
│    parrot_sip       │ ◄────────────────────────► │   parrot_media      │
├─────────────────────┤                            ├─────────────────────┤
│ Dialog/Transaction  │                            │ MediaSession        │
│   - Call state      │                            │   - RTP handling    │
│   - SDP negotiation │                            │   - Audio pipeline  │
└─────────────────────┘                            └─────────────────────┘
         ▲                                                   ▲
         │                                                   │
         │ {:start_media,                                   │ {:media_started,
         │  session_id,                                     │  session_id,
         │  sdp_params}                                     │  local_sdp}
         │                                                   │
         ▼                                                   ▼
    Call Control                                      Media Processing
```

## Usage Example

### Starting the System

```elixir
# 1. Start transport layer
{:ok, transport_pid} = ParrotTransport.Udp.start_link(
  port: 5060,
  name: :sip_transport
)

# 2. Start SIP layer with transport reference
{:ok, sip_handler} = ParrotSip.TransportHandler.start_link(
  name: ParrotSip.TransportHandler,
  transport_ref: :sip_transport
)

# 3. Transport and SIP now communicate via messages
# When UDP receives a packet:
#   → sends {:packet_received, data, source, metadata} to SIP handler
# When SIP needs to send:
#   → sends {:send_packet, data, destination} to transport
```

### Implementing a UAC

```elixir
defmodule MyApp.SipClient do
  use GenServer
  
  def init(_) do
    # Register with transport to receive packets
    ParrotTransport.Udp.register_handler(:sip_transport, self())
    {:ok, %{}}
  end
  
  def handle_info({:packet_received, data, source, metadata}, state) do
    # Parse and process SIP message
    case ParrotSip.parse_message(data) do
      {:ok, message} -> 
        handle_sip_message(message, source, state)
      {:error, _} ->
        {:noreply, state}
    end
  end
  
  defp send_sip_message(message, destination) do
    raw_data = ParrotSip.serialize_message(message)
    GenServer.cast(:sip_transport, {:send_packet, raw_data, destination})
  end
end
```

## Benefits of This Architecture

1. **No Direct Dependencies**: Apps don't call each other's modules directly
2. **Clear Interfaces**: Communication only through well-defined messages
3. **Testability**: Easy to mock message passing in tests
4. **Flexibility**: Can easily replace transport layer (UDP → TCP)
5. **Distribution Ready**: Apps can run on different nodes
6. **Monitoring**: Easy to trace/log all inter-app communication

## Message Reference

### Transport → SIP Messages

| Message | Description | Example |
|---------|-------------|---------|
| `{:packet_received, data, source, metadata}` | Raw packet received | `{:packet_received, "SIP/2.0...", {{127,0,0,1}, 5060}, %{transport: :udp}}` |

### SIP → Transport Messages

| Message | Description | Example |
|---------|-------------|---------|
| `{:send_packet, data, destination}` | Send raw packet | `{:send_packet, "INVITE sip:...", {{10,0,0,1}, 5060}}` |
| `{:send_sip_response, response, source}` | Send SIP response | `{:send_sip_response, %Message{}, %Source{}}` |
| `{:send_sip_request, request, destination}` | Send SIP request | `{:send_sip_request, %Message{}, {ip, port}}` |

### SIP → Media Messages

| Message | Description | Example |
|---------|-------------|---------|
| `{:start_media, session_id, params}` | Start media session | `{:start_media, "call-123", %{codecs: [:opus, :pcmu]}}` |
| `{:stop_media, session_id}` | Stop media session | `{:stop_media, "call-123"}` |

### Media → SIP Messages

| Message | Description | Example |
|---------|-------------|---------|
| `{:media_started, session_id, local_sdp}` | Media ready | `{:media_started, "call-123", "v=0..."}` |
| `{:media_error, session_id, reason}` | Media failed | `{:media_error, "call-123", :no_codec_match}` |

## Testing

The message-based architecture makes testing straightforward:

```elixir
defmodule TransportTest do
  use ExUnit.Case
  
  test "SIP message routing" do
    # Start test handler
    {:ok, test_handler} = GenAgent.start_link()
    
    # Register as handler
    ParrotTransport.Udp.register_handler(:transport, test_handler)
    
    # Simulate incoming packet
    send(:transport, {:udp, nil, {127,0,0,1}, 5060, "INVITE sip:test"})
    
    # Verify handler received message
    assert_receive {:packet_received, "INVITE sip:test", _, _}
  end
end
```

## Migration Notes

If you're migrating from the monolithic structure:

1. **Remove direct module calls** between apps
2. **Add message handlers** for inter-app communication  
3. **Use TransportHandler** as the bridge between transport and SIP
4. **Register handlers** with transport to receive packets
5. **Send via messages** instead of calling transport functions

The architecture ensures clean separation while maintaining the same functionality.