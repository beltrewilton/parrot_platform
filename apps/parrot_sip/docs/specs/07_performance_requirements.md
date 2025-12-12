# Performance Requirements and Benchmarks

**Version:** 1.0.0-draft
**Status:** DRAFT
**Date:** 2025-12-03

## 1. Overview

This document defines performance targets, benchmarking methodology, and scalability requirements for the UAS/UAC/B2BUA system.

### 1.1 Target Platform

**Hardware:**
- CPU: 8 cores @ 2.4 GHz (Intel Xeon or equivalent)
- RAM: 32 GB
- Network: 1 Gbps Ethernet
- Storage: SSD (for logging)

**Software:**
- Erlang/OTP 26+
- Elixir 1.15+
- Linux kernel 5.15+ (Ubuntu 22.04 LTS)

---

## 2. Performance Targets

### 2.1 Throughput

| Metric | Target | Rationale |
|--------|--------|-----------|
| Concurrent calls | 10,000+ | Production B2BUA scale |
| Calls per second (CPS) | 100+ | Busy hour capacity |
| Call setup time | < 100ms | User experience |
| BYE processing time | < 50ms | Quick cleanup |

### 2.2 Latency

| Operation | P50 | P95 | P99 | Max |
|-----------|-----|-----|-----|-----|
| INVITE → 180 | 10ms | 30ms | 50ms | 100ms |
| 200 OK → ACK | 5ms | 15ms | 25ms | 50ms |
| BYE → 200 OK | 5ms | 10ms | 20ms | 50ms |
| Handler callback | 1ms | 5ms | 10ms | 20ms |

**Note:** Latency excludes network RTT (SIP signaling to remote party)

### 2.3 Resource Usage

| Resource | Target | Warning | Critical |
|----------|--------|---------|----------|
| CPU (avg) | < 40% | 60% | 80% |
| Memory | < 4GB | 8GB | 16GB |
| Processes | < 100k | 150k | 200k |
| File descriptors | < 50k | 75k | 100k |
| ETS tables | < 1000 | 1500 | 2000 |

**Per 10,000 concurrent calls:**
- ~60,000 processes (6 per call: Session, UAS, UAC, 2 Dialogs, avg transactions)
- ~600 MB memory (60 KB per call)
- ~20,000 file descriptors (UDP/TCP sockets)

### 2.4 Reliability

| Metric | Target | Measurement |
|--------|--------|-------------|
| Uptime | 99.99% | < 52 min downtime/year |
| Call success rate | 99.9% | < 0.1% failed calls |
| Process crash rate | < 0.01% | < 1 crash per 10k calls |
| Memory leak | 0 | Constant memory after GC |

---

## 3. Scalability Analysis

### 3.1 Linear Scaling

**Hypothesis:** Throughput scales linearly with CPU cores.

| Cores | Expected Concurrent Calls | Expected CPS |
|-------|--------------------------|--------------|
| 2 | 2,500 | 25 |
| 4 | 5,000 | 50 |
| 8 | 10,000 | 100 |
| 16 | 20,000 | 200 |
| 32 | 40,000 | 400 |

**Test:** Run benchmark with 2, 4, 8, 16 cores, verify linear scaling.

### 3.2 Bottleneck Analysis

**Potential bottlenecks:**

1. **Registry lookups** - O(1) ETS, not a bottleneck
2. **Supervisor child management** - DynamicSupervisor uses ETS, O(1)
3. **Message passing** - Erlang scales to millions of messages/sec
4. **GC pauses** - Can cause latency spikes
5. **Scheduler contention** - At extreme load (>50k processes/core)

**Mitigation:**
- Use `+scl 4` (scheduler compaction of load) for better cache locality
- Monitor GC with `:erlang.system_info(:garbage_collection)`
- Use dirty schedulers for CPU-intensive tasks (SDP parsing)

### 3.3 Memory Scaling

**Formula:**
```
Memory = Base + (Calls × Per_Call_Memory)

Base = 100 MB (VM, code, ETS)
Per_Call_Memory = 60 KB

For 10,000 calls:
Memory = 100 MB + (10,000 × 60 KB)
       = 100 MB + 600 MB
       = 700 MB
```

**Test:** Verify memory growth is linear, no leaks.

---

## 4. Benchmarking Methodology

### 4.1 Call Load Generation

**Tool:** SIPp with `-r` (rate) and `-m` (max calls)

