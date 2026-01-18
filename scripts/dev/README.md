# Development Scripts

Ad-hoc test scripts for manual testing and debugging. These are **not** official examples or automated tests.

## Scripts

### test_answer_play.exs
Simple answer and play test - answers calls and plays `priv/audio/parrot-welcome.wav`.

```bash
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_answer_play.exs
```

### test_dtmf_dsl.exs
DTMF test server using the high-level Parrot DSL (InviteHandler, Router, Bridge.Handler).

```bash
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_dtmf_dsl.exs
```

### test_dtmf_server.exs
DTMF test server using low-level SIP/media primitives (DTMFTestHandler, SipStackHelper).

```bash
SIP_TRACE=true LOG_LEVEL=debug mix run scripts/dev/test_dtmf_server.exs
```

## Testing

Call the server with a SIP client:
```bash
pjsua sip:test@127.0.0.1:5080
# or
gophone dial sip:test@127.0.0.1:5080
```

Then send DTMF digits to see them collected.
