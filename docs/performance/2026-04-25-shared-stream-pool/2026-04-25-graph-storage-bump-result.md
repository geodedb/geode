# Graph-storage Phase 1 dep bump — cascade re-test result

**Date:** 2026-04-25 22:09 UTC
**Ingest run:** `docs/performance/2026-04-25-edges-contains/repro-{server,ingest}.log` (this run)
**Pre-fix baseline:** `docs/performance/2026-04-25-edges-contains/diagnosis.md` + `docs/performance/2026-04-25-shared-stream-pool/post-fix-diagnosis.md`
**Predecessor reports:**

- `post-fix-diagnosis.md` (per-engine pool fanout hypothesis)
- `upstream-handoff.md` (graph-storage shared-pool design)
- Upstream design: `~/src/devnw/zig/graph-storage/docs/2026-04-25-shared-engine-thread-pool.md`

---

## TL;DR

> **CORRECTION (2026-04-25 22:44 UTC):** The "Real dominant cause"
> row below was wrong. A second cascade re-run with stack capture
> ran to completion and showed **zero threads in any rwlock
> acquisition path** at cascade time. The frozen
> `mg_rwlock_exclusive_wait_ns_total` is a historical artifact of
> early-run contention, not a live signal of writer starvation. See
> `docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md`
> §"Part 2 — Post-fix re-analysis" for the corrected verdict. The
> first row (per-engine pool fanout structurally fixed) stands; the
> rwlock-as-remaining-cause inference does not.

| Hypothesis | Status | Evidence |
|------------|--------|----------|
| Per-engine `tp.ThreadPool` fanout (`16 × 56 = 896` workers / graph) is the root cause of the cascade | **REFUTED as sole cause; CONFIRMED as a contributor.** Fix landed structurally — thread count fell from 1881 → 97 (~19× reduction), well past the predicted ≤300 target — but the cascade still triggered at the same point with the same client-side error pattern. | NLWP, ingest log, server metrics (below) |
| ~~Real dominant cause: Writer starvation on `mg.rwlock`~~ **(REFUTED — see correction above)** | ~~`mg_rwlock_exclusive_wait_ns_total` froze at 17.85s for the entire 25-min run; readers continued acquiring at low rate~~ — Part 2 stacks show no thread is in any rwlock path; the metric represents past contention, not current parking. | server log metrics tail (kept for historical record); see `stacks-analysis.md` §Part 2 for the corrected analysis |
| Actual dominant cause (current best understanding) | **Unknown — upstream of the database.** All worker threads idle, stream-query handlers idle in `BufferedProtoReader.nextMessage`, QUIC reactor in normal 500 µs yield loop. Bottleneck is at the QUIC transport / client protocol boundary. New investigation thread needed. | `stacks-analysis.md` §"Part 2 — Post-fix re-analysis" |

---

## What changed

Single dep bump in `geode/build.zig.zon`:

```
graph_storage:  0ce15769076d7c783c57d674e90182bc073853d1
            →  5ead31bc3204f117c24bbdffcbb280a545007be7
```

This pulled in graph-storage Phase 1 (commits `ef9bf88` → `5ead31b`):

- `feat(config): add GraphConfig.external_thread_pool field`
- `refactor(engine): borrow-or-own thread pool, default 4 workers`
- `feat(engine): borrowed thread pool — skip shutdown/deinit on close`
- `feat(sharded): single shared thread pool across all 16 shards`
- two test commits

No geode source change required. `ShardedGraphEngine.create` now lazily owns a single `tp.ThreadPool` shared across all 16 sub-engines per graph, instead of every sub-engine instantiating its own. Per-graph thread budget collapses from 896 → 4. **Geode did not need to adopt `external_thread_pool`** for this run — the structural fix activates with the default code path.

## Result

### Thread count (structural fix landed)

```
$ ps -o nlwp,pid,etimes,stat,comm -p $SERVER_PID
NLWP     PID ELAPSED STAT COMMAND
  97  454426    1246 Sl   geode
```

| Run | NLWP at cascade | Notes |
|-----|-----------------|-------|
| Pre-fix baseline | **1838** | per-connection QUIC pool leak only |
| Post shared-stream-pool (commit `b52846cc`) | **1881** | QUIC pool fixed; per-engine pool fanout dominates |
| **Post graph-storage Phase 1 (this run)** | **97** | per-engine fanout structurally fixed |

19× reduction. Predicted target was ≤80, actual is 97 (likely ~16 from the new shared sharded pool + ~64 from the geode QUIC stream pool + a few service threads). The post-fix-diagnosis hypothesis is fully validated at the thread-budget level.

### Cascade timeline (problem persists, different cause)

- `21:44:45` ingest start, 16 parallel workers, 5 edge files queued
- `21:44:53` 16 pinned QUIC connections acquired
- `21:45:04` 281/623 nodes flushed — last forward progress
- `21:54:23` (**~9 min later**) all chunks fail simultaneously: `batch begin tx: context deadline exceeded`
- `21:54:24` pipeline retries in serial mode
- `22:04:24` serial mode also stalls — `transport read_length to 127.0.0.1:3171: deadline exceeded`
- `22:09:45` 1500s timeout hit → `INGEST_TIMED_OUT_OR_FAILED exit=124`