```bash
# Generate 1000 concurrent calls, 10 CPS
sipp -sn uac \
  -r 10 \
  -m 1000 \
  -l 1000 \
  -d 60000 \
  127.0.0.1:5060
```

**Scenarios:**
1. **Steady state:** 10k concurrent calls, 60s avg duration
2. **Ramp up:** 0 → 10k calls over 100s
3. **Spike:** Burst 100 CPS for 10s
4. **Mixed:** Various call durations (1s-300s)

### 4.2 Metrics Collection

**Tools:**
- **Erlang Observer:** `:observer.start()`
- **Telemetry:** Custom metrics via `:telemetry`
- **Prometheus:** `prometheus.ex` exporter
- **System:** `vmstat`, `top`, `iotop`

**Key Metrics:**
```elixir
defmodule ParrotSip.Metrics do
  use Prometheus.Metric

  @doc "Total active calls"
  def active_calls do
    DynamicSupervisor.count_children(SessionSupervisor)
    |> Map.get(:active)
  end

  @doc "Call setup latency histogram"
  def call_setup_latency do
    Histogram.new(
      name: :parrot_sip_call_setup_duration_milliseconds,
      help: "Call setup time from INVITE to 200 OK",
      buckets: [10, 25, 50, 100, 250, 500, 1000]
    )
  end

  @doc "Calls per second"
  def calls_per_second do
    Counter.new(
      name: :parrot_sip_calls_total,
      help: "Total calls processed"
    )
  end
end
```

### 4.3 Benchmark Harness

```elixir
defmodule ParrotSip.Benchmark do
  @doc "Run benchmark with given parameters"
  def run(opts \\ []) do
    concurrent_calls = Keyword.get(opts, :concurrent_calls, 1000)
    cps = Keyword.get(opts, :cps, 10)
    duration_sec = Keyword.get(opts, :duration, 60)

    # Start B2BUA
    {:ok, _} = start_b2bua()

    # Start metrics collection
    {:ok, collector} = Metrics.Collector.start_link()

    # Start SIPp load generators
    {:ok, caller_sipp} = start_sipp_uac(cps: cps, max_calls: concurrent_calls)
    {:ok, callee_sipp} = start_sipp_uas(port: 5061)

    # Wait for test duration
    Process.sleep(duration_sec * 1000)

    # Stop SIPp
    stop_sipp(caller_sipp)
    stop_sipp(callee_sipp)

    # Collect results
    metrics = Metrics.Collector.get_results(collector)

    # Generate report
    generate_report(metrics)
  end
end
```

### 4.4 Performance Tests

```elixir
defmodule ParrotSip.PerformanceTest do
  use ExUnit.Case, async: false

  @moduletag :performance
  @moduletag timeout: :infinity

  test "sustain 10k concurrent calls" do
    results = Benchmark.run(
      concurrent_calls: 10_000,
      cps: 100,
      duration: 300  # 5 minutes
    )

    assert results.successful_calls >= 10_000
    assert results.failed_calls < 10  # < 0.1% failure rate
    assert results.p99_setup_latency < 100  # ms
    assert results.memory_used < 1_000_000_000  # < 1 GB
  end

  test "handle call spike" do
    results = Benchmark.run(
      concurrent_calls: 1000,
      cps: 100,  # Spike: 100 CPS
      duration: 10
    )

    assert results.successful_calls >= 1000
    assert results.p99_setup_latency < 150  # Allow higher latency during spike
  end

  test "memory stability over time" do
    # Run for 1 hour, check for leaks
    collector = Metrics.MemoryCollector.start_link()

    Benchmark.run(
      concurrent_calls: 1000,
      cps: 10,
      duration: 3600
    )

    memory_samples = Metrics.MemoryCollector.get_samples(collector)

    # Memory should stabilize (constant after GC)
    initial_memory = Enum.take(memory_samples, 10) |> Enum.sum() |> div(10)
    final_memory = Enum.take(memory_samples, -10) |> Enum.sum() |> div(10)

    # Allow 10% growth (GC overhead)
    assert final_memory < initial_memory * 1.1
  end
end
```

---

## 5. Optimization Strategies

### 5.1 Process Pooling

**Problem:** Creating processes has overhead (~2μs per process)

**Solution:** Process pools for common operations

