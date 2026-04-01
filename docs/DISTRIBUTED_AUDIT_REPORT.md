# Full Codebase Audit: `src/distributed/`

**Date:** 2026-04-01
**Scope:** `src/distributed/` (20 files, 12,837 lines)
**Language:** Zig 0.15.1
**Branch:** `session/20260401`

---

## Repository

- **Project:** Geode Graph Database
- **Platform:** GitLab
- **Languages:** Zig
- **Scope:** `src/distributed/` -- Raft consensus, federation, 2PC, sharding, cluster coordination, distributed query execution

---

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented (TESTED) | 55 | 61.1% |
| Partially Implemented (EXEMPT with code) | 20+ | 22.2% |
| Not Implemented (stubs/scaffolds) | 15 | 16.7% |

**Open gaps:** 28 (Critical: 4, High: 5, Medium: 11, Low: 8)

**Critical gap chain:** The distributed write path has **four independent layers of data loss**:

1. `proposeCommand` discards command content (GAP-D003)
2. `handleMessage` zeroes out AppendEntries fields (GAP-D002)
3. Protobuf serialization drops entries and snapshot data (GAP-D026)
4. Replication sends empty snapshots (GAP-D001)

**Phantom tests:** 9 CANARY TESTED tokens reference non-existent test names. 20+ tokens reference missing geodetestlab spec files.

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 5 |
| High | 20+ |
| Medium | 10 |
| Low | 8 |

**Top finding:** Dual Raft wrappers (`raft.zig` + `raft_consensus.zig`) with diverging type systems wrapping the same external library. `proposeCommand` discards all command data; `handleMessage` zeroes all AppendEntries/InstallSnapshot fields. The Raft consensus layer is structurally non-functional.

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 | 2 |
| P1 | 5 |
| P2 | 10 |
| P3 | 5 |

**Top finding:** `NetworkTransport.sendToNode` holds a global mutex during QUIC send + 350ms retry sleep (`network_transport.zig:65-119`). All inter-node communication serializes behind this lock.

### Security

| Risk Level | Count |
|-----------|-------|
| Critical | 2 |
| High | 5 |
| Medium | 5 |
| Low | 2 |

**Immediate actions:** 0 secret rotations needed. 2 critical unauthenticated endpoints require fix before any production cluster deployment.

---

## Cross-Domain Summary

| Domain | Findings | Docs Updated |
|--------|----------|-------------|
| Gap Analysis | 28 | DISTRIBUTED_GAP_ANALYSIS.md |
| Quality | 43 | DISTRIBUTED_QUALITY_GAP_ANALYSIS.md |
| Performance | 22 | DISTRIBUTED_PERF_GAP_ANALYSIS.md |
| Security | 14 | DISTRIBUTED_SECURITY_GAP_ANALYSIS.md |
| **Total** | **107** | |

---

## Top 20 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | File:Line |
|---|--------|---------|----------|-----------|
| 1 | Gap | **Raft proposeCommand discards command content** -- `_ = cmd; self.inner.propose(&.{});` | Critical | `raft_consensus.zig:650-653` |
| 2 | Gap | **Raft handleMessage zeroes AppendEntries/InstallSnapshot** -- all fields replaced with 0/empty | Critical | `raft_consensus.zig:615-643` |
| 3 | Gap | **Raft protobuf conversion drops entries and snapshot data** -- wire format cannot carry log data | Critical | `raft_consensus.zig:413-476` |
| 4 | Gap | **Cluster replication sends empty 0-byte snapshots** -- replicas receive no data | Critical | `cluster.zig:635-637` |
| 5 | Security | **Unauthenticated Raft QUIC listener** -- any network peer can inject Raft frames (RequestVote, AppendEntries) | Critical | `cluster.zig:430-492` |
| 6 | Security | **Unauthenticated JOIN_CLUSTER** -- rogue nodes can join cluster, receive replication data, leak topology | Critical | `cluster.zig:499-517` |
| 7 | Quality | **2PC applyUndoOperation is a no-op** -- abort does not roll back changes, violating atomicity | Critical | `twophase.zig:394-396` |
| 8 | Quality | **cluster.zig start() blocks forever** -- `defer thread.join()` on infinite-loop threads | Critical | `cluster.zig:405-421` |
| 9 | Quality | **apply_callback error silently swallowed** -- committed entry application failures are lost | Critical | `raft_consensus.zig:682` |
| 10 | Perf | **Mutex held during QUIC send + 350ms retry sleep** -- serializes all inter-node traffic | P0 | `network_transport.zig:65-119` |
| 11 | Perf | **Mutex held during 5s QUIC handshake** -- blocks all 2PC operations | P0 | `twophase.zig:141-201` |
| 12 | Security | **2PC transport has no authentication** -- raw protobuf, no HELLO/token | High | `twophase.zig:140-391` |
| 13 | Security | **query_transport sends empty credentials** -- username="" password="" in HELLO | High | `query_transport.zig:609-617` |
| 14 | Security | **Debug build auto-bypasses TLS** in query_transport and 2PC (federation was already fixed) | High | `query_transport.zig:578`, `twophase.zig:161,343` |
| 15 | Security | **Federation queries may bypass coordinator-side RLS** -- results merged without RLS filtering | High | `federation.zig:277-398` |
| 16 | Gap | **union_distinct is a placeholder** -- falls through to union_all without deduplication | High | `federation.zig:856-859` |
| 17 | Gap | **hash_aggregate has hardcoded sum=0** -- GROUP BY aggregation returns wrong values | High | `enhanced_query_coordinator.zig:465-523` |
| 18 | Gap | **query_planner.zig is entirely scaffolded** -- 15+ methods with `_ = self; _ = param` | High | `query_planner.zig` (entire file) |
| 19 | Perf | **SpicePool created/destroyed per query** -- 1-2ms thread pool lifecycle overhead per distributed query | High | `query_coordinator.zig:148-149` |
| 20 | Perf | **Sequential 2PC prepare O(N*RTT)** -- 3x latency amplification for 3-participant transactions | High | `twophase.zig:495-539` |

