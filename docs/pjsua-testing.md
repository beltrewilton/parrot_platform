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
