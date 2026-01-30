# Ralph Loop: Beads Task Workflow

## Instructions

You are working through tasks tracked in bd/beads. Follow this workflow to process tasks by priority.

### 1. Check Current State
```bash
# Check ready tasks (no blockers) - filter by priority if needed
bd ready
bd ready --priority 1

# Check what's blocked and why
bd blocked

# List open tasks by priority
bd list --status open --priority 1
bd list --status open --priority 2
```

### 2. Find Next Task to Work

**Priority order:** P1 > P2 > P3

For epics, check their children:
```bash
bd show <epic-id>  # Shows children with status
```

Pick the first **unblocked, open task** (not epic) and view full details:
```bash
bd show <task-id>
```

### 3. Work the Task
- Read the task's acceptance criteria carefully
- Follow TDD: write tests first, then implementation
- Reference the file paths and line numbers in the task
- **STRICTLY follow the OTP Best Practices below**

### 4. Verify Completion
Before marking complete, verify ALL acceptance criteria:
- [ ] All acceptance criteria checkboxes satisfied
- [ ] Tests pass: `mix test`
- [ ] No new warnings: `mix compile --warnings-as-errors`
- [ ] Code formatted: `mix format`
- [ ] OTP best practices followed (see below)

### 5. Mark Complete and Commit
```bash
bd close <task-id>
git add -A && git commit -m "feat: <brief description>

Closes <task-id>"
bd sync
```

### 6. Check for Newly Unblocked Tasks
After closing a task, check if any blocked tasks are now ready:
```bash
bd ready
bd blocked
```

### 7. Completion Signal
The completion condition depends on what was requested. Examples:

**All P1 tasks complete:**
```
<promise>ALL P1 TASKS COMPLETE</promise>
```

**All tasks complete:**
```
<promise>ALL TASKS COMPLETE</promise>
```

**Specific epic complete:**
```
<promise>EPIC <epic-id> COMPLETE</promise>
```

If you cannot complete a task (stuck, needs clarification), output:
```
<promise>BLOCKED: <task-id> - <reason></promise>
```

---

## OTP BEST PRACTICES (MANDATORY)

### Supervision Tree Rules

| ❌ If you see this | ✅ Implement this instead |
|-------------------|---------------------------|
| Flat supervisor with many children | Layered tree: AppSupervisor -> DomainSupervisor -> Workers |
| `:one_for_one` with coupled children | `:one_for_all` or `:rest_for_one` based on dependency direction |
| Missing `child_spec/1` | Define in child module with `restart: :transient/:permanent`, `shutdown: 5000` |
| `Supervisor.start_link(children, opts)` inline | `use Supervisor` with `init/1` callback |

**For every supervisor you touch:**
1. Draw the failure domain boundary - which processes MUST die together?
2. Choose strategy: `:one_for_one` (independent), `:one_for_all` (coupled), `:rest_for_one` (ordered deps)
3. Set `shutdown: :brutal_kill` only for stateless, otherwise 5000-30000ms
4. Add telemetry: `:telemetry.execute([:parrot, :supervisor, :restart], %{count: 1}, %{name: __MODULE__})`

### GenServer Rules

| ❌ If you see this | ✅ Implement this instead |
|-------------------|---------------------------|
| Bloated state (caching entire tables) | Minimal state + ETS for shared reads or query on demand |
| Agent for complex logic | GenServer with explicit `handle_*` clauses |
| Missing catch-all `handle_info/2` | `def handle_info(msg, state), do: (Logger.warning("Unexpected: #{inspect msg}"); {:noreply, state})` |
| `GenServer.cast` needing confirmation | `GenServer.call` with timeout handling |
| `GenServer.call` for fire-and-forget | `GenServer.cast` to avoid blocking caller |
| Hardcoded timeout | `@call_timeout Application.compile_env(:app, :call_timeout, 5_000)` |