---

## Detailed Domain Reports

### A. Gap Analysis

#### Critical Gaps

**GAP-D001: Cluster replication sends empty payload**

- `cluster.zig:635-637`: `const snapshot = try self.allocator.alloc(u8, 0);`
- Comment: `// TODO: Replication needs rework for per-graph storage layout.`
- Impact: Replicas have no data. Failover to a replica results in complete data loss.

**GAP-D002: Raft handleMessage zeroes out AppendEntries**

- `raft_consensus.zig:615-622`: `.append_entries => |_|` -- binds payload then discards it; all fields set to 0/empty.
- Impact: Log replication is broken. Followers never receive leader entries.

**GAP-D003: Raft proposeCommand discards command content**

- `raft_consensus.zig:650-653`: `_ = cmd; self.inner.propose(&.{});`
- Impact: No command data enters the Raft log. All consensus proposals are empty.

**GAP-D026: Raft protobuf conversion drops entries and snapshot data**

- `raft_consensus.zig:413-476`: `messageToProto` omits `entries` field; `protoToMessage` sets `entries: &.{}`.
- Impact: Even if handleMessage were fixed, the wire format cannot carry log entries.

#### High Gaps

**GAP-D004: 2PC abort undo is a no-op** (`twophase.zig:394-396`)
**GAP-D005: union_distinct is a placeholder** (`federation.zig:856-859`)
**GAP-D006: hash_aggregate has hardcoded sum=0** (`enhanced_query_coordinator.zig:465-523`)
**GAP-D007: query_planner.zig entirely scaffolded** (577 lines, 15+ stub methods)
**GAP-D008: Raft PersistentStorage all no-ops** (`raft_consensus.zig:222-245`)

#### Phantom Tests (9 tokens referencing non-existent tests)

| Gap-ID | CANARY Token | Missing Test | File |
|--------|-------------|-------------|------|
| GAP-D009 | REQ-GQL-020 | e2e_cluster_replication | cluster.zig |
| GAP-D010 | REQ-GQL-2PC-005 | TestCANARY_DistributedQuery | cluster.zig |
| GAP-D011 | REQ-DIST-QUERY-COORD-001 | TestCANARY_REQ_DIST_QUERY_COORD_001 | enhanced_query_coordinator.zig |
| GAP-D012 | REQ-DIST-QUERY-COORD-002 | TestCANARY_REQ_DIST_QUERY_COORD_002 | enhanced_query_coordinator.zig |
| GAP-D013 | REQ-DIST-QUERY-TRANSPORT-001 | TestCANARY_REQ_DIST_QUERY_TRANSPORT_001 | query_transport.zig |
| GAP-D014 | REQ-DIST-QUERY-TRANSPORT-002 | TestCANARY_REQ_DIST_QUERY_TRANSPORT_002 | query_transport.zig |
| GAP-D015 | 20+ tokens | geode_distributed_queries.yml, geode_advanced_features.yml | multiple |
| GAP-D016 | REQ-GQL-RAFT-PERSIST | e2e_raft_persist_snapshot_membership (sham) | raft_persistent.zig |
| GAP-D017 | REQ-GQL-041 | e2e_distributed_cluster (commented out) | network_transport.zig |

#### Status Mismatches (20+ EXEMPT tokens with real implementations)

