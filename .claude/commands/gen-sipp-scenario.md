---
name: /gen-sipp-scenario
description: Generate new SIPp XML scenario file
---

# SIPp Scenario Generator

Generate SIPp XML scenario files based on description.

## Process

1. **Ask for scenario description**
   - UAC (client) or UAS (server) scenario?
   - What messages should be exchanged?
   - Any timing requirements?
   - Expected responses?

2. **Generate XML following existing patterns**
   - Check `test/sipp/scenarios/` for examples
   - Use proper SIPp XML structure
   - Include necessary attributes

3. **Add timing with pause elements**
   - Use `<pause milliseconds="N"/>` for delays
   - Required for CANCEL scenarios (wait after 180)
   - Prevents race conditions

4. **Suggest corresponding Elixir test**
   - Show how to call the scenario
   - Include assertion patterns
   - Reference similar existing tests

## SIPp Scenario Structure

```xml
<?xml version="1.0" encoding="ISO-8859-1"?>
<scenario name="Scenario Name">
  <!-- UAS: Receive request -->
  <recv request="INVITE" />

  <!-- Send response -->
  <send>
    <![CDATA[
      SIP/2.0 200 OK
      [last_Via:]
      [last_From:]
      [last_To:];tag=[call_number]
      [last_Call-ID:]
      [last_CSeq:]
      Contact: <sip:[local_ip]:[local_port];transport=[transport]>
      Content-Length: 0

    ]]>
  </send>

  <!-- Optional: Pause -->
  <pause milliseconds="100"/>

  <!-- UAC: Receive ACK -->
  <recv request="ACK" />
</scenario>
```

## Common Scenario Types

**Basic UAS (server):**
- `test/sipp/scenarios/basic/uas_invite.xml` - Answer with 180 then 200
- `test/sipp/scenarios/basic/uas_bye.xml` - Answer then wait for BYE
- `test/sipp/scenarios/basic/uas_options.xml` - Respond to OPTIONS

**Basic UAC (client):**
- `test/sipp/scenarios/basic/uac_invite.xml` - Send INVITE, expect 200
- `test/sipp/scenarios/basic/uac_bye.xml` - Send INVITE, answer, send BYE

**Cancel:**
- `test/sipp/scenarios/cancel/uas_cancel.xml` - Send 180, expect CANCEL

**Error:**
- `test/sipp/scenarios/basic/uas_busy.xml` - Reject with 486

## SIPp Keywords

- `[last_Via:]` - Copy Via from request
- `[last_From:]` - Copy From from request
- `[last_To:]` - Copy To from request
- `[last_Call-ID:]` - Copy Call-ID
- `[last_CSeq:]` - Copy CSeq
- `[call_number]` - Unique call number
- `[local_ip]` - SIPp local IP
- `[local_port]` - SIPp local port
- `[transport]` - Transport protocol

## Example Test Code

```elixir
test "description of scenario" do
  sipp_port = random_port()
  local_port = random_port()

  # Start SIPp UAS
  sipp_task = start_sipp_uas("path/to/scenario.xml", sipp_port)

  # Your test code here
  {:ok, ua} = UA.start_link(TestHandler, self(), port: local_port)
  # ...

  # Verify SIPp completed
  assert :ok = Task.await(sipp_task, 10_000)
end
```
