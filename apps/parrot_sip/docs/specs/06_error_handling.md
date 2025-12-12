# Error Handling and Recovery

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-03

## 1. Overview

This document defines error handling strategies for all failure modes in the UAS/UAC/B2BUA system.

### 1.1 Error Categories

1. **Protocol Errors** - Invalid SIP messages, malformed headers
2. **State Errors** - Invalid state transitions, wrong timing
3. **Resource Errors** - Out of memory, process limits, ports exhausted
4. **Network Errors** - Timeouts, connection failures, DNS failures
5. **Application Errors** - Handler crashes, invalid SDP, routing failures
6. **Process Crashes** - Unexpected exits, bugs, assertions

---

## 2. Error Handling Philosophy

### 2.1 Principles

**EH-1: Fail Fast**
- Don't try to recover from programmer errors
- Crash and let supervisor clean up
- Restart with clean state

**EH-2: Be Explicit**
- Return `{:ok, result}` or `{:error, reason}`
- Don't use exceptions for control flow
- Pattern match on errors

**EH-3: Layer Responsibility**
- Protocol errors → Protocol layer
- State errors → Entity/Session layer
- Application errors → Handler layer

**EH-4: Graceful Degradation**
- One bad call doesn't crash system
- Reject new calls under load
- Log errors for debugging

### 2.2 Error Response Strategy

```
┌─────────────────────────────────────────┐
│ Error Source                             │
├─────────────────────────────────────────┤
│ Protocol violation                       │ → Delegate to Transaction/Dialog
│ Invalid state transition                 │ → Return {:error, :invalid_state}
│ Resource exhaustion                      │ → Reject call, log error
│ Network timeout                          │ → Notify owner, cleanup
│ Handler crash                            │ → Catch, log, use default behavior
│ Process crash                            │ → Let it crash, supervisor cleans up
└─────────────────────────────────────────┘
```

---

## 3. Protocol Errors

### 3.1 Malformed SIP Messages

**Error:** INVITE missing required headers (From, To, Call-ID, CSeq, Via)

**Detection:** Transaction/Message parsing layer

**Handling:**
```elixir
# In Transaction.Server
def process_request(raw_message) do
  case Parser.parse(raw_message) do
    {:ok, message} ->
      validate_required_headers(message)

    {:error, :parse_error} ->
      # Send 400 Bad Request
      send_error_response(400, "Bad Request - Malformed Message")
      :drop
  end
end

defp validate_required_headers(message) do
  required = [:from, :to, :call_id, :cseq, :via]

  missing = Enum.filter(required, fn header ->
    Map.get(message, header) == nil
  end)

  if missing == [] do
    {:ok, message}
  else
    send_error_response(400, "Missing required headers: #{inspect(missing)}")
    {:error, :missing_headers}
  end
end
```

**Entity Impact:** None (never reaches entity layer)

**Recovery:** Automatic (bad request dropped)

### 3.2 Invalid SDP

**Error:** SDP body is malformed or missing required fields

**Detection:** Entity layer (when trying to use SDP)

**Handling:**
```elixir
# In UAS
def handle_call({:answer, sdp}, _from, state) do
  case validate_sdp(sdp) do
    :ok ->
      response = build_200_ok(sdp)
      {:reply, :ok, :answering, state}

    {:error, reason} ->
      Logger.warn("Invalid SDP provided: #{inspect(reason)}")
      {:reply, {:error, :invalid_sdp}, state.current_state, state}
  end
end

defp validate_sdp(sdp) do
  # Basic validation
  cond do
    sdp == nil or sdp == "" ->
      {:error, :empty_sdp}

    not String.contains?(sdp, "v=0") ->
      {:error, :missing_version}

    not String.contains?(sdp, "m=") ->
      {:error, :missing_media}

    true ->
      :ok
  end
end
```

**Entity Impact:** Returns error to caller, stays in current state

**Recovery:** Handler can retry with valid SDP or reject call

### 3.3 Protocol Violations

**Error:** Receiving BYE before call established, ACK without INVITE, etc.

**Detection:** DialogStatem (RFC 3261 compliance)

**Handling:**
```elixir
# In DialogStatem
def early({:call, from, {:bye}}, data) do
  # Can't BYE a call that's not established
  response = build_error_response(481, "Call/Transaction Does Not Exist")
  {:reply, {:error, :invalid_state}, :early, data}
end
```

**Entity Impact:** None (Dialog layer handles)

**Recovery:** Automatic (error response sent)

---

## 4. State Errors

### 4.1 Invalid State Transition