Files with EXEMPT tokens that should be promoted to IMPL: `twophase.zig` (11 tokens), `sharding.zig` (5 tokens), `cluster.zig` (4 tokens), `query_coordinator.zig` (4 tokens).

---

### B. Code Quality

#### Critical Quality Issues

| # | Finding | File:Line | Classification |
|---|---------|-----------|---------------|
| Q1 | `proposeCommand` discards all command data | `raft_consensus.zig:650-653` | Confirmed Bug |
| Q2 | `handleMessage` zeroes AppendEntries/InstallSnapshot | `raft_consensus.zig:615-643` | Confirmed Bug |
| Q3 | `applyUndoOperation` is a no-op stub | `twophase.zig:394-396` | Confirmed Bug |
| Q4 | `start()` blocks forever (defer join on infinite loops) | `cluster.zig:405-421` | Confirmed Bug |
| Q5 | `apply_callback` error silently swallowed | `raft_consensus.zig:682` | Confirmed Bug |

#### Code Duplication

- `cloneBindingRow` duplicated 3x across federation.zig, query_coordinator.zig, enhanced_query_coordinator.zig
- `freeBindingRow` duplicated 4x (adds query_transport.zig)
- `cloneSchema` duplicated 3x
- Raft `drainReady` duplicated in raft.zig and raft_consensus.zig
- 5 different `ShardInfo` structs across 5 files with incompatible fields
- Pagination logic copy-pasted 5x in enhanced_query_coordinator.zig

#### Dead Code

- `federation_root.zig`: entire file is dead (zero imports found)
- `cluster.zig`: `handleLeaveCluster`, `handleReplicateData`, `handleFailoverRequest`, `forwardToShard` are all stubs
- `raft_consensus.zig`: `freeMessage`, `freeLogEntryDeep` are no-ops
- `mod.zig`: `PartitionAwarePlanner` has hardcoded `["node1", "node2"]`

#### Thread Safety

- `federation_flag.zig:16`: `g_last_federation_mismatch` is a non-atomic `bool`
- `federation_latency_aggregate.zig:53-54`: `g_current`/`g_archive` are unsynchronized globals
- `twophase.zig:241`: `global_transport` has no synchronization
- `CoordinatorMetrics` counters incremented non-atomically

#### Compilation Issues

- `cluster.zig:609`: Uses `std.mem.copy` which was removed in Zig 0.15 (should be `@memcpy`)

#### Files Exceeding 800-Line Guideline

| File | Lines | Excess |
|------|-------|--------|
| federation.zig | 1,732 | 2.2x |
| twophase.zig | 1,281 | 1.6x |
| sharding.zig | 1,261 | 1.6x |
| enhanced_query_coordinator.zig | 1,236 | 1.5x |
| cluster.zig | 1,196 | 1.5x |

---

### C. Performance

#### P0 -- Critical (2 findings)

**PERF-D001: Mutex held during network I/O + 350ms sleep**

- `network_transport.zig:65-119`
- `self.mutex.lock()` held through QUIC connect, send, and 3 retries with 50/100/200ms sleep
- Impact: All inter-node communication serializes behind one lock. One slow peer blocks all cluster traffic.
- Fix: Lock only for peer-map lookup; release before I/O.

**PERF-D002: Mutex held during 5s QUIC handshake**

- `twophase.zig:141-201`
- `self.mutex.lock()` held through `waitForHandshake(5)` on cache miss
- Impact: One slow handshake blocks all 2PC operations for 5 seconds.
- Fix: Use per-endpoint locks or connection-in-progress flags.

#### P1 -- High (5 findings)

| # | Finding | File:Line | Impact |
|---|---------|-----------|--------|
| PERF-D003 | Sequential 2PC prepare O(N*RTT) | `twophase.zig:495-539` | 3x latency for 3 participants |
| PERF-D004 | Sequential 2PC commit with retry | `twophase.zig:550-581` | 700ms worst case per participant |
| PERF-D005 | Raft frame read spin-wait 200x5ms=1s | `raft_consensus.zig:348-396` | 1s blocking per frame on slow reads |
| PERF-D006 | Unbounded thread-per-connection | `cluster.zig:440-441` | ~8MB stack per thread, no limit |
| PERF-D007 | SpicePool created/destroyed per query | `query_coordinator.zig:148` | ~1-2ms overhead per distributed query |

#### P2 -- Medium (10 findings)

