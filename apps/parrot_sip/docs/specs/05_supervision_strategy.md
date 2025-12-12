# Supervision Strategy and OTP Design

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-03

## 1. Overview

This document defines the OTP supervision tree for UAS/UAC/B2BUA components, ensuring fault tolerance and proper resource cleanup.

### 1.1 Design Principles

**SP-1: Let It Crash**
- Don't defensively handle every error
- Let supervisors restart failed processes
- Separate supervision domains (entities, sessions)

**SP-2: Temporary Workers**
- Entities and Sessions are `:temporary` (don't restart on crash)
- Crashed call = terminated call (don't resurrect)
- Supervisor cleans up crashed processes

**SP-3: Process Isolation**
- Each entity = separate process
- Each session = separate process
- Crash in one call doesn't affect others

**SP-4: Monitoring, Not Linking**
- Sessions monitor their entities
- Entities monitor their dialogs
- Unidirectional dependency (no circular links)

---

## 2. Complete Supervision Tree

```
Application.Supervisor (one_for_one)
├── ParrotSip.Registry (one process for entire app)
│
├── ParrotSip.Transport.Supervisor (one_for_one)
│   ├── UDP.Listener
│   └── TCP.Listener
│
├── ParrotSip.Transaction.Supervisor (simple_one_for_one)
│   ├── TransactionStatem #1
│   ├── TransactionStatem #2
│   └── TransactionStatem #N (thousands)
│
├── ParrotSip.Dialog.Supervisor (simple_one_for_one)
│   ├── DialogStatem #1
│   ├── DialogStatem #2
│   └── DialogStatem #N (thousands)
│
└── ParrotSip.B2BUA.Supervisor (rest_for_one)
    ├── ParrotSip.UAS.Supervisor (simple_one_for_one)
    │   ├── UAS #1 (gen_statem)
    │   ├── UAS #2
    │   └── UAS #N
    │
    ├── ParrotSip.UAC.Supervisor (simple_one_for_one)
    │   ├── UAC #1 (gen_statem)
    │   ├── UAC #2
    │   └── UAC #N
    │
    └── ParrotSip.B2BUA.SessionSupervisor (simple_one_for_one)
        ├── Session #1 (gen_statem)
        ├── Session #2
        └── Session #N
```

---

## 3. Supervisor Specifications

### 3.1 Application Supervisor

**Module:** `ParrotSip.Application`

```elixir
defmodule ParrotSip.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Registry for process lookup
      {Registry, keys: :unique, name: ParrotSip.Registry},

      # Transport listeners
      ParrotSip.Transport.Supervisor,

      # Protocol layer (existing)
      ParrotSip.Transaction.Supervisor,
      ParrotSip.Dialog.Supervisor,

      # Application layer (new)
      ParrotSip.B2BUA.Supervisor
    ]

    opts = [strategy: :one_for_one, name: ParrotSip.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**Strategy:** `:one_for_one`
**Rationale:** Independent subsystems. Crash in transactions doesn't affect dialogs, etc.

**Max Restarts:** 3 in 5 seconds (default)

---

### 3.2 B2BUA Supervisor

**Module:** `ParrotSip.B2BUA.Supervisor`

```elixir
defmodule ParrotSip.B2BUA.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      # Entity supervisors first
      {DynamicSupervisor,
        name: ParrotSip.UAS.Supervisor,
        strategy: :one_for_one,
        max_restarts: 1000,
        max_seconds: 1},

      {DynamicSupervisor,
        name: ParrotSip.UAC.Supervisor,
        strategy: :one_for_one,
        max_restarts: 1000,
        max_seconds: 1},

      # Session supervisor last (depends on entity supervisors)
      {DynamicSupervisor,
        name: ParrotSip.B2BUA.SessionSupervisor,
        strategy: :one_for_one,
        max_restarts: 1000,
        max_seconds: 1}
    ]

    # rest_for_one: If UAS.Supervisor crashes, restart UAC and Session supervisors
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

**Strategy:** `:rest_for_one`
**Rationale:**
- Entity supervisors are required for sessions
- If entity supervisor crashes, sessions become orphaned
- Restart session supervisor to clean up orphans

**Max Restarts:** 3 in 5 seconds (for supervisor itself)

---

### 3.3 Entity Supervisors (UAS/UAC)

**Module:** `ParrotSip.UAS.Supervisor`, `ParrotSip.UAC.Supervisor`

```elixir
defmodule ParrotSip.UAS.Supervisor do
  # Uses DynamicSupervisor (started in B2BUA.Supervisor)

  @doc "Start a new UAS entity"
  def start_uas(opts) do
    child_spec = {ParrotSip.UAS, opts}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Terminate a UAS entity"
  def terminate_uas(uas_pid) do
    DynamicSupervisor.terminate_child(__MODULE__, uas_pid)
  end

  @doc "Count active UAS entities"
  def count do
    DynamicSupervisor.count_children(__MODULE__)
  end
end
```

**Strategy:** `:one_for_one` (DynamicSupervisor default)
**Restart:** `:temporary`
**Rationale:**
- Each UAS is independent (one call)
- Don't restart crashed entities (call is over)
- Supervisor just cleans up process

**Max Restarts:** 1000 in 1 second
**Rationale:** Under load, many calls start/stop rapidly. High limit prevents supervisor crash.

---

### 3.4 Session Supervisor

**Module:** `ParrotSip.B2BUA.SessionSupervisor`

```elixir
defmodule ParrotSip.B2BUA.SessionSupervisor do
  # Uses DynamicSupervisor

  def start_session(opts) do
    child_spec = {ParrotSip.B2BUA.Session, opts}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def terminate_session(session_pid) do
    DynamicSupervisor.terminate_child(__MODULE__, session_pid)
  end

  def count_active_calls do
    %{active: active} = DynamicSupervisor.count_children(__MODULE__)
    active
  end
end
```

**Strategy:** `:one_for_one`
**Restart:** `:temporary`
**Rationale:** Same as entities - don't restart crashed sessions.

---

## 4. Process Lifecycles

### 4.1 Normal Call Flow

```
1. INVITE arrives
2. Transport → Transaction.Server → Handler
3. Handler creates Session
   └─ Session started under SessionSupervisor
4. Session creates UAS
   └─ UAS started under UAS.Supervisor
5. Session creates UAC
   └─ UAC started under UAC.Supervisor
6. Call established
7. BYE arrives
8. Session terminates
   ├─ Notifies UAS to terminate
   ├─ Notifies UAC to terminate
   └─ Session exits normally
9. UAS exits normally
10. UAC exits normally
11. All processes removed from supervision tree
```

**Process Count:**
- +1 Session (under SessionSupervisor)
- +1 UAS (under UAS.Supervisor)
- +1 UAC (under UAC.Supervisor)
- +1 Dialog for UAS (under Dialog.Supervisor)
- +1 Dialog for UAC (under Dialog.Supervisor)
- +N Transactions (under Transaction.Supervisor)

**Total: ~6-10 processes per call**

### 4.2 Crash Scenarios

#### Scenario 1: UAS Crashes

```
1. UAS process crashes (bug, timeout, etc.)
2. UAS.Supervisor removes crashed child
3. Session receives {:DOWN, ref, :process, uas_pid, reason}
4. Session terminates UAC
5. Session logs error and exits
6. SessionSupervisor removes crashed session
```

**Recovery:** None (call terminated). No restart.

#### Scenario 2: Session Crashes

```
1. Session process crashes
2. SessionSupervisor removes crashed child
3. UAS receives {:DOWN, ref, :process, session_pid, reason}
4. UAS has no owner, exits
5. UAC receives {:DOWN, ref, :process, session_pid, reason}
6. UAC has no owner, exits
7. All entities cleaned up
```

**Recovery:** None. Orphaned entities clean themselves up.

#### Scenario 3: Supervisor Crashes

```
1. UAS.Supervisor crashes (bug in supervisor logic)
2. B2BUA.Supervisor detects EXIT
3. B2BUA.Supervisor strategy is :rest_for_one
4. B2BUA.Supervisor restarts UAS.Supervisor
5. B2BUA.Supervisor restarts UAC.Supervisor (comes after UAS)
6. B2BUA.Supervisor restarts SessionSupervisor (comes last)
7. All running sessions/entities were killed
8. New sessions can be created
```

**Impact:** ALL active calls dropped. Severe but recoverable.

**Mitigation:** Supervisor code is simple (minimal crash risk).

---

## 5. Monitoring and Links

### 5.1 Monitoring Strategy

**Rule:** Use `Process.monitor/1`, not `Process.link/1`

**Rationale:**
- Links are bidirectional (crash propagates both ways)
- Monitors are unidirectional (parent watches child)
- Supervisors use links, we use monitors

### 5.2 Session Monitors

```elixir
defmodule ParrotSip.B2BUA.Session do
  def init({invite, handler_mod, handler_state}) do
    # Create UAS
    {:ok, uas_pid} = UAS.Supervisor.start_uas(...)

    # Monitor UAS (don't link!)
    uas_ref = Process.monitor(uas_pid)

    # Create UAC
    {:ok, uac_pid} = UAC.Supervisor.start_uac(...)
    uac_ref = Process.monitor(uac_pid)

    data = %Data{
      a_leg: %{uas: uas_pid, ref: uas_ref},
      b_leg: %{uac: uac_pid, ref: uac_ref}
    }

    {:ok, :routing, data}
  end

  # Handle crash
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      ref == state.a_leg.ref ->
        Logger.error("A-leg crashed: #{inspect(reason)}")
        # Terminate B-leg
        UAC.terminate(state.b_leg.uac)
        {:stop, :normal, state}

      ref == state.b_leg.ref ->
        Logger.error("B-leg crashed: #{inspect(reason)}")
        # Reject A-leg
        UAS.reject(state.a_leg.uas, 500, "Internal Error")
        {:stop, :normal, state}
    end
  end
end
```

### 5.3 Entity Monitors

```elixir
defmodule ParrotSip.UAS do
  def init(opts) do
    owner = opts[:owner]
    owner_ref = Process.monitor(owner)

    # Create dialog
    {:ok, dialog_pid} = DialogStatem.start_link(...)
    dialog_ref = Process.monitor(dialog_pid)

    data = %Data{
      owner: owner,
      owner_ref: owner_ref,
      dialog: dialog_pid,
      dialog_ref: dialog_ref
    }

    {:ok, :incoming, data}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.owner_ref ->
        # Session died, clean up
        Logger.warn("Owner died, terminating UAS")
        {:stop, :normal, state}

      ref == state.dialog_ref ->
        # Dialog crashed (shouldn't happen)
        Logger.error("Dialog crashed: #{inspect(reason)}")
        {:stop, :dialog_crashed, state}
    end
  end
end
```

---

## 6. Resource Cleanup

### 6.1 Normal Termination

**UAS Termination:**
```elixir
def terminate(reason, _state, data) do
  # Unregister from registry
  Registry.unregister(ParrotSip.Registry, {:uas, data.id})

  # Dialog cleanup (if not already terminated)
  if Process.alive?(data.dialog) do
    DialogStatem.stop(data.dialog)
  end

  # Cancel timers
  if data.timers.timer_h do
    Process.cancel_timer(data.timers.timer_h)
  end

  Logger.info("UAS #{data.id} terminated: #{inspect(reason)}")
  :ok
end
```

**Session Termination:**
```elixir
def terminate(reason, _state, data) do
  # Stop media proxy
  if data.media_proxy do
    MediaProxy.stop(data.media_proxy)
  end

  # Demonitor entities (they'll clean themselves up)
  if data.a_leg.ref, do: Process.demonitor(data.a_leg.ref, [:flush])
  if data.b_leg.ref, do: Process.demonitor(data.b_leg.ref, [:flush])

  # Unregister
  Registry.unregister(ParrotSip.Registry, {:session, data.session_id})

  Logger.info("Session #{data.session_id} terminated: #{inspect(reason)}")
  :ok
end
```

### 6.2 Forced Cleanup

If process crashes without normal termination:
- Supervisor removes from child list
- Registry automatically removes (process monitor)
- Dialogs terminate (monitored by entities)
- Transactions timeout naturally

**No resource leaks.**

---

## 7. Registry Usage

### 7.1 Process Registration

**Purpose:** Lookup processes by ID (not just PID)

**Registry Key Format:**
```elixir
{:uas, entity_id}         # UAS entities
{:uac, entity_id}         # UAC entities
{:session, session_id}    # B2BUA sessions
{:dialog, dialog_id}      # Dialogs (existing)
```

**Registration:**
```elixir
# UAS registers itself
def init(opts) do
  entity_id = generate_id()
  Registry.register(ParrotSip.Registry, {:uas, entity_id}, %{
    created_at: DateTime.utc_now(),
    remote_uri: opts[:invite].from.uri
  })

  # ...
end
```

**Lookup:**
```elixir
# Find UAS by ID
case Registry.lookup(ParrotSip.Registry, {:uas, entity_id}) do
  [{pid, _metadata}] -> {:ok, pid}
  [] -> {:error, :not_found}
end
```

**Automatic Cleanup:**
- Registry monitors registered processes
- On process death, registry removes entry
- No manual unregister needed (but good practice)

---

## 8. Startup and Shutdown

### 8.1 Application Startup

```
1. Application.start
2. Start Registry
3. Start Transport.Supervisor
   ├─ Start UDP listener
   └─ Start TCP listener
4. Start Transaction.Supervisor (no children yet)
5. Start Dialog.Supervisor (no children yet)
6. Start B2BUA.Supervisor
   ├─ Start UAS.Supervisor (DynamicSupervisor, no children)
   ├─ Start UAC.Supervisor (DynamicSupervisor, no children)
   └─ Start SessionSupervisor (DynamicSupervisor, no children)
7. Ready to accept calls
```

**Startup Time:** < 100ms (no children to start)

### 8.2 Graceful Shutdown

```elixir
defmodule ParrotSip.Application do
  def stop(_state) do
    # Shutdown order (automatic by supervisor tree)
    # 1. Stop B2BUA.Supervisor
    #    - Stops SessionSupervisor (kills all sessions)
    #    - Stops UAC.Supervisor (kills all UACs)
    #    - Stops UAS.Supervisor (kills all UASs)
    # 2. Stop Dialog.Supervisor (kills all dialogs)
    # 3. Stop Transaction.Supervisor (kills all transactions)
    # 4. Stop Transport.Supervisor (stops listeners)
    # 5. Stop Registry

    Logger.info("ParrotSip shutting down")
    :ok
  end
end
```

**Shutdown Behavior:**
- All active calls are terminated
- Entities send BYE if possible (best-effort)
- Timeout after 5s (brutal_kill)

**Graceful Shutdown (Optional):**
```elixir
# Before Application.stop:
defmodule ParrotSip.GracefulShutdown do
  def shutdown do
    # Stop accepting new calls
    Transport.stop_accepting()

    # Wait for active calls to finish
    wait_for_calls(timeout: 30_000)

    # Stop application
    Application.stop(:parrot_sip)
  end

  defp wait_for_calls(opts) do
    timeout = opts[:timeout]
    start = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn ->
      count = B2BUA.SessionSupervisor.count_active_calls()
      elapsed = System.monotonic_time(:millisecond) - start

      cond do
        count == 0 -> :done
        elapsed > timeout -> :timeout
        true -> :wait
      end
    end)
    |> Stream.take_while(&(&1 == :wait))
    |> Enum.each(fn _ -> Process.sleep(1000) end)
  end
end
```

---

## 9. Fault Tolerance Analysis

### 9.1 Single Call Failure

**Scenario:** One call crashes due to bug.

**Impact:**
- Only that call is affected
- Other calls continue normally
- No supervisor restarts (temporary strategy)

**Recovery:**
- Automatic cleanup via monitors
- Remote party receives BYE or timeout
- No manual intervention needed

**MTBF Impact:** None

### 9.2 High Load Crash

**Scenario:** System overloaded, many calls timeout.

**Impact:**
- Many entities timeout simultaneously
- High supervisor churn (adding/removing children)
- Possible supervisor crash if max_restarts exceeded

**Mitigation:**
- High max_restarts (1000/sec) for entity supervisors
- Load shedding: Reject new calls when at capacity
- Rate limiting in transport layer

**Recovery:**
- If supervisor crashes, rest_for_one restarts it
- Existing calls lost, but system recovers
- New calls can be accepted

### 9.3 Supervisor Crash

**Scenario:** Bug in supervisor code (rare).

**Impact:**
- All children under that supervisor killed
- Parent supervisor restarts failed supervisor
- Clean slate (all calls lost)

**Mitigation:**
- Keep supervisor code simple (minimal logic)
- Test supervisor behavior thoroughly
- Use standard DynamicSupervisor (battle-tested)

**Recovery:**
- Automatic (parent restarts child supervisor)
- System available for new calls immediately

---

## 10. Monitoring and Observability

### 10.1 Process Metrics

**Expose via Telemetry:**
```elixir
defmodule ParrotSip.Metrics do
  def active_sessions do
    %{active: count} = DynamicSupervisor.count_children(SessionSupervisor)
    count
  end

  def active_uas_entities do
    %{active: count} = DynamicSupervisor.count_children(UAS.Supervisor)
    count
  end

  def active_uac_entities do
    %{active: count} = DynamicSupervisor.count_children(UAC.Supervisor)
    count
  end

  def total_processes do
    Process.list() |> length()
  end

  def memory_usage do
    :erlang.memory()
  end
end
```

**Export to Prometheus/StatsD:**
- `parrot_sip_active_sessions{}`
- `parrot_sip_active_uas{}`
- `parrot_sip_active_uac{}`
- `parrot_sip_process_count{}`
- `parrot_sip_memory_bytes{type="total"|"processes"|"binary"}`

### 10.2 Crash Reporting

**Log all crashes:**
```elixir
defmodule ParrotSip.CrashLogger do
  def handle_event([:parrot_sip, :crash], measurements, metadata, _config) do
    Logger.error("""
    Process crashed:
      PID: #{inspect(metadata.pid)}
      Module: #{metadata.module}
      Reason: #{inspect(metadata.reason)}
      State: #{inspect(metadata.state)}
      Stacktrace: #{inspect(metadata.stacktrace)}
    """)

    # Send to error tracking (Sentry, Rollbar, etc.)
    ErrorTracker.report(metadata)
  end
end

# Attach in application.ex
:telemetry.attach("crash-logger", [:parrot_sip, :crash], &CrashLogger.handle_event/4, nil)
```

### 10.3 Health Checks

```elixir
defmodule ParrotSip.HealthCheck do
  def healthy? do
    checks = [
      supervisor_alive?: supervisor_alive?,
      registry_alive?: registry_alive?,
      transport_listening?: transport_listening?,
      load_acceptable?: load_acceptable?
    ]

    Enum.all?(checks, fn {_name, result} -> result end)
  end

  defp supervisor_alive? do
    Process.whereis(ParrotSip.Supervisor) != nil
  end

  defp load_acceptable? do
    active = Metrics.active_sessions()
    max = Application.get_env(:parrot_sip, :max_sessions, 10_000)
    active < max * 0.9  # Under 90% capacity
  end
end
```

---

## 11. Performance Characteristics

### 11.1 Process Overhead

**Per Call:**
- 1 Session process (~2KB)
- 1 UAS process (~2KB)
- 1 UAC process (~2KB)
- 2 Dialog processes (~2KB each)
- N Transaction processes (~1KB each)

**Total per call:** ~12-15KB

**10,000 concurrent calls:** ~120-150MB

### 11.2 Supervisor Overhead

**DynamicSupervisor:**
- Child list: ETS table (fast lookup)
- Add/remove child: O(1)
- Count children: O(1)

**No performance bottleneck.**

### 11.3 Registry Overhead

**Process lookup:**
- ETS table: O(1) lookup
- Automatic cleanup: Process monitor overhead (minimal)

**No performance bottleneck.**

---

## 12. Testing Supervision

### 12.1 Crash Injection Tests

```elixir
test "UAS crash terminates session" do
  {:ok, session} = start_test_session()
  {:ok, uas} = get_session_uas(session)

  # Kill UAS
  Process.exit(uas, :kill)

  # Verify session terminates
  assert_down(session, timeout: 1000)
end

test "supervisor handles rapid start/stop" do
  # Start 1000 UAS entities rapidly
  entities = Enum.map(1..1000, fn _ ->
    {:ok, uas} = UAS.Supervisor.start_uas(...)
    uas
  end)

  # Stop all
  Enum.each(entities, &GenServer.stop/1)

  # Verify supervisor still healthy
  assert Process.alive?(Process.whereis(UAS.Supervisor))
  assert %{active: 0} = DynamicSupervisor.count_children(UAS.Supervisor)
end
```

### 12.2 Supervisor Restart Tests

```elixir
test "B2BUA supervisor recovers from crash" do
  # Start some sessions
  sessions = start_sessions(10)

  # Kill B2BUA.Supervisor
  supervisor = Process.whereis(B2BUA.Supervisor)
  Process.exit(supervisor, :kill)

  # Wait for restart
  Process.sleep(100)

  # Verify supervisor restarted
  new_supervisor = Process.whereis(B2BUA.Supervisor)
  assert new_supervisor != nil
  assert new_supervisor != supervisor

  # Old sessions dead, new can be created
  assert Enum.all?(sessions, &(not Process.alive?(&1)))
  {:ok, _new_session} = start_test_session()
end
```

---

**Review Status:**
- [ ] Supervision tree reviewed
- [ ] Crash scenarios tested
- [ ] Monitoring implemented
- [ ] Approved by: _____________