**Error:** Calling `answer()` on terminated UAS

**Detection:** Entity state machine guard

**Handling:**
```elixir
# In UAS
def terminated({:call, from, {:answer, _sdp}}, _data) do
  # Can't answer terminated call
  {:reply, {:error, :invalid_state}, :terminated, data}
end

def ringing({:call, from, {:answer, sdp}}, data) do
  # Valid transition
  send_200_ok(sdp)
  {:reply, :ok, :answering, data}
end
```

**Application Impact:** Receives `{:error, :invalid_state}`

**Recovery:** Application should check state before calling

**Test:**
```elixir
test "cannot answer terminated UAS" do
  {:ok, uas} = UAS.start_link(...)
  UAS.reject(uas, 486, "Busy")

  # Wait for termination
  :timer.sleep(100)

  # Try to answer
  assert {:error, :invalid_state} = UAS.answer(uas, sdp: "...")
end
```

### 4.2 Race Conditions

**Error:** CANCEL arrives simultaneously with 200 OK

**Detection:** Transaction layer + UAC state machine

**Handling:**
```elixir
# In UAC
def ringing(:call, :cancel, _from, data) do
  # Send CANCEL
  Transaction.Client.cancel(data.transaction)
  {:reply, :ok, :ringing, data}
end

# Race: 200 OK arrives after CANCEL sent but before 487
def ringing(:cast, {:tx_response, {200, response}}, data) do
  # Call answered despite CANCEL
  # RFC 3261: Must send ACK, then BYE

  Logger.warn("Call answered after CANCEL sent, will hang up")

  # Send ACK
  Dialog.send_ack(data.dialog, response)

  # Send BYE immediately
  Dialog.send_request(data.dialog, :bye)

  # Notify owner call was answered then hung up
  notify(data.owner, {:uac_answered_then_cancelled, self()})

  {:next_state, :terminating, data}
end
```

**Application Impact:** Receives notification of race condition

**Recovery:** Automatic (call hung up gracefully)

---

## 5. Resource Errors

### 5.1 Process Limit Exceeded

**Error:** System hitting max process limit (ERL: `+P 1000000`)

**Detection:** Supervisor or process creation failure

**Handling:**
```elixir
# In SessionSupervisor
def start_session(opts) do
  case DynamicSupervisor.start_child(__MODULE__, {Session, opts}) do
    {:ok, pid} ->
      {:ok, pid}

    {:error, :max_children} ->
      Logger.error("Process limit reached, rejecting new call")
      {:error, :system_overload}

    {:error, reason} ->
      Logger.error("Failed to start session: #{inspect(reason)}")
      {:error, reason}
  end
end

# In transport handler
def handle_incoming_invite(invite) do
  case SessionSupervisor.start_session(invite: invite, ...) do
    {:ok, session} ->
      :ok

    {:error, :system_overload} ->
      # Send 503 Service Unavailable
      send_error_response(503, "Service Unavailable - System Overload")
      :ok
  end
end
```

**Application Impact:** New calls rejected with 503

**Recovery:** Existing calls complete, new calls accepted when capacity available

**Monitoring:**
```elixir
defmodule ParrotSip.LoadShedding do
  def check_capacity do
    active = SessionSupervisor.count_active_calls()
    max = Application.get_env(:parrot_sip, :max_concurrent_calls, 10_000)

    if active >= max do
      {:error, :at_capacity}
    else
      {:ok, active}
    end
  end
end

# Before creating session
case LoadShedding.check_capacity() do
  {:ok, _count} ->
    SessionSupervisor.start_session(...)

  {:error, :at_capacity} ->
    send_error_response(503, "Service Unavailable")
end
```

### 5.2 Memory Exhaustion

**Error:** System running out of memory

**Detection:** OOM killer or allocation failure

**Handling:**
```elixir
# Monitor memory usage
defmodule ParrotSip.MemoryMonitor do
  use GenServer

  def init(_) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check_memory, state) do
    memory = :erlang.memory(:total)
    max_memory = get_max_memory()

    if memory > max_memory * 0.9 do
      Logger.error("Memory usage at 90%: #{memory} bytes")
      # Reject new calls
      LoadShedding.enable(:memory_pressure)
    else
      LoadShedding.disable(:memory_pressure)
    end

    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_memory, 5_000)
  end

  defp get_max_memory do
    # 80% of system memory
    :erlang.memory(:system) * 0.8
  end
end
```

**Application Impact:** New calls rejected until memory recovers

**Recovery:** GC runs, old calls complete, memory recovered