```elixir
defmodule ParrotSip.ProcessPool do
  use GenServer

  def init(opts) do
    pool_size = opts[:size]
    workers = Enum.map(1..pool_size, fn _ ->
      {:ok, pid} = Worker.start_link()
      pid
    end)

    {:ok, %{workers: workers, index: 0}}
  end

  def get_worker do
    GenServer.call(__MODULE__, :get_worker)
  end

  def handle_call(:get_worker, _from, state) do
    worker = Enum.at(state.workers, state.index)
    next_index = rem(state.index + 1, length(state.workers))
    {:reply, worker, %{state | index: next_index}}
  end
end
```

**Note:** Not needed for entities/sessions (short-lived, not poolable).

### 5.2 ETS Optimization

**Problem:** Large state in gen_statem slows down GC

**Solution:** Store large data structures in ETS

```elixir
defmodule ParrotSip.Session do
  def init(opts) do
    # Create ETS table for this session
    table = :ets.new(:session_data, [:set, :private])

    :ets.insert(table, {:metadata, opts[:metadata]})
    :ets.insert(table, {:extra_headers, []})

    # Only keep essential data in process state
    data = %Data{
      session_id: generate_id(),
      ets_table: table,
      a_leg: nil,
      b_leg: nil
    }

    {:ok, :routing, data}
  end

  def terminate(_reason, _state, data) do
    # Clean up ETS table
    :ets.delete(data.ets_table)
    :ok
  end
end
```

### 5.3 Binary Optimization

**Problem:** String concatenation creates garbage

**Solution:** Use iodata and binaries efficiently

```elixir
# Bad: Creates intermediate strings
def build_uri(user, host, port) do
  "sip:" <> user <> "@" <> host <> ":" <> Integer.to_string(port)
end

# Good: Uses iodata (no intermediate binaries)
def build_uri(user, host, port) do
  IO.iodata_to_binary(["sip:", user, "@", host, ":", Integer.to_string(port)])
end

# Better: Pattern match binaries
def build_uri(user, host, port) do
  <<"sip:", user::binary, "@", host::binary, ":", port::binary>>
end
```

### 5.4 Message Passing Optimization

**Problem:** Large messages copy data

**Solution:** Use references and lookups

```elixir
# Bad: Pass entire INVITE message
notify(owner, {:uas_created, self(), invite_message})

# Good: Pass reference, owner looks up if needed
notify(owner, {:uas_created, self(), invite_id})
```

### 5.5 GC Tuning

**Strategy:** Tune GC for SIP workload (many short-lived processes)

```erlang
% In vm.args
+hms 8192           # Initial heap size (8KB, good for entities)
+hmbs 16384         # Binary heap minimum size
+scl 4              # Scheduler compaction
+sub true           # Scheduler utilization balancing
+swt very_low       # Scheduler wake-up threshold
+sbwt very_long     # Scheduler busy-wait threshold
```

**Test:** Benchmark with different GC settings, measure P99 latency.

---

## 6. Load Testing Scenarios

### 6.1 Scenario 1: Steady State

**Goal:** Verify system can sustain target load

**Parameters:**
- Concurrent calls: 10,000
- CPS: 100
- Call duration: 60s average
- Duration: 30 minutes

**Success Criteria:**
- ✓ All calls complete successfully
- ✓ CPU < 60% average
- ✓ Memory < 1.5 GB
- ✓ P99 latency < 100ms

**SIPp Command:**
```bash
sipp -sf uac_scenario.xml \
  -r 100 \
  -l 10000 \
  -d 60000 \
  -m 180000 \  # 30min × 100 CPS
  -trace_err \
  -timeout 120000 \
  127.0.0.1:5060
```

### 6.2 Scenario 2: Ramp Up

**Goal:** Test system under increasing load

**Parameters:**
- Start: 0 calls
- End: 10,000 calls
- Ramp: 100s
- Call duration: 120s

**Success Criteria:**
- ✓ No call failures during ramp
- ✓ Latency remains stable
- ✓ No process crashes

### 6.3 Scenario 3: Spike Load

**Goal:** Test resilience to traffic spikes

**Parameters:**
- Baseline: 1,000 concurrent calls (10 CPS)
- Spike: 10,000 concurrent calls (100 CPS for 100s)
- Recovery: Back to baseline

**Success Criteria:**
- ✓ System handles spike without crashes
- ✓ Latency degrades gracefully (< 200ms P99 during spike)
- ✓ Returns to normal after spike

### 6.4 Scenario 4: Long Duration

**Goal:** Detect memory leaks and resource exhaustion

**Parameters:**
- Concurrent calls: 5,000
- CPS: 50
- Duration: 24 hours

