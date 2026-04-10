# Distributed Module Performance Gap Analysis

**Date:** 2026-04-01
**Scope:** `src/distributed/`

## Summary

| PerfSeverity | Open | Closed | Total |
|-------------|------|--------|-------|
| P0 (Critical) | 0 | 2 | 2 |
| P1 (High) | 5 | 0 | 5 |
| P2 (Medium) | 10 | 0 | 10 |
| P3 (Low) | 5 | 0 | 5 |

## P0 -- Critical

### PERF-D001: Mutex held during network I/O + 350ms retry sleep -- **CLOSED (2026-04-10)**

- **File:** `network_transport.zig:64-134`
- **Pattern:** `self.mutex.lock(); defer self.mutex.unlock();` held through QUIC connect, send, and 3 retries with 50/100/200ms sleep
- **Impact:** All inter-node cluster communication (heartbeats, replication, Raft messages) serializes behind one lock. One slow/unreachable peer blocks all healthy peer communication for up to 350ms.
- **Fix:** Lock only for peer-map lookup/update. Release before I/O. Clone peer info under lock, then send lock-free.
- **Expected improvement:** Eliminates cascading latency under network instability.
- **Resolution:** Lock-free I/O pattern implemented at `network_transport.zig:64-134`. Mutex is now held only for peer-map lookup, released before network operations.

### PERF-D002: Mutex held during 5s QUIC handshake -- **CLOSED (2026-04-10)**

- **File:** `twophase.zig:170-245`
- **Pattern:** `self.mutex.lock(); defer self.mutex.unlock();` held through `client.waitForHandshake(5)` on cache miss
- **Impact:** First 2PC connection to a new endpoint blocks ALL other 2PC traffic for up to 5 seconds.
- **Fix:** Use per-endpoint connection-in-progress flag. Release global mutex before handshake.
- **Expected improvement:** Prevents 5s cascading 2PC timeouts during cluster expansion.
- **Resolution:** Narrow mutex window implemented at `twophase.zig:170-245`. Global mutex released before QUIC handshake.

## P1 -- High

### PERF-D003: Sequential 2PC prepare O(N*RTT)

- **File:** `twophase.zig:495-539`
- **Impact:** 3 participants at 10ms RTT = 30ms vs 10ms parallel. 5 participants = 5x amplification.
- **Fix:** Use `spice_wrapper.parallelForEach` (already used in scatter-gather paths).

### PERF-D004: Sequential 2PC commit with retry backoff

- **File:** `twophase.zig:550-581`
- **Impact:** One failing participant delays all subsequent commits by up to 700ms.
- **Fix:** Parallelize commit sends.

### PERF-D005: Raft frame read spin-wait 200x5ms=1s

- **File:** `raft_consensus.zig:348-396`
- **Impact:** Two consecutive spin-wait loops (header + payload) = 2s worst case per frame read.
- **Fix:** Reduce sleep to 200us with 5000 retries, or use event-based I/O notification.

### PERF-D006: Unbounded thread-per-connection in cluster

- **File:** `cluster.zig:440-441`
- **Pattern:** `std.Thread.spawn` + `detach()` per accepted QUIC connection. No limit.
- **Impact:** 100 connections = ~800MB stack memory. Connection storms during partition recovery exhaust OS threads.
- **Fix:** Use semaphore or atomic counter to cap concurrent connection threads.

### PERF-D007: SpicePool created/destroyed per distributed query

- **File:** `query_coordinator.zig:148-149`, `txn_coordinator.zig:183`, `query_transport.zig:84`
- **Impact:** ~1-2ms thread pool lifecycle overhead per query (thread creation + join).
- **Fix:** Create SpicePool once in struct init, reuse across queries.

## P2 -- Medium (10 findings)

| ID | Finding | File:Line |
|----|---------|-----------|
| PERF-D008 | Non-atomic `g_last_federation_mismatch` bool | `federation_flag.zig:16` |
| PERF-D009 | Non-atomic `g_current`/`g_archive` latency aggregates | `federation_latency_aggregate.zig:53-54` |
| PERF-D010 | Non-atomic statistics counters | `enhanced_query_transport.zig` |
| PERF-D011 | Unbounded alloc from u32 length prefix | `raft_consensus.zig:375` |
| PERF-D012 | Unbounded alloc from u32 length prefix | `twophase.zig:312` |
| PERF-D013 | Unbounded alloc from u32 length prefix | `twophase.zig:784` |
| PERF-D014 | Unbounded alloc from u32 length prefix | `federation.zig:1354` |
| PERF-D015 | Unbounded alloc from u32 length prefix | `query_transport.zig:843` |
| PERF-D016 | QueryCache unbounded with no eviction policy | `federation.zig:1126-1196` |
| PERF-D017 | ConsistentHash.getNodes O(n) scan vs O(log n) binary search | `sharding.zig:952-958` |

## P3 -- Low (5 findings)

| ID | Finding | File:Line |
|----|---------|-----------|
| PERF-D018 | Sequential federation remote operations | `federation.zig:766-779` |
| PERF-D019 | Full materialization before merge (no streaming) | `query_coordinator.zig:62-69` |
| PERF-D020 | Allocation churn in scatter-gather (2575+ allocs per 5-shard query) | `query_coordinator.zig:97-298` |
| PERF-D021 | QueryCache.computeKey allocates string per lookup | `federation.zig:1186-1194` |
| PERF-D022 | No distributed performance benchmarks exist | All files |

---

*Generated 2026-04-01, updated 2026-04-10*
