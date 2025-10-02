# Parrot Platform Implementation Guide

## Project Overview

Parrot Platform is a complete, production-ready SIP (Session Initiation Protocol) implementation written in pure Elixir/OTP. This is **NOT a prototype or MVP** - it is a complete RFC-compliant implementation with no shortcuts, TODOs that say "for now", or deferred functionality.

## Core Philosophy

### 1. Complete Implementation - No Shortcuts

**NEVER** write code with comments like:
- "For now, we..."
- "A more complete implementation would..."
- "TODO: implement this properly later"
- "Let the handler/user decide..."

If the RFC specifies behavior, implement it completely. If the library should handle something per the specification, the library handles it - don't defer to the user unless it's explicitly meant to be user-configurable.

**Example of what NOT to do:**
```elixir
# BAD - Don't do this!
def process_cancel(cancel_msg) do
  # For now, we allow the handler to decide whether to honor the CANCEL
  # A more complete implementation would check dialog state
  Handler.uas_cancel(cancel_msg, handler)
end
```

**Example of correct approach:**
```elixir
# GOOD - Complete RFC 3261 Section 9.2 implementation
def process_cancel(cancel_msg, trans, handler) do
  case DialogStatem.uas_find(cancel_msg) do
    {:ok, dialog_pid} ->
      dialog_state = get_dialog_state(dialog_pid)

      case dialog_state do
        :confirmed ->
          # RFC 3261: CANCEL cannot cancel confirmed dialog
          resp = Message.reply(cancel_msg, 481, "Call/Transaction Does Not Exist")
          TransactionStatem.server_response(resp, trans)

        :early ->
          # Early dialog - CANCEL is valid
          Handler.uas_cancel({:uas_id, trans}, handler)
      end

    :not_found ->
      # No dialog - normal CANCEL
      Handler.uas_cancel({:uas_id, trans}, handler)
  end
end
```

### 2. RFC Compliance is Mandatory

Every behavior must follow the relevant RFCs:
- **RFC 3261** - SIP: Session Initiation Protocol (primary specification)
- **RFC 3262** - Reliability of Provisional Responses in SIP
- **RFC 3263** - SIP: Locating SIP Servers
- **RFC 3265** - SIP-Specific Event Notification
- **RFC 4566** - SDP: Session Description Protocol

When implementing a feature, cite the RFC section in comments and implement it completely.

### 3. Elixir/OTP Idioms

#### Use OTP Behaviors Correctly

- **GenServer**: For stateful processes that handle synchronous/asynchronous calls
- **gen_statem**: For complex state machines (dialogs, transactions)
- **DynamicSupervisor**: For dynamically created processes (transactions, dialogs)
- **Registry**: For process discovery and pub/sub

**Example - Transaction State Machine:**
```elixir
defmodule ParrotSip.TransactionStatem do
  @behaviour :gen_statem

  @impl :gen_statem
  def callback_mode, do: :state_functions

  # Separate function for each state
  def trying({:call, from}, {:send_response, resp}, data) do
    # Handle event in trying state
    {:next_state, :proceeding, data, [{:reply, from, :ok}]}
  end

  def proceeding({:call, from}, {:send_response, resp}, data) do
    # Handle event in proceeding state
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end
end
```

#### Pattern Matching and Guards

Use pattern matching extensively, especially in function heads:

```elixir
# Match on message type and status code
def process_response(%Message{type: :response, status_code: code}, data)
    when code >= 200 and code < 300 do
  # Success response
end

def process_response(%Message{type: :response, status_code: code}, data)
    when code >= 300 do
  # Failure response
end
```

#### Data Structures

Use structs with proper typespecs:

```elixir
defmodule ParrotSip.Message do
  @type t :: %__MODULE__{
          method: atom() | nil,
          request_uri: String.t() | nil,
          status_code: integer() | nil,
          via: [Via.t()],
          from: From.t() | nil,
          to: To.t() | nil,
          call_id: String.t() | nil,
          cseq: CSeq.t() | nil
        }

  defstruct [
    :method,
    :request_uri,
    :status_code,
    via: [],  # ALWAYS initialize collections as empty
    :from,
    :to,
    :call_id,
    :cseq
  ]
end
```

