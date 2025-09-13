# Umbrella Migration Status

## Current Status: INCOMPLETE ❌

The umbrella structure has been created but the actual code migration is NOT complete. Only skeleton apps exist.

## Migration Progress

### ✅ Completed
- Umbrella project structure created
- Three apps created: `parrot_transport`, `parrot_media`, `parrot_sip`
- Basic module structure in each app
- Mix configurations set up

### ❌ Not Completed
- **79 source files** need to be migrated from `lib/`
- **69 test files** need to be migrated from `test/`
- Module namespaces need to be updated (Parrot.Sip.* → ParrotSip.*)
- Inter-app communication needs implementation
- Tests are not passing (most don't exist in apps yet)

## File Migration Checklist

### Transport App (parrot_transport)
**Source files to migrate from `lib/parrot/sip/transport/`:**
- [ ] inet.ex → apps/parrot_transport/lib/parrot_transport/inet.ex
- [ ] source.ex → apps/parrot_transport/lib/parrot_transport/source.ex (✅ created skeleton)
- [ ] state_machine.ex → apps/parrot_transport/lib/parrot_transport/state_machine.ex
- [ ] supervisor.ex → apps/parrot_transport/lib/parrot_transport/supervisor.ex (✅ created skeleton)
- [ ] transport_udp.ex → apps/parrot_transport/lib/parrot_transport/udp.ex (✅ created simplified version)

**Tests to migrate:**
- [ ] test/parrot/sip/transport/*.exs → apps/parrot_transport/test/

### Media App (parrot_media)
**Source files to migrate from `lib/parrot/media/`:**
- [ ] alaw_pipeline.ex
- [ ] audio_chunker.ex
- [ ] audio_devices.ex
- [ ] basic_rtp_depayloader.ex
- [ ] media_session.ex
- [ ] media_session_supervisor.ex
- [ ] opus_pipeline.ex
- [ ] pipeline_helpers.ex
- [ ] portaudio_pipeline.ex
- [ ] rtp_packet.ex
- [ ] rtp_packet_logger.ex
- [ ] silence_source.ex
- [ ] timestamp_generator.ex
- [ ] timestamp_preserving_g711_encoder.ex

**Additional files:**
- [ ] lib/parrot/media_handler.ex → apps/parrot_media/lib/parrot_media/handler.ex
- [ ] lib/parrot/sip/sdp.ex → apps/parrot_media/lib/parrot_media/sdp.ex (✅ created skeleton)

**Tests to migrate:**
- [ ] test/parrot/media/*.exs → apps/parrot_media/test/
- [ ] test/media/*.exs → apps/parrot_media/test/

### SIP App (parrot_sip)
**Source files to migrate from `lib/parrot/sip/`:**
- [ ] branch.ex
- [ ] connection.ex
- [ ] dialog.ex
- [ ] dialog/supervisor.ex
- [ ] dialog_statem.ex
- [ ] dns/resolver.ex
- [ ] handler.ex
- [ ] handler_adapter/*.ex (6 files)
- [ ] handlers/*.ex
- [ ] headers.ex
- [ ] headers/*.ex (19 header files)
- [ ] message.ex
- [ ] message_helper.ex
- [ ] method.ex
- [ ] method_set.ex
- [ ] parser.ex
- [ ] serializer.ex
- [ ] source.ex
- [ ] transaction.ex
- [ ] transaction/supervisor.ex
- [ ] transaction_statem.ex
- [ ] transport.ex (needs refactoring to use message passing)
- [ ] uac.ex
- [ ] uac_handler_adapter.ex
- [ ] uas.ex
- [ ] uri.ex
- [ ] uri_parser.ex
- [ ] validators.ex

**Additional files:**
- [ ] lib/parrot/uac_handler.ex → apps/parrot_sip/lib/parrot_sip/uac_handler.ex
- [ ] lib/parrot/uas_handler.ex → apps/parrot_sip/lib/parrot_sip/uas_handler.ex

**Tests to migrate:**
- [ ] test/parrot/sip/*.exs → apps/parrot_sip/test/

## Critical Refactoring Required

### 1. Namespace Changes
All modules need namespace updates:
- `Parrot.Sip.*` → `ParrotSip.*`
- `Parrot.Media.*` → `ParrotMedia.*`
- `Parrot.Sip.Transport.*` → `ParrotTransport.*`

### 2. Remove Direct Module Calls
Replace direct cross-app module calls with message passing:

**Before:**
```elixir
# In SIP app calling transport directly
Parrot.Sip.Transport.send(message, destination)
```

**After:**
```elixir
# In SIP app using message passing
{:ok, transport} = Registry.lookup(Parrot.Registry, :sip_transport)
send(transport, {:send_packet, serialize(message), destination})
```

### 3. Handler Pattern Updates
The handler pattern needs to be split:
- `Parrot.Handler` → Split into `ParrotSip.Handler` and `ParrotMedia.Handler`
- Each app defines its own handler behavior

## Examples Migration Guide

Once the migration is complete, examples need these changes:

### 1. Dependencies
**Old (monolithic):**
```elixir
defp deps do
  [{:parrot_platform, "~> 0.0.1-alpha.3"}]
end
```

**New (umbrella):**
```elixir
defp deps do
  [
    {:parrot_sip, path: "../apps/parrot_sip"},
    {:parrot_media, path: "../apps/parrot_media"},
    {:parrot_transport, path: "../apps/parrot_transport"}
  ]
end
```

### 2. Module References
**Old:**
```elixir
alias Parrot.Sip.UAC
alias Parrot.Media.MediaSession
```

**New:**
```elixir
alias ParrotSip.UAC
alias ParrotMedia.MediaSession
```

### 3. Starting Services
**Old:**
```elixir
{:ok, _} = Parrot.Sip.Transport.Udp.start_link(%{port: 5060})
```

**New:**
```elixir
{:ok, transport} = ParrotTransport.start_listener(:udp, port: 5060)
ParrotTransport.register_handler(transport, self())
```

### 4. Inter-App Communication
**Old (direct calls):**
```elixir
def handle_sdp(sdp) do
  Parrot.Media.MediaSession.process_sdp(sdp)
end
```

**New (message passing):**
```elixir
def handle_sdp(sdp, session_id) do
  {:ok, media_session} = Registry.lookup(ParrotMedia.Registry, {:media_session, session_id})
  send(media_session, {:process_sdp, sdp})
end
```

## Test Migration Requirements

1. All tests in `test/` need to be moved to appropriate app test directories
2. Test helpers need to be duplicated or shared appropriately
3. Integration tests that span apps should remain at root level
4. SIPp tests must remain at root level (they test the full system)

## Estimated Work Remaining

- [ ] **~40 hours** - Complete file migration and namespace updates
- [ ] **~20 hours** - Refactor cross-app dependencies to message passing
- [ ] **~20 hours** - Fix and migrate all tests
- [ ] **~10 hours** - Update examples and generators
- [ ] **~10 hours** - Documentation updates

**Total: ~100 hours of work remaining**

## Next Steps for Examples

**DO NOT update examples yet!** The migration is incomplete. Wait until:

1. All source files are migrated
2. All tests pass in all apps
3. Inter-app communication is fully implemented
4. The monolithic `lib/` directory can be removed

## How to Verify Migration is Complete

Run these commands and ensure they all pass:

```bash
# Each app should compile without warnings
cd apps/parrot_transport && mix compile --warnings-as-errors
cd apps/parrot_media && mix compile --warnings-as-errors
cd apps/parrot_sip && mix compile --warnings-as-errors

# All tests should pass
cd apps/parrot_transport && mix test
cd apps/parrot_media && mix test
cd apps/parrot_sip && mix test

# No cross-app dependencies should exist
cd apps/parrot_transport && mix xref graph # Should show no ParrotSip or ParrotMedia
cd apps/parrot_media && mix xref graph # Should show no ParrotSip or ParrotTransport
cd apps/parrot_sip && mix xref graph # Should show no ParrotTransport or ParrotMedia

# Integration tests should pass
mix test test/integration

# SIPp tests should pass
mix test.sipp
```

## Current State Summary

**⚠️ WARNING: The migration is NOT ready for use!**

Only the basic umbrella structure exists. The actual functionality has NOT been migrated. Do not attempt to use the apps or update examples yet.