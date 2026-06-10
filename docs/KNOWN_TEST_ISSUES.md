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

**Result: 175 named `test-*` steps — 167 PASS, 6 FAIL, 2 TIMEOUT, 0 not-run (count-pushdown reclassified PASS after a 15-min re-run; the original 300 s sweep scored it TIMEOUT).**

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
| `test-simple-merge-fastpath` | FAIL (10/11 tests pass) | **Real functional bug.** `test "bulkMergeNode apply_on_match updates existing node (true upsert)"` (`tests/bulk_ingest/test_simple_merge_fastpath.zig:476`) fails `expectEqualStrings("bob@example.com", email_prop.String)` — the bulk-MERGE apply-on-match path does not persist a *new* property introduced on the match update. Aligns with the documented bulk-MERGE limitation area (see CLAUDE.md → Full-text search bulk-MERGE). FLE key was set, so this is not the master-key path. |
| `test-perf` | FAIL (10/11 tests pass) | **Perf gate, hardware-dependent.** The two-phase bulk-edge throughput test asserts a parallel speedup threshold; this host measured `speedup=1.07x–1.10x`, below the gate. Reproduces idle. Treat as a host-relative perf signal, not a correctness regression. |
| `test-stream-pool-concurrent-lanes` | FAIL (2/3 tests pass) | `test "task31_edge: submit() — 8 tasks on 4-thread pool all complete"` (`tests/test_stream_pool_concurrent_lanes.zig:236`) fails `ctx.max_concurrent >= 2`. The scheduler completed tasks without ever observing ≥2 in-flight. Reproduces idle; concurrency-observation assertion is too strict for the platform scheduler or there is a real serialization. |
| `test-perf-c-introspection-index` | FAIL (7/7 tests pass, **3 leaks**) | All assertions pass, but the FLE-keyed introspection-index path leaks 3 allocations (leak originates in `src/fle_integration.zig:469` `encryptFieldIfNeeded` → `key_manager.getFEK`). The leak alone trips the non-zero exit. |
| `test-gpu` | FAIL (compile) | **Environmental.** No GPU/Vulkan shader toolchain on this host; the GPU test target fails to compile its shader/native pieces. Expected on non-GPU CI/dev hosts. |
| `test-e2e` | FAIL (compile) | Pulls in benchmark + fuzz targets that have not been migrated to Zig 0.16: `tests/e2e_tde_encryption.zig` uses the removed `std.time.milliTimestamp`; `fuzz/targets/txn_sequence_fuzz.zig` / `decimal_roundtrip_fuzz.zig` use the old `testing.Smith` fuzz signature; `bench_federation_mismatch_*` / `bench_redo_optimization_delta` fail to compile. These are separate never-compiled paths, not e2e logic regressions. |
| `test-cluster-3node-subprocess` | TIMEOUT (300 s) | Known: the 3-node subprocess cluster reliably stalls/crashes in the QUIC vendor library during multi-node bring-up (see project memory "A6f QUIC processShortHeader crash"). The in-process cluster steps (`test-cluster-3node-election`, `test-cluster-steady-state`, `test-cluster-bootstrap`, `test-cluster-identity`) PASS. |
| `test-all` | TIMEOUT (300 s) | The `test-all` aggregate (unit + e2e) inherits the `test-e2e` compile failures and the `test-count-pushdown` slowness (~7-13 min, passes), and also drives the blocked `graph_store_unit_tests` shard below. Not a distinct issue — it is the union of the rows above plus the shard note. |

### Blocked: `graph_store_unit_tests` shard / monolithic `zig build test`

`zig build test` aggregates ~60 test binaries via a sharded dependency graph.
The `graph_store_unit_tests` shard (rooted at `src/graph_store.zig`)
transitively imports `execution.zig → raft_consensus.zig → txn_coordinator.zig`
and pulls those files' inline `test` blocks into the test root. Several of
those paths never compiled under the test root and were therefore silently
absent from `zig build test`. Commit `faac1f3e` repaired the mechanical ones
(missing module imports on the test root; the removed `.noop` Message variant;
the `std.Io.Dir`/`File` API; stale managed-`ArrayList` calls; the protobuf
`.@"enum"` field form; `std.json.ObjectMap` unmanaged form).

**Residual blocker (library limitation):** the txn_coordinator 2PC tests
protobuf-encode `distributed_schema.TwoPhaseOperation`, which is a Zig `union`.
The pinned `protobuf` 0.1.3 (`zig-pkg/protobuf-0.1.3-…`) rejects a union as a
submessage at comptime:

```
protobuf.zig:711  internal_init(comptime T: type, ...)  // requires @typeInfo(T) == .@"struct"
protobuf.zig:713  @compileError("Invalid internal init type {s}", .{@typeName(T)})  // T = TwoPhaseOperation (union)
wire.zig:704      error: expected type 'builtin.Type.StructField', found 'builtin.Type.UnionField'
```

This is the same protobuf "union-as-submessage" blocker tracked for the
distributed cluster bring-up. Until the protobuf dependency gains union support
(or `TwoPhaseOperation` is reshaped into a struct-with-oneof), the
`graph_store_unit_tests` shard — and therefore the single monolithic
`zig build test` invocation — cannot fully compile. The per-step sweep above is
the canonical local baseline in the meantime; the graph_store logic itself is
exercised by the many passing `test-graph-*`, `test-merge-*`, `test-perf-*`,
`test-match-*`, and bulk-ingest steps.

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
