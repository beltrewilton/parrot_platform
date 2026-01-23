# Ad-hoc SIP Testing with pjsua

pjsua is a command-line SIP client useful for testing when SIPp scenarios are insufficient (e.g., DTMF on macOS where SIPp can't use raw sockets).

## Install

```bash
brew install pjsip
```

## Basic Call Test

```bash
# Make call via UDP, null audio (no microphone needed)
pjsua --null-audio --no-tcp "sip:test@127.0.0.1:5080;transport=udp"
```

## Send DTMF During Call

Use a subshell to pipe commands after connection:

```bash
(
  sleep 4          # Wait for call to connect
  echo "#"         # Enter DTMF mode (RFC 2833)
  sleep 0.5
  echo "1234"      # Send digits
  sleep 6          # Let call run
  echo "h"         # Hangup
  sleep 1
  echo "q"         # Quit
) | pjsua --null-audio --no-tcp --local-port=5090 \
    "sip:test@127.0.0.1:5080;transport=udp"
```

## Key Options

| Option | Purpose |
|--------|---------|
| `--null-audio` | No microphone/speaker (headless testing) |
| `--no-tcp` | Force UDP only |
| `--local-port=PORT` | Set local SIP port (avoid conflicts) |
| `--log-file=FILE` | Save detailed logs |
| `transport=udp` | In URI, forces UDP transport |

## Interactive Commands

Once connected:
- `#` - Send RFC 2833 DTMF (then enter digits)
- `*` - Send DTMF via SIP INFO
- `h` - Hangup current call
- `d` - Dump call status
- `q` - Quit

## Example Test Server

```bash
# Start Parrot DTMF test server
LOG_LEVEL=debug mix run test_dtmf_server.exs
```

## Debugging

Check logs for:
- `CONFIRMED` - Call connected
- `Sending DTMF digit id X` - pjsua sending DTMF
- Server should show `DTMF digit detected: X`

```bash
# View pjsua log
grep -i "dtmf\|confirmed\|state changed" /tmp/pjsua.log
```

## Registration Testing

Test SIP REGISTER flows with digest authentication.

### Start the Registrar Server

```bash
# Simple registrar (no presence)
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_registrar.exs

# Registrar with presence integration
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_registrar_presence.exs

# Using orchestration script (recommended - includes logging setup)
./scripts/dev/test_registrar_with_pjsua.sh
```

### Register a User

```bash
# Register alice (credentials: alice / secret123)
pjsua --null-audio --no-tcp --local-port=5090 \
  --id="sip:alice@127.0.0.1" \
  --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="alice" --password="secret123"

# Register bob (credentials: bob / secret456)
pjsua --null-audio --no-tcp --local-port=5091 \
  --id="sip:bob@127.0.0.1" \
  --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="bob" --password="secret456"
```

### Registration Options

| Option | Purpose |
|--------|---------|
| `--id=URI` | SIP identity (AOR) |
| `--registrar=URI` | Registrar server address |
| `--realm="*"` | Accept any authentication realm |
| `--username=NAME` | Authentication username |
| `--password=SECRET` | Authentication password |
| `--reg-timeout=SEC` | Registration expiry (default 300) |

### Expected Registration Flow

1. pjsua sends REGISTER (no credentials)
2. Server responds 401 Unauthorized with WWW-Authenticate
3. pjsua sends REGISTER with Authorization header
4. Server validates credentials, responds 200 OK

### Interactive Registration Commands

Inside pjsua console:

| Command | Action |
|---------|--------|
| `ru` | Unregister (send REGISTER with expires=0) |
| `rr` | Re-register |
| `Lr` | Show registration status |

### Registration with Logging

```bash
pjsua --null-audio --no-tcp --local-port=5090 \
  --log-file=/tmp/pjsua_alice.log --log-level=5 \
  --id="sip:alice@127.0.0.1" \
  --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="alice" --password="secret123"
```

### Verify Registration in Logs

```bash
# Check for successful registration
grep -i "registration success\|200 OK" /tmp/pjsua_alice.log

# Check for auth challenge
grep -i "401\|WWW-Authenticate" /tmp/pjsua_alice.log
```

## Presence Testing

Test SUBSCRIBE/NOTIFY presence flows.

### Setup: Two Registered Users

Terminal 1 - Start server:
```bash
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_registrar_presence.exs
```

Terminal 2 - Register Alice:
```bash
pjsua --null-audio --no-tcp --local-port=5090 \
  --id="sip:alice@127.0.0.1" --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="alice" --password="secret123"
```

Terminal 3 - Register Bob:
```bash
pjsua --null-audio --no-tcp --local-port=5091 \
  --id="sip:bob@127.0.0.1" --registrar="sip:127.0.0.1:5080" \
  --realm="*" --username="bob" --password="secret456"
```

### Subscribe to Presence

In Bob's pjsua console:

```
>>> +b sip:alice@127.0.0.1    # Add Alice as buddy
>>> s                          # Subscribe to all buddy presence
```

### Presence Commands

| Command | Action |
|---------|--------|
| `+b URI` | Add buddy |
| `-b INDEX` | Remove buddy |
| `bl` | List buddies |
| `s` | Subscribe to buddy presence |
| `u` | Unsubscribe from buddy presence |
| `t` | Toggle online status |
| `T` | Show presence status |

### Test Presence State Changes

1. In Bob's console, subscribe to Alice: `+b sip:alice@127.0.0.1` then `s`
2. In Alice's console, unregister: `ru`
   - Bob receives NOTIFY: Alice offline
3. In Alice's console, re-register: `rr`
   - Bob receives NOTIFY: Alice available

### Expected Presence Flow

```
Bob -> Server: SUBSCRIBE sip:alice@...
Server -> Bob: 200 OK
Server -> Bob: NOTIFY (initial state - Alice available)

[Alice unregisters with 'ru']
Server -> Bob: NOTIFY (Alice offline)

[Alice re-registers with 'rr']
Server -> Bob: NOTIFY (Alice available)
```

### Verify Presence in Logs

```bash
# Check for SUBSCRIBE handling
grep -i "SUBSCRIBE\|NOTIFY" server.log

# Check Bob received NOTIFY
grep -i "NOTIFY\|presence\|buddy" /tmp/pjsua_bob.log
```

## Combined Test Workflow

```bash
# 1. Use orchestration script for full logging
./scripts/dev/test_registrar_with_pjsua.sh

# 2. Follow the printed pjsua commands
# 3. Test registration flow (automatic on pjsua start)
# 4. Test presence (add buddy, subscribe, unregister/re-register)
# 5. Examine logs in the timestamped logs/ directory
```

## Test Users

The dev registrar scripts provide these test accounts:

| Username | Password |
|----------|----------|
| alice | secret123 |
| bob | secret456 |
