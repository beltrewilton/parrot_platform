# Examples Migration Guide

## ⚠️ CRITICAL: Migration is NOT Complete!

**DO NOT migrate examples yet!** The umbrella apps only have skeleton implementations. Here's what needs to happen before examples can be updated:

## Current Reality

### What EXISTS:
- ✅ Umbrella project structure
- ✅ Three apps created with basic configs
- ✅ 11 skeleton files across the apps
- ✅ Basic tests that verify modules exist

### What DOESN'T EXIST:
- ❌ 68 source files still need migration
- ❌ 69 test files still need migration  
- ❌ Actual functionality (most modules are empty or simplified)
- ❌ Inter-app communication implementation
- ❌ Working SIP stack
- ❌ Working media handling
- ❌ Working transport beyond basic UDP

## Prerequisites Before Updating Examples

The following must be complete before examples can work:

### 1. Complete File Migration
All 79 files from `lib/` must be migrated to their respective apps with namespace changes:
- `Parrot.Sip.*` → `ParrotSip.*`
- `Parrot.Media.*` → `ParrotMedia.*`
- `Parrot.Sip.Transport.*` → `ParrotTransport.*`

### 2. Working Inter-App Communication
Replace all direct module calls with message passing. This requires:
- Shared registry implementation
- Message protocols defined between apps
- Handler registration mechanisms

### 3. All Tests Passing
Currently only 8 trivial tests exist. Need:
- All 69 test files migrated
- Tests updated for new namespaces
- Integration tests for inter-app communication

## How to Update Examples (AFTER Migration is Complete)

### Step 1: Update mix.exs Dependencies

**Old (monolithic):**
```elixir
defmodule MyApp.MixProject do
  use Mix.Project
  
  defp deps do
    [
      {:parrot_platform, "~> 0.0.1-alpha.3"}
    ]
  end
end
```

**New (umbrella - for development):**
```elixir
defmodule MyApp.MixProject do
  use Mix.Project
  
  defp deps do
    [
      {:parrot_sip, path: "../parrot_platform/apps/parrot_sip"},
      {:parrot_media, path: "../parrot_platform/apps/parrot_media"},
      {:parrot_transport, path: "../parrot_platform/apps/parrot_transport"}
    ]
  end
end
```

**New (umbrella - for hex publication):**
```elixir
defmodule MyApp.MixProject do
  use Mix.Project
  
  defp deps do
    [
      {:parrot_sip, "~> 0.0.1"},
      {:parrot_media, "~> 0.0.1"},
      {:parrot_transport, "~> 0.0.1"}
    ]
  end
end
```

### Step 2: Update Module Aliases

**Old:**
```elixir
alias Parrot.Sip.UAC
alias Parrot.Sip.UAS
alias Parrot.Sip.Message
alias Parrot.Media.MediaSession
alias Parrot.MediaHandler
alias Parrot.UacHandler
```

**New:**
```elixir
alias ParrotSip.UAC
alias ParrotSip.UAS
alias ParrotSip.Message
alias ParrotMedia.MediaSession
alias ParrotMedia.Handler, as: MediaHandler
alias ParrotSip.UacHandler
```

### Step 3: Update Application Startup

**Old:**
```elixir
def start(_type, _args) do
  children = [
    {Parrot.Sip.Transport.Udp, %{port: 5060, handler: MyHandler}}
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

**New:**
```elixir
def start(_type, _args) do
  children = [
    # Start shared registry
    {Registry, keys: :unique, name: MyApp.Registry},
    
    # Start transport
    {Task, fn -> start_transport() end}
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end

defp start_transport do
  {:ok, transport} = ParrotTransport.start_listener(:udp, port: 5060)
  
  # Register SIP handler to receive packets
  sip_handler = spawn(fn -> sip_packet_handler() end)
  Registry.register(MyApp.Registry, :sip_handler, sip_handler)
  ParrotTransport.register_handler(transport, sip_handler)
end
```

### Step 4: Update Handler Patterns

**Old (direct handler):**
```elixir
defmodule MyHandler do
  @behaviour Parrot.Handler
  
  def handle_request(message, source) do
    # Handle SIP request
  end
end
```

**New (message-based handler):**
```elixir
defmodule MySipHandler do
  use GenServer
  
  def handle_info({:packet_received, data, source, metadata}, state) do
    case ParrotSip.parse_message(data) do
      {:ok, message} ->
        handle_sip_message(message, source, state)
      _ ->
        {:noreply, state}
    end
  end
  
  defp handle_sip_message(message, source, state) do
    # Handle parsed SIP message
    {:noreply, state}
  end
end
```

### Step 5: Update Media Handling

**Old:**
```elixir
{:ok, media_session} = Parrot.Media.MediaSession.start_link(%{
  id: session_id,
  handler: MyMediaHandler
})
```

**New:**
```elixir
{:ok, media_session} = ParrotMedia.start_session(%{
  id: session_id,
  media_handler: MyMediaHandler,
  handler_args: %{}
})

# Register for inter-app communication
Registry.register(MyApp.Registry, {:media_session, session_id}, media_session)
```

### Step 6: Update SDP Handling

**Old:**
```elixir
sdp = Parrot.Sip.Sdp.build(%{...})
```

**New:**
```elixir
sdp = ParrotMedia.Sdp.build_offer(%{...})
```

## Generator Updates Required

The mix task generators need updates:

### parrot.gen.uac
- Update template dependencies
- Update module references
- Add registry setup
- Update handler patterns

### parrot.gen.uas  
- Update template dependencies
- Update module references
- Add registry setup
- Update handler patterns

## Testing Your Updated Examples

After updating, verify with:

```bash
# Get dependencies
mix deps.get

# Compile and check for warnings
mix compile --warnings-as-errors

# Run tests
mix test

# Test with SIPp if applicable
mix test.sipp
```

## Common Migration Issues

### Issue 1: Module not found
**Error:** `(UndefinedFunctionError) function Parrot.Sip.UAC.start_link/1 is undefined`
**Fix:** Update to `ParrotSip.UAC.start_link/1`

### Issue 2: Handler behavior not found
**Error:** `@behaviour Parrot.Handler`
**Fix:** Use `@behaviour ParrotSip.Handler` or implement message-based handler

### Issue 3: Transport not receiving packets
**Error:** No packets received
**Fix:** Ensure handler is registered with transport using `ParrotTransport.register_handler/2`

### Issue 4: Media session not found
**Error:** Registry lookup fails
**Fix:** Ensure media session is registered in shared registry

## Timeline

**DO NOT START MIGRATION YET!**

Estimated timeline for umbrella migration completion:
- Transport app completion: ~1 week
- Media app completion: ~2 weeks  
- SIP app completion: ~3 weeks
- Testing and integration: ~1 week
- **Total: ~7 weeks**

Check `MIGRATION_STATUS.md` for current progress before attempting any example updates.