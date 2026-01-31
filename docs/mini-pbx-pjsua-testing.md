# Mini PBX Testing with pjsua

A hands-on guide for running the Mini PBX example and testing calls, registration, presence, and transfers using pjsua.

## Prerequisites

### Install pjsua

```bash
brew install pjsip
```

### Verify Installation

```bash
pjsua --help
```

## Quick Reference

| Feature | Extension/URI | Credentials |
|---------|--------------|-------------|
| Registration | 1001-1010 | password = extension (e.g., 1001/1001) |
| Auto-attendant | 100 | No auth needed |
| Internal calls | 1xxx | Must be registered |
| Outbound PSTN | 9 + number | Must be registered |
| Voicemail | *86 | PIN = extension |

---

## Step 1: Start Mini PBX

The Mini PBX is a standalone application. Start it by navigating to its directory:

```bash
cd examples/parrot_mini_pbx
iex -S mix
```

You should see:
```
Mini PBX running on port 5060
```

### Custom Port

Use a different port with the PORT environment variable:

```bash
PORT=5070 iex -S mix
```

### Debug Logging

Enable debug logs with:

```bash
LOG_LEVEL=debug iex -S mix
```

### SIP Packet Tracing

Enable SIP packet tracing with:

```bash
SIP_TRACE=true iex -S mix
```

Or combine options:

```bash
PORT=5070 LOG_LEVEL=debug SIP_TRACE=true iex -S mix
```

### Useful Commands in IEx

```elixir
# Check the port
ParrotMiniPbx.get_port()

# List all registrations
ParrotMiniPbx.registrations()

# Clear all data (registrations, voicemails, etc.)
ParrotMiniPbx.clear_all()

# Direct storage access
alias Parrot.Examples.MiniPBX.Storage
Storage.lookup_extension("1001")
```

---

## Step 2: Register Extensions

### Terminal 1: Extension 1001 (Alice)

```bash
pjsua \
  --null-audio \
  --no-tcp \
  --local-port=5090 \
  --registrar="sip:127.0.0.1:5060" \
  --id="sip:1001@pbx.local" \
  --realm="*" \
  --username="1001" \
  --password="1001"
```

You should see:
```
Registration: code=200 OK
```

### Terminal 2: Extension 1002 (Bob)

```bash
pjsua \
  --null-audio \
  --no-tcp \
  --local-port=5091 \
  --registrar="sip:127.0.0.1:5060" \
  --id="sip:1002@pbx.local" \
  --realm="*" \
  --username="1002" \
  --password="1002"
```

### Verify Registrations (in IEx)

```elixir
# Check if 1001 is registered
ParrotMiniPbx.registrations()
# => [%{aor: "sip:1001@pbx.local", contact: "sip:1001@127.0.0.1:5090", expires: 3600}]

# Or direct lookup
alias Parrot.Examples.MiniPBX.Storage
Storage.lookup_extension("1001")
# => {:ok, "sip:1001@127.0.0.1:5090"}
```

---

## Step 3: Make Calls

### Call the Auto-Attendant (100)

From Alice's terminal (1001), type:

```
m
sip:100@127.0.0.1:5060
```

This calls the IVR. You'll hear (once media is set up):
- Welcome message
- Menu: Press 1 for Sales, 2 for Support, 0 for Operator

### Extension-to-Extension Call (1001 → 1002)

From Alice's terminal:

```
m
sip:1002@127.0.0.1:5060
```

Bob's phone rings. In Bob's terminal, answer with:
```
a
```

To hang up (either terminal):
```
h
```

### Outbound PSTN Call (dial 9 + number)

From Alice's terminal:

```
m
sip:91234567890@127.0.0.1:5060
```

This routes to configured PSTN carriers. The PBX will attempt to connect via:
1. carrier1.example.com (priority 1)
2. carrier2.example.com (priority 2)

---

## Step 4: Presence (BLF)

### Subscribe to Presence

From Alice's terminal, subscribe to Bob's presence:

```
# In pjsua, use the su command (may need custom setup)
```

Or programmatically in IEx:

```elixir
alias Parrot.Examples.MiniPBX.Storage

# Set Bob's presence to available
Storage.set_presence_state("sip:1002@pbx.local", :available)

# Check Bob's presence
Storage.get_presence_state("sip:1002@pbx.local")
# => {:ok, :available}

# Change to busy (e.g., when on a call)
Storage.set_presence_state("sip:1002@pbx.local", :busy)

# Or DND
Storage.set_presence_state("sip:1002@pbx.local", :dnd)
```

### Presence States

| State | Description | BLF Color |
|-------|-------------|-----------|
| `:available` | Ready for calls | Green |
| `:busy` | On a call | Red |
| `:dnd` | Do Not Disturb | Red blinking |
| `:offline` | Not registered | Off |

---

## Step 5: Transfers

### Blind Transfer

During an active call from Alice to Bob, Alice can transfer Bob to another extension:

```
# In pjsua during active call
xfer sip:1003@127.0.0.1:5060
```

This sends a REFER request to transfer the call.

### Attended Transfer

1. Alice calls Bob
2. Alice puts Bob on hold: `H` (capital H for hold)
3. Alice calls Carol: `m` then `sip:1003@127.0.0.1:5060`
4. Alice connects Bob and Carol: `X` (capital X for attended transfer)

