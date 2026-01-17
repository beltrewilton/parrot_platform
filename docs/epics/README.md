# MOS Quality Metrics Epics

## Overview

These epics enhance the MOS (Mean Opinion Score) quality monitoring system to provide accurate, real-world metrics instead of placeholder values.

## Epic Summary

| Epic | Title | Purpose | Status |
|------|-------|---------|--------|
| [EPIC-MOS-001](./EPIC-MOS-001-rtcp-parsing.md) | RTCP Parsing | Extract jitter/delay from RTCP Receiver Reports | Planned |
| [EPIC-MOS-002](./EPIC-MOS-002-sequence-tracking.md) | Sequence Tracking | Detect packet loss from RTP sequence gaps | Planned |

## Dependency Graph

```
┌─────────────────────────────────────────────────────────────────┐
│                     MOS Quality System                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────────────┐           ┌─────────────────┐            │
│   │  EPIC-MOS-001   │           │  EPIC-MOS-002   │            │
│   │  RTCP Parsing   │           │  Seq Tracking   │            │
│   └────────┬────────┘           └────────┬────────┘            │
│            │                             │                      │
│            │  No dependencies            │  No dependencies     │
│            │  between epics              │  between epics       │
│            │                             │                      │
│            ▼                             ▼                      │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                    MOS Calculator                        │  │
│   │  - Receives metrics from both sources                    │  │
│   │  - Calculates bidirectional MOS scores                   │  │
│   └─────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Parallel Execution Strategy

Both epics can be worked on **in parallel** by separate agents/developers:

### EPIC-MOS-001 (RTCP Parsing)
- **Focus**: Network protocol parsing, Membrane pipeline integration
- **Key deliverables**: RTCP parser, demuxer, sink elements
- **Metrics provided**: Jitter (from remote), RTT, outbound loss (from remote's RR)

### EPIC-MOS-002 (Sequence Tracking)
- **Focus**: RTP packet analysis, local measurement
- **Key deliverables**: Sequence tracker, Observer integration
- **Metrics provided**: Inbound packet loss, local jitter

### Integration Point

Both epics converge at the **MOS Calculator**, which will:
1. Accept metrics from both sources
2. Track separate inbound/outbound quality
3. Provide unified call quality summaries

## Metrics Coverage After Completion

| Metric | Current | After EPIC-001 | After EPIC-002 | After Both |
|--------|---------|----------------|----------------|------------|
| Inbound Loss | 0% (placeholder) | 0% | ✅ Real | ✅ Real |
| Outbound Loss | N/A | ✅ From RR | N/A | ✅ From RR |
| Inbound Jitter | 0ms (placeholder) | 0ms | ✅ Real | ✅ Real |
| Outbound Jitter | N/A | ✅ From RR | N/A | ✅ From RR |
| RTT/Delay | 50ms (default) | ✅ From RR | 50ms | ✅ From RR |

## Task Counts

| Epic | Core Tasks | Bonus Tasks | Total |
|------|------------|-------------|-------|
| EPIC-MOS-001 | 11 | 0 | 11 |
| EPIC-MOS-002 | 9 | 2 | 11 |
| **Combined** | **20** | **2** | **22** |

## Recommended Execution Order

For a single developer:
1. Start with EPIC-MOS-002 Phase 1 (Sequence Tracker) - immediate value
2. Then EPIC-MOS-001 Phase 1 (RTCP Parser) - more complex
3. Complete both Phase 2s (pipeline integration)
4. Integration testing

For parallel execution:
- Agent A: EPIC-MOS-001 (RTCP focus)
- Agent B: EPIC-MOS-002 (RTP sequence focus)
- Sync point: Calculator integration (Phase 3 of both)
