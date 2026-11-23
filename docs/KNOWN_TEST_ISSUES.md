# Known Test Issues

This document is the canonical, evidence-backed baseline of the local Zig test
suite (`zig build test-*` steps) plus the historical geodetestlab integration
numbers. It is rebaselined from a single real run — see the metadata block
below — under GAP-0860.

> **How to refresh:** re-run the per-step sweep (commands in "Reproduction"
> below), then rewrite the per-step table from THAT run. The geodetestlab
> integration suite lives in `../geode-test-harness` and requires a separate
> harness run (`make test` / `make test-everything-otel`); record those numbers
> as a dated historical snapshot until a fresh harness run is captured.

## Canonical Local Baseline (2026-06-10)

> **Status 2026-11-15:** the counts in this section are historical. The last
> full per-step sweep is the 2026-06-11 one below (236 PASS, 0 FAIL,
> 1 TIMEOUT, 3 SKIP of 240 steps). `build.zig` now registers about 1,000
> named `test-*` steps and no full sweep of them has been recorded, so there
> is no current pass count; the "expected baseline 175/179" figures below
> describe the 179-step set of 2026-06-10 only. Every named step runs in the
> sharded aggregate `zig build test` or is listed in `build.zig`'s
> `not_in_aggregate_steps` (see "Which named steps the aggregate runs"); the
> intentionally red reproduction on that list on 2026-11-22 is
> `test-sonny2848-tenant-subquery-aggregation` (row below);
> `test-sonny2822-update-counts` (resolved 2026-11-22) runs in the
> aggregate.
> `test-sonny6571-schema-names` (resolved 2026-11-15, SONNY-6590; green
> twice more on graph-storage v0.4.22), `test-sonny6595-wal-drain`
> (resolved 2026-11-16), `test-sonny2979-txn-crash-atomicity` (resolved
> 2026-11-16) and `test-sonny6658-autocommit-crash-atomicity` (resolved
> 2026-11-16) run in the aggregate.

| Field | Value |
|---|---|
| Date | 2026-06-10 (UTC) |
| Commit | `faac1f3e` (branch `gap-closure-2026-06-09`) |
| Zig | 0.16.0 |
| Host | 32-core x86_64 (znver2), Linux 6.17 |
| Env | `GEODE_MASTER_KEY` set to a 32-byte test value (required by FLE-backed tests) |
| Method | each named `test-*` build step run in isolation, 300 s per-step timeout |

**Result (historical, at `faac1f3e`): 175 named `test-*` steps — 167 PASS, 6 FAIL, 2 TIMEOUT, 0 not-run (count-pushdown reclassified PASS after a 15-min re-run; the original 300 s sweep scored it TIMEOUT).** For the current expected baseline after the GAP-0863 fixes, see the refresh block below.

### Round-end full sweep (2026-06-11, post Task 42) — 237/240 runnable PASS, 0 FAIL

Full per-step sweep of all 240 named `test-*` steps at the end of the
`gap-closure-2026-06-10` round (300 s per-step timeout, parallel-load
conditions):

| Field | Value |
|---|---|
| Result | **236 PASS, 0 FAIL, 1 TIMEOUT, 3 SKIP** |
| TIMEOUT | `test-count-pushdown` — contention only: passes 2/2 solo (29/29 steps) immediately after the sweep |
| SKIP (intentional) | `test-cluster-3node-subprocess` (known hang, GAP-0838 family), `test-cluster-replicable-mutations` (intentionally-red TDD repro), `test-all` (aggregate) |
| Effective | **237/240 runnable steps pass; the only non-running steps are the 3 documented skips** |

The step count grew 179 → 240 this round (new named steps for GAP-0514
Phase 6 promotions, GAP-086x/088x regressions, test-wal, test-iso-conformance,
test-gql-conformance, distributed/sharding/KMS suites, etc.).

### GAP-0863 refresh (2026-06-10, commit `0eefbb9a`) — expected baseline 174/179

The GAP-0863 test-gate fixes landed on `gap-closure-2026-06-10`
(`487a2424` test-e2e compile, `5083a30e` perf-c FLE teardown, `4f689520`
stream-pool observation; plus `8bdb9737` FLE-catalog isolation). Each
formerly-failing step was re-run in isolation on the idle 32-core baseline
host at commit `0eefbb9a` (same env as the sweep):

| Step | 2026-06-10 re-run result |
|---|---|
| `test-perf-c-introspection-index` | **PASS** — 8/8, 0 leaks (was: 3 FLE leaks) |
| `test-stream-pool-concurrent-lanes` | **PASS** — 3/3 (was: `max_concurrent >= 2` assertion) |
| `test-e2e` | **gql_conformance FIXED 2026-06-11 (GAP-0892, commit `8833fc4a`)** — the suite's only stable failures (T11/T12/T14) are gone: `gql_conformance` is 21/21, T1–T20 plus the `ZZ_cleanup` teardown (also runnable standalone via the NEW `zig build test-gql-conformance`). A 2026-06-11 re-run under heavy parallel build load scored 83/86 steps / 69/71 tests with 2 DIFFERENT, load-sensitive failures: `tests/test_perf_optimizations.zig` GAP-0203 Fix #4 (QUIC readPacket 5 s deadline; passes idle — 18/18 on one idle re-run, 17/18 on another, flake class) and `tests/integration/test_server_memory_pressure.zig` (RSS read returned 0 under load; passes idle). An idle-host re-run is owed at the Pass-12 rebaseline before declaring the step stably green. |
| `test-perf` | **PASS — reclassified** (see row below): exits 0 on two consecutive idle-host runs, 44/48 tests + 4 opt-in slow-bench skips |
| `test-gpu` | **RESOLVED 2026-06-11 (GAP-0878)** — compiles and PASSES (16/16 steps; 2 Vulkan tests pass, hardware-dispatch test gated behind `GEODE_GPU_DISPATCH_TESTS=1`; see row below) |
| `test-cluster-3node-subprocess` | not re-run (known reliable hang; entry kept below) |

Four named steps were also **added** since the `faac1f3e` sweep, so the
denominator is now **179**: `test-raft-apply` (27/27 PASS),
`test-raft-hardstate-durability` (2/2 PASS), `test-txn-coordinator-2pc`
(0/4 then — all 4 protobuf-union-gated self-skips; 4/4 run and pass since
SONNY-6484, on the native G2PC write set), and
`test-cluster-replicable-mutations` (TIMEOUT at 300 s — an *intentionally
red* TDD reproduction of the 2026-06-09 cluster write-replication gaps; 3-node
subprocess family, see row below).

**New expected baseline: 179 named `test-*` steps — 175 PASS, 1 FAIL
(`test-e2e`), 3 TIMEOUT (`test-all`, `test-cluster-3node-subprocess`,
`test-cluster-replicable-mutations`).** (`test-gpu` moved FAIL→PASS on
2026-06-11 via GAP-0878; new `test-gap*` steps added this round are counted
at the next full re-sweep.)
The per-step re-runs above are the evidence for the delta from 167/175; a
full 179-step re-sweep is owed at the next rebaseline.

> **Update 2026-06-10:** the sharded pre-push gate
> (`zig build test -Dtest-shard-total=4 -Dtest-shard-index=0..3` under
> `CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1`, no ambient `GEODE_MASTER_KEY`) is now
> GREEN on all four shards (0:158/158, 1:207/207, 2:182/182, 3:102/102; the
> only "skips" are the opted-out subprocess-cluster tests and the
> protobuf-union-gated 2PC tests). Two defects that had blocked it were fixed:
> (1) cross-test FLE-catalog contamination via the shared
> `/tmp/geode_fle_catalog.dat` (see `test-simple-merge-fastpath` row below), and
> (2) the `graph_store_unit_tests` compile blocker (see "RESOLVED" section
> below). The per-step sweep table above predates those fixes and is otherwise
> still representative for the standalone `test-*` steps.