Server post-mortem: still alive, RSS 207 MB, 360 open FDs, **97 threads**, `State: S (sleeping)` — blocked, not spinning.

### The smoking gun — server-side rwlock metrics

`mg_rwlock_exclusive_wait_ns_total` metric **frozen at exactly `17,847,391,971` ns (≈17.85s) across every log line in the second half of the run** (samples below). Shared-acquire counter continues creeping up at ~7 acquisitions per polling interval (~1 Hz):

```
mg_rwlock_shared_acquired_total=678 mg_rwlock_shared_wait_ns_total=1121338 mg_rwlock_exclusive_wait_ns_total=17847391971
mg_rwlock_shared_acquired_total=685 mg_rwlock_shared_wait_ns_total=1130865 mg_rwlock_exclusive_wait_ns_total=17847391971
mg_rwlock_shared_acquired_total=689 mg_rwlock_shared_wait_ns_total=1135089 mg_rwlock_exclusive_wait_ns_total=17847391971
mg_rwlock_shared_acquired_total=696 mg_rwlock_shared_wait_ns_total=1143582 mg_rwlock_exclusive_wait_ns_total=17847391971
mg_rwlock_shared_acquired_total=707 mg_rwlock_shared_wait_ns_total=1156837 mg_rwlock_exclusive_wait_ns_total=17847391971
mg_rwlock_shared_acquired_total=714 mg_rwlock_shared_wait_ns_total=1165649 mg_rwlock_exclusive_wait_ns_total=17847391971
```

Interpretation: **a writer is parked on `mg.rwlock` and no further exclusive wait is being recorded** — i.e., no new writer is even reaching the contended lock state because the previous writer is still queued. Readers (low-frequency counter pings) continue draining. This is textbook reader-preferring rwlock starvation.

The aggregate wait-time of 17.85s for one writer to reach the front of the queue, on a 1500s ingest, is the proximate cause of the chunk-level `context deadline exceeded` errors.

## Why this matches the rwlock-fairness investigation, not the pool-leak one

The pool-leak hypothesis predicted that thread starvation at the kernel scheduler would amplify any contended lock into an end-to-end deadline miss. The structural fix removes that amplification — but if the lock is **already** starved at the protocol level (writer cannot acquire while any reader is holding shared), then thread budget is irrelevant.

That second condition is what we have. Evidence:

1. NLWP collapsed without resolving the cascade — refutes "kernel scheduler is the bottleneck."
2. `exclusive_wait_ns_total` is monotonic but currently frozen at a single high value — refutes "many writers backlogged" and confirms "one writer permanently blocked."
3. `shared_wait_ns_total` is microseconds — refutes "readers contending with each other."
4. Server `State: S` not `R` — process is parked at a futex, not burning CPU.
5. Pre-existing investigation `docs/performance/2026-04-25-enterprise-rwlock-fairness/stacks-analysis.md` already attributed the cascade to writer starvation on the same lock at baseline `e9ee75d7`.

## Recommended next actions

1. **Mark the shared-stream-pool plan complete with caveats.** SP Tasks 2/3 (per-connection pool hoist) are done and correct (`b52846cc`). Tasks 4/5 (cascade re-repro + closure) are partially-resolved: the graph-storage Phase 1 dep bump landed and structurally fixed the thread budget, but the cascade itself is not the pool-leak's responsibility. Add a closure note pointing here.
2. **Resume the rwlock-fairness plan** (`docs/superpowers/plans/2026-04-25-enterprise-rwlock-fairness.md`). Baseline metrics from this run can be compared against any candidate fix without re-fighting the thread-budget noise.
3. **Forward the upstream notify** from `thread-pool` v0.2.1 release to the graph-storage agent: `graph-storage/src/sharded_engine_test.zig:381` can revert `max_submitter_queues = 32` → `64` once `build.zig.zon` bumps thread_pool to v0.2.1 (`3a06f01`). Out of scope for geode; tracked here only so the chain isn't lost.
4. **Optional follow-up:** geode adoption of `external_thread_pool` (single server-lifetime pool injected into every `ShardedGraphEngine.create/open` call site at `src/storage/graph_storage_adapter.zig:3140` and `:3208`) is still recommended — it would further drop NLWP from `(N graphs × 4) + 64` to a fixed `~8 + 64` regardless of graph count. Marginal at current N but valuable for multi-graph deployments. See `upstream-handoff.md` §"Geode's downstream changes (after upstream lands)".

## Artifacts

- Server log: `docs/performance/2026-04-25-edges-contains/repro-server.log`
- Ingest log: `docs/performance/2026-04-25-edges-contains/repro-ingest.log`
- Repro script: `/tmp/run-edges-contains-repro.sh`
- Build delta: `git diff build.zig.zon` shows only the `graph_storage` URL/hash change
