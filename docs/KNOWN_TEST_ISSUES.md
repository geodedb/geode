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
| `test-e2e` | **gql_conformance FIXED 2026-06-11 (GAP-0892, commit `8833fc4a`)** — the suite's only stable failures (T11/T12/T14) are gone: `gql_conformance` is 20/20 (also runnable standalone via the NEW `zig build test-gql-conformance`). A 2026-06-11 re-run under heavy parallel build load scored 83/86 steps / 69/71 tests with 2 DIFFERENT, load-sensitive failures: `tests/test_perf_optimizations.zig` GAP-0203 Fix #4 (QUIC readPacket 5 s deadline; passes idle — 18/18 on one idle re-run, 17/18 on another, flake class) and `tests/integration/test_server_memory_pressure.zig` (RSS read returned 0 under load; passes idle). An idle-host re-run is owed at the Pass-12 rebaseline before declaring the step stably green. |
| `test-perf` | **PASS — reclassified** (see row below): exits 0 on two consecutive idle-host runs, 44/48 tests + 4 opt-in slow-bench skips |
| `test-gpu` | **RESOLVED 2026-06-11 (GAP-0878)** — compiles and PASSES (16/16 steps; 2 Vulkan tests pass, hardware-dispatch test gated behind `GEODE_GPU_DISPATCH_TESTS=1`; see row below) |
| `test-cluster-3node-subprocess` | not re-run (known reliable hang; entry kept below) |

