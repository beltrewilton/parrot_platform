# Quickstart: RFC 2833/4733 Telephone-Event Parser

**Branch**: `003-telephone-event-parser` | **Date**: 2026-01-09

## What This Does

Detects DTMF digits (0-9, *, #, A-D) from RFC 4733 telephone-event RTP packets and sends notifications to your Membrane pipeline.

## Installation

The element lives in `parrot_media` - no additional dependencies required.

## Basic Usage

### 1. Add to Your Pipeline

```elixir
def handle_init(_ctx, opts) do
  spec = [
    # ... your RTP source ...
    |> child(:dtmf_parser, %ParrotMedia.Elements.TelephoneEventParser{
      payload_type: 101  # From SDP negotiation
    })
    |> child(:audio_decoder, ...)
  ]

  {[spec: spec], %{}}
end
```

### 2. Handle DTMF Notifications

```elixir
def handle_child_notification({:dtmf, digit}, :dtmf_parser, _ctx, state) do
  IO.puts("User pressed: #{digit}")
  {[], state}
end
```

## Configuration

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `payload_type` | integer | Yes | RTP payload type for telephone-event (typically 96-127, commonly 101) |

## Notification Format

```elixir
{:dtmf, digit}
```

Where `digit` is one of: `"0"`, `"1"`, `"2"`, `"3"`, `"4"`, `"5"`, `"6"`, `"7"`, `"8"`, `"9"`, `"*"`, `"#"`, `"A"`, `"B"`, `"C"`, `"D"`

## Example: Collecting PIN

```elixir
defmodule MyPipeline do
  use Membrane.Pipeline

  def handle_init(_ctx, %{telephone_event_pt: pt}) do
    spec = [
      # ... pipeline spec with TelephoneEventParser ...
    ]
    {[spec: spec], %{collected_digits: "", expecting: 4}}
  end

  def handle_child_notification({:dtmf, digit}, :dtmf_parser, _ctx, state) do
    digits = state.collected_digits <> digit

    if String.length(digits) >= state.expecting do
      IO.puts("PIN entered: #{digits}")
      # Validate PIN, continue call flow...
      {[], %{state | collected_digits: ""}}
    else
      {[], %{state | collected_digits: digits}}
    end
  end
end
```

## Payload Type from SDP

The telephone-event payload type is negotiated in SDP. Look for:

```
m=audio 5004 RTP/AVP 0 101
a=rtpmap:101 telephone-event/8000
a=fmtp:101 0-15
```

In this example, payload type is `101`.

## Testing

```bash
# Run unit tests
mix test apps/parrot_media/test/parrot_media/elements/telephone_event_parser_test.exs

# Run integration tests
mix test apps/parrot_media/test/parrot_media/elements/telephone_event_parser_integration_test.exs
```

## Debugging

Enable debug logging to see parsed events:

```bash
LOG_LEVEL=debug mix test
```

## Key Behaviors

- **Pass-through**: All RTP packets flow through unchanged
- **One notification per digit**: Retransmitted packets are deduplicated
- **Long presses**: Handled correctly (one notification when key released)
- **Mixed traffic**: Only parses packets matching configured payload_type
