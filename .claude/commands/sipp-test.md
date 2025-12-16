---
name: /sipp-test
description: Run SIPp integration tests for a specific scenario
---

# SIPp Integration Test Runner

Run SIPp integration tests for specific scenarios or test files.

## Usage

```bash
# Run all SIPp tests
mix test --only sipp

# Run specific test file
mix test test/sipp/client_test.exs --only sipp

# Run specific test line
LOG_LEVEL=info mix test test/sipp/client_test.exs:LINE --only sipp

# With debug logging and SIP trace
LOG_LEVEL=debug SIP_TRACE=true mix test test/sipp/client_test.exs:LINE --only sipp
```

## Common Test Locations

**Client Tests** (`test/sipp/client_test.exs`):
- Basic INVITE: line 33
- CANCEL scenario: line 378
- OPTIONS request: line 115
- REGISTER: line 433

**UA Tests** (`test/sipp/ua_test.exs`):
- Outbound call with answer: line 109
- Outbound call with 180 Ringing: line 143
- Outbound call rejected 486: line 164
- Cancel before answer: line 186
- Incoming call auto-answer: line 245
- Incoming then BYE: line 264

## Troubleshooting

If tests fail:
1. Check SIPp is installed: `sipp -v`
2. Review SIP messages: Add `SIP_TRACE=true`
3. Check timing: SIPp scenarios have pause windows
4. See error logs in terminal output