**GenServer checklist:**
1. State should be < 1KB serialized. If larger, justify or use ETS.
2. Every `call` must handle `{:error, :timeout}` at call site OR document why `:infinity` is safe
3. Add `handle_continue/2` for expensive init work (don't block supervisor)
4. Include catch-all `handle_info` that logs + returns `{:noreply, state}`
5. Add `@impl true` to every callback

### Process & Concurrency Rules

| ❌ If you see this | ✅ Implement this instead |
|-------------------|---------------------------|
| `spawn/1` for important work | `Task.Supervisor.async_nolink` or supervised child |
| Unbounded producer/consumer | GenStage or manual backpressure with call blocking |
| `Process.sleep` in prod | `Process.send_after(self(), :tick, interval)` + `handle_info(:tick, ...)` |
| Missing link/monitor | Explicit `Process.monitor(pid)` and handle `:DOWN` |

**Process rules:**
1. NEVER use `spawn/1` - always `spawn_link`, `spawn_monitor`, or `Task.Supervisor`
2. If process A needs result from B: `GenServer.call` (with timeout handling)
3. If A notifies B, doesn't care about result: `GenServer.cast`
4. For work that can fail independently: `Task.Supervisor.async_nolink` + handle `:DOWN`
5. Replace ALL `Process.sleep` with `send_after` pattern

### Error Handling Rules (LET IT CRASH)

| ❌ If you see this | ✅ Implement this instead |
|-------------------|---------------------------|
| `try/rescue` around GenServer logic | Remove it. Let it crash. Supervisor restarts clean. |
| `rescue _ -> :ok` | Delete this. Either handle specific errors or crash. |
| `rescue e -> Logger.error(e)` | Crash. Logger will capture via SASL/Telemetry. |
| Returning `{:error, reason}` from `init/1` | Return `:ignore` for "skip this" or crash for "retry later" |
| `:trap_exit` without EXIT handler | Either add `handle_info({:EXIT, pid, reason}, state)` or remove `trap_exit` |

**Error handling philosophy: LET IT CRASH**
1. Remove `try/rescue` unless: parsing external input, calling NIFs, or explicitly documented boundary
2. Use `{:ok, result} | {:error, reason}` for EXPECTED failures (user input, network)
3. Use crash/raise for UNEXPECTED failures (bugs, invariant violations)
4. If you add `:trap_exit`, you MUST handle `{:EXIT, pid, reason}` - audit this
5. Supervisor restart is the recovery mechanism, not rescue blocks

### Code Quality Rules

| ❌ If you see this | ✅ Implement this instead |
|-------------------|---------------------------|
| Nested case/cond 3+ deep | Multi-clause functions with pattern matching |
| `func() \|> next()` | `data \|> func() \|> next()` - pipes start with data |
| `acc <> string` in loop | `[acc, string]` iolist, `IO.iodata_to_binary` at end |
| `Enum` on huge/infinite data | `Stream` for lazy eval |
| `length(list) == 0` | `match?([], list)` or `Enum.empty?/1` |
| `elem(tuple, 0)` | Pattern match `{first, _} = tuple` |

**Idiomatic Elixir rules:**
1. Max 2 levels of case/cond nesting - refactor to function heads
2. Pipes: always start with data, not function call
3. String building: use iolists, convert once at boundary
4. Large data: `Stream` over `Enum`
5. Pattern match > accessor functions

### gen_statem Rules (CRITICAL for this codebase)

| ❌ If you see this | ✅ Implement this instead |
|-------------------|---------------------------|
| GenServer for complex state machines | `gen_statem` with explicit state functions |
| Manual state tracking with atoms | State function per state: `def trying(event_type, event, data)` |
| Timers via `Process.send_after` | `:gen_statem.state_timeout` or `{{:timeout, name}, time, event}` |
| Missing `:via` tuple for registry | `{:via, Registry, {MyRegistry, key}}` in `start_link` |

**gen_statem checklist:**
1. Use state functions (not `handle_event` callback mode) for clarity
2. Timers: use built-in `{:state_timeout, ms, event}` actions
3. Registration: use `:via` tuple for atomic registration with spawn
4. State data: separate state (atom) from data (map/struct)
5. Add `@impl true` to `callback_mode/0`, `init/1`, and all state functions

---

## Quality Gates

**DO NOT close a task unless:**
1. All tests pass
2. The specific bug/feature is verified working
3. Acceptance criteria are met
4. Code is committed
5. OTP best practices are followed

**DO NOT skip tasks** - work them in dependency order as shown by `bd blocked`.
