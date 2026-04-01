# Distributed Module Gap Closure Report

**Date:** 2026-04-01
**Scope:** `src/distributed/`
**Branch:** `session/20260401`
**Commits:** 9

---

## Summary

| Status | Count |
|--------|-------|
| Closed | 42 |
| Won't Do | 26 |
| Blocked | 0 |
| Remaining Open | 39 |
| **Total Findings** | **107** |

## Closed Items (42)

### Batch 1: Raft Command Serialization (Critical -- GAP-D002, GAP-D003, GAP-D026, QUAL-D001, QUAL-D002, QUAL-D005)

**Commit:** `19ae991f fix(distributed): wire Raft command serialization and field passthrough`

| Gap-ID | Domain | Description | Resolution |
|--------|--------|-------------|------------|
| GAP-D003 / QUAL-D001 | Gap/Quality | proposeCommand discards command content | Serializes Command via protobuf RaftCommand before calling inner.propose() |
| GAP-D002 / QUAL-D002 | Gap/Quality | handleMessage zeroes AppendEntries/InstallSnapshot | Passes through all fields including entries conversion |
| GAP-D026 | Gap | Protobuf conversion drops entries and snapshot data | messageToProto/protoToMessage now carry entries and snapshot data |
| QUAL-D005 | Quality | apply_callback error silently swallowed | Errors are now logged with @errorName |

### Batch 2: Unbounded Allocation Guards (SEC-D008, PERF-D011-D015)

**Commit:** `bad91f81 fix(distributed): reject oversized wire frames before allocation (max 16MiB)`

| Gap-ID | Domain | Description | Resolution |
|--------|--------|-------------|------------|
| SEC-D008 | Security | Unbounded alloc from u32 length prefix (5 sites) | Added `if (msg_len > 16*1024*1024) return error.FrameTooLarge` at all 5 sites |
| PERF-D011-D015 | Performance | Same 5 allocation sites | Same fix |

### Batch 3: Debug TLS Bypass Removal (SEC-D005)

**Commit:** `ae1ccbbe fix(distributed): remove debug-mode TLS bypass in 2PC and query transport`

| Gap-ID | Domain | Description | Resolution |
|--------|--------|-------------|------------|
| SEC-D005 | Security | Debug build auto-bypasses TLS (3 locations) | Removed `builtin.mode == .Debug` bypass from query_transport.zig and twophase.zig (x2) |

### Batch 4: Thread Safety (PERF-D008, PERF-D009, QUAL thread-safety)

**Commit:** `d014d784 fix(distributed): make federation flag atomic and protect latency aggregates with mutex`

| Gap-ID | Domain | Description | Resolution |
|--------|--------|-------------|------------|
| PERF-D008 | Performance | Non-atomic g_last_federation_mismatch | Replaced with std.atomic.Value(bool), updated all read/write sites |
| PERF-D009 | Performance | Non-atomic g_current/g_archive | Added g_mutex protecting all access |
| QUAL (thread) | Quality | Global mutable state without sync (3 findings) | Addressed by atomic + mutex |

### Batch 5: Mutex-During-I/O Fix (PERF-D001, PERF-D002)

**Commit:** `32bf4948 perf(distributed): release mutex before network I/O in transport and 2PC`

| Gap-ID | Domain | Description | Resolution |
|--------|--------|-------------|------------|
| PERF-D001 | Performance | Mutex held during QUIC send + 350ms retry | Split lock: copy peer info under lock, send lock-free |
| PERF-D002 | Performance | Mutex held during 5s QUIC handshake | Split lock: cache check under lock, handshake lock-free, re-lock with double-check |

### Batch 6: cluster.zig Fixes (QUAL-D004, QUAL compilation, QUAL resource leaks)

**Commit:** `cc33a184 fix(distributed): fix Zig 0.15 memcpy, resource leaks, and cluster shutdown`

