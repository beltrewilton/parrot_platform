# ParrotTransport + ParrotSip Integration - THE REAL API

## Summary

**apps/parrot_sip** has a simpler, lower-level API than the old examples. You implement `ParrotSip.Handler` behavior directly, but most callbacks are just routing decisions that return the same thing every time.

## The Handler Behavior (6 callbacks)

```elixir
defmodule MyApp.SipHandler do
  @behaviour ParrotSip.Handler

  alias ParrotSip.{Message, UAS, UAC}

  # ============================================================
  # Routing callbacks (usually just return standard responses)
  # ============================================================

  @impl true
  def transp_request(_sip_msg, _args) do
    # Called when transport receives a request
    # Almost always return :process_transaction
    :process_transaction
  end

  @impl true
  def transaction(_trans, _sip_msg, _args) do
    # Called when transaction is created
    # Almost always return :process_uas for server side
    :process_uas
  end

  @impl true
  def transaction_stop(_trans, _result, _args) do
    # Called when transaction terminates
    # Usually nothing to do here
    :ok
  end

  # ============================================================
  # YOUR BUSINESS LOGIC - These are the important ones!
  # ============================================================

  @impl true
  def uas_request(uas, sip_msg, _args) do
    # THIS IS WHERE YOUR SERVER LOGIC GOES
    case sip_msg.method do
      :invite ->
        # Answer with 180 Ringing
        ringing = Message.reply(sip_msg, 180, "Ringing")
        UAS.response(ringing, uas)

        # Then answer with 200 OK
        # (In real code, you'd wait for user to answer)
        ok = Message.reply(sip_msg, 200, "OK")
        UAS.response(ok, uas)

      :bye ->
        # End call
        response = Message.reply(sip_msg, 200, "OK")
        UAS.response(response, uas)

      :options ->
        response = Message.reply(sip_msg, 200, "OK")
        UAS.response(response, uas)

      _ ->
        response = Message.reply(sip_msg, 501, "Not Implemented")
        UAS.response(response, uas)
    end

    :ok
  end

  @impl true
  def uas_cancel(_uas_id, _args) do
    # Called when CANCEL received
    # Stop ringing, clean up, etc.
    :ok
  end

  @impl true
  def process_ack(_sip_msg, _args) do
    # Called when ACK received (after 200 OK to INVITE)
    # Start media here
    :ok
  end
end
```

## Key Points

1. **You MUST implement all 6 callbacks** even if some just return `:ok`

2. **The routing callbacks (`transp_request`, `transaction`) almost always return the same thing**
   - This is just telling ParrotSip to route the message through the normal flow
   - You could have logic here to reject certain requests early

3. **`uas_request` is where your main server logic goes**
   - Pattern match on `sip_msg.method`
   - Use `Message.reply/2` or `Message.reply/3` to create responses
   - Use `UAS.response/2` to send them back

4. **Transactions and Dialogs are automatic**
   - When you send 200 OK to INVITE, a dialog is created automatically
   - Retransmissions, timers, state machines - all handled by ParrotSip
   - You don't touch `TransactionStatem` or `DialogStatem` directly

5. **For client side (making calls), use UAC**:
```elixir
invite = Message.new_request(:invite, "sip:bob@example.com", ...)

{:uac_id, _trans} = UAC.request(invite, fn
  {:message, %{status_code: 180}} ->
    IO.puts("Ringing...")

  {:message, %{status_code: 200}} = response ->
    IO.puts("Answered!")
    # Send ACK
    ack = Message.create_ack(invite, response)
    UAC.ack_request(ack)

  {:stop, reason} ->
    IO.puts("Transaction stopped: #{inspect(reason)}")
end)
```

## Wiring with ParrotTransport

```elixir
defmodule MyApp.SipStack do
  use GenServer

  alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}
  alias ParrotSip.{Handler, TransportHandler}

  def init(_opts) do
    # 1. Create handler
    handler = Handler.new(MyApp.SipHandler, %{})

    # 2. Start ParrotSip TransportHandler
    {:ok, sip_handler} = TransportHandler.start_link(name: :sip_transport)

    # 3. Start ParrotTransport UDP
    {:ok, udp} = ParrotTransport.start_listener(%ListenerConfig{
      transport: :udp,
      port: 5060
    })
    ParrotTransport.register_handler(udp, self())

    # 4. Start ParrotTransport TCP
    {:ok, tcp} = ParrotTransport.start_tcp_listener(%ListenerConfig{
      transport: :tcp,
      port: 5060
    }, self())

    {:ok, %{handler: handler, sip_handler: sip_handler, udp: udp, tcp: tcp}}
  end

  # Forward packets from ParrotTransport to ParrotSip
  def handle_info({:incoming_packet, %IncomingPacket{} = packet}, state) do
    metadata = %{
      transport: packet.source.transport,
      local_ip: elem(packet.source.local_addr, 0),
      local_port: elem(packet.source.local_addr, 1)
    }

    send(state.sip_handler, {
      :packet_received,
      packet.data,
      packet.source.remote_addr,
      metadata
    })

    {:noreply, state}
  end
end
```

