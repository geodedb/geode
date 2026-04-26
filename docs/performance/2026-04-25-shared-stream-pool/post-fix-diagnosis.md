# Post-fix diagnosis (2026-04-25)

The shared-stream-pool fix (commit `b52846cc`) hoisted the per-connection
QUIC stream-pool + acceptor-pool to server lifetime, but did **NOT** resolve
the cascade. New repro shows:

- **NLWP after fix: 1881** (up from pre-fix 1838)
- Cascade still triggers on `edges_contains.jsonl` at the same point
- 1500s ingest still times out

## Root cause (revised)

The per-connection QUIC pool was a minor contributor (~5 threads/connection).
The dominant source is **per-graph storage-engine pools** in the
`graph_storage` package itself.

Address-clustering of the 1881 idle workers in `cascade-stacks.txt`:

| Pools | Workers each | Total threads |
|-------|--------------|---------------|
| 1 | 64 | 64 (new shared `stream_pool`, working as designed) |
| 1 | 16 | 16 (`ShardedCoordinator`, working as designed) |
| 1 | 4 | 4 (new shared `acceptor_pool`, working as designed) |
| **32** | **56** | **1792 ← the leak** |
| 2 | 2 | 4 |

`56` is exactly `nproc` on this box. Each `GraphEngine.init` in
`zig-pkg/graph_storage-.../src/engine.zig:202` calls
`tp.ThreadPool.init(allocator, .{ .scheduler_variant = .work_stealing, .max_submitter_queues = 1 })`
without setting `max_threads` — and the vendored `thread_pool` library at
`types.zig:365` defaults `max_threads = @min(cpu_guess, 64)`.

`ShardedGraphEngine.create` (sharded_engine.zig:107) calls `GraphEngine.create`
**16 times per graph** (one per shard).

So per graph: 16 sub-engines × 56 workers = **896 idle workers**.

We see 32 such pools × 56 = 1792 threads. That's ~2 sharded engines worth of
sub-engines. The instance count varies run-to-run because some sub-engines
get GC'd between connections; the structural issue is that each sub-engine
has its own CPU-sized pool.

## Why this starves the QUIC packet pump

1792 idle workers all park in `pool.Core.idle` (futex wait). When new work
arrives, the pool's wakeup path competes with the QUIC reactor for kernel
scheduler slots; under sustained 16-way load, the `>5s` end-to-end delay
between client send and server ack exceeds the client deadline → cascade.

## Why the per-engine pool exists

Each `GraphEngine` uses its pool **only** for `BufferPool.flushAllParallel`
(buffer_pool.zig:265). The pool is otherwise idle.

This is wildly oversized: a 56-worker pool dedicated to flushing dirty pages
on a single shard is unnecessary. 4 workers shared across all shards would
be ample.

## Fix options

### Option A — Set `max_threads = 4` in graph_storage

Modify `engine.zig:202` and `engine.zig:318` to pass
`.max_threads = 4` (or similar small value).

Cost: 2-line change to vendored package. Per-graph thread budget drops from
896 → 64. Three graphs × 16 shards × 4 = 192 workers (vs. 1792 today).

### Option B — Share one pool across all sub-engines

Pass a single `*tp.ThreadPool` into `ShardedGraphEngine.create` and have
all 16 sub-engines call `setThreadPool(shared_pool)` instead of each
creating their own.

Cost: API change to graph_storage. Cleanest fix but requires upstream work.

### Option C — Lazy pool creation

Don't create the engine pool until the first `flushAllParallel`. If the
graph never flushes large batches, never spawn workers.

Cost: most invasive change. Only useful if we expect many tiny graphs.

## Recommendation

**Option A** is the right next step:

- Smallest blast radius (2-line patch to vendored deps)
- Matches the reality that the per-engine pool is only used for buffer flushes
- Unblocks the cascade investigation immediately
- Option B (the cleaner architectural fix) can follow as upstream work

Expected post-fix thread count: **~250–300 idle workers** total (well below
the kernel-scheduler-fairness cliff).

## Implications for the shared-stream-pool plan

- **SP Tasks 2+3 (committed):** still correct — eliminates the per-connection
  pool leak surface. KEEP. The fix is necessary but insufficient.
- **SP Task 4 (cascade repro):** FAILED — cascade still triggers because of
  the per-engine pools, not the per-connection pools.
- **SP Task 5 (full msft-graph + closure):** BLOCKED on the per-engine fix.

A new mini-plan should target Option A specifically.