### 5.3 Port Exhaustion

**Error:** No more file descriptors for sockets

**Detection:** Transport layer fails to bind/connect

**Handling:**
```elixir
# In Transport layer
def start_listener(port) do
  case :gen_udp.open(port, [:binary, active: true]) do
    {:ok, socket} ->
      {:ok, socket}

    {:error, :emfile} ->
      Logger.error("Port exhaustion: too many open files")
      {:error, :port_exhaustion}

    {:error, :eaddrinuse} ->
      Logger.error("Port #{port} already in use")
      {:error, :address_in_use}
  end
end
```

**Application Impact:** Cannot accept new calls

**Recovery:** Requires system intervention (increase ulimit, restart)

---

## 6. Network Errors

### 6.1 DNS Failure

**Error:** Cannot resolve destination hostname

**Detection:** UAC when building INVITE

**Handling:**
```elixir
# In UAC
def init(opts) do
  dest_uri = opts[:dest_uri]

  case resolve_uri(dest_uri) do
    {:ok, ip, port} ->
      # Build INVITE with resolved IP
      invite = build_invite(ip, port, opts)
      {:ok, :initiating, %Data{invite: invite, ...}}

    {:error, :nxdomain} ->
      Logger.warn("DNS resolution failed for #{dest_uri}")
      notify(opts[:owner], {:uac_error, :dns_failure})
      {:stop, :dns_failure}

    {:error, :timeout} ->
      Logger.warn("DNS timeout for #{dest_uri}")
      notify(opts[:owner], {:uac_error, :dns_timeout})
      {:stop, :dns_timeout}
  end
end

defp resolve_uri(uri_string) do
  uri = Uri.parse!(uri_string)
  host = uri.host

  case :inet.gethostbyname(String.to_charlist(host), :inet, 5000) do
    {:ok, {:hostent, _, _, _, _, [ip | _]}} ->
      {:ok, ip, uri.port || 5060}

    {:error, reason} ->
      {:error, reason}
  end
end
```

**Application Impact:** Session receives `{:uac_error, :dns_failure}`

**Recovery:** Session can try alternate destination or reject call

### 6.2 Network Timeout

**Error:** No response to INVITE (Timer B fires)

**Detection:** Transaction layer Timer B (32 seconds)

**Handling:**
```elixir
# In UAC
def calling(:timeout, :timer_b, data) do
  # Timer B fired - no response to INVITE
  Logger.warn("INVITE timeout for #{data.dest_uri}")

  notify(data.owner, {:uac_timeout, self()})

  {:next_state, :terminated, data}
end

# In Session
def connecting(:info, {:uac_timeout, uac_pid}, data) do
  # B-leg timed out
  Logger.warn("B-leg timeout, trying next destination or rejecting")

  # If forking, try next destination
  case data.b_legs do
    [failed | [next | rest]] when failed == uac_pid ->
      # Start next UAC
      {:ok, new_uac} = UAC.start_link(...)
      {:next_state, :connecting, %{data | b_legs: [new_uac | rest]}}

    _ ->
      # No more destinations
      UAS.reject(data.a_leg, 408, "Request Timeout")
      {:next_state, :terminated, data}
  end
end
```

**Application Impact:** Session tries alternate route or rejects call

**Recovery:** Automatic (timeout handled gracefully)

### 6.3 Connection Reset

**Error:** TCP connection reset during call

**Detection:** Transport layer socket error

**Handling:**
```elixir
# In Transport.TCP
def handle_info({:tcp_closed, socket}, state) do
  Logger.warn("TCP connection closed")

  # Notify all dialogs using this connection
  notify_dialogs(state.dialogs, :connection_lost)

  {:stop, :normal, state}
end

# In DialogStatem
def established(:info, :connection_lost, data) do
  Logger.error("Connection lost for dialog #{data.id}")

  # Terminate dialog
  {:stop, :connection_lost, data}
end

# In UAS
def established(:info, {:DOWN, ref, :process, dialog_pid, :connection_lost}, data)
    when ref == data.dialog_ref do
  Logger.error("Connection lost, terminating call")

  notify(data.owner, {:uas_connection_lost, self()})

  {:next_state, :terminated, data}
end
```

**Application Impact:** Call terminated, session notified

**Recovery:** None (call lost)

---

## 7. Application Errors

### 7.1 Handler Crash

**Error:** Handler callback raises exception

**Detection:** Caught in Session/Entity