`zig build` (the production binary) compiles clean. The 174 passing steps cover
the parser/lexer, planner, storage/MVCC/WAL, index types, security/auth/FLE
wiring, transport, cluster bootstrap/identity/steady-state, RLS, GPS policy,
LSP/MCP, timeseries, FTS, and the bulk-ingest fast paths.

### Failures and hangs (named, with evidence)

Each was re-confirmed by re-running the step in isolation on an idle host (so
these are not load-induced flakes unless noted).

| Step | Result | Root cause (verified) |
|---|---|---|
| `test-count-pushdown` | SLOW — passes with a longer timeout | **Not a hang.** Re-verified 2026-06-10 with a 15-minute timeout: completes with exit 0 (2/2 tests). The step takes ~7–13 minutes (large-store count benchmarks), so it exceeds the 300 s sweep timeout. Adjusted baseline: 167/175 pass. Treat as a slow step needing a per-step timeout ≥ 15 min, not a defect. |
| `test-simple-merge-fastpath` | **RESOLVED 2026-06-10** (11/11 pass) | **Was a test-isolation defect, not a bulk-MERGE bug.** `test "bulkMergeNode apply_on_match updates existing node (true upsert)"` (`tests/bulk_ingest/test_simple_merge_fastpath.zig:476`) failed `expectEqualStrings("bob@example.com", email_prop.String)` because `email_prop.String` was FLE *ciphertext* (envelope alg-id `0x01`), not plaintext. The bulk-MERGE apply-on-match path was correct all along: it wrote the new `email` prop and FLE-encrypted it because the process-global FLE catalog had `('User','email')` configured — leaked in via the shared `{GEODE_DATA_DIR or /tmp}/geode_fle_catalog.dat` file that `tests/test_gap0854_fle_chain.zig` persisted (it ran `CALL geode.fle.configureField('User','email')` without isolating GEODE_DATA_DIR). The earlier "FLE key was set" note was from a one-off isolated run; under the pre-push shards (which set neither GEODE_MASTER_KEY nor GEODE_DATA_DIR) the *same* test fails first on the master-key requirement, then on the ciphertext mismatch. **Fix:** both FLE-touching tests now (a) install a deterministic test `GEODE_MASTER_KEY` via a libc `setenv` shim and (b) isolate the persisted FLE catalog to their own per-test tmp dir via `GEODE_DATA_DIR` + `fle_catalog.resetGlobalCatalog`, so neither depends on ambient env nor contaminates a sibling test. Production fail-closed `GEODE_MASTER_KEY` requirement is unchanged. |
| `test-perf` | **RECLASSIFIED PASS 2026-06-10** (host-relative) | Re-verified at `0eefbb9a`: exits 0 on two consecutive idle-host runs — `Build Summary: 59/59 steps succeeded; 44/48 tests passed (4 skipped)`. The 4 skips are the opt-in slow bench smoke tests (`GEODE_RUN_SLOW_TESTS=1` to enable). The two-phase bulk-edge throughput test measured `speedup=1.07x` and PASSES its invariant — the gate was relaxed in `e1219da4` (2026-05-24) to "parallel is not >1.5× WORSE than baseline", enforced off-CI only; the earlier baseline FAIL is no longer reproducible (the contaminated-FLE-environment fixes `8bdb9737`/`5083a30e` are the likely cause of the prior 10/11). Treat as host-relative: heavy host contention can still breach the not-worse invariant (the test self-skips the check when its contention deadlines trip). |
| `test-stream-pool-concurrent-lanes` | **RESOLVED 2026-06-10** (GAP-0863c, commit `4f689520`; 3/3 pass) | Was: `test "task31_edge: submit() — 8 tasks on 4-thread pool all complete"` (`tests/test_stream_pool_concurrent_lanes.zig:236`) failed `ctx.max_concurrent >= 2` — the test raced the scheduler against a ~5 ms task body, so run-to-completion was a legal schedule. The production pool was correct (`submit()` routes to the all-worker default lane post Task #31). Fix: tasks are held at the existing barrier, the test waits bounded (2 s) for ≥2 in-flight lanes, then releases and drains all 8 — observation is deterministic and the assertion stays real (a serializing pool pins its lone lane and fails). Re-verified at `0eefbb9a`: 3/3 (and 10/10 green in a loop at fix time). |
| `test-perf-c-introspection-index` | **RESOLVED 2026-06-10** (GAP-0863b; 8/8 pass, 0 leaks) | **Was a test-teardown gap exposed by ambient FLE-catalog contamination, not a production leak.** The original 3-leak failure ("7/7 tests pass, 3 leaks" traced to `src/fle_integration.zig:469` `encryptFieldIfNeeded` → `key_manager.getFEK`) required the same contaminated environment as the `test-simple-merge-fastpath` row above: an ambient `GEODE_MASTER_KEY` plus a stale shared `/tmp/geode_fle_catalog.dat` with `('User','email')` configured. Under contamination this suite's `setNodeProperty(..., "email", ...)` writes took the real FLE encrypt path, which lazily instantiates the **process-global** FLE KeyManager on the store's allocator (`std.testing.allocator`); production keeps that singleton for the process lifetime by design (`getFEK` returns the FEK by value — `[32]u8` — so there is nothing for the call site to free; the 3 "leaked" allocations are the KeyManager instance + FEK cache key + cache map storage, all owned by the singleton). **Fix:** the property-writing tests in `tests/test_perf_c_lsp_introspection_index.zig` now `defer fle_integration.resetGlobalKeyStateForTesting()` (no-op when FLE is unconfigured), and a new deterministic regression test reproduces the original failure end-to-end — it configures `('User','email')` via the real `CALL geode.fle.configureField` dispatch inside an isolated `GEODE_DATA_DIR`, asserts the stored value is a true FLE envelope and that the introspection index still reports the property key, and verifies the teardown leaves the leak checker clean. Removing the teardown defer reproduces the exact 3-leak trace. |
| `test-gpu` | **RESOLVED 2026-06-11** (GAP-0878; exits 0 — 16/16 steps, 2 Vulkan tests pass + 1 documented skip) | **Was Zig 0.16 migration debt in `src/gpu` + one corrupt embedded SPIR-V word + an unvalidated hardware-dispatch path.** Fixed: `src/gpu/phase0.zig` `std.once` → mutex-guarded lazy init (`std.Io.Mutex`); `src/gpu/telemetry.zig` ArrayList `.writer` → `std.Io.Writer.Allocating`; `src/gpu/memory_manager.zig` freed a many-pointer as a slice; `src/gpu/vulkan_ffi.zig`/`vulkan_loader.zig` were missing the `VK_PHYSICAL_DEVICE_TYPE_*`/`VK_MEMORY_HEAP_DEVICE_LOCAL_BIT` constants `vulkan_compute.zig` references; `tests/gpu/test_vulkan_basic.zig` had a corrupted OpDecorate word (`0x00000047`, word-count 0) in its embedded SPIR-V making the module invalid (pipeline creation failed on real hardware). Residual (documented in-test): the Vulkan compute DISPATCH path hangs in the driver on real hardware (mesa/NVK, RTX 4060 Ti, 2026-06-11) — the vector-addition dispatch test is opt-in via `GEODE_GPU_DISPATCH_TESTS=1` until the execute() path is hardened. Device-init and buffer-copy tests run unconditionally and pass on Vulkan hosts; everything self-skips/compiles cleanly on GPU-less hosts. |
| `test-e2e` | **COMPILE FIXED 2026-06-10** (GAP-0863a) — step now runs end-to-end; 1 step still red: `gql_conformance` 17/20 (3 runtime failures) | Zig 0.16 migration debt across 22 files closed: removed-API uses (`std.time.milliTimestamp`/`nanoTimestamp`/`Timer`, `std.Thread.sleep`, `std.fs.cwd`/`File`, `std.process.Child.init`/`getEnvVarOwned`/`getEnvMap`, `std.heap.GeneralPurposeAllocator`, `std.crypto.random`, `std.mem.trimLeft`, `std.Io.fixedBufferStream`, ArrayList `.writer`) migrated to the repo's established compat patterns; all byte-driven fuzz targets ported to the Zig 0.16 `*std.testing.Smith` signature (drawing bytes via `smith.slice`); `tests/e2e_graph_algos_new.zig` (imported a never-exported `graph_algos_stub`) rewritten against the real `geode.graph.community_louvain` / `community_label_propagation` API and now actually runs (was compile-only; 5/5 pass). Verified 2026-06-10 and re-verified at `0eefbb9a` (GAP-0863d): 84/86 steps green, 68/71 tests pass; the only failures are exactly `gql_conformance` T11/T12/T14. **Residual (newly revealed, pre-existing):** `gql_conformance` T11/T12/T14 fail — bare `count(*)` after `SESSION SET PROPERTY GRAPH` returns 0 via the count-pushdown fast path (`match_operations.countNodesFastPath` → `countNodesForGraph` counts the in-memory store before the lazy on-disk graph load) while row-iterating queries over the same graphs (T15–T18) return correct data. The fixture also assumes pre-seeded `G1`/`G2` datasets that nothing in-repo seeds (a clean checkout would also fail T15–T18). **RESOLVED 2026-06-11 (GAP-0892, commit `8833fc4a`):** the diagnosis was corrected during the fix — neither lazy-load nor missing fixtures: `SESSION SET PROPERTY GRAPH "G1"/"G2"` seeds the fixture graphs in-engine (`createTestGraphG1/G2`, `src/execution.zig`), but `query_traits.analyzeProgram` picks the trailing Query as the handler fast-path target, so the QUIC count-pushdown fast path executed only the MATCH against the request-start session graph and skipped the SESSION SET (and its seeding) entirely. Fixed with `ProgramAnalysis.has_effectful_preamble` gating the count + node-scan fast paths; `gql_conformance` is now 21/21, T1–T20 plus the `ZZ_cleanup` teardown (`zig build test-gql-conformance`, regression `test-gap0892`). |
| `test-edge-torn-read-stress` | **RESOLVED 2026-09-19 (SONNY-1797)** — un-quarantined; back in the aggregate `test` step (12/12 green in a loop) | Was a general protection exception (UAF-class) reproduced at Geode main / v0.8.16 (`a4c5b08f`): a genuine borrowed-slice torn read in the graph-store adjacency hot path. The `bulk_merge_edge` apply path (`bulkMergeEdgesBatchShardLocked`) holds the per-graph `mg.rwlock` only SHARED plus a per-SOURCE-shard lock, while adjacency readers (`getOutgoingEdgeIds`) also hold `mg.rwlock` SHARED — so the shard lock does NOT exclude readers. The append (`appendAdjId`) already grows the backing array by immutable-swap + grace-list retire of the old buffer (never inline-free), but the RESIDUAL half was on the reader: it read the borrowed slice's `(ptr, len)` in natural order and could observe `(old_ptr, new_len)` (old ptr loaded before the swap, new len after), indexing one past the retired buffer. **Fix:** `src/graph_store.zig` `adjItemsSnapshot` mirrors the writer's release with an ACQUIRE-load of `len` FIRST, then reads `ptr`, taking a torn-free snapshot; used by `outAdjItems`/`inAdjItems` and the `*Checked` variants. `build.zig` restores `shardDep(test_step, ..., 15, ...)` so the test runs in the aggregate `test` step. |
| `test-cluster-3node-subprocess` | TIMEOUT (300 s) | Known: the 3-node subprocess cluster reliably stalls/crashes in the QUIC vendor library during multi-node bring-up (see project memory "A6f QUIC processShortHeader crash"). The in-process cluster steps (`test-cluster-3node-election`, `test-cluster-steady-state`, `test-cluster-bootstrap`, `test-cluster-identity`) PASS. |
| `test-cluster-replicable-mutations` | **RESOLVED** — 9/9 pass (3m, re-run 2026-11-12 for SONNY-6450; named step only, not in the aggregate) | Added 2026-06-09 (commit `7b168f62`) as a deliberately failing reproduction of the cluster write-replication gaps (edge CREATE, DELETE/DETACH DELETE, MERGE, ungated MATCH…SET did not replicate); those gaps are closed and it passes. SONNY-6450 item 2: it and `test-cluster-steady-state` (3/3) take their client and cluster ports from `tests/test_ports.zig` (they bound 127.0.0.11-13 on the fixed ports 3141 and 4242). Spawns three real `geode serve` subprocesses on distinct loopback addresses. |
| `test-slab-packing-geode` | TIMEOUT (1800 s) — **found 2026-11-11 by SONNY-2772** (named step only, not in the aggregate) | The step had stopped compiling: `tests/test_slab_packing_geode.zig` walked each shard's edge index with `.iterator()` and a `u32` `prop_head`, but graph_storage 0.4.10's `EdgeIndexMap` has no iterator (it is visited with `forEachLive`) and its `prop_head` is `u64` (`error: no field or member function named 'iterator' in 'edge_index_map.EdgeIndexMap'`, then `:161`). SONNY-2772 ported both walks to `forEachLive` (`countLegacyEdgePropHeads`). The step now compiles, but a Debug run did not finish in 30 minutes: the test process wrote ~2 MB/s at ~16% CPU (2.8 GB after 23 min) while ingesting its `N = 50_000` nodes (`tests/test_slab_packing_geode.zig:34`) through the durable adapter path, so no assertion was reached. Kept out of the aggregate (`not_in_aggregate_steps`) until it is made to finish (fewer nodes, or a ReleaseFast lane) and passes. |
| `test-sonny4877-grant-retire-fail-closed` | **RESOLVED 2026-11-11 (SONNY-4877)** — 2/2 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: after `grant_migration.retireMigratedGrantPolicies` failed (allocation failure collecting names, or a persistence-delete failure in `AuthGraphManager.dropPolicy`/`sealChain`), the legacy `auto_migrated_grant_*` allow stayed enabled and `gps.decide()` still allowed the revoked principal. **Fix:** `PolicyCatalog.disableAllowPoliciesWithPrefix` disables every migrated allow (and invalidates cached decisions) before any fallible step; a retry that finds a row a failed run already removed reseals the chain. |
| `test-sonny2412-kms-latency-flat` | **RESOLVED 2026-11-13 (quic v0.1.51, SONNY-6478)** — 1/1 pass with the perf gate enforced (`GEODE_PERF_GATES=enforce`: median of the first 16 = 11.11 ms, last 16 = 11.26 ms, 1.01x); registered in `shardDep` (aggregate `test`) | Was an intentionally red reproduction of a quic defect (added 2026-11-13 on v0.1.49; still red on v0.1.50: 43.69 ms -> 140.81 ms, 3.22x). 64 remote KMS unwraps on one QUIC connection: with no request in flight the server endpoint kept sending about 370 datagrams a second, STREAM frames re-carrying the already-delivered responses of completed request streams, each acknowledged by the client and sent again; each request added one such stream. quic v0.1.51 retires a stream once both directions are finished (RFC 9000 section 3) and no longer resends acknowledged data, so geode needs no `teardownStream` call (it never made one). |
| `test-sonny6524-label-dict-split` | **RESOLVED 2026-11-14 (SONNY-6524)** — 7/7 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: graph-storage 0.4.15 refuses to open a graph whose shard label dictionaries disagree on an id its records use (`LabelDictionaryDiverged`), so the shapes older geode left (the ORDER BY split, names given through the shard 0 view before 2026-05-29, a 0.4.14 broadcast that failed part-way) could not be opened at all, and a refused graph reported the generic `GraphQuarantined ... restart the server to retry`. **Fix:** `src/storage/label_dict_divergence.zig` classifies a refused graph from its 16 dictionaries and logs the shape and the repair; `GEODE_LABEL_DICT_ADOPT_SHARD0` opens a named graph in the shift shape with graph-storage's `.adopt_shard0`; the lost-name shapes stay refused; reads and writes of a refused graph fail with 58000 `LabelDictionaryDiverged`. |
| `test-sonny2822-update-counts` | **RESOLVED 2026-11-22 (SONNY-2822)** — 1/1 pass (46 steps on QUIC and 46 on gRPC); registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: the wire protocol had no field for a statement's update counts, so a driver's RowsAffected() was 0 for MATCH ... SET, DELETE and a CREATE with no RETURN. **Fix:** `DataPage.update_counts = 5` (message `UpdateCounts`, src/proto/geode.proto), set on the final page of every successful result: counted by the statement undo record's write hooks (`statement_undo.append` / `appendCreated`, `src/update_counts.zig`) and by the QUIC write fast paths from what their adapter primitive reports (`MergeResult.created`, `ApplyResult.created`); a failed statement reports none, a ROLLBACK in the same program takes back its body's. The MATCH ... CREATE summary row stays. |
| `test-sonny6924-scan-node-read-shard-exclusion` | **RESOLVED 2026-11-22 (SONNY-6924)** — 2/2 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: the engine-direct scan (`src/server/node_scan_stream.zig`) read a node's record, labels and properties holding no shard lock, beside an insert on the same shard. The insert grows the shard's node-page free-space bitmap (`NodeStore.putNode` -> `FreeSpaceManager.ensureCapacity`, a `std.DynamicBitSet.resize` that frees the old mask array) and `NodeStore.getNode` consults it first, so a live node read as absent: `tests/test_where_scan_writer_progress.zig` failed with NodeNotFound after exactly 199 writer inserts (CI pipeline 3099350732; 3 of 413 local ReleaseSafe runs). **Fix:** `StorageAdapter.lockNodeShardForRead` takes a node's shard lock SHARED (after the graph lookup), and the scan reads every node under it: `materializeNode`, `materializeNodeProjected` and `nodeMatchesPattern` take a `ShardReadHold`, which keeps the lock across up to 256 consecutive nodes of one shard (an insert waits at most one batch) and is released before any call that takes a shard lock itself and before the graph lock it nests in. Other callers of the unlocked reads (the planned read runtime, the legacy executor, MERGE verifiers) are unchanged: they were not audited for a held shard lock, which the SHARED acquire would deadlock on. |
| `test-sonny6941-explain-index-seek` | **RESOLVED 2026-11-23 (SONNY-6941)** — 11/11 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction, twice. (1) A tenant-bound session's `EXPLAIN MATCH (n:PlanProbe {k: $p}) RETURN n.k`, with a btree index on `PlanProbe(k)`, planned `Scan, Expand, Project`: `buildPlanIfSupported` demotes a tenant-bound (or RLS) session to the legacy executor, whose simple-node branch scanned the whole label, and SONNY-6276 (171f79a5e) had made the version-1 EXPLAIN say so. **Fix:** that branch starts from the exact property index (`planned_read_runtime.legacyStartSeek`), records the seek for PROFILE (`match_operations.takeExactSeek`), the legacy EXPLAIN asks the same decision (`legacyStartUsesIndex`), and the version-1 plan emits `Expand` only for a pattern with a relationship. (2) Security review: the seek ran with no catalog index too, unreported. **Fix:** it seeks only on a key a catalog btree/hash index covers; it drops another tenant's postings on their engine tenant tag before resolving or reading them, reads the graph through `ensureGraphHydrated` (hydration and quarantine, as the scan), polls the read budget per posting, and falls back to the scan only when the index cannot answer (busy, over an FLE field, graph gone). |
| `test-sonny6942-detach-delete-shards` | **RESOLVED 2026-11-23 (SONNY-6942)** — 1/1 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: an auto-commit statement over nodes on every engine shard committed one engine transaction per node, not one per shard (`MATCH (n) DETACH DELETE n`, `MATCH (n) SET ...` and a failed one, over 512 nodes on 16 shards: 481, 481 and 961 commits). SONNY-6658 kept the statement's engine transaction open until it ended on ONE shard; a change on any other shard committed an engine transaction of its own (a WAL fsync) and first wrote the statement's undo to `txn_undo.wal` (a second fsync), so a 30,000-node DETACH DELETE went past geode-client-go's 30s cleanup budget. **Fix:** the statement keeps an engine transaction on each shard it writes (`t_auto_shard_txns` in `src/storage/graph_storage_adapter.zig`, joined through `statementLocalTxn` and the reserved-id node insert), all committed when it ends after one undo log write (`statement_undo.flushBeforeStatementCommit(spans_shards)`); a node batch create commits them first (`settleAutoShardTxns`). A failed statement writes nothing to the log: each shard's transaction commits its changes with their undo. |
| `test-sonny2848-tenant-subquery-aggregation` | FAIL — **intentionally red** (TDD reproduction, added 2026-11-12); NOT in `shardDep`, compiled by `test-compile` | On a tenant-scoped session, `MATCH (a:S) WITH a, COUNT { (a)-[:T]->() } AS d WHERE d > 0 RETURN count(a)`, the same with `EXISTS {}` or a comprehension after `WITH`, `MATCH (a:S) RETURN sum(COUNT { ... })`, and even `MATCH (a:S) WITH a RETURN count(a)` return 0; an unscoped session gets the right answer. Not the tenant predicate: a concrete tenant scope demotes the read from the planned read runtime to the legacy executor (`planned_read_runtime.zig`, GAP-0846 demotion), whose single-pattern aggregate branch in `match_operations.zig` `executeMatchQueryImpl` ("pre-aggregate all matched nodes into a single row") evaluates the RETURN's aggregates before the `WITH`, through `aggregation_evaluation.evaluateGroupAggregation`, which reads node properties only and cannot evaluate an expression in a row binding; the `WITH` then sees one row `{count}` and no `a`. The ticket's other subquery forms (uncorrelated/correlated `COUNT {}`/`EXISTS {}` in WHERE, comprehensions, `IN (subquery)`, `shortestPath()`) are green and pinned in `test-sonny6338-tenant-visibility-consistency`. Register it in `shardDep` in the commit that fixes it. |
| `test-sonny6700-storage-scrub` | **RESOLVED 2026-11-17 (SONNY-6700)** — 2/2 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: there was no operator procedure that overwrites a graph's dead space (`CALL geode.storage.scrub()` was unknown, 42002), so a value superseded by an update or a DELETE stayed in `props.store` / `var.store` / the WAL until its space was reused; and the graph-storage scrub SONNY-6692 added left freed var-store slab runs in the shared slab block and never touched allocated pages no live record owns. **Fix:** graph-storage 0.4.28 `scrubDeadSpace` proves ownership first (a walk of every live node's properties and labels and every out-edge's properties, following overflowed values) and then tombstones unreferenced slab slots, zeroes unheld slab bytes, and zeroes and frees unowned pages; `CALL geode.storage.scrub()` (Admin only, audited, self-locking: one graph's lock at a time) scrubs and checkpoints every graph (src/execution/storage_dispatch.zig `executeStorageScrub`). |
| `test-sonny6494-ipv6-query` | **RESOLVED 2026-11-13 (SONNY-6494 item 6)** — 1/1 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: `geode query --server [::1]:<port>` against a real `geode serve --listen [::1]:<port>` exited 1 with `Ipv6EndpointUnsupported`, because `src/client/quic_endpoint_host.zig` refused every IPv6 destination for geode-client-zig before v0.3.16, which bound an IPv4-only endpoint. v0.3.16 resolves and dials the host itself (IPv6 bracketed from a `[::]:0` endpoint; a name prefers IPv4 and falls back to IPv6), so the module was removed and the CLI passes the host through; only an IPv6 zone, which the QUIC dialler cannot parse, is still refused with its reason. `--server`, `--dsn`, `ip6-localhost` and the MCP endpoint client all answer. |
| `test-sonny6494-mcp-dsn-errors` | **RESOLVED 2026-11-13 (SONNY-6494)** — 4/4 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: a malformed MCP endpoint DSN was answered by every MCP tool with `Error: Failed to initialize client` and by resources with `Failed to connect to Geode server`, `geode mcp --endpoint <bad DSN>` started anyway, and `geode query --server 127.0.0.1:0` failed with a bare `Unexpected`. `src/mcp/client.zig` `endpointErrorMessage` now maps geode-client-zig v0.3.16's `InvalidDSN` / `InvalidPort` / `UnsupportedScheme` / `InputTooLong` (and geode's port-0, IPv6-zone and insecure-DSN refusals) to messages; `geode mcp` checks the DSN at startup (exit 2, DSN not echoed); a client address with port 0 is refused. The resources half of the test runs on a non-leak-checking allocator: mcp v0.1.21 returns `resources/read` results with `.owned = false`, so every resource response leaks (upstream, independent of this change). |
| `test-gql-conformance-rq` | **RESOLVED 2026-11-14 (SONNY-6536)** — 24/24 pass; registered in `shardDep` (aggregate `test`) | RQ-0019 demanded exactly 42000 for a privilege violation. ISO/IEC 39075:2024 4.2.4.2 names the condition with no subcondition and 23.1 allows subclass `000` or an implementation-defined subclass (first character `5`-`9` or `I`-`Z`), so the gql library's 42501 conforms; the test now asserts that rule. No library change. |
| `test-sonny2979-txn-crash-atomicity` | **RESOLVED 2026-11-16** (SONNY-2979; PASS, in `shardDep`) | Was: a real `geode serve` killed (SIGKILL) with a transaction open over several requests (32 CREATEs and a SET of a node that existed before) and one left open by a single request (32 CREATEs) kept, after the restart, every change its requests had committed in the engine (red on 2026-11-16 before the fix: Multi=32, Single=23, the SET survived). **Fix:** the durable undo log `<data dir>/txn_undo.wal` (`src/txn_durable_undo.zig`): inside an explicit transaction every undo entry is fsynced before its change is made (creates log an intent naming the id first), COMMIT writes a COMMITTED record after the engine commit (its commit point), a rollback a ROLLED_BACK record, and startup undoes every transaction with neither, idempotently, before serving; sealed under `GEODE_TDE_KEY`. Companions: `test-sonny2979-txn-commit-durable` (committed transactions survive whole, a rolled-back one is not undone again, the sealed log) and `test-sonny2979-undo-wal-format`. Design and residuals (auto-commit statements are not covered): docs/TRANSACTION_MANAGEMENT.md, "Crash Durability and Atomicity". |
| `test-sonny6658-autocommit-crash-atomicity` | **RESOLVED 2026-11-16** (SONNY-6658; PASS, in `shardDep`) | Was: a real Debug `geode serve`, armed with the SONNY-6658 crash point (`GEODE_TEST_STATEMENT_KILL_KEY=crash_v`, `GEODE_TEST_STATEMENT_KILL_AFTER=8`: the process SIGKILLs itself when a statement is about to set `crash_v` on a node for the 9th time), ran the auto-commit statement `MATCH (n:T) SET n.crash_v = 1, n:Marked` over 32 nodes spread over the shards and was restarted on the same data directory: `crash_v=8 Marked=8` survived (want 0 each; red on `ba9a698a3`). **Fix:** an auto-commit statement's engine transaction is committed at its end (one is opened at its first write on that write's shard when it has none); before a change that commits an engine transaction of its own, its undo is written to `txn_undo.wal`, it is sealed with COMMITTED (ROLLED_BACK when it fails), and startup undoes an unsealed one. Companion: `test-sonny6658-statement-undo-log` (a one-shard statement writes no log record and commits one engine transaction). Design and residuals: docs/TRANSACTION_MANAGEMENT.md, "Crash Durability and Atomicity". |
| `test-sonny6613-path-ownership` | **RESOLVED 2026-11-15 (SONNY-6613 item 1)** — 5/5 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: every statement that kept a path value in a result row leaked the path's node and edge arrays on every session kind (`freeValue` never freed a path, most such results do not own their values, and the arrays `keepPaths` / the traversals allocate belonged to nothing). **Fix:** the result's `OwnedGraphEntities` tracker owns the path arrays its rows keep (`adoptPath`, `keepRowPath` in src/execution/match_operations.zig; trackers merged by hand now move them too, `absorb`; a UNION keeps each arm's tracker, `link`); `duplicateValue` copies a path's arrays and `freeValue` frees them (src/execution/value_utilities.zig). The step now also reads every path through its arrays and sweeps an allocation failure over eight path statements in every session (which found and fixed a double free in `applyRowWindow` and error-path leaks in the shortest-path search and the multi-pattern executor). The `path_leak` arena workaround in tests/test_sonny3046_with_bound_variable_join.zig is gone. |
| `test-sonny6548-cli-query-options` | **RESOLVED 2026-11-14 (SONNY-6560)** — 3/3 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: `geode query --format txt` printed nothing and exited 0 (the renderer returned success for a format it does not draw), an unknown option exited 0 (no branch for it), and `--help` documented `--begin`/`--commit`/`--rollback`, which nothing read, so `CREATE ... --begin --rollback` committed. `--format` is checked against json/table/csv/dot/mermaid and the renderer's fall-through is an error; unknown options are refused by `geode query` and, through `src/cli/option_check.zig`, every other command (exit 2); the transaction flags are refused and gone from the help (an explicit transaction is BEGIN/ROLLBACK lines of `--batch`). Wider regression: `test-sonny6560-cli-unsupported-options`. |
| `test-sonny6548-quic-cdc-control` | **RESOLVED 2026-11-14 (SONNY-6561)** — 2/2 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: with CDC running (`CALL cdc.enable()`), QUIC CDC_CONTROL answered `NO_ENGINE` and CDC_DIAGNOSTICS reported CDC disabled, because the `.cdc_diag` / `.cdc_ctrl` arms of src/server/quic_connection_handler.zig read `ServerState.cdc_engine`, which nothing assigned. **Fix:** both transports answer through one implementation (`storage_dispatch.cdcDiagnosticsAnswer` / `cdcControlAnswer`, re-exported by `execution`) and refuse the same callers with the same SQLSTATE (`CdcRefusal`: 28000 unauthenticated, 42501 not an administrator); the dead field is deleted. `test-sonny6561-cdc-transport-parity` compares QUIC and gRPC for four principals and three CDC states (0 of 86 answers differ; 40 did). |
| `test-sonny6548-wire-result-metadata` | **RESOLVED 2026-11-15 (SONNY-6562)** — 3/3 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: `RETURN 1.25 AS a` was declared FLOAT (src/eval/type_helpers.zig `.Decimal => "FLOAT"`; ISO/IEC 39075 21.2: an exact numeric literal is exact numeric), `RETURN 2 AS a UNION RETURN 1.25 AS a` INTEGER (src/server/proto_util.zig `inferColumnType` typed a column from its first non-null value; 14.2 / 22.18 want the combined type), `FOR a IN [2,1,3] RETURN a ORDER BY a DESC` sent `ordered:false` (src/query/query_traits.zig had no `.For` arm), and a version-1 PROFILE under `GEODE_SPILL_THRESHOLD_BYTES` sent `spill_reason:"threshold"` with every spill counter 0. **Fix:** a decimal is DECIMAL; a column is the 22.18/22.19 combination of all its values (ANY across base types; a node-scan stream longer than its 10-row schema sample declares its property columns ANY); `query_traits.resultOrderBy` decides `ordered` and `order_keys` for every statement shape on both transports; the executor never spills, so PROFILE reports no spill. `test-sonny6562-wire-metadata` checks every declared type against the protobuf values sent over QUIC and gRPC (5/5). |
| `test-sonny6548-raft-persistent-voted-for` | **REMOVED 2026-11-14 (SONNY-6563)** — the step and its test file are gone with the code they tested | `raft_persistent.RaftNode` (src/distributed/raft_persistent.zig) wrote and read only `current_term`, so a reopened node had `voted_for = null`. Nothing in the server reached it (only `lib.zig` exported it; no symbol in the Debug binary), so it was deleted rather than fixed. The cluster's `raft_consensus.RaftNode` keeps term and vote together in the raft library's FileStorage `hard_state` file: `test-raft-hardstate-durability` now asserts the vote survives a restart and a second candidate is refused in that term, and `test-sonny6563-vote-persist-before-send` that the grant leaves the node only after the vote is fsynced (it did not; fixed). |
| `test-sonny6548-gql-identifier-words` | **RESOLVED 2026-11-15 (SONNY-6564)** — 3/3 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: SET and REMOVE refused `type`/`property` (ISO/IEC 39075 21.3 non-reserved words) as the target variable (src/gql/parser.zig parseSetClause / parseRemoveClause required `.identifier`) though MATCH bound them, and the parser accepted reserved words as variables (`MATCH (match:X) RETURN match`, `RETURN MATCH`). **Fix:** one predicate (`Parser.isBindingName`, src/gql/identifier_words.zig) for every binding and referencing position; reserved words are 42000 naming the delimited form (`` `match` ``, newly lexed). PATH, VALUE, COUNT, AVG and TIMESTAMP stay names, a documented non-conformance: Geode's procedures yield columns so named (docs/GQL_COMPLIANCE.md). `test-sonny6564-identifier-words` covers every reserved and non-reserved word in every position (5/5). |
| `test-sonny6571-tde-at-rest` | **RESOLVED 2026-11-15 (SONNY-6571)** — 2/2 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: with `GEODE_TDE_KEY` set, a 3-node cluster of real `geode serve` processes wrote the replicated CREATE in plaintext to every node's Raft log, `<data>/raft/entries.wal` (label, property key, string and integer value): the raft library's `FileStorage` wrote the log, hard state and snapshots as given. The Raft entry and snapshot data are now sealed by `src/distributed/raft_tde_storage.zig`. Names in the storage engine's schema-name files are `test-sonny6571-schema-names`. |
| `test-sonny6595-wal-drain` | **RESOLVED 2026-11-16 (SONNY-6595 item 5, graph-storage v0.4.22)** — in `shardDep`, passes with and without TDE | Was: after a SIGKILL and a restart, a shard nothing made dirty kept its whole replayed WAL through every light checkpoint and the clean shutdown (3,698,816 bytes in all 16 shards, 3,721,856 with TDE), because graph-storage truncated a WAL only in a checkpoint of a dirty shard and recovery left the replayed file. graph-storage v0.4.22 (SONNY-6599) fsyncs the directory and truncates the WAL recovery replayed, and an open drains a WAL whose contents the pages already cover. geode keeps its lazy-open policy (startup cost): at startup it opens only a graph with an IdMap snapshot (to check the snapshot stamp, `loadOneGraphFromAdapter`), and that open drains the WAL; a graph with none (never checkpointed) is opened by the first statement that touches it (`requireExistingGraphLocked`), and until then its WAL holds exactly the crash's tail, harmless (every record below the manifest's `last_checkpoint_lsn`) and bounded (one crash's tail, dropped at the open). The test now pins that contract: with no statement the WAL equals the tail exactly, through 5 s of light checkpoints; the first statement on the graph opens it and the WAL is 0 right after; a clean shutdown leaves 0, whether or not a statement ran; every node survives every restart. |
| `test-sonny6571-schema-names` | **RESOLVED 2026-11-15 (SONNY-6590)** — passes; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: with `GEODE_TDE_KEY` set, a single `geode serve` wrote label and relationship type names in plaintext to all 16 shards' `labels.dict` and property key names to `props.idx` (graph-storage) and to geode's `prop_exact.idx` / `prop_rev.idx`. graph-storage v0.4.17 seals its side files and geode seals its exact-index files with the same envelope (`src/storage/graph_storage_adapter.zig`, `writeSealedExactFile`). The step now also writes a property index and a time-series point and scans after a SIGKILL and a restart; with the pin alone it was still red on `prop_exact.idx` / `prop_rev.idx` and on `<data>/timeseries/ts.wal` (time-series encryption needed `GEODE_TS_TDE=1`; it now follows `GEODE_TDE_KEY`). Upgrade and refusal cover: `test-sonny6590-tde-side-files`. |
| `test-*-tsan` (the TSan companions) | FAIL (ThreadSanitizer data races) — **found 2026-11-12 by SONNY-6328** (named steps only, not in the aggregate) | Before SONNY-6328 they were built by the self-hosted x86_64 backend, which ignores `sanitize_thread`: no instrumentation, no runtime, and they passed while detecting nothing (a deliberate race passed too). They are now built with the LLVM backend (`tsanTest` in `build.zig`; `test-sonny6328-tsan-detects-race` proves a race is reported, exit 66), and they report races. `test-sonny1318-procedure-tenancy-tsan` (26 reports) and `test-sonny1330-parallel-union-tsan` (35): all in the thread_pool 0.2.9 dependency, `RingQueue.tryPush` / `stealHalf` (`src/queue/ring_queue.zig:90`) against `LocalQueue.steal` / `tryPushBottom` / `popBottom` (`src/pool.zig:262-300`), whose `switch (self.*)` copies the whole queue union (a plain memcpy over the atomic head/tail) on every call. `test-ordered-scan-tsan` (22): the same thread_pool reports plus `OrderedBTree.Cursor.next` / `seek` / `normalizeForward` (`src/ordered_btree.zig`) against `insertIntoLeaf` — geode's `orderedScan` broke the tree's no-mutation-while-iterating contract; **fixed by SONNY-6375** (each batch under `mg.rwlock` SHARED + the shard lock, no cursor kept across a release): the step now reports only thread_pool frames (12 in the 2026-11-12 run), and with those suppressed (`race:thread_pool-0.2.9-*/src/pool.zig`, `.../src/queue/ring_queue.zig`) it and `test-sonny6375-ordered-scan-locking-tsan` pass with 0 reports. `test-startup-lazy-hydrate-tsan` stalls in TSan's per-frame `addr2line` symbolization (25-minute cap hit with no output); run its binary with `TSAN_OPTIONS=symbolize=0 log_path=...` and symbolize the PCs in one `addr2line` batch: 2026-11-12 (SONNY-6375) it reached test 40/47 in 25 min with 114 reports, 110 thread_pool and 4 geode (`getCurrentGlobalStore` copying the store against a `hydration_build_mutex` lock), the latter **fixed by SONNY-6375**. Since SONNY-6433 the suite keeps its stores on tmpfs (`/dev/shm`) and runs to completion: 2026-11-12 all 47 tests pass (129 s under TSan; 38 s uninstrumented, where it had reached 40/47 at 25 min), with 122 reports, every one in thread_pool 0.2.9 frames (`LocalQueue.steal` / `tryPushBottom` / `popBottom`, `src/pool.zig:269-301`) and none in geode frames. `test-ordered-index-autobuild-tsan` (10) and `test-parallel-index-rebuild-tsan` (8) report only thread_pool frames. The library fixes belong in thread_pool and graph_storage; no CI job runs the companions until they pass. |
| `test-sonny6452-tde-page-tail-repair` | **RESOLVED 2026-11-13 (SONNY-6452)** — registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: geode had no command that finds or repairs the records a store written by graph_storage <= 0.4.11 lost from its encrypted pages (SONNY-6441). `geode storage verify --check tde-page-tail` reports them without opening the store; `geode storage repair --tde-page-tail --i-have-a-backup` restores what is derivable (docs/TDE_FILE_LEVEL_ENCRYPTION.md, "Upgrading stores written before graph_storage 0.4.12"). |
| `test-sonny6457-connectex-client-cert` | **RESOLVED 2026-11-13 (SONNY-6457 item 1)** — 2/2 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: `QuicClient.connectEx` (`src/transport/quic.zig`) put a client certificate path in the vendor config's `cert_path`, which makes the vendored quic endpoint a SERVER (`endpoint.zig:798`, `is_server = cfgp.cert_path != null or ...`), and never loaded the certificate into `inline_client_cert_der` / `inline_client_priv_key`. Against a `geode serve` with `GEODE_MTLS_REQUIRED=1` and `GEODE_MTLS_CLIENT_CA`, a client certificate in the bundle is rejected, and a certificate without its key, a key without its certificate, or an unreadable file is not refused before dialling. `connectEx` now loads the certificate and key into the client TLS fields and never sets `cert_path`. |
| `test-sonny6457-mtls-cli-unsupported` | **RESOLVED 2026-11-13 (SONNY-6457 item 5)** — 2/2 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction: `geode mtls map create` / `delete` / `config` write `geode_mtls_state.db` in the CLI state directory and print "Created mTLS mapping" / "mTLS configuration updated", and `map list` / `status` read it back, exit 0; nothing on the server reads that file and the server's certificate-to-user store (`src/security/mtls_provider.zig`) is never populated, so a mapping changes nothing (story SONNY-6458). Every `geode mtls` subcommand is now refused as unsupported (non-zero exit, names SONNY-6458 and `GEODE_MTLS_REQUIRED`) and the state-file code is removed. |
| `test-sonny6457-external-kms-compile` | **RESOLVED 2026-11-13 (SONNY-6457 item 4)** — 4/4 pass; registered in `shardDep` (aggregate `test`) | Was an intentionally red TDD reproduction (a compile error): `src/security/external_kms_client.zig:333` and `:645` build `std.http.Client{ .allocator = ... }` with no `.io` ("missing struct field: io"), and the rest of both `httpPost` functions uses the pre-0.15 `client.open` / `request.write` / `finish` / `wait` / `reader` API. Nothing in the product constructs the Vault Transit or AWS KMS client (KMS wiring is story SONNY-6380), so no build analysed this code. Both clients now POST through `std.http.Client.fetch` with an `Io` (`httpPostJson`), and responses are parsed as JSON (`jsonStringField`). |
| `test-eng3922` | **RESOLVED 2026-11-14 (SONNY-6540 item 8)** — 9/9 pass | Case (c) (`tests/test_eng3922_dim_guard.zig:442`) answered ParseMemoryLimit (54000) instead of VectorTooLarge on its 65,536-element array literal: each decimal literal left a digit buffer on the parser arena (`src/gql/parser.zig`, the float literal), more than doubling a decimal element's parse cost, so under the test's arena-over-arena allocator the literal crossed the 64 MiB parser budget. Fixed at the cost (the digits are stack scratch); the budget is unchanged. Regression: `test-sonny6540-vector-literal-parse`. |
| `test-graph-store` | **RESOLVED 2026-11-14 (SONNY-6555 item 9)** — the failing inline case tested the root `free.store` sanitizer that SONNY-6523 removed as dead code (no sharded graph reads `<graph root>/free.store`) | The case now asserts what remains true: a stray root `free.store` does not affect the reopen (node, property and count intact). Its "truncated to 0 bytes" assertion is gone with the sanitizer. |
| `test-all` | TIMEOUT (300 s) | The `test-all` aggregate (unit + e2e) inherits the `test-e2e` runtime failures (T11/T12/T14 — the compile failures are fixed as of `487a2424`) and the `test-count-pushdown` slowness (~7-13 min, passes). Not a distinct issue — it is the union of the rows above. |

### RESOLVED (2026-06-10): `graph_store_unit_tests` shard / sharded `zig build test`

`zig build test` aggregates ~60 test binaries via a sharded dependency graph.
The `graph_store_unit_tests` shard (rooted at `src/graph_store.zig`)
transitively imports `execution.zig → raft_consensus.zig → txn_coordinator.zig`
and pulls those files' inline `test` blocks into the test root. Several of
those paths never compiled under the test root and were therefore silently
absent from `zig build test`. Commit `faac1f3e` repaired the mechanical ones
(missing module imports on the test root; the removed `.noop` Message variant;
the `std.Io.Dir`/`File` API; stale managed-`ArrayList` calls; the protobuf
`.@"enum"` field form; `std.json.ObjectMap` unmanaged form).

**The former residual blocker is now FIXED.** It had two parts:

1. **Latent bug in `src/distributed/value_convert.zig` (`protoValueToJsonValue`)**
   — `ev.data == .text` compared the active tag of an OPTIONAL oneof
   (`?ExtendedValueUnion`) without unwrapping it (`operator == not allowed for
   type '?schema.ExtendedValueUnion'`). Only test code reaches this function
   (production uses `propertyValueToProto` / `applyMapEntriesTo*`), so it never
   tripped `zig build`. Now unwraps the optional before the tag compare.

2. **protobuf union-as-submessage @compileError.** The txn_coordinator 2PC tests
   `protobuf.encode` a `distributed_schema.TwoPhaseMessage`, whose `operations`
   field is a repeated `TwoPhaseOperation` Zig `union`. The pinned `protobuf`
   0.1.3 rejects a union as a submessage at comptime (`protobuf.zig:713
   @compileError "Invalid internal init type ... TwoPhaseOperation"`;
   `wire.zig:704 expected StructField found UnionField`). These were **inline
   `test` blocks** in `src/distributed/txn_coordinator.zig`, so they rode into
   the graph_store test root and failed it to COMPILE. They are now **moved out**
   to the standalone `tests/test_txn_coordinator_2pc.zig`
   (`zig build test-txn-coordinator-2pc`), where the union-encode body is
   comptime-gated behind a `protobuf_union_submessage_supported` flag — the file
   compiles and the four tests self-skip (`error.SkipZigTest`) until the protobuf
   dependency gains union-as-submessage support (or `TwoPhaseOperation` is
   reshaped into a struct-with-oneof). Production never reaches the union-encode
   path. `distributed/txn_coordinator.TxnCoordinator` IS instantiated in
   cluster mode (`ClusterCoordinator.init`, `src/distributed/cluster.zig`) as
   the apply target of committed `txn_prepare` / `txn_decide` entries, but
   nothing in the server proposes such an entry (SONNY-6547), so no 2PC
   ever runs. No server code path runs a 2PC protocol: `src/distributed/twophase.zig` was
   compiled only by its tests and was removed (SONNY-6563), and
   `src/transactions/two_phase_commit.zig`, named here before, was never
   compiled and was removed (SONNY-6298).

   **SONNY-6484:** the four tests no longer skip. Since GAP-0870 the
   coordinator decodes only the native G2PC write set
   (`txn_coordinator.serializeWriteSet`) and votes abort on a protobuf one,
   and no code path produces a protobuf `TwoPhaseMessage`; the tests now
   build G2PC write sets and run (4/4).

With those two fixes, all four `zig build test` shards
(`-Dtest-shard-total=4 -Dtest-shard-index=0..3`) COMPILE and pass under the
pre-push hook env (`CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1`, no `GEODE_MASTER_KEY`).
The protobuf union blocker itself (for real distributed 2PC wire encode) remains
open and is still tracked for the distributed cluster bring-up.

### Which named steps the aggregate runs (SONNY-2772, 2026-11-11)

Every named `test-*` step either runs in the sharded aggregate
`zig build test` (its RUN steps reach `shardDep`, in some shard) or is listed,
with its reason, in `not_in_aggregate_steps` in `build.zig`.
`checkNamedTestStepsInAggregate` enforces this at configure time, so
`zig build -l` fails on a named step that is in neither, and on a listed name
that matches no step or one that runs in the aggregate. Before SONNY-2772,
108 of 628 named steps ran in no aggregate shard. 54 were registered through
`shardDep`; the other 54 were listed. Two of those, `test-gap0862` and
`test-gap0880`, failed on the restored store's resident-cache counts and were
fixed and registered by SONNY-6277. The list holds aggregators (`test-all`,
`test-e2e`, `test-perf`), TSan companions, the e2e, benchmark and perf lanes,
GPU, the subprocess cluster and CLI e2e tests, per-file runners whose files
already run in the aggregate (the `test-lsp-*` files through `test-lsp`, the
in-process cluster smokes through `tests/all_tests.zig`), and one step that
does not pass reliably, `test-slab-packing-geode` (row above).
`test-sonny-write-allowlist-r4-transport` left the list with SONNY-6466: its
abandoned-join check timed the 60 s stall watchdog (its client, which since
SONNY-6301 waits past a reply deadline while the server lives, never left at
1 s), and a close on a sibling stream or a vanished client was not seen
sooner; it passed 7 of 7 runs alone and runs in the aggregate.
`test-first-boot-admin-breadcrumb` left the list with SONNY-6271: its
reset-password case used `resetpass12345`, which the password policy the CLI
adopted in `d8709a2a` refuses (too short, no uppercase, one word); it now uses
a compliant passphrase and runs in the aggregate. Read the list in
`build.zig` for the current set; this document does not copy it.

### tests/ files no build step compiles (SONNY-6542, 2026-11-14)

Every `tests/*.zig` file is either compiled by some step (the root of a test
module, or a tests/ file such a root reaches through an `@import` the
compiler analyzes) or listed, with its reason, in
`scripts/ci/unreachable_test_sources.zig`. `checkTestSourcesReachable` in
`build.zig` enforces this at configure time (`zig build -l`). An unreferenced
container-level `const _x = @import("x.zig");` does not count: Zig never
analyzes it, which is how `tests/all_tests.zig` carried ~90 imports whose
tests never ran. Of the 564 files found: 33 pass and run in
`test-sonny6542-revived`, 142 were removed, 2 turned out to be reached (a
helper and a fixture built through an options path), and 387 were listed.
SONNY-6548 (2026-11-14) triaged the 67 that failed when run: 21 had a stale
expectation or a test defect, were corrected and run in
`test-sonny6542-revived`; 46 were removed (stale and covered by a live step,
written for the deleted client's options, or vacuous: parse-only or mocked
execution presented as feature tests); the product bugs they exposed are the
five `test-sonny6548-*` reproductions above. It also removed 7 listed files
that only exercised dead code (src/types/hash.zig,
src/query/materialized_views.zig, src/optimizer/selectivity_estimator.zig
and the GraphStore path finders, none reachable from the server), and
`tests/canary_rls_abac.zig` (no test block; a placeholder policy mock that
only the unbuilt `benchmarks/benchmark_rls_abac_variance.zig` timed). 311
are listed: 210 do not compile under Zig 0.16, 96 import `../src/` by
relative path (outside a tests/ module root), 3 leak under the testing
allocator, 1 only skips, and `tests/windows_stdio_smoke.zig` is built by a
Makefile target. Their
CANARY markers say `IMPL` until they run. Reviving one: port it, register a
named step through `shardDep`, delete its entry; a failure that is a product
bug stays out of the aggregate and is listed in this document.

### Reproduction

```bash
export GEODE_MASTER_KEY='testmasterkey32chars-DO-NOT-USE-IN-PROD-12345678'

# Production binary (must stay green):
zig build

# Per-step baseline sweep (enumerate from build.zig, run each in isolation):
grep -oE 'b\.step\("test-[^"]+"' build.zig | sed -E 's/b\.step\("//;s/"$//' \
  | sort -u | while read -r step; do
      timeout 300 zig build "$step" >/tmp/$step.log 2>&1
      echo "$step rc=$?"
    done

# Before claiming the aggregate `zig build test` is green: compile every
# artifact it runs, in all shards, without running them. The sweep above only
# reaches artifacts that have a named step; this also reaches the rest
# (SONNY-2394). Heavy: run it on its own.
zig build test-compile

# Re-run a single failing/hanging step:
zig build test-count-pushdown        # SLOW: passes in ~7-13 min (use timeout >= 15 min)
zig build test-e2e                   # gql_conformance 21/21 (T1-T20 + ZZ_cleanup) since GAP-0892 (2026-06-11); residual flakes under load: GAP-0203 QUIC deadline + RSS read (both pass idle)
zig build test-gpu                   # PASS (GAP-0878 resolved 2026-06-11); dispatch test opt-in: GEODE_GPU_DISPATCH_TESTS=1
```

## geodetestlab Integration Suite — historical snapshot (requires a harness run)

The full integration suite lives in `../geode-test-harness` and is **not**
exercised by the local `zig build test-*` sweep above. It requires a dedicated
harness run (`GEODE_BINARY=… make test`, ~25 min with 2 workers, 198 specs) or
`make test-everything-otel`. No fresh harness run was captured for THIS
baseline.

**Last recorded harness numbers (historical, pre-2026-06-10):** ~97% pass rate,
1644/1688 reported (≈46 intentionally skipped). Treat these as a stale snapshot
until a harness run is recorded here with a date. To refresh:

```bash
cd ../geode-test-harness
GEODE_BINARY=/path/to/geode make test          # 198-spec integration suite
# or, with span/metric capture for triage:
make test-everything-otel GEODE_BINARY=/path/to/geode
```

### Notes carried forward from earlier harness runs (verify before trusting)

These items were recorded against earlier harness runs and are kept for triage
context. They are **not** reproduced by the 2026-06-10 local sweep above (that
sweep does not run the harness). Re-confirm against a fresh harness run before
acting:

- **Skipped Cypher-extension features (not ISO GQL):** pattern comprehension
  (`[(p)-[:KNOWS]->(f) | f.name]`) and map projection (`n {.name, .age}`) are
  intentionally unimplemented (Cypher syntax, outside ISO/IEC 39075).
- **Recursive CTEs are supported** (GAP-0268 / GAP-0859); the fixpoint executor
  has a 100-iteration cycle cap. See [GQL_COMPLIANCE.md](GQL_COMPLIANCE.md) and
  `zig build test-recursive-cte` (PASS in this baseline).
- **`extended_test_runner.py` drift (2026-05-07):** the in-tree Python runner
  reported ~200 spec failures (notably `gql_pattern_matching_comprehensive`
  0/35) that the harness CLI runner did not. This was attributed to runner
  setup/persistence drift, not geode behavior. The authoritative runner is the
  harness CLI; the Python runner is a candidate for deprecation. Not reproduced
  locally (the Python runner is not part of this baseline).
- **Load-induced 30 s spec timeouts (2026-05-07):** a few specs intermittently
  hit `Test timed out after 30000ms` under heavy concurrent host load; each
  passed when re-run in isolation. Environmental, not a regression.

## Updating This Document

1. Re-run the per-step sweep (Reproduction above) at the current commit.
2. Rewrite the "Canonical Local Baseline" table and the failures/hangs table
   from THAT run — keep only issues that still reproduce, with file:line and the
   exact assertion/error.
3. For integration coverage, run the harness in `../geode-test-harness` and
   record the dated numbers in the historical section.

*Last rebaselined: 2026-06-10 (GAP-0860) from commit `faac1f3e`. Refreshed 2026-06-10 (GAP-0863d) from per-step re-runs at commit `0eefbb9a`; `test-gpu` moved FAIL→PASS 2026-06-11 (GAP-0878) — expected baseline 175/179 (1 FAIL / 3 TIMEOUT); full re-sweep owed at next rebaseline. 2026-11-15: no full sweep of the ~1,000 steps now registered has been recorded; see the status note under "Canonical Local Baseline".*