**Key principle**: Collections like `via` should ALWAYS be initialized as empty lists `[]`, never `nil`. This makes pattern matching cleaner and prevents nil errors.

#### Process Supervision Trees

Organize supervision properly:

```
ParrotSip.Application
├── ParrotSip.Registry (Registry)
├── ParrotSip.Transaction.Supervisor (DynamicSupervisor)
│   └── ParrotSip.TransactionStatem (gen_statem, :temporary restart)
└── ParrotSip.Dialog.Supervisor (DynamicSupervisor)
    └── ParrotSip.DialogStatem (gen_statem, :temporary restart)
```

- Use `:temporary` restart strategy for transactions and dialogs (they're ephemeral)
- Use Registry with `{:via, Registry, {ParrotSip.Registry, id}}` for process registration

### 4. Code Organization

#### Separation of Concerns

**Clear boundaries between modules:**

- **parrot_sip**: SIP protocol logic ONLY
  - Message parsing/serialization
  - Transaction state machines
  - Dialog state machines
  - SIP headers and URIs

- **parrot_transport**: Transport layer (UDP, TCP, TLS, SCTP)
  - Socket management
  - Connection framing
  - Transport-level error handling

- **parrot_media**: RTP/RTCP media handling
  - RTP packet processing
  - Media streams
  - Codec negotiation

**Never mix concerns.** For example, ParrotSip should NEVER handle TCP framing or socket management - that belongs in ParrotTransport.

#### Pure Functions vs. Stateful Processes

Separate pure functional logic from stateful process logic:

```elixir
# Pure functional module
defmodule ParrotSip.Dialog do
  @moduledoc """
  Pure functional operations on Dialog structs.
  No side effects, no process state.
  """

  @spec uas_create(Message.t(), Message.t()) :: {:ok, t()} | {:error, term()}
  def uas_create(req_msg, resp_msg) do
    # Pure function - just transforms data
  end
end

# Stateful process module
defmodule ParrotSip.DialogStatem do
  @moduledoc """
  Stateful dialog state machine using gen_statem.
  Manages dialog lifecycle as a process.
  """
  @behaviour :gen_statem

  # Delegates pure operations to Dialog module
  def early({:call, from}, {:uas_request, req}, data) do
    {:ok, updated_dialog} = Dialog.uas_process(req, data.dialog)
    {:next_state, :confirmed, %{data | dialog: updated_dialog}}
  end
end
```

### 5. Testing Strategy

#### Comprehensive Test Coverage

- **Unit tests** for all pure functions
- **Integration tests** for state machines and processes
- **Property-based tests** for protocol compliance (when appropriate)
- **Doctests** for simple examples in module documentation

Current status: **1,020 tests, all passing**

#### Test Organization

```elixir
defmodule ParrotSip.MessageTest do
  use ExUnit.Case, async: true  # Pure functions can run async

  describe "new_request/3" do
    test "creates request with empty Via header list" do
      msg = Message.new_request(:invite, "sip:alice@example.com")
      assert msg.via == []
      assert msg.method == :invite
    end
  end
end

defmodule ParrotSip.DialogStatemTest do
  use ExUnit.Case, async: false  # State machines need sync

  setup do
    # Clean up registry before each test
    Registry.unregister_match(ParrotSip.Registry, :_, :_)
    :ok
  end

  test "dialog transitions from early to confirmed on 200 OK" do
    # Test state machine behavior
  end
end
```

### 6. Error Handling

#### Let It Crash (for unexpected errors)

```elixir
# Don't try/catch for logic errors - let it crash
def process_request(msg) do
  # This will crash if msg.via is nil - that's a bug, fix it
  [top_via | _] = msg.via
  # ...
end
```

#### Return {:ok, result} | {:error, reason} for Expected Failures

```elixir
@spec validate_message(Message.t()) :: {:ok, Message.t()} | {:error, String.t()}
def validate_message(message) do
  with :ok <- validate_via_header(message),
       :ok <- validate_cseq_header(message),
       :ok <- validate_call_id_header(message) do
    {:ok, message}
  end
end
```

#### Send Proper SIP Error Responses

```elixir
# When handling invalid SIP messages, return proper SIP error responses
def uas_request(%Message{via: []} = msg) do
  resp = Message.reply(msg, 400, "Missing Via header")
  {:reply, resp}
end

def uas_request(%Message{max_forwards: 0} = msg) do
  resp = Message.reply(msg, 483, "Too Many Hops")
  {:reply, resp}
end
```

### 7. Documentation Standards

#### Module Documentation

Every module needs:
1. High-level description
2. RFC references
3. State diagrams (for state machines)
4. Usage examples
5. Implementation notes

```elixir
defmodule ParrotSip.DialogStatem do
  @moduledoc """
  SIP Dialog State Machine Implementation

  Implements RFC 3261 Section 12 - Dialogs using Erlang's `:gen_statem` behavior.

  ## RFC 3261 Section 12 - Dialogs

  A dialog represents a peer-to-peer SIP relationship between two user agents.

  Dialog states per RFC 3261:
  - **Early**: Created by provisional (1xx) responses
  - **Confirmed**: Established by 2xx responses
  - **Terminated**: Dialog has ended

  ## State Machine Diagram

  ```
               INVITE Request/Response
                       |
                       v
             +------------------+
             |      :early      |<----+ 1xx response
             +------------------+     |
               |              |       |
       2xx     |              +-------+
     response  |
               v
             +------------------+
             |   :confirmed     |
             +------------------+
               |
       BYE     |
     or error  |
               v
             +------------------+
             |  :terminated     |
             +------------------+
  ```

  ## References

  - RFC 3261 Section 12: Dialogs
  - RFC 3261 Section 12.1: Creation of a Dialog
  """
```

#### Function Documentation

Include:
- Purpose
- Parameters with types
- Return values
- RFC references
- Examples

```elixir
@doc """
Creates a response for a SIP request.

## Parameters
- `request` - Original SIP request message
- `status_code` - HTTP-style status code (100-699)
- `reason_phrase` - Human-readable reason

## Returns
- Response message with proper headers copied from request

## RFC References
- RFC 3261 Section 8.2.6: Generating the Response

## Example
    iex> request = Message.new_request(:invite, "sip:bob@example.com")
    iex> response = Message.reply(request, 200, "OK")
    iex> response.status_code
    200
"""
@spec reply(t(), integer(), String.t()) :: t()
def reply(request, status_code, reason_phrase) do
  # Implementation
end
```

### 8. Git Commit Guidelines

#### Small, Focused Commits

Each commit should:
- Do ONE thing
- Have a clear, concise message (one-liner preferred)
- Pass all tests
- Be reviewable in isolation

**Good commits:**
```
Remove unused ParrotSip.Connection module - transport framing belongs in ParrotTransport
Implement RFC 3261 Section 9.2 compliant CANCEL handling
Make transaction debug logging configurable via options or application env
```

**Bad commits:**
```
WIP various fixes
Update code
Fix bugs and add features
```

#### Commit Message Format

```
<imperative verb> <what> - <why if not obvious>

Detailed explanation if needed (optional).
Can reference RFC sections.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

### 9. Performance Considerations

#### Avoid Premature Optimization

- Correctness first, performance second
- Profile before optimizing
- Use `:telemetry` for metrics

#### OTP Best Practices

- Keep process mailboxes small
- Use `Registry` instead of `:global` for process discovery
- Use `DynamicSupervisor` for dynamically created processes
- Monitor long-lived resources properly

#### Memory Management

```elixir
# Clean up completed transactions/dialogs
def init(args) do
  # Set :temporary restart so failed processes don't restart
  {:ok, state, {:continue, :start_cleanup_timer}}
end

def handle_continue(:start_cleanup_timer, state) do
  # Schedule cleanup of terminated dialogs/transactions
  Process.send_after(self(), :cleanup, 30_000)
  {:noreply, state}
end
```

### 10. Common Patterns in Parrot Platform

#### Transaction Management

```elixir
# Generate transaction ID from message
trans_id = Transaction.generate_id(request)

# Start transaction under supervisor
{:ok, pid} = DynamicSupervisor.start_child(
  Transaction.Supervisor,
  {TransactionStatem, {role, request, options}}
)

# Register in Registry
{:via, Registry, {ParrotSip.Registry, trans_id}}
```

#### Dialog Identification

```elixir
# Dialogs identified by Call-ID + local-tag + remote-tag
dialog_id = Dialog.generate_id(:uas, call_id, local_tag, remote_tag)

# Find dialog
case DialogStatem.find_dialog(dialog_id) do
  {:ok, pid} -> # Found
  {:error, :no_dialog} -> # Not found
end
```

#### Message Processing Pipeline

```elixir
# Process through a pipeline of functions
process_list = [
  &validate_request/1,
  &check_dialog/1,
  &handle_method/1,
  &invoke_handler/1
]

case do_process(process_list, sip_msg) do
  {:reply, resp} -> send_response(resp)
  :ok -> :ok
end

defp do_process([], _), do: :ok
defp do_process([f | rest], msg) do
  case f.(msg) do
    :ok -> :ok
    {:reply, _} = reply -> reply
    {:process, msg1} -> do_process(rest, msg1)
  end
end
```

## Implementation Checklist

When implementing new features:

- [ ] Read and understand the relevant RFC sections
- [ ] Implement complete behavior (no "for now" shortcuts)
- [ ] Add comprehensive tests (unit + integration)
- [ ] Document with RFC references
- [ ] Use proper Elixir/OTP idioms
- [ ] Separate pure functions from stateful processes
- [ ] Handle all error cases per RFC
- [ ] Add typespecs
- [ ] Verify all tests pass
- [ ] Make small, focused commits

## Examples from Parrot Platform

### Example 1: Via Header Refactoring

**Problem**: Via headers were sometimes nil, sometimes a single header, sometimes a list.

**Solution**: Standardize to ALWAYS be a list.

```elixir
# Before (inconsistent)
via: nil  # or Via.t() or [Via.t()]

# After (consistent)
via: []   # Always a list, initialized as empty
```

This required:
1. Initialize `via: []` in `Message.new_request/3` and `new_response/3`
2. Update `add_via/2` to only handle list cases
3. Update serializer to check `via == []` instead of `via == nil`
4. Update all tests

### Example 2: CANCEL Handling

**Problem**: Initial implementation had "For now, we allow the handler to decide".

**Solution**: Implement RFC 3261 Section 9.2 completely.

```elixir
def process_cancel(cancel_msg, trans, handler) do
  case DialogStatem.uas_find(cancel_msg) do
    {:ok, dialog_pid} ->
      case get_dialog_state(dialog_pid) do
        :confirmed ->
          # RFC 3261: Cannot CANCEL confirmed dialog
          resp = Message.reply(cancel_msg, 481, "Call/Transaction Does Not Exist")
          TransactionStatem.server_response(resp, trans)

        :early ->
          # CANCEL is valid for early dialogs
          Handler.uas_cancel({:uas_id, trans}, handler)
      end

    :not_found ->
      # No dialog - normal CANCEL
      Handler.uas_cancel({:uas_id, trans}, handler)
  end
end
```

Added tests for:
- CANCEL for pending transaction (no dialog)
- CANCEL for early dialog (should succeed)
- CANCEL for confirmed dialog (should reject with 481)

### Example 3: Removing Dead Code

**Problem**: `ParrotSip.Connection` module existed but was unused.

**Solution**: Delete it completely.

- Verified it was only used in its own test
- Verified functionality was redundant
- Deleted 403 lines of code
- Confirmed all 1,017 remaining tests passed

## Summary

Parrot Platform is a complete, production-ready SIP implementation. Every feature must:
1. Be fully RFC-compliant
2. Use proper Elixir/OTP idioms
3. Have comprehensive tests
4. Be well-documented
5. Have no shortcuts or "TODO" deferments

This is not a prototype - this is a complete implementation that users can rely on.