**Handling:**
```elixir
# In Session
def routing(:enter, _old_state, data) do
  # Call handler for routing decision
  try do
    case data.handler_module.route_call(data.invite, data.handler_state) do
      {:route, dest, new_state} ->
        create_uac(dest)
        {:keep_state, %{data | handler_state: new_state}}

      {:reject, code, reason, new_state} ->
        UAS.reject(data.a_leg, code, reason)
        {:next_state, :terminated, %{data | handler_state: new_state}}
    end
  rescue
    error ->
      Logger.error("Handler crashed in route_call: #{inspect(error)}")
      Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")

      # Use default behavior: reject with 500
      UAS.reject(data.a_leg, 500, "Internal Server Error")
      {:next_state, :terminated, data}
  end
end
```

**Application Impact:** Call rejected with 500

**Recovery:** Automatic (default behavior used)

**Monitoring:** Log and alert on handler crashes

### 7.2 Invalid Routing Decision

**Error:** Handler returns invalid response

**Detection:** Pattern match failure

**Handling:**
```elixir
# In Session
def routing(:enter, _old_state, data) do
  case safe_call_handler(data) do
    {:route, dest, new_state} when is_binary(dest) ->
      # Valid
      create_uac(dest)

    {:fork, dests, new_state} when is_list(dests) ->
      # Valid
      create_uacs(dests)

    {:reject, code, reason, new_state}
        when is_integer(code) and code >= 300 ->
      # Valid
      UAS.reject(data.a_leg, code, reason)

    invalid ->
      # Invalid return value
      Logger.error("Handler returned invalid value: #{inspect(invalid)}")
      UAS.reject(data.a_leg, 500, "Internal Server Error")
      {:next_state, :terminated, data}
  end
end
```

**Application Impact:** Call rejected with 500

**Recovery:** Automatic (validation + default behavior)

### 7.3 SDP Modification Failure

**Error:** Handler's modify_sdp returns invalid SDP

**Detection:** SDP validation

**Handling:**
```elixir
# In Session
def connecting(:info, {:uac_answered, uac_pid, sdp}, data) do
  # Call handler to modify SDP
  case safe_modify_sdp(:b_to_a, sdp, data) do
    {:ok, modified_sdp, new_state} ->
      # Validate modified SDP
      case validate_sdp(modified_sdp) do
        :ok ->
          UAS.answer(data.a_leg, sdp: modified_sdp)

        {:error, reason} ->
          Logger.error("Handler returned invalid SDP: #{inspect(reason)}")
          # Use original SDP
          UAS.answer(data.a_leg, sdp: sdp)
      end

    {:reject, code, reason, new_state} ->
      # Handler wants to reject
      UAC.hangup(uac_pid)
      UAS.reject(data.a_leg, code, reason)
  end
end
```

**Application Impact:** Falls back to original SDP if modification fails

**Recovery:** Automatic (graceful degradation)

---

## 8. Process Crashes

### 8.1 Entity Crash

**Error:** UAS/UAC process crashes due to bug

**Detection:** Supervisor receives EXIT, Session receives :DOWN

**Handling:**
```elixir
# In Session
def handle_info({:DOWN, ref, :process, pid, reason}, state) do
  cond do
    ref == state.a_leg.ref ->
      Logger.error("A-leg crashed: #{inspect(reason)}")
      # Terminate B-leg
      if state.b_leg do
        UAC.hangup(state.b_leg.uac)
      end
      {:stop, :normal, state}

    ref == state.b_leg.ref ->
      Logger.error("B-leg crashed: #{inspect(reason)}")
      # Reject A-leg
      UAS.reject(state.a_leg.uas, 500, "Internal Server Error")
      {:stop, :normal, state}
  end
end
```

**Application Impact:** Call terminated

**Recovery:** Automatic cleanup via monitors

**Investigation:** Crash logged with stacktrace for debugging

### 8.2 Session Crash

**Error:** Session process crashes

**Detection:** Entities receive :DOWN, Supervisor cleans up

**Handling:**
```elixir
# In UAS
def handle_info({:DOWN, ref, :process, _pid, reason}, data)
    when ref == data.owner_ref do
  Logger.warn("Owner (session) crashed: #{inspect(reason)}")

  # Send BYE if possible
  if data.current_state == :established do
    Dialog.send_request(data.dialog, :bye)
  end

  # Terminate
  {:stop, :normal, data}
end
```

**Application Impact:** Entities clean themselves up

**Recovery:** Automatic (no orphaned processes)

### 8.3 Supervisor Crash

**Error:** Supervisor itself crashes (rare)

