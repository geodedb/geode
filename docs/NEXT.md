# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Now (P0)

1. **Doc sync tool Zig compatibility fix (REQ-GQL-018)**
   - **Why**: Tool currently fails due to bufferedReader API change in newer Zig versions
   - **What**: Update src/tools/doc_sync.zig to use current Zig 0.15.1 std.io API
   - **Acceptance**: `zig run src/tools/doc_sync.zig` executes without compilation errors; produces requirement analysis
   - **ISO**: 24.x
   - **Deps**: src/tools/doc_sync.zig
   - **Scope**: S
   - **DRI**: docs

2. **Numeric promotion matrix documentation (REQ-GQL-013)**
   - **Why**: Clarify coercion rules and add TypeMismatch.DivZero subclass for stable diagnostics
   - **What**: Add promotion table to README; introduce TypeMismatch.DivZero subclass code
   - **Acceptance**: `RETURN 1/0` emits TypeMismatch.DivZero; mixed int+decimal operations follow documented table
   - **ISO**: 16.x, 23.2
   - **Deps**: src/eval.zig, src/diagnostics.zig
   - **Scope**: S
   - **DRI**: core

3. **MVCC conflict detection completion (REQ-GQL-027)**
   - **Why**: Current implementation lacks write-write conflict detection and lock management
   - **What**: Add conflict detection matrix, lock escalation, and proper abort handling
   - **Acceptance**: Concurrent conflicting updates produce proper abort with status_class 25000; snapshot isolation maintained
   - **ISO**: §8
   - **Deps**: src/txn/manager.zig, WAL integration
   - **Scope**: L
   - **DRI**: core

## Next (P1)

1. **Path patterns execution (REQ-GQL-017)**
   - **Why**: Enable bounded path queries with deterministic tie-breaking
   - **What**: Implement PathExpand operator with BFS; document tie-break policy (length, start_id, end_id)
   - **Acceptance**: `MATCH (a)-[*1..3]->(b) RETURN a, b` returns stable ordering; UA005/UA006 flags present
   - **ISO**: 22.4, UA005/UA006
   - **Deps**: src/planner.zig, storage adjacency
   - **Scope**: L
   - **DRI**: core

2. **Storage catalog persistence (REQ-GQL-025)**
   - **Why**: Complete persistent storage layer with catalog and adjacency structures
   - **What**: Add catalog persistence, CSR adjacency storage, free space management
   - **Acceptance**: Database restart preserves schema metadata; adjacency scans use CSR format
   - **ISO**: impl-defined storage management
   - **Deps**: src/storage/catalog.zig, src/storage/page_manager.zig
   - **Scope**: L
   - **DRI**: storage

3. **Index selectivity accuracy (REQ-GQL-039)**
   - **Why**: Improve cost-based planning with better cardinality estimates
   - **What**: Enhance SelectivityEstimator with HLL++ sketches and adaptive sampling
   - **Acceptance**: Selective queries choose index scan; non-selective choose full scan; EXPLAIN shows accurate selectivity estimates
   - **ISO**: 14.4 (MATCH planning)
   - **Deps**: src/index/selectivity.zig, src/planner.zig
   - **Scope**: M
   - **DRI**: core

4. **WAL compaction automation (REQ-GQL-026)**
   - **Why**: Prevent unbounded WAL growth with automated segment reclamation
   - **What**: Add background compaction based on configurable thresholds and checkpoint boundaries
   - **Acceptance**: Long-running database automatically reclaims old WAL segments; configurable via GEODE_WAL_COMPACT_INTERVAL
   - **ISO**: §8
   - **Deps**: src/wal/wal.zig, src/server/main.zig
   - **Scope**: M
   - **DRI**: storage

5. **Memory governance enhancements (REQ-GQL-037)**
   - **Why**: Improve memory safety and prevent OOM conditions
   - **What**: Enhanced spill triggers, memory pressure detection, graceful degradation
   - **Acceptance**: Large queries spill to disk before OOM; memory pressure metrics in PROFILE
   - **ISO**: impl-defined resource management
   - **Deps**: src/util/memory_governor.zig, src/server/main.zig
   - **Scope**: M
   - **DRI**: core

6. **Text formatting parity (REQ-GQL-023)**
   - **Why**: Ensure consistent multi-format outputs for automation and human consumption
   - **What**: Complete text serializer for all EXPLAIN/PROFILE variants
   - **Acceptance**: `PROFILE RETURN 1` with `--format=txt` matches golden file; all JSON fields have text equivalents
   - **ISO**: 24.x (conformance disclosure)
   - **Deps**: src/util/text_formatter.zig, src/client/main.zig
   - **Scope**: S
   - **DRI**: core

## Later (P2+)

1. **Distributed scaffold implementation (REQ-GQL-028/042)**
   - **Why**: Foundation for future scale-out and high availability
   - **What**: Raft leader election, 2PC coordinator interfaces, shard-aware query planning
   - **Acceptance**: Feature-flagged distributed mode supports basic replication; 2PC prepare/commit phases work
   - **ISO**: impl-defined distribution semantics
   - **Deps**: new dist/ module, src/txn/ integration
   - **Scope**: L
   - **DRI**: dist

2. **Lock manager implementation (REQ-GQL-044)**
   - **Why**: Enable proper concurrency control and deadlock detection
   - **What**: Reader/writer locks, deadlock detection, lock escalation policies
   - **Acceptance**: Concurrent transactions properly serialize; deadlocks detected and resolved
   - **ISO**: §8
   - **Deps**: src/txn/manager.zig, new locking module
   - **Scope**: L
   - **DRI**: core

