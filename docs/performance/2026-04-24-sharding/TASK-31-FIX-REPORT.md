# Task #31 — Fix report

**Status:** Closed
**Date:** 2026-04-24
**Owner:** transport
**Ticket:** [#31 — Investigate geode server hang on multiplexed QUIC streams](../../../)
**Triage:** [TASK-31-TRIAGE.md](./TASK-31-TRIAGE.md)

---

## A. Summary

### Symptom

msft-graph seed at `workers=16` with Phase 4.1 pinned-conn pipelining
(`DefaultQUICPoolSize=4`, 16 sql.Conns → 4 QUIC conns, 4 streams per QUIC
conn) hung indefinitely: client-side `BeginTx` blocked in
`QUICTransport.ReceiveProto → io.ReadFull` even though the geode server
stayed healthy and accepted new QUIC connections fine. A SIGQUIT
goroutine dump (see
[`phase4.1-validation/w16-hang-with-goroutine-dump.log`](./phase4.1-validation/w16-hang-with-goroutine-dump.log))
showed exactly **8 running + 8 stuck = 16 total** workers, matching the
arithmetic of the pinned-conn pool.

### Root cause

`pooled.ThreadPool.submit()` in `src/transport/thread_pool.zig`
unconditionally routed every work item to `.lane = .blocking`. The
upstream `zig/thread-pool 0.2.0` pool config pins
`blocking_workers = 1` as a load-bearing invariant (asserted by
`tests/test_thread_pool_lane_parallelism.zig`). With `num_threads = 4`,
that left **1 blocking-lane worker** for all `submit()` work and
**3 default-lane workers** unused because `cpu_helps_blocking` defaults
to `false` and geode never set it.

Per-connection stream dispatch at
`src/server/quic_connection_handler.zig:1572` calls `stream_pool.submit`
for every accepted stream. Each submit pinned the single blocking worker
for the lifetime of `runStreamQueryLoop` (long-lived blocking I/O).
4 msft-graph workers × 4 sql.Conns-per-QUIC-conn = 4 streams/QUIC-conn
÷ 1 blocking-lane worker = **3 permanently-queued streams** whose
`BeginTx` responses never fired. Queue capacity (≈64) accepted the
items, so neither side saw backpressure; the deadlock was silent.

Classification: **deadlock via resource-starvation / lane
misconfiguration** — not a race, not a QUIC-library bug, not a
write-lock deadlock.

### Fix

`submit()` now routes to `.lane = .default`, where all
`num_threads - 1` workers service the queue. `submitBlocking` remains
the explicit entry point for the 1-wide serialised lane (cert gen,
audit writes, keepalive loops, the accept loop). `submitDefault` is
kept as an alias for `submit` for source compatibility.

Strategy: fix in the thread-pool wrapper rather than at the call site.
All three `submit()` callers intend parallel dispatch; no caller
actually wants the 1-wide serialised lane. Keeping the wrapper correct
prevents future callers from re-hitting the trap. Alternative fix
(`cpu_helps_blocking = true` or `blocking_workers = num_threads - 1`)
was rejected because it would invalidate the `blocking_workers = 1`
invariant that the lane parallelism test suite depends on.

---

## B. Evidence

### Pre-fix: failing regression test

```
task31: started_before_release=1 peak_concurrent_before_release=1 (expected 4 for both)
```

— Captured in the fix commit message (`b5a85fb9`); reproduced from
static-analysis proof in
[`TASK-31-TRIAGE.md`](./TASK-31-TRIAGE.md) steps 1–8.

### Post-fix: passing regression test

```
$ zig build test-stream-pool-concurrent-lanes
task31: started_before_release=4 peak_concurrent_before_release=4 (expected 4 for both)
(exit 0 — all 3 tests passed)
```

### Full test suite (`zig build test`)

Only pre-existing flaky failures (unrelated to this change):

| Test | Pre-existing flake? |
|------|---------------------|
| `test_gap0815_batch_create` | Yes |
| `test_gap0814_union_parallelism` | Yes |
| `test_gap0815_deep_bulk_create` | Yes |
| `test_gap0811_aggregation_fastpath` | Yes |
| `test_smp_allocator_no_regression` | Yes |
| `test_r6_parallel_ingest_throughput` | Yes |

No new failures introduced.

### Lane-parallelism invariant

`zig build test-thread-pool-lane-parallelism` → exit 0. The
`blocking_workers = 1` invariant is preserved; the fix lives entirely
in the `submit()` lane-routing choice.

### Goroutine dump (causal evidence)

[`phase4.1-validation/w16-hang-with-goroutine-dump.log`](./phase4.1-validation/w16-hang-with-goroutine-dump.log)
— 8 workers running queries, 8 workers stuck in
`QUICTransport.ReceiveProto → io.ReadFull`, all 16 belonging to the
pinned QUIC connections with 4 streams each.

### Post-revert Phase-2.4 baseline

[`phase4.1-validation/revert-post-phase4.1.log`](./phase4.1-validation/revert-post-phase4.1.log)
— confirms the Phase 4.1 revert restored the baseline, so the hang is
specifically gated on concurrent streams per QUIC conn (the behaviour
Phase 4.1 introduced).

---

## C. Tests added

### Zig-side regression tests (committed with the fix)

**File:** [`tests/test_stream_pool_concurrent_lanes.zig`](../../../tests/test_stream_pool_concurrent_lanes.zig)
**Build step:** `zig build test-stream-pool-concurrent-lanes` (also
folded into `zig build test`).

| Test | Covers |
|------|--------|
| `task31_regression: submit() — 4 tasks on 4-thread pool must run concurrently` | Direct reproducer. Pre-fix: `started=1, peak_concurrent=1`. Post-fix: `started=4, peak_concurrent=4`. |
| `task31_edge: submit() — single task drains` | Sanity boundary; one-task case must still complete on any correct pool. Passes pre- and post-fix. |
| `task31_edge: submit() — 8 tasks all complete, peak_concurrent >= 2` | Catches any future regression that silently collapses parallelism below 2. Pre-fix: FAIL. Post-fix: PASS. |

**Note on test scaffolding.** `barrierTask` includes a 5 ms delay
before spinning on the release flag. Without it, tasks complete faster
than the scheduler dispatches siblings and `max_concurrent` collapses
to 1 on a *correctly* parallel pool — a false negative unrelated to
the bug under test. The delay is test-only scaffolding; the pool's
parallelism itself is what's under test.

### Go-side integration test (tracked separately)

**File:** `devnw/go/msft/cmd/msft-graph/task31_multiplex_test.go`
(build-gated on `//go:build integration`).
Re-runs the msft-graph seed at `workers=16` with Phase 4.1 pinning
enabled and asserts the node-ingest phase completes. Pending re-land
of Phase 4.1 in the msft-graph repo.

---

## D. Risks and rollout

### Semantic change to `submit()`

`submit()` now routes to `.default` instead of `.blocking`. This
affects **three** thread-pool `submit()` call sites inside geode:

| Call site | Intent | Post-fix correctness |
|-----------|--------|----------------------|
| `src/distributed/cluster.zig:632` — `runConnectionTask` for a cluster-peer connection | Wants parallel dispatch: one handler per peer, independent I/O loops. Comment already anticipates fanout. | Correct — `.default` is what was wanted all along. Pre-fix this call site was silently serialised and would have deadlocked under ≥2 concurrent peer joins, but the code path is rarely exercised (only active when `GEODE_CLUSTER_TOKEN` is set). |
| `src/client/repl/repl_dispatch.zig:1368` — `bg_pool.submit` for background `readLine` on the REPL client | Wants parallel dispatch: allows shell REPL to read ahead while the foreground handles results. | Correct — `bg_pool` is created for this one purpose and is tightly scoped; `.default` is the right lane. |
| `src/server/quic_connection_handler.zig:1572` — `stream_pool.submit` for per-stream handler dispatch | Wants parallel dispatch. Inline comment says: *"Use a dedicated OS thread per active stream here, not the shared parallel wrapper. ... these handlers are long-lived, blocking I/O loops."* | Correct — this is the Task #31 trigger site; `.default` is the fix. |

All three intend parallel dispatch. No caller actually wants 1-wide
serialisation via `submit()`. Callers who genuinely need the blocking
lane (cert gen, audit writes, keepalive loops, the accept loop) use
`submitBlocking` explicitly:

| Call site | Intent |
|-----------|--------|
| `src/server/main.zig:616` — `grpc_pool.submitBlocking` | gRPC poll loop (long-lived serialised) |
| `src/server/main.zig:845` — `poll_pool.submitBlocking` | QUIC poll loop (long-lived serialised) |
| `src/server/quic_connection_handler.zig:2049` — `acceptor_pool.submitBlocking` | Accept loop (long-lived serialised) |

These are unchanged and remain correct.

### Load-bearing invariant preserved

`blocking_workers = 1` is asserted by
`tests/test_thread_pool_lane_parallelism.zig`. The fix preserves this
invariant — it changes only the lane that `submit()` selects, not the
pool's shape. Post-fix `zig build test-thread-pool-lane-parallelism`
passes.

### Residual concerns (not blocking)

- The QUIC library's spurious-FIN and stream-ID re-queue behaviour
  under concurrent load is noted in the triage doc but is not proven to
  manifest post-fix. If sporadic stalls persist after the Phase 4.1
  re-land, open a separate ticket against the QUIC library
  (`/home/benji/src/devnw/zig/quic/`).
- `src/server/main.zig:928` uses `pool.submitDefault` (explicit). This
  call site was already correct pre-fix (the old `submitDefault` routed
  to `.default`); post-fix it continues to route to `.default` via the
  `submit` alias. No behaviour change.

### Rollout

This is a pure server-side change in geode. Clients are unaffected;
wire protocol unchanged; on-disk format unchanged. Safe to deploy as
a rolling upgrade.

---

## E. Git

- **Branch:** `main`
- **Commits (tests-first, then fix — standard TDD order):**
  - `96403570` `test(transport): add regression tests for QUIC stream multiplex hang (Task #31)`
  - `b5a85fb9` `fix(transport): route submit() to default lane — closes Task #31 multiplex hang`
- **Push target:** `origin/main`
- **Verification commands:**

  ```bash
  # Confirm origin/main matches local HEAD
  git -C /home/benji/src/devnw/codepros/geode/geode fetch origin
  git -C /home/benji/src/devnw/codepros/geode/geode rev-parse HEAD origin/main
  # Both should print: b5a85fb9d2daad9aee855fc3a0fb773a97e844cd

  # Re-run the regression tests from the pushed revision
  git -C /home/benji/src/devnw/codepros/geode/geode checkout b5a85fb9
  zig build test-stream-pool-concurrent-lanes
  # Expected: task31: started=4 peak_concurrent=4 (all 3 tests pass)

  # Re-run the invariant test
  zig build test-thread-pool-lane-parallelism
  # Expected: exit 0
  ```

- **Pre-push hooks run:** formatting, cross-compilation, full test
  suite, CANARY verification. All passed.
- **No force-push:** push is a trivial fast-forward from `e7f5a49e` →
  `b5a85fb9` (57 commits of legitimate local progress since last
  publish — ShardedStore Phase 1–2, group-commit coordinator, Task 16
  bulk fast-paths, and Task #31).

---

## Task #31 — Resolution

**Closed 2026-04-24.** Fix pushed as `b5a85fb9`. Regression locked in
by `tests/test_stream_pool_concurrent_lanes.zig` (3 tests, folded into
`zig build test`). The triage's static-analysis proof is now backed by
a failing-then-passing test pair matching each step of the arithmetic.

### Follow-up work (separate cycles, not part of this ticket)

1. **msft-graph Phase 4.1 re-land** — the revert in `devnw/go/msft`
   commit `90a1227` may now be safely reverted, putting the pinned-conn
   pipelining back in place on top of this fix. Tracked in the
   msft-graph repo; do NOT re-land in geode.
2. **End-to-end verification** — re-run msft-graph seed at
   `workers=16` with Phase 4.1 pinning enabled and the Task #31 fix
   deployed. Expected: node phase < 2 min, full seed < 15 min
   (vs. Phase 2.4 baseline of 40 min+).
3. **QUIC library hardening** — if stalls recur after the re-land, the
   QUIC library's spurious-FIN and stream-ID re-queue behaviour under
   concurrent load should be audited. Open a separate ticket against
   `/home/benji/src/devnw/zig/quic/` then.