**Success Criteria:**
- ✓ Memory remains constant (no leak)
- ✓ No file descriptor leaks
- ✓ No process leaks
- ✓ Performance consistent over 24h

**Monitoring:**
```bash
# Monitor every 5 minutes
while true; do
  echo "$(date), $(ps aux | grep beam | awk '{print $6}'), \
        $(lsof -p $(pgrep beam.smp) | wc -l)" \
    >> metrics.csv
  sleep 300
done
```

### 6.5 Scenario 5: Forking Load

**Goal:** Test B2BUA forking performance

**Parameters:**
- Concurrent calls: 1,000
- Fork factor: 3 destinations per call
- CPS: 10

**Expected:**
- 1,000 UAS entities
- 3,000 UAC entities (3× forking)
- 4,000 total entities

**Success Criteria:**
- ✓ All forks handled correctly
- ✓ First-answer-wins logic works
- ✓ CANCELs sent to non-winners

---

## 7. Performance Monitoring

### 7.1 Real-Time Dashboard

**Metrics to display:**
- Active calls (gauge)
- Calls/second (rate)
- Call setup latency (histogram)
- CPU usage (gauge)
- Memory usage (gauge)
- Error rate (rate)

**Tools:**
- Grafana + Prometheus
- Phoenix LiveDashboard
- Custom Telemetry dashboard

### 7.2 Alerting

**Thresholds:**
```yaml
alerts:
  - name: HighLatency
    condition: p99_latency > 200ms for 5min
    severity: warning
    action: notify_ops

  - name: HighCPU
    condition: cpu_usage > 80% for 10min
    severity: critical
    action: [notify_ops, scale_up]

  - name: HighErrorRate
    condition: error_rate > 1% for 5min
    severity: critical
    action: [notify_ops, stop_new_calls]

  - name: MemoryLeak
    condition: memory_growth > 10% per hour
    severity: warning
    action: [notify_ops, schedule_restart]
```

### 7.3 Performance Regression Testing

**CI Pipeline:**
```yaml
# .github/workflows/performance.yml
name: Performance Tests

on:
  pull_request:
    branches: [main]

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2

      - name: Setup Elixir
        uses: erlef/setup-beam@v1

      - name: Install SIPp
        run: sudo apt-get install -y sipp

      - name: Run benchmark
        run: mix test --only performance

      - name: Compare to baseline
        run: |
          ./scripts/compare_benchmark.sh \
            results.json \
            baseline.json
```

**Baseline tracking:**
- Store benchmark results in git
- Compare PR results to main branch
- Fail if latency >10% regression

---

## 8. Capacity Planning

### 8.1 Scaling Formula

**Single server capacity:**
```
Max_Calls = (Cores × 1250) - Overhead

For 8 cores:
Max_Calls = (8 × 1250) - 0
          = 10,000 calls

Overhead:
- Each core can handle ~1250 concurrent calls
- Assumes avg 8 processes/call, 10k processes/core
```

### 8.2 Cluster Scaling

**Multi-server deployment:**
- Use DNS SRV for load distribution
- Each server handles 10k calls
- Total capacity: Servers × 10k

**Example:**
- 5 servers @ 8 cores = 50k concurrent calls
- With N+1 redundancy: 40k usable capacity

### 8.3 Auto-Scaling

**Kubernetes HPA (Horizontal Pod Autoscaler):**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: parrot-sip-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: parrot-sip
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60

    - type: Pods
      pods:
        metric:
          name: parrot_sip_active_calls
        target:
          type: AverageValue
          averageValue: 8000
```

---

## 9. Performance Acceptance Criteria

Implementation MUST meet these benchmarks:

| Test | Requirement | Status |
|------|-------------|--------|
| 10k concurrent calls | ✓ Pass | ⬜ Pending |
| 100 CPS sustained | ✓ Pass | ⬜ Pending |
| P99 < 100ms setup latency | ✓ Pass | ⬜ Pending |
| < 1 GB memory @ 10k calls | ✓ Pass | ⬜ Pending |
| 0 memory leaks (24h test) | ✓ Pass | ⬜ Pending |
| 99.9% success rate | ✓ Pass | ⬜ Pending |
| Linear CPU scaling | ✓ Pass | ⬜ Pending |

**Sign-off:**
- [ ] All benchmarks passing
- [ ] Load tests completed
- [ ] Performance dashboard deployed
- [ ] Approved by: _____________

---

**Review Status:**
- [ ] Performance targets approved
- [ ] Benchmarks executed
- [ ] Results documented
- [ ] Approved by: _____________