---

## Step 6: DTMF Testing

### Send DTMF During Call

While in an active call:

```
# Switch to DTMF mode (RFC 2833)
#

# Then type digits
1234

# Or single digit
1
```

### Scripted DTMF (for automation)

```bash
(
  sleep 4          # Wait for call to connect
  echo "m"         # Make call
  echo "sip:100@127.0.0.1:5060"
  sleep 2          # Wait for answer
  echo "#"         # Enter DTMF mode
  sleep 0.5
  echo "1"         # Press 1 for Sales
  sleep 5
  echo "h"         # Hangup
  sleep 1
  echo "q"         # Quit
) | pjsua --null-audio --no-tcp --local-port=5095 \
    --registrar="sip:127.0.0.1:5060" \
    --id="sip:1001@pbx.local" \
    --realm="*" \
    --username="1001" \
    --password="1001"
```

---

## Step 7: Voicemail

### Access Voicemail

Dial *86 to access voicemail:

```
m
sip:*86@127.0.0.1:5060
```

Enter your PIN when prompted (PIN = extension number).

### Controls

- `1` - Listen to message
- `7` - Delete message
- `9` - Save and next
- `*` - Repeat message

### Store a Test Voicemail (IEx)

```elixir
alias Parrot.Examples.MiniPBX.Storage
Storage.store_voicemail("1001", "sip:1002@pbx.local", "/tmp/voicemail-1.wav")
Storage.get_voicemails("1001")
```

---

## Useful pjsua Commands

| Command | Description |
|---------|-------------|
| `m` | Make a call |
| `a` | Answer incoming call |
| `h` | Hangup current call |
| `H` | Hold/unhold current call |
| `#` | Send RFC 2833 DTMF |
| `*` | Send SIP INFO DTMF |
| `xfer <uri>` | Blind transfer |
| `X` | Attended transfer |
| `d` | Dump call status |
| `dd` | Dump detailed status |
| `q` | Quit pjsua |

---

## Debug Tips

### Enable SIP Tracing

Start the Mini PBX with:
```bash
SIP_TRACE=true iex -S mix
```

### View Registrations

```elixir
ParrotMiniPbx.registrations()
```

### Clear All Data

```elixir
ParrotMiniPbx.clear_all()
```

### Check Active Subscriptions

```elixir
alias Parrot.Examples.MiniPBX.Storage
Storage.get_subscriptions("sip:1002@pbx.local")
```

### pjsua Logging

```bash
pjsua --log-file=/tmp/pjsua.log --log-level=5 ...
```

View important entries:
```bash
grep -i "register\|invite\|200 OK\|401\|dtmf" /tmp/pjsua.log
```

---

## Common Issues

### "Registration failed: 401 Unauthorized"

- Check username/password match (password = extension number)
- Ensure `--realm="*"` is set
- Verify the extension is in the 1001-1010 range

### "404 Not Found" on calls

- The called extension is not registered
- Internal calls (1xxx) require source IP from 192.168.0.0/16 subnet
  - For localhost testing, the router may reject based on IP scope
- Check `Storage.lookup_extension("1001")` returns a contact

### No audio during calls

- Mini PBX requires media pipeline setup (see note below)
- Use `--null-audio` to skip actual audio
- Audio files referenced (welcome.wav, etc.) need to exist

### Port conflicts

- Change `--local-port` to different values for each pjsua instance
- Ensure port 5060 is available for Mini PBX
- Use `PORT=5070` environment variable to change Mini PBX port

---

## Architecture Reference

```
┌─────────────────────────────────────────────────────────────┐
│                      Mini PBX Router                        │
├─────────────────────────────────────────────────────────────┤
│  REGISTER  →  Registration Handler (digest auth)           │
│  SUBSCRIBE →  Presence Handler (BLF)                        │
├─────────────────────────────────────────────────────────────┤
│  Scope: 192.168.0.0/16 (authenticated)                      │
│    1xxx → Extensions Handler (internal calls)               │
│    9xxx → Outbound Handler (PSTN via carriers)              │
├─────────────────────────────────────────────────────────────┤
│  Global:                                                     │
│    100  → AutoAttendant Handler (IVR)                       │
│    *86  → Voicemail Handler                                  │
└─────────────────────────────────────────────────────────────┘

Storage (Mnesia):
  - Registrations: AOR → Contact mappings
  - Presence: Extension status (available/busy/dnd/offline)
  - Subscriptions: BLF watchers
  - Voicemail: Messages per extension
```

---

## Running the Full Test Suite

```bash
# All Mini PBX SIPp tests
mix test apps/parrot/test/sipp/mini_pbx_test.exs --include sipp

# Presence tests
mix test apps/parrot/test/sipp/mini_pbx_presence_test.exs --include sipp

# With debug output
LOG_LEVEL=debug SIP_TRACE=true mix test apps/parrot/test/sipp/mini_pbx_test.exs --include sipp
```

---

## Note on Media

The Mini PBX uses audio prompts (welcome.wav, main-menu.wav, etc.) for IVR. For full audio playback:

1. Place WAV files in the configured audio directory
2. Configure the media pipeline with appropriate devices
3. For testing without audio, focus on SIP signaling tests

The current test suite skips media-heavy tests (marked with `@tag skip: "requires full media pipeline"`).