## Comparison: Old vs New

### Old (lib/parrot with HandlerAdapter)

- ✅ **Simpler user code**: Just write `handle_invite/2` functions
- ✅ **No behavior to implement**: HandlerAdapter wraps your callbacks
- ❌ **More magic**: Hidden adapter layer
- ❌ **Less explicit**: Hard to see the flow

```elixir
# Old way - simple callbacks, no behavior
def handle_invite(request, state) do
  {:respond, 200, "OK", %{}, sdp}
end
```

### New (apps/parrot_sip)

- ✅ **More explicit**: You see the full Handler behavior
- ✅ **Less magic**: Direct implementation
- ✅ **Cleaner architecture**: No adapter layer
- ❌ **More boilerplate**: Must implement all 6 callbacks

```elixir
# New way - implement behavior
@behaviour ParrotSip.Handler

def uas_request(uas, sip_msg, _args) do
  response = Message.reply(sip_msg, 200)
  UAS.response(response, uas)
  :ok
end
```

## Rich Callback System

**apps/parrot_sip now supports optional method-specific and transaction state callbacks:**

### Method-Specific Callbacks

Instead of manually dispatching in `uas_request/3`, you can implement method-specific callbacks:

```elixir
defmodule MyApp.SipHandler do
  @behaviour ParrotSip.Handler

  # Optional - automatically called for OPTIONS requests
  def handle_options(uas, sip_msg, args) do
    response = Message.reply(sip_msg, 200, "OK")
    UAS.response(response, uas)
    :ok
  end

  # Optional - automatically called for INVITE requests
  def handle_invite(uas, sip_msg, args) do
    ringing = Message.reply(sip_msg, 180, "Ringing")
    UAS.response(ringing, uas)
    :ok
  end

  # Required - fallback for methods without specific handlers
  def uas_request(uas, sip_msg, args) do
    response = Message.reply(sip_msg, 501, "Not Implemented")
    UAS.response(response, uas)
    :ok
  end
end
```

**Available method callbacks:** `handle_options/3`, `handle_invite/3`, `handle_bye/3`, `handle_cancel/3`, `handle_register/3`, `handle_subscribe/3`, `handle_notify/3`, `handle_message/3`, `handle_info/3`

### Transaction State Callbacks

Get notified when transactions change state:

```elixir
defmodule MyApp.SipHandler do
  @behaviour ParrotSip.Handler

  # Optional - called when transaction enters :trying state
  def handle_transaction_trying(trans, sip_msg, args) do
    Logger.info("Transaction #{trans.id} trying")
    :ok
  end

  # Optional - called when transaction enters :proceeding state
  def handle_transaction_proceeding(trans, sip_msg, args) do
    Logger.info("Transaction #{trans.id} proceeding")
    :ok
  end

  # Optional - called when transaction enters :completed state
  def handle_transaction_completed(trans, sip_msg, args) do
    Logger.info("Transaction #{trans.id} completed")
    :ok
  end

  # Optional - called when transaction enters :confirmed state (INVITE only)
  def handle_transaction_confirmed(trans, sip_msg, args) do
    Logger.info("Transaction #{trans.id} confirmed")
    :ok
  end
end
```

**Available transaction callbacks:** `handle_transaction_trying/3`, `handle_transaction_proceeding/3`, `handle_transaction_completed/3`, `handle_transaction_confirmed/3`

### Dialog State Callbacks

**Note**: Dialog callbacks are defined in the behavior but not yet wired up to DialogStatem. This requires UAS/DialogStatem integration work to pass the Handler through the dialog creation flow.

```elixir
# Defined but not yet functional:
def handle_dialog_early(dialog, sip_msg, args) do
  Logger.info("Dialog #{dialog.id} early")
  :ok
end

def handle_dialog_confirmed(dialog, sip_msg, args) do
  Logger.info("Dialog #{dialog.id} confirmed")
  :ok
end
```

## Bottom Line

**Yes, the foundational APIs are the same:**
- `Message.reply/2` - create responses
- `UAS.response/2` - send responses (server)
- `UAC.request/2` - send requests (client)
- `Transaction` and `Dialog` are hidden from you

**What changed:**
- Old: HandlerAdapter wraps simple callbacks
- New: You implement `ParrotSip.Handler` behavior directly
- New: Rich callback system for method-specific and transaction state handling

**The new way is more verbose but more explicit and easier to understand.**
