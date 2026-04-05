# Distributed Module Master Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the distributed module (Raft, 2PC, federation, sharding) production-ready by executing the 8 existing sub-plans in dependency order, closing all ~120 distributed gaps across GAP, PERF, SECURITY, and QUALITY gap analysis files.

**Architecture:** The distributed module has 27 files / 13,782 LOC. Transport and federation query execution work. Consensus (Raft), transactions (2PC), and query planning are scaffolded stubs. This plan sequences the sub-plans to build from the bottom up: consensus first, then transactions, then query coordination, then security and performance hardening.

**Tech Stack:** Zig 0.15.1, external `raft` library (`gitlab.com/devnw/zig/raft`), QUIC transport, protobuf (raft_schema, distributed_schema)

---

## Prerequisites (Completed 2026-04-05)

These items were closed during the April 5 full codebase audit:

- [x] **GAP-0503:** Distributed module gated behind `--enable-experimental-distributed` flag
- [x] **SEC-D005:** Debug build TLS bypass removed from twophase.zig and query_transport.zig
- [x] **SEC-D006:** TLS downgrade env vars consolidated to single `GEODE_CLUSTER_INSECURE`
- [x] **SEC-10:** Federation refuses connections when `GEODE_CLUSTER_TOKEN` is unset
- [x] **GAP-0504:** CANARY markers fixed in distributed module (40+ phantom TESTED→IMPL)

---

## Execution Phases

### Phase 1: Consensus Foundation (Week 1-2)

**Estimated effort:** 2-3 weeks

These two plans are independent and can run in parallel:

- [ ] **Sub-plan 1:** [Raft Consolidation](2026-04-01-raft-consolidation.md) (18 steps)
  - Wire PersistentStorage to file-backed term/votedFor
  - Convert raft.zig to shim delegating to raft_consensus
  - Delete dead code (federation_root.zig)
  - Add architecture documentation
  - **Closes:** GAP-D002 (handleMessage zeroes fields), GAP-D003 (proposeCommand discards), GAP-D008 (PersistentStorage stubs), GAP-D026 (protobuf drops data)

- [ ] **Sub-plan 2:** [Replication & 2PC Undo](2026-04-01-replication-and-2pc-undo.md) (11 steps)
  - Implement GraphStore.serializeSnapshot for cluster replication
  - Wire snapshot into cluster.zig replication path
  - Implement applyUndoOperation for CREATE reversal
  - **Closes:** GAP-D001 (empty snapshots), GAP-D004 (2PC abort no-op)

### Phase 2: Cluster Security (Week 2-3)

**Depends on:** Phase 1 (Raft must handle messages correctly before adding auth)

- [ ] **Sub-plan 3:** [Cluster Authentication](2026-04-01-cluster-authentication.md) (18 steps)
  - Add GEODE_CLUSTER_TOKEN auth to Raft listener
  - Add auth to JOIN_CLUSTER handler
  - Add auth to 2PC transport connections
  - Add auth to query_transport connections
  - **Closes:** SEC-D001 (unauthenticated Raft), SEC-D002 (JOIN_CLUSTER no auth), SEC-D003 (2PC no auth), SEC-D004 (query_transport empty creds)

### Phase 3: Query Correctness (Week 3-4)

**Depends on:** Phase 1 (correct replication needed for distributed queries)

These two plans are independent and can run in parallel:

- [ ] **Sub-plan 4:** [Federation Correctness](2026-04-01-federation-correctness.md) (13 steps)
  - Fix union_distinct to actually deduplicate results
  - Fix hash_aggregate to compute real sum/count/avg values
  - **Closes:** GAP-D005 (union_distinct returns duplicates), GAP-D006 (hash_aggregate hardcoded zeros)

- [ ] **Sub-plan 5:** [Distributed Query Planner](2026-04-01-distributed-query-planner.md) (17 steps)
  - Wire stubs to real CBO statistics
  - Implement shard-local query rewriting
  - Add actual selectivity estimation
  - Parallelize federation remote operations
  - **Closes:** GAP-D007 (query_planner scaffolded), GAP-D027 (no CANARY tokens)

### Phase 4: Hardening (Week 4-6)

**Depends on:** Phases 1-3 (functional module needed before optimization)

These three plans are independent and can run in parallel:

- [ ] **Sub-plan 6:** [Security Hardening](2026-04-01-security-hardening.md) (17 steps)
  - Add coordinator-side RLS enforcement for federated results
  - Implement replay protection (nonce tracking)
  - Add tenant isolation in federation queries
  - Implement atomic Raft state persistence (fsync + rename)
  - **Closes:** SEC-D007 (federation skips RLS), SEC-D008 (unbounded alloc), SEC-D009 (no replay protection), SEC-D010 (cross-tenant leakage), SEC-D011 (Raft zero TLS)

- [ ] **Sub-plan 7:** [Performance Optimization](2026-04-01-distributed-performance.md) (19 steps)
  - Eliminate per-call SpicePool allocation
  - Parallelize 2PC prepare (sequential → concurrent)
  - Add connection limits to cluster listener
  - Replace non-atomic globals with atomic counters
  - Add QueryCache eviction (LRU, bounded)
  - Optimize ConsistentHash to O(log n)
  - **Closes:** PERF-D001 through PERF-D022

- [ ] **Sub-plan 8:** [Test Coverage & Quality](2026-04-01-test-coverage-and-quality.md) (12 steps)
  - Replace sham Raft test with real assertions
  - Add 2PC transaction unit tests
  - Extract duplicated result utilities (cloneBindingRow, freeBindingRow, cloneSchema)
  - Add value_convert unit tests
  - Create geodetestlab spec stubs for distributed features
  - **Closes:** GAP-D009 through GAP-D017, GAP-D028, QUAL-D001 through QUAL-D005+

---

## Dependency Graph

```
Phase 1 (parallel):
  ├── Raft Consolidation ──────────┐
  └── Replication & 2PC Undo ──────┤
                                   │
Phase 2 (sequential):              │
  └── Cluster Authentication ──────┤
                                   │
Phase 3 (parallel):                │
  ├── Federation Correctness ──────┤
  └── Distributed Query Planner ───┤
                                   │
Phase 4 (parallel):                │
  ├── Security Hardening ──────────┤
  ├── Performance Optimization ────┤
  └── Test Coverage & Quality ─────┘
```

## Total Effort

| Phase | Plans | Steps | Estimated Duration |
|-------|-------|-------|--------------------|
| 1 | 2 (parallel) | 29 | 2-3 weeks |
| 2 | 1 | 18 | 1 week |
| 3 | 2 (parallel) | 30 | 1-2 weeks |
| 4 | 3 (parallel) | 48 | 2-3 weeks |
| **Total** | **8** | **125** | **6-9 weeks** |

## Gap Coverage Matrix

| Gap Analysis File | Total Gaps | Addressed by Plans | Remaining |
|-------------------|------------|-------------------|-----------|
| DISTRIBUTED_GAP_ANALYSIS.md | 28 | 28 (Phases 1-3) | 0 |
| DISTRIBUTED_PERF_GAP_ANALYSIS.md | 22 | 22 (Phase 4, Plan 7) | 0 |
| DISTRIBUTED_SECURITY_GAP_ANALYSIS.md | 14 | 12 (Phases 2,4) | 2 (SEC-D012, SEC-D013 depend on full multi-tenancy) |
| DISTRIBUTED_QUALITY_GAP_ANALYSIS.md | 43+ | 43+ (Phase 4, Plan 8) | 0 |
| **Total** | **~107** | **~105** | **~2** |

## Validation Criteria

After all 8 sub-plans are complete:

1. **Unit tests:** `zig build test --summary all` passes with 0 failures
2. **Raft consensus:** Cluster of 3 nodes elects leader, replicates writes, survives single-node restart
3. **2PC transactions:** Distributed COMMIT applies changes on all participants; ABORT rolls them back
4. **Federation queries:** `MATCH (n) RETURN count(n)` across 2 nodes returns correct count (not doubled)
5. **Authentication:** All inter-node communication requires GEODE_CLUSTER_TOKEN
6. **Performance:** 2PC prepare parallelized (latency < 1.5x single-node RTT for 3 participants)
7. **CANARY accuracy:** All distributed CANARY markers have STATUS=TESTED with real test references
8. **Feature gate:** `--enable-experimental-distributed` flag can be removed (module is production-ready)

## Notes

- The `--enable-experimental-distributed` gate (GAP-0503) stays in place until all 8 sub-plans pass validation
- Each sub-plan should be executed in its own worktree to allow parallel development
- Sub-plans within a phase can be assigned to different agents/developers
- Commit after each task within a sub-plan (125 total commits expected)
- Run `zig build test` after every step — do not batch test runs
