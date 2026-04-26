# Upstream handoff — graph-storage shared engine thread pool

**Date:** 2026-04-25
**Companion to:** `post-fix-diagnosis.md` (same directory)
**Upstream report:** `~/src/devnw/zig/graph-storage/docs/2026-04-25-shared-engine-thread-pool.md`

---

## What this document is

A short summary of why the per-engine thread-pool fix is **upstream work** in `graph-storage`, not a geode-side patch. The full design is in the upstream report linked above.

## Why upstream, not geode

Three structural reasons:

1. **The leak is at `GraphEngine.init`.** `src/engine.zig:202` (and `:318`) calls `tp.ThreadPool.init` with no `max_threads`, defaulting to `min(cpu, 64)` = 56 workers per engine. Geode cannot influence this without vendor-patching the dependency.
2. **`ShardedGraphEngine` lives upstream.** Even if geode passes one pool in, geode cannot stop `ShardedGraphEngine.create` from spawning 16 inner pools (`src/sharded_engine.zig:103-109` × `SHARD_COUNT = 16`) without an upstream API change.
3. **The thread_pool dependency is already designed for sharing** (multiple submitters, pool-scoped TLS, 64 submitter slots — see upstream §3). The current per-engine ownership pattern is the unidiomatic case. Fixing it upstream aligns graph-storage with how the dependency was meant to be used.

## Geode's downstream changes (after upstream lands)

Order of operations:

1. Wait for graph-storage to land `GraphConfig.external_thread_pool` (and the matching `ShardedGraphEngine` propagation) — see upstream §5.
2. Bump the graph-storage dependency in `build.zig.zon`.
3. Add a server-lifetime `tp.ThreadPool` to `src/server/main.zig` alongside the existing shared `stream_pool` / `acceptor_pool` (commit `b52846cc`):

   ```zig
   var storage_pool = try tp.ThreadPool.init(allocator, .{
       .scheduler_variant = .work_stealing,
       .max_threads = @min(8, std.Thread.getCpuCount() catch 4),
       .max_submitter_queues = 64,  // 4 graphs × 16 shards = 64 — exactly at cap
   });
   defer storage_pool.deinit();
   ```

4. Pass it into both `ShardedGraphEngine.create` and `ShardedGraphEngine.open` call sites in `src/storage/graph_storage_adapter.zig` (currently `:3140` and `:3208`) via `GraphConfig.external_thread_pool`.
5. Extend the existing pool-leak regression test (`tests/test_pool_lifetime_no_leak.zig` from SP Task 1) to also assert `NLWP < cpu_count + 16 + N_open_graphs` after opening N graphs. Pre-fix observed: 1881. Post-fix expected: ≤80.
6. Re-run the cascade repro from `post-fix-diagnosis.md`. Expected outcome: cascade resolved, ingest of `edges_contains.jsonl` completes inside the 1500s budget.
7. Update the SP plan (`docs/superpowers/plans/2026-04-25-shared-stream-pool.md`) with a note that Tasks 4 and 5 are unblocked by the upstream change and a link to the upstream report.

## Interim mitigation (if upstream is blocked)

If the upstream change cannot land within the current investigation window, the **vendored 2-line patch** (Option A from `post-fix-diagnosis.md`) is acceptable as a temporary unblock:

```zig
// In zig-pkg cache copy of graph-storage src/engine.zig:202 and :318
self.thread_pool = try tp.ThreadPool.init(allocator, .{
    .scheduler_variant = .work_stealing,
    .max_submitter_queues = 1,
    .max_threads = 4,            // ← TODO: drop after upstream shared-pool lands
});
```

This drops the per-graph thread budget from 896 → 64. It does NOT solve the structural problem (still per-engine ownership; still drifts on every dependency bump). It exists only to unblock the cascade work while upstream lands.

## Mutex/lock impact

None. The shared pool sits below all storage tiers in the lock hierarchy (CLAUDE.md §"Mutex Lock Ordering") and is internally lock-free. No tier-table edits needed.

## Status

- [x] Diagnosis complete (`post-fix-diagnosis.md`)
- [x] Upstream report filed (`graph-storage/docs/2026-04-25-shared-engine-thread-pool.md`)
- [x] Geode handoff filed (this document)
- [ ] Upstream implementation (graph-storage)
- [ ] Upstream test suite (graph-storage)
- [ ] Geode dependency bump
- [ ] Geode adoption (4 call sites + 1 server-lifetime pool)
- [ ] Cascade re-repro proves fix