Four named steps were also **added** since the `faac1f3e` sweep, so the
denominator is now **179**: `test-raft-apply` (27/27 PASS),
`test-raft-hardstate-durability` (2/2 PASS), `test-txn-coordinator-2pc`
(0/4 — all 4 protobuf-union-gated self-skips; step PASSES), and
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
| `test-e2e` | **COMPILE FIXED 2026-06-10** (GAP-0863a) — step now runs end-to-end; 1 step still red: `gql_conformance` 17/20 (3 runtime failures) | Zig 0.16 migration debt across 22 files closed: removed-API uses (`std.time.milliTimestamp`/`nanoTimestamp`/`Timer`, `std.Thread.sleep`, `std.fs.cwd`/`File`, `std.process.Child.init`/`getEnvVarOwned`/`getEnvMap`, `std.heap.GeneralPurposeAllocator`, `std.crypto.random`, `std.mem.trimLeft`, `std.Io.fixedBufferStream`, ArrayList `.writer`) migrated to the repo's established compat patterns; all byte-driven fuzz targets ported to the Zig 0.16 `*std.testing.Smith` signature (drawing bytes via `smith.slice`); `tests/e2e_graph_algos_new.zig` (imported a never-exported `graph_algos_stub`) rewritten against the real `geode.graph.community_louvain` / `community_label_propagation` API and now actually runs (was compile-only; 5/5 pass). Verified 2026-06-10 and re-verified at `0eefbb9a` (GAP-0863d): 84/86 steps green, 68/71 tests pass; the only failures are exactly `gql_conformance` T11/T12/T14. **Residual (newly revealed, pre-existing):** `gql_conformance` T11/T12/T14 fail — bare `count(*)` after `SESSION SET PROPERTY GRAPH` returns 0 via the count-pushdown fast path (`match_operations.countNodesFastPath` → `countNodesForGraph` counts the in-memory store before the lazy on-disk graph load) while row-iterating queries over the same graphs (T15–T18) return correct data. The fixture also assumes pre-seeded `G1`/`G2` datasets that nothing in-repo seeds (a clean checkout would also fail T15–T18). **RESOLVED 2026-06-11 (GAP-0892, commit `8833fc4a`):** the diagnosis was corrected during the fix — neither lazy-load nor missing fixtures: `SESSION SET PROPERTY GRAPH "G1"/"G2"` seeds the fixture graphs in-engine (`createTestGraphG1/G2`, `src/execution.zig`), but `query_traits.analyzeProgram` picks the trailing Query as the handler fast-path target, so the QUIC count-pushdown fast path executed only the MATCH against the request-start session graph and skipped the SESSION SET (and its seeding) entirely. Fixed with `ProgramAnalysis.has_effectful_preamble` gating the count + node-scan fast paths; `gql_conformance` is now 20/20 (`zig build test-gql-conformance`, regression `test-gap0892`). |
| `test-edge-torn-read-stress` | **RESOLVED 2026-09-19 (SONNY-1797)** — un-quarantined; back in the aggregate `test` step (12/12 green in a loop) | Was a general protection exception (UAF-class) reproduced at Geode main / v0.8.16 (`a4c5b08f`): a genuine borrowed-slice torn read in the graph-store adjacency hot path. The `bulk_merge_edge` apply path (`bulkMergeEdgesBatchShardLocked`) holds the per-graph `mg.rwlock` only SHARED plus a per-SOURCE-shard lock, while adjacency readers (`getOutgoingEdgeIds`) also hold `mg.rwlock` SHARED — so the shard lock does NOT exclude readers. The append (`appendAdjId`) already grows the backing array by immutable-swap + grace-list retire of the old buffer (never inline-free), but the RESIDUAL half was on the reader: it read the borrowed slice's `(ptr, len)` in natural order and could observe `(old_ptr, new_len)` (old ptr loaded before the swap, new len after), indexing one past the retired buffer. **Fix:** `src/graph_store.zig` `adjItemsSnapshot` mirrors the writer's release with an ACQUIRE-load of `len` FIRST, then reads `ptr`, taking a torn-free snapshot; used by `outAdjItems`/`inAdjItems` and the `*Checked` variants. `build.zig` restores `shardDep(test_step, ..., 15, ...)` so the test runs in the aggregate `test` step. |
| `test-cluster-3node-subprocess` | TIMEOUT (300 s) | Known: the 3-node subprocess cluster reliably stalls/crashes in the QUIC vendor library during multi-node bring-up (see project memory "A6f QUIC processShortHeader crash"). The in-process cluster steps (`test-cluster-3node-election`, `test-cluster-steady-state`, `test-cluster-bootstrap`, `test-cluster-identity`) PASS. |
| `test-cluster-replicable-mutations` | TIMEOUT (300 s) — **intentionally red** (TDD reproduction) | Added 2026-06-09 (commit `7b168f62`) as a deliberately FAILING reproduction of the cluster write-replication gaps (edge CREATE, DELETE/DETACH DELETE, MERGE, ungated MATCH…SET do not replicate; only pure single-node CREATE does). Spawns three real `geode serve` subprocesses — same 3-node subprocess family as the `test-cluster-3node-subprocess` hang below. Stays red/timeout by design until the replication gaps are fixed; do not count it against the gate as a regression. |
| `test-slab-packing-geode` | TIMEOUT (1800 s) — **found 2026-11-11 by SONNY-2772** (named step only, not in the aggregate) | The step had stopped compiling: `tests/test_slab_packing_geode.zig` walked each shard's edge index with `.iterator()` and a `u32` `prop_head`, but graph_storage 0.4.10's `EdgeIndexMap` has no iterator (it is visited with `forEachLive`) and its `prop_head` is `u64` (`error: no field or member function named 'iterator' in 'edge_index_map.EdgeIndexMap'`, then `:161`). SONNY-2772 ported both walks to `forEachLive` (`countLegacyEdgePropHeads`). The step now compiles, but a Debug run did not finish in 30 minutes: the test process wrote ~2 MB/s at ~16% CPU (2.8 GB after 23 min) while ingesting its `N = 50_000` nodes (`tests/test_slab_packing_geode.zig:34`) through the durable adapter path, so no assertion was reached. Kept out of the aggregate (`not_in_aggregate_steps`) until it is made to finish (fewer nodes, or a ReleaseFast lane) and passes. |
| `test-sonny-write-allowlist-r4-transport` | FAIL (QUIC read timeout) — **found 2026-11-11 by SONNY-2772** (named step only, not in the aggregate) | `test "round 4b-1c over QUIC: flat server memory for a WHERE that keeps nothing, …"` (`tests/test_sonny_write_allowlist_r4_transport.zig:721`, SONNY-3368) times out reading the reply while seeding its two 1,500-pair chains (`executeAndCollectWithTimeout`, ~line 745) on unmodified code; under host load `test "round 4a over QUIC: PROFILE repros refused, …"` (`:993`) also timed out in some runs. The gRPC cases pass. Kept out of the aggregate until the QUIC seeding answers inside its timeout. |
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
   path: `distributed/txn_coordinator.TxnCoordinator` is held as a
   `?*TxnCoordinator = null` field on raft_consensus and is never instantiated;
   the live 2PC path is `src/transactions/two_phase_commit.zig`.

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
in-process cluster smokes through `tests/all_tests.zig`), and two steps that
do not pass, `test-slab-packing-geode` and
`test-sonny-write-allowlist-r4-transport` (rows above).
`test-first-boot-admin-breadcrumb` left the list with SONNY-6271: its
reset-password case used `resetpass12345`, which the password policy the CLI
adopted in `d8709a2a` refuses (too short, no uppercase, one word); it now uses
a compliant passphrase and runs in the aggregate. Read the list in
`build.zig` for the current set; this document does not copy it.

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
zig build test-e2e                   # gql_conformance 20/20 since GAP-0892 (2026-06-11); residual flakes under load: GAP-0203 QUIC deadline + RSS read (both pass idle)
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

*Last rebaselined: 2026-06-10 (GAP-0860) from commit `faac1f3e`. Refreshed 2026-06-10 (GAP-0863d) from per-step re-runs at commit `0eefbb9a`; `test-gpu` moved FAIL→PASS 2026-06-11 (GAP-0878) — expected baseline 175/179 (1 FAIL / 3 TIMEOUT); full re-sweep owed at next rebaseline.*
