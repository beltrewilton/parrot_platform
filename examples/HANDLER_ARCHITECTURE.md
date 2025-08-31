# Parrot Handler Architecture Guide

## Overview

The Parrot platform has two distinct handler patterns depending on whether you're building a UAC (client) or UAS (server) application.

## Handler Layers

### 1. Low-Level Transport Handler (`Parrot.Sip.Handler` behavior)
- Direct interface with the transport and transaction layers
- Complex callbacks: `transp_request/2`, `transaction/3`, `uas_request/3`, `process_ack/2`
- Deals with transaction state machines and low-level SIP protocol details
- Most developers don't implement this directly

### 2. High-Level Application Handlers
- **`Parrot.UasHandler`** - For building SIP servers
- **`Parrot.UacHandler`** - For building SIP clients
- Simple callbacks: `handle_invite/2`, `handle_bye/2`, `handle_options/2`, etc.
- Return simple tuples without state management concerns

### 3. The Bridge: `HandlerAdapter.Core`
- Implements the low-level `Parrot.Sip.Handler` behavior
- Calls your high-level handler methods
- Manages state automatically
- Handles transaction and dialog lifecycle

## UAC (Client) Pattern

```
Your UAC Application (e.g., ParrotExampleUac)
    ├── Embedded minimal handler callbacks
    │   └── Just return :noreply or :ok
    ├── UAC Callbacks
    │   └── Handle responses via UAC.request/2
    └── MediaHandler
        └── Manages audio streaming
```

### Key Points:
- No separate transport handler module needed
- Minimal handler callbacks embedded in main module
- Real logic is in the main module using `UAC.request/2` with callbacks
- Responses are handled directly via callback functions
- Simpler architecture for client applications

### Example:
```elixir
# Send request with callback
callback = fn response -> 
  send(self(), {:uac_response, response})
end
UAC.request(invite, callback)

# Handle response in your GenServer
def handle_info({:uac_response, response}, state) do
  # Process response here
end
```

## UAS (Server) Pattern

```
Transport Layer
    ↓
HandlerAdapter.Core
    ↓
Your IncomingCallHandler
    ├── handle_invite/2
    ├── handle_bye/2
    ├── handle_ack/2
    └── etc.
```

### Key Points:
- `IncomingCallHandler` implements method-specific callbacks
- Returns 5-tuple responses: `{:respond, status, reason, headers, body}`
- State is managed by HandlerAdapter.Core
- No need to use `Parrot.UasHandler` behavior when using HandlerAdapter

### Example:
```elixir
defmodule MyApp.IncomingCallHandler do
  # Note: No "use Parrot.UasHandler" here
  
  def handle_invite(request, state) do
    # Process INVITE, return response without state
    {:respond, 200, "OK", %{"content-type" => "application/sdp"}, sdp_answer}
  end
  
  def handle_bye(_request, _state) do
    {:respond, 200, "OK", %{}, ""}
  end
end

# Register with transport
handler = Parrot.Sip.Handler.new(
  Parrot.Sip.HandlerAdapter.Core,
  {MyApp.IncomingCallHandler, initial_state}
)
```

## Common Pitfalls

1. **Don't use `Parrot.UasHandler` behavior with HandlerAdapter.Core**
   - The behavior expects 6-tuple responses with state
   - HandlerAdapter.Core expects 5-tuple responses without state

2. **UAC doesn't need a complex transport handler**
   - Keep it minimal - just consume messages
   - Use UAC.request callbacks for response handling

3. **State management confusion**
   - With HandlerAdapter.Core: Don't include state in responses
   - With direct Parrot.UasHandler: Include state in responses

## When to Use What

### Use HandlerAdapter.Core when:
- Building a UAS that needs to handle incoming calls
- You want automatic state management
- You need transaction and dialog lifecycle management

### Use UAC.request callbacks when:
- Building a UAC that makes outbound calls
- You want simple response handling
- You're managing your own state in a GenServer

### Use Parrot.UasHandler/UacHandler behaviors directly when:
- Building a standalone handler without HandlerAdapter
- You need full control over state management
- You're implementing a custom adapter