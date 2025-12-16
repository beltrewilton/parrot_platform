---
name: /review-rfc
description: Check SIP implementation against RFC 3261 compliance
---

# RFC 3261 Compliance Review

Review code changes for RFC 3261 compliance and best practices.

## Review Checklist

1. **Read the implementation**
   - Understand what the code does
   - Identify the SIP mechanism being implemented

2. **Check RFC references**
   - All transaction code must reference RFC 3261 sections
   - Dialog code must reference RFC 3261 Section 12
   - Timer values must match RFC specifications exactly

3. **Cross-reference RFC text**
   - Read the relevant RFC 3261 section
   - Verify behavior matches RFC requirements
   - Check edge cases mentioned in RFC

4. **Verify timer values**
   - Timer A: 500ms (INVITE request retransmit)
   - Timer B: 64*T1 (32s - INVITE transaction timeout)
   - Timer D: 32s+ (response retransmit wait time)
   - Timer E: 500ms (non-INVITE request retransmit)
   - Timer F: 64*T1 (32s - non-INVITE timeout)
   - Timer G: 500ms (INVITE response retransmit)
   - Timer H: 64*T1 (32s - ACK wait time)
   - Timer I: 4s or 0s (ACK retransmit wait)
   - Timer J: 64*T1 or 0s (non-INVITE response wait)
   - Timer K: 5s or 0s (response retransmit wait)

5. **State machine validation**
   - Check state transitions match RFC diagrams
   - Verify all states are reachable
   - Ensure proper error handling

6. **Suggest improvements**
   - Edge cases not handled
   - Additional timer scenarios
   - Error conditions from RFC

## Key RFC 3261 Sections

- **Section 17**: Transactions
- **Section 17.1**: Client Transaction
- **Section 17.2**: Server Transaction
- **Section 12**: Dialogs
- **Section 8**: Registration
- **Section 13**: Initiating a Session
- **Section 15**: Terminating a Session

## Example Review

```elixir
# Good: RFC reference present
def trying(:cast, {:received, msg}, state) do
  # RFC 3261 Section 17.1.1.2: INVITE Client Transaction
  # Upon receiving 1xx response, transition to proceeding
  ...
end

# Bad: No RFC reference
def trying(:cast, {:received, msg}, state) do
  # Handle 1xx response
  ...
end
```