| Gap-ID | Domain | Description | Resolution |
|--------|--------|-------------|------------|
| QUAL (compilation) | Quality | std.mem.copy removed in Zig 0.15 | Replaced with @memcpy |
| QUAL (leaks) | Quality | handleNodeFailure/promoteReplica leak old slices | Free old replica_nodes before reassignment |
| QUAL (leaks) | Quality | determineAffectedShards return value leaked | Added defer free at call site |
| QUAL-D004 | Quality | start() blocks forever | Added shutdown_flag atomic, stop()/join() methods, loop exit conditions |

### Batch 7: Spin-Wait Optimization (PERF-D005)

**Commit:** `1908760e perf(distributed): reduce Raft frame read spin-wait from 5ms to 200us`

| Gap-ID | Domain | Description | Resolution |
|--------|--------|-------------|------------|
| PERF-D005 | Performance | Raft frame read 200x5ms=1s spin-wait | Reduced to 5000x200us, same 1s timeout but 25x better responsiveness |

### Batch 8: CANARY Status Promotions (GAP-D018-D025)

**Commit:** `aca974a7 chore(distributed): promote CANARY status EXEMPT->IMPL for implemented functions`

20+ CANARY tokens promoted from EXEMPT to IMPL across cluster.zig, twophase.zig, query_coordinator.zig, sharding.zig.

### Batch 9: Phantom Test Cleanup (GAP-D009-D015)

**Commit:** `05a8a607 chore(distributed): clean up phantom test references in CANARY tokens`

9 CANARY tokens downgraded from TESTED to IMPL with phantom TEST= references removed.

---

## Won't Do Items (26)

| Category | Count | Reason |
|----------|-------|--------|
| Architectural rewrites | 6 | query_planner.zig scaffold, dual Raft wrappers, dual coordinators, code duplication extraction, file splitting, API consolidation |
| Security infrastructure | 8 | Cluster auth (mTLS/token), JOIN_CLUSTER auth, 2PC auth, query_transport credentials, TLS env var consolidation, RLS federation, replay protection, tenant isolation |
| Performance optimization | 6 | Sequential 2PC parallel, thread pool, SpicePool reuse, QueryCache eviction, ConsistentHash binary search, streaming merge |
| Testing infrastructure | 4 | e2e_distributed_cluster, twophase unit tests, raft_persist real assertions, geodetestlab specs |
| Feature implementation | 2 | union_distinct deduplication, hash_aggregate real aggregation |

All Won't Do items require either architectural design decisions, external infrastructure, or dedicated feature work beyond the scope of gap closure.

---

## Verification

| Check | Result |
|-------|--------|
| `zig build test` | PASS (exit 0) |
| All 9 commits | Clean cherry-pick, no conflicts |
| Pre-commit hooks | PASS (per agent reports) |
| Regression | None detected |

---

## Files Modified

| File | Batches | Changes |
|------|---------|---------|
| `src/distributed/raft_consensus.zig` | 1, 2, 7 | Command serialization, field passthrough, frame guard, spin-wait |
| `src/distributed/cluster.zig` | 6, 8, 9 | memcpy, leaks, shutdown, CANARY updates |
| `src/distributed/twophase.zig` | 2, 3, 5, 8 | Frame guard, TLS bypass, mutex fix, CANARY updates |
| `src/distributed/query_transport.zig` | 2, 3, 9 | Frame guard, TLS bypass, CANARY updates |
| `src/distributed/federation.zig` | 2, 4 | Frame guard, atomic flag reads |
| `src/distributed/federation_flag.zig` | 4 | Atomic bool |
| `src/distributed/federation_latency_aggregate.zig` | 4 | Mutex protection |
| `src/distributed/federation_root.zig` | 4 | Atomic flag reads |
| `src/distributed/network_transport.zig` | 5 | Mutex-during-I/O fix |
| `src/distributed/query_coordinator.zig` | 8 | CANARY updates |
| `src/distributed/sharding.zig` | 8 | CANARY updates |
| `src/distributed/enhanced_query_coordinator.zig` | 9 | CANARY updates |
| `src/distributed/enhanced_query_transport.zig` | 9 | CANARY updates |

**13 files modified** across 9 commits.

---

*Generated 2026-04-01*
