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

**Result: 175 named `test-*` steps — 167 PASS, 6 FAIL, 2 TIMEOUT, 0 not-run (count-pushdown reclassified PASS after a 15-min re-run; the original 300 s sweep scored it TIMEOUT). Adjusted 2026-06-10: `test-perf-c-introspection-index` re-passed after the GAP-0863b leak fix (8/8, 0 leaks) → 168 PASS / 5 FAIL pending the round's full re-sweep.**

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

`zig build` (the production binary) compiles clean. The 167 passing steps cover
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
| `test-perf` | FAIL (10/11 tests pass) | **Perf gate, hardware-dependent.** The two-phase bulk-edge throughput test asserts a parallel speedup threshold; this host measured `speedup=1.07x–1.10x`, below the gate. Reproduces idle. Treat as a host-relative perf signal, not a correctness regression. |
| `test-stream-pool-concurrent-lanes` | FAIL (2/3 tests pass) | `test "task31_edge: submit() — 8 tasks on 4-thread pool all complete"` (`tests/test_stream_pool_concurrent_lanes.zig:236`) fails `ctx.max_concurrent >= 2`. The scheduler completed tasks without ever observing ≥2 in-flight. Reproduces idle; concurrency-observation assertion is too strict for the platform scheduler or there is a real serialization. |
| `test-perf-c-introspection-index` | **RESOLVED 2026-06-10** (GAP-0863b; 8/8 pass, 0 leaks) | **Was a test-teardown gap exposed by ambient FLE-catalog contamination, not a production leak.** The original 3-leak failure ("7/7 tests pass, 3 leaks" traced to `src/fle_integration.zig:469` `encryptFieldIfNeeded` → `key_manager.getFEK`) required the same contaminated environment as the `test-simple-merge-fastpath` row above: an ambient `GEODE_MASTER_KEY` plus a stale shared `/tmp/geode_fle_catalog.dat` with `('User','email')` configured. Under contamination this suite's `setNodeProperty(..., "email", ...)` writes took the real FLE encrypt path, which lazily instantiates the **process-global** FLE KeyManager on the store's allocator (`std.testing.allocator`); production keeps that singleton for the process lifetime by design (`getFEK` returns the FEK by value — `[32]u8` — so there is nothing for the call site to free; the 3 "leaked" allocations are the KeyManager instance + FEK cache key + cache map storage, all owned by the singleton). **Fix:** the property-writing tests in `tests/test_perf_c_lsp_introspection_index.zig` now `defer fle_integration.resetGlobalKeyStateForTesting()` (no-op when FLE is unconfigured), and a new deterministic regression test reproduces the original failure end-to-end — it configures `('User','email')` via the real `CALL geode.fle.configureField` dispatch inside an isolated `GEODE_DATA_DIR`, asserts the stored value is a true FLE envelope and that the introspection index still reports the property key, and verifies the teardown leaves the leak checker clean. Removing the teardown defer reproduces the exact 3-leak trace. |
| `test-gpu` | FAIL (compile) | **Environmental.** No GPU/Vulkan shader toolchain on this host; the GPU test target fails to compile its shader/native pieces. Expected on non-GPU CI/dev hosts. |
| `test-e2e` | **COMPILE FIXED 2026-06-10** (GAP-0863a) — step now runs end-to-end; 1 step still red: `gql_conformance` 17/20 (3 runtime failures) | Zig 0.16 migration debt across 22 files closed: removed-API uses (`std.time.milliTimestamp`/`nanoTimestamp`/`Timer`, `std.Thread.sleep`, `std.fs.cwd`/`File`, `std.process.Child.init`/`getEnvVarOwned`/`getEnvMap`, `std.heap.GeneralPurposeAllocator`, `std.crypto.random`, `std.mem.trimLeft`, `std.Io.fixedBufferStream`, ArrayList `.writer`) migrated to the repo's established compat patterns; all byte-driven fuzz targets ported to the Zig 0.16 `*std.testing.Smith` signature (drawing bytes via `smith.slice`); `tests/e2e_graph_algos_new.zig` (imported a never-exported `graph_algos_stub`) rewritten against the real `geode.graph.community_louvain` / `community_label_propagation` API and now actually runs (was compile-only; 5/5 pass). Verified 2026-06-10: 84/86 steps green, 68/71 tests pass. **Residual (newly revealed, pre-existing):** `gql_conformance` T11/T12/T14 fail — bare `count(*)` after `SESSION SET PROPERTY GRAPH` returns 0 via the count-pushdown fast path (`match_operations.countNodesFastPath` → `countNodesForGraph` counts the in-memory store before the lazy on-disk graph load) while row-iterating queries over the same graphs (T15–T18) return correct data. The fixture also assumes pre-seeded `G1`/`G2` datasets that nothing in-repo seeds (a clean checkout would also fail T15–T18). Needs a dedicated follow-up: seed fixtures in-test + fix the count fast-path lazy-load interaction. |
| `test-cluster-3node-subprocess` | TIMEOUT (300 s) | Known: the 3-node subprocess cluster reliably stalls/crashes in the QUIC vendor library during multi-node bring-up (see project memory "A6f QUIC processShortHeader crash"). The in-process cluster steps (`test-cluster-3node-election`, `test-cluster-steady-state`, `test-cluster-bootstrap`, `test-cluster-identity`) PASS. |
| `test-all` | TIMEOUT (300 s) | The `test-all` aggregate (unit + e2e) inherits the `test-e2e` compile failures and the `test-count-pushdown` slowness (~7-13 min, passes), and also drives the blocked `graph_store_unit_tests` shard below. Not a distinct issue — it is the union of the rows above plus the shard note. |

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

# Re-run a single failing/hanging step:
zig build test-count-pushdown        # SLOW: passes in ~7-13 min (use timeout >= 15 min)
zig build test-simple-merge-fastpath # 10/11; apply_on_match upsert assertion
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

*Last rebaselined: 2026-06-10 (GAP-0860) from commit `faac1f3e`.*
