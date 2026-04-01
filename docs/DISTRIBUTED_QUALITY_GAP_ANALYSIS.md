# Distributed Module Code Quality Gap Analysis

**Date:** 2026-04-01
**Scope:** `src/distributed/` (20 files, 12,837 lines)

## Summary

| Severity | Count |
|----------|-------|
| Critical | 5 |
| High | 20+ |
| Medium | 10 |
| Low | 8 |

## Critical

### QUAL-D001: proposeCommand discards all command data

- **File:** `raft_consensus.zig:650-653`
- **Code:** `_ = cmd; self.inner.propose(&.{});`
- **Classification:** Confirmed Bug
- **Impact:** Every Raft proposal through raft_consensus.zig proposes empty bytes. The apply callback never sees actual command data. All distributed writes are silently lost.

### QUAL-D002: handleMessage zeroes AppendEntries/InstallSnapshot

- **File:** `raft_consensus.zig:615-643`
- **Code:** `.append_entries => |_| .{ .term = 0, .prev_log_index = 0, ... entries: &.{} }`
- **Classification:** Confirmed Bug
- **Impact:** Log replication and snapshot installation are no-ops. Raft consensus cannot replicate data.

### QUAL-D003: 2PC applyUndoOperation is a no-op

- **File:** `twophase.zig:394-396`
- **Code:** `fn applyUndoOperation(entry: UndoEntry) !void { _ = entry; }`
- **Classification:** Confirmed Bug
- **Impact:** 2PC abort does not roll back changes. Atomicity violated.

### QUAL-D004: cluster.zig start() blocks forever

- **File:** `cluster.zig:405-421`
- **Code:** `defer raft_thread.join()` on infinite-loop thread
- **Classification:** Confirmed Bug
- **Impact:** Calling thread hangs permanently. No shutdown mechanism exists.

### QUAL-D005: apply_callback error silently swallowed

- **File:** `raft_consensus.zig:682`
- **Code:** `_ = callback(self.allocator, .{ .write = entry.data }) catch {};`
- **Classification:** Confirmed Bug
- **Impact:** Committed entry application failures are lost. Silent data loss.

## High -- Code Duplication

| Finding | Files | Copies |
|---------|-------|--------|
| `cloneBindingRow` | federation.zig, query_coordinator.zig, enhanced_query_coordinator.zig | 3 |
| `freeBindingRow` | federation.zig, query_coordinator.zig, enhanced_query_coordinator.zig, query_transport.zig | 4 |
| `cloneSchema` | federation.zig, query_coordinator.zig, enhanced_query_coordinator.zig | 3 |
| Dual Raft wrappers | raft.zig (251L) vs raft_consensus.zig (703L) | 2 |
| `ShardInfo` struct | mod.zig, cluster.zig, sharding.zig, query_coordinator.zig, enhanced_query_coordinator.zig | 5 |
| `NodeRegistry` | query_coordinator.zig, enhanced_query_coordinator.zig | 2 |
| Pagination logic | enhanced_query_coordinator.zig (5 merge methods) | 5 |

**Fix:** Extract shared utilities to `distributed/result_utils.zig`. Consolidate Raft wrappers.

## High -- Dead Code

| Finding | File:Line |
|---------|-----------|
| `federation_root.zig` entire file (zero imports) | `federation_root.zig:1-15` |
| `handleLeaveCluster` stub (always returns OK) | `cluster.zig:997-1001` |
| `handleReplicateData` stub | `cluster.zig:1003-1006` |
| `handleFailoverRequest` stub | `cluster.zig:1175-1178` |
| `forwardToShard` stub | `cluster.zig:1167-1172` |
| `raft.zig handleMessage` discards all args | `raft.zig:147-156` |
| `PersistentStorage` all no-ops | `raft_consensus.zig:222-245` |
| `PartitionAwarePlanner` with hardcoded values | `mod.zig:29-147` |

## High -- Error Handling

| Finding | File:Line |
|---------|-----------|
| `loadPersistentState` failure silently ignored | `raft_persistent.zig:86` |
| `savePersistentState` failure silently ignored | `raft_persistent.zig:92` |
| 2PC commit marked successful after 3 failed retries | `twophase.zig:565-578` |
| Parse error returns empty result (no error indication) | `query_coordinator.zig:220-228` |
| 2PC network errors discarded with `_ = err` | `twophase.zig:518` |

## High -- Thread Safety

| Finding | File:Line |
|---------|-----------|
| `g_last_federation_mismatch` non-atomic bool | `federation_flag.zig:16` |
| `g_current`/`g_archive` globals no sync | `federation_latency_aggregate.zig:53-54` |
| `global_transport` no sync | `twophase.zig:241-242` |
| `CoordinatorMetrics` counters non-atomic | `query_coordinator.zig:836-858` |

## High -- Resource Leaks

| Finding | File:Line |
|---------|-----------|
| `handleNodeFailure` leaks old replica_nodes slice | `cluster.zig:533-541` |
| `promoteReplica` leaks old replica_nodes slice | `cluster.zig:581-589` |
| `determineAffectedShards` return value never freed | `cluster.zig:1088-1103` |

## Medium -- Compilation Issue

- `cluster.zig:609`: Uses `std.mem.copy` removed in Zig 0.15. Should be `@memcpy` or `std.mem.copyForwards`.

## Medium -- Oversized Files

| File | Lines | Guideline | Excess |
|------|-------|-----------|--------|
| federation.zig | 1,732 | 800 | 2.2x |
| twophase.zig | 1,281 | 800 | 1.6x |
| sharding.zig | 1,261 | 800 | 1.6x |
| enhanced_query_coordinator.zig | 1,236 | 800 | 1.5x |
| cluster.zig | 1,196 | 800 | 1.5x |

## Medium -- API Design Issues

| Finding | File:Line |
|---------|-----------|
| Two competing coordinators (DistributedCoordinator vs ClusterCoordinator) | `mod.zig` vs `cluster.zig` |
| Two competing Raft wrappers with diverging types | `raft.zig` vs `raft_consensus.zig` |
| Three PersistentStorage implementations | `raft_consensus.zig`, `raft_persistent.zig`, external library |

## Low -- Test Coverage Gaps

11 of 20 files have zero inline tests:

| File | Lines |
|------|-------|
| cluster.zig | 1,196 |
| twophase.zig | 1,281 |
| sharding.zig | 1,261 |
| enhanced_query_coordinator.zig | 1,236 |
| enhanced_query_transport.zig | 1,079 |
| query_transport.zig | 864 |
| query_planner.zig | 577 |
| txn_coordinator.zig | 542 |
| value_convert.zig | 204 |
| network_transport.zig | 170 |
| raft_persistent.zig | 153 |

---

*Generated 2026-04-01*