3. **Page compaction and vacuum (REQ-GQL-040)**
   - **Why**: Prevent space amplification in slotted page storage
   - **What**: Background vacuum process, fragmentation detection, space reclamation
   - **Acceptance**: Fragmented pages automatically compacted; space utilization >85% maintained
   - **ISO**: impl-defined storage management
   - **Deps**: src/storage/page_manager.zig
   - **Scope**: M
   - **DRI**: storage

4. **Encryption at rest design (REQ-GQL-038)**
   - **Why**: Prepare for compliance and data protection requirements
   - **What**: Design document with key hierarchy, KMS integration, threat model
   - **Acceptance**: Design document approved; encryption interfaces defined
   - **ISO**: impl-defined security
   - **Deps**: docs/, new security module design
   - **Scope**: M
   - **DRI**: security

5. **Recovery harness expansion (REQ-GQL-041)**
   - **Why**: Validate crash safety and WAL correctness under stress
   - **What**: Deterministic crash injection, large-scale fuzz testing, replay verification
   - **Acceptance**: 1000+ randomized crash scenarios pass recovery verification in <30s each
   - **ISO**: §8
   - **Deps**: tests/, src/wal/
   - **Scope**: M
   - **DRI**: storage

6. **Sharding strategy configuration (REQ-GQL-043)**
   - **Why**: Enable optimal data distribution for different workloads
   - **What**: Edge-cut vs vertex-cut partitioning, hybrid strategies, partition metadata
   - **Acceptance**: Configurable partitioning strategies; query planner respects partition boundaries
   - **ISO**: impl-defined distribution
   - **Deps**: dist/ module, src/planner.zig
   - **Scope**: L
   - **DRI**: dist

7. **Advanced query optimization (REQ-GQL-ORDER-OPT)**
   - **Why**: Improve performance for complex queries with ordering and limits
   - **What**: Top-k optimization, ranked enumeration, adaptive re-optimization
   - **Acceptance**: `ORDER BY ... LIMIT` queries show early termination in PROFILE; adaptive reopt triggers on estimate misses
   - **ISO**: 16.18–16.19
   - **Deps**: src/planner.zig, src/exec.zig
   - **Scope**: L
   - **DRI**: core

8. **Secret scanning automation (REQ-GQL-045)**
   - **Why**: Prevent accidental secret exposure in logs and code
   - **What**: Automated secret detection in CI, runtime log filtering
   - **Acceptance**: CI fails on detected secrets; runtime logs never contain sensitive data
   - **ISO**: impl-defined security
   - **Deps**: CI configuration, logging infrastructure
   - **Scope**: S
   - **DRI**: security

## Cutline

Excluded this milestone: full GPU operators, learned cost model integration, encryption implementation (beyond design), full distributed query shipping, advanced WCOJ attribute ordering heuristics, path cardinality estimation research prototypes. Rationale: focus on correctness, durability, and core GQL conformance first.

## Recent Progress (Snapshot)

- ✅ **Memory governance** (REQ-GQL-037): Added memory limit tracking with spill triggers for HashAgg/Sort/Distinct
- ✅ **WAL skip ratio** (REQ-GQL-026): Exposed skip_ratio metric in WAL recovery; test validates ≥0.60 efficiency
- ✅ **Storage checksum diagnostics** (REQ-GQL-026): Added mapStorageError for PageChecksumMismatch → StoragePageChecksum diagnostic
- ✅ **GROUP BY HashAgg** (REQ-GQL-016): Execution complete in exec.runGroupedQuery; comprehensive test coverage
- ✅ **Transaction baseline** (REQ-GQL-027): BEGIN/COMMIT/ROLLBACK with proper status_class responses (00000/25000)
- ✅ **WAL compaction automation** (REQ-GQL-026): Configurable via GEODE_WAL_COMPACT_INTERVAL (default 5 commits)
- ✅ **Index selectivity estimator** (REQ-GQL-039): Cost-based decisions with adaptive learning
- ✅ **NodeIndexScan metadata** (REQ-GQL-039): Enhanced PROFILE with index_name and selectivity_est
- ✅ **Text formatting parity** (REQ-GQL-023): EXPLAIN/PROFILE text output with --format=txt
- ✅ **Diagnostics precedence** (REQ-GQL-014/030): UA002 folding with deterministic precedence rules
- ✅ **Binary protocol stability** (REQ-GQL-021/022): SCHEMA/BINDINGS framing with status codes
- ✅ **Set operations** (REQ-GQL-003): UNION/INTERSECT/EXCEPT with DISTINCT/ALL semantics
- ✅ **Expression engine** (REQ-GQL-004/005): CASE expressions, string predicates, mixed-type arithmetic
- ✅ **Temporal literals** (REQ-GQL-008): DATE/TIME/DATETIME parsing with normalization

## Summary (Top Risks)

1. **Doc sync tool compatibility** — immediate blocker for requirement validation
2. **MVCC conflict detection** — risk of data consistency anomalies
3. **Missing distributed scaffold** — scale-out blocked
4. **Storage catalog persistence** — limits production readiness
5. **Path pattern execution** — limits query expressiveness

First 8 tasks enumerated across Now+Next cover immediate correctness, observability, and core functionality gaps.