| # | Finding | File:Line |
|---|---------|-----------|
| PERF-D008 | Non-atomic global mismatch flag | `federation_flag.zig:16` |
| PERF-D009 | Non-atomic latency aggregates | `federation_latency_aggregate.zig:53-54` |
| PERF-D010 | Non-atomic stats counters | `enhanced_query_transport.zig` |
| PERF-D011-15 | Unbounded alloc from u32 length prefix (5 sites) | `raft_consensus.zig:375`, `twophase.zig:312,784`, `federation.zig:1354`, `query_transport.zig:843` |
| PERF-D016 | QueryCache has no size bound or eviction | `federation.zig:1126-1196` |
| PERF-D017 | ConsistentHash.getNodes uses O(n) linear scan | `sharding.zig:952-958` |
| PERF-D018 | Sequential federation remote operations | `federation.zig:766-779` |
| PERF-D019 | Federation materializes all rows before merge | `query_coordinator.zig:62-69` |

---

### D. Security

#### Critical (2 findings)

**SEC-D001: Unauthenticated Raft QUIC listener** (CWE-306)

- `cluster.zig:430-492`
- `networkLoop` accepts any QUIC connection and processes Raft frames with zero authentication.
- Attack: Send `RequestVote` with term=999999 to force leader stepdown. Send fabricated `AppendEntries` with graph mutations to corrupt data.
- Fix: Require mTLS with cluster-issued certificates or GEODE_CLUSTER_TOKEN pre-auth handshake.

**SEC-D002: Unauthenticated JOIN_CLUSTER + topology leak** (CWE-306, CWE-862)

- `cluster.zig:499-517`
- `handleJoinCluster` adds any node to cluster, triggers rebalancing, and returns full cluster topology.
- Attack: Send JOIN_CLUSTER message to add rogue node. Replication pushes data to attacker.
- Fix: Authenticate join requests with cluster token. Add node allowlisting.

#### High (5 findings)

| # | Finding | CWE | File:Line |
|---|---------|-----|-----------|
| SEC-D003 | 2PC has no app-layer auth | CWE-306 | `twophase.zig:140-391` |
| SEC-D004 | query_transport sends empty credentials | CWE-287 | `query_transport.zig:609-617` |
| SEC-D005 | Debug build auto-bypasses TLS (3 locations) | CWE-295 | `query_transport.zig:578`, `twophase.zig:161,343` |
| SEC-D006 | TLS downgrade via 3 inconsistent env vars | CWE-757 | Multiple files |
| SEC-D007 | Federation queries may bypass coordinator-side RLS | CWE-863 | `federation.zig:277-398` |

#### Medium (5 findings)

| # | Finding | CWE | File:Line |
|---|---------|-----|-----------|
| SEC-D008 | Unbounded alloc from u32 length prefix (5 sites) | CWE-770 | Multiple |
| SEC-D009 | No replay protection on Raft/2PC messages | CWE-294 | `cluster.zig`, `twophase.zig` |
| SEC-D010 | Cross-tenant leakage via federation | CWE-200 | `federation.zig:277-296` |
| SEC-D011 | Raft RPC has zero TLS configuration | CWE-319 | `raft_consensus.zig:181-218` |
| SEC-D012 | Topology leak in JOIN_CLUSTER response | CWE-200 | `cluster.zig:513-516` |

---

## Overall Assessment

The `src/distributed/` module is **architecturally ambitious but not production-ready**. The core distributed primitives (Raft consensus, 2PC, cluster replication) have structural issues that prevent them from functioning correctly:

1. **Raft consensus is non-functional**: Four independent layers (proposeCommand, handleMessage, protobuf conversion, replication) each independently discard or zero out data. No log entry can traverse the full path from proposal to follower application.

2. **2PC atomicity is broken**: The abort path's undo mechanism is a no-op stub. Aborted transactions leave partial writes on participants.

3. **Security is absent on the control plane**: The Raft listener, cluster join, and 2PC transport have no authentication. A network-adjacent attacker can join the cluster, inject consensus messages, and force premature transaction commits.

4. **Performance bottlenecks in critical paths**: Global mutexes held during network I/O (up to 5s) serialize all inter-node communication.

**The federation and distributed query subsystems are the most complete**, with working query forwarding, result merging (except union_distinct and hash_aggregate), and connection management. These subsystems have real tests and CANARY tracking.

**Recommended priority:**

1. Do not enable distributed/cluster features in production until Raft and 2PC issues are resolved
2. Add authentication to all inter-node communication before any multi-node deployment
3. Fix mutex-under-I/O patterns before load testing
4. Clean up phantom test references to restore CANARY governance accuracy

---

## Blockers

- No GitLab API access configured -- platform issues were not created/updated
- geodetestlab spec files `geode_distributed_queries.yml` and `geode_advanced_features.yml` could not be verified (not found in `../geode-test-harness/`)
- `cluster.zig:609` uses removed `std.mem.copy` -- may not compile on Zig 0.15

---

*Generated by full codebase audit on 2026-04-01*