**Detection:** Parent supervisor

**Handling:** See 05_supervision_strategy.md §9.3

**Application Impact:** All children killed, supervisor restarted

**Recovery:** Automatic (parent restarts child supervisor)

---

## 9. Error Reporting and Logging

### 9.1 Structured Logging

```elixir
defmodule ParrotSip.ErrorLogger do
  require Logger

  def log_error(category, details) do
    Logger.error("[#{category}] #{format_error(details)}",
      category: category,
      details: details,
      timestamp: DateTime.utc_now()
    )

    # Send to error tracking service
    ErrorTracker.report(category, details)
  end

  defp format_error(details) when is_map(details) do
    details
    |> Map.take([:reason, :state, :message])
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(", ")
  end
end

# Usage
ErrorLogger.log_error(:state_error, %{
  module: UAS,
  function: :answer,
  reason: :invalid_state,
  state: :terminated,
  entity_id: data.id
})
```

### 9.2 Error Metrics

```elixir
defmodule ParrotSip.ErrorMetrics do
  def increment(error_type) do
    :telemetry.execute(
      [:parrot_sip, :error],
      %{count: 1},
      %{type: error_type}
    )
  end
end

# Attach handler
:telemetry.attach_many(
  "error-metrics",
  [[:parrot_sip, :error]],
  &ErrorMetrics.handle_event/4,
  nil
)

# Export to Prometheus
# parrot_sip_errors_total{type="state_error"} 42
# parrot_sip_errors_total{type="protocol_error"} 15
# parrot_sip_errors_total{type="network_timeout"} 8
```

### 9.3 Error Aggregation

**Detect error storms:**
```elixir
defmodule ParrotSip.ErrorStorm do
  use GenServer

  def init(_) do
    {:ok, %{errors: [], window_start: now()}}
  end

  def handle_cast({:error, error}, state) do
    errors = [error | state.errors]
    now = now()

    # Keep only errors in last 60 seconds
    recent = Enum.filter(errors, fn e ->
      now - e.timestamp < 60_000
    end)

    if length(recent) > 100 do
      # Error storm detected!
      Logger.error("ERROR STORM: #{length(recent)} errors in 60s")
      alert_ops()
    end

    {:noreply, %{errors: recent, window_start: now}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
```

---

## 10. Testing Error Scenarios

### 10.1 Error Injection

```elixir
defmodule ParrotSip.ErrorInjection do
  @doc "Simulate process crash"
  def crash_process(pid, reason \\ :kill) do
    Process.exit(pid, reason)
  end

  @doc "Simulate network timeout"
  def block_network(pid, duration_ms) do
    # Suspend process (simulates network delay)
    :sys.suspend(pid)
    Process.send_after(self(), {:resume, pid}, duration_ms)
  end

  @doc "Simulate memory pressure"
  def cause_memory_pressure do
    # Allocate large binaries
    spawn(fn ->
      Enum.each(1..1000, fn _ ->
        :binary.copy(<<0>>, 1_000_000)
        Process.sleep(10)
      end)
    end)
  end
end
```

### 10.2 Error Test Cases

```elixir
test "UAS handles handler crash gracefully" do
  defmodule CrashingHandler do
    use B2BUA.Handler

    def init(_), do: {:ok, %{}}

    def route_call(_invite, _state) do
      raise "Intentional crash"
    end
  end

  {:ok, session} = Session.start_link(
    invite: invite,
    handler: CrashingHandler,
    handler_state: %{}
  )

  # Should receive 500 error
  assert_receive {:sip_sent, %{status_code: 500}}

  # Session should terminate gracefully
  assert_down(session)
end

test "session handles UAS crash" do
  {:ok, session} = start_test_session()
  {:ok, uas} = get_session_uas(session)

  # Kill UAS
  Process.exit(uas, :kill)

  # Session should clean up
  assert_down(session, timeout: 1000)

  # UAC should be terminated
  {:ok, uac} = get_session_uac(session)
  assert_down(uac, timeout: 1000)
end
```

---

## 11. Error Recovery Checklist

For each error type, verify:

- [ ] Error is detected (logged with context)
- [ ] Appropriate action taken (reject, retry, crash)
- [ ] Resources cleaned up (no leaks)
- [ ] Remote party notified (SIP response/request)
- [ ] Metrics recorded (for monitoring)
- [ ] Test case exists (error scenario covered)

---

**Review Status:**
- [ ] Error scenarios reviewed
- [ ] Recovery strategies verified
- [ ] Tests implemented
- [ ] Approved by: _____________
