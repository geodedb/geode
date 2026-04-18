# Triage: #751 — CLI session setup queues behind thread-pool under concurrent write load

- **Status:** triage complete; no fix implemented.
- **Date:** 2026-04-16
- **Branch:** main @ `ece42db7` (release `v0.3.3`).
- **Repro:** `BACKGROUND_LOAD=1 ./tests/test_count_nodes_no_flake.sh` — 10/10 MATCH runs time out at ~5073 ms (client `--timeout 5`).

## Issue Restated

With N concurrent writer CLIs hammering short-lived `CREATE … RETURN` connections, a newly connecting CLI cannot complete session setup within any reasonable deadline. Per-writer latency cost on a measurement CLI scales linearly with N until the client deadline is hit — the query itself is not running slowly; the connection is waiting for an admission slot.

## Build/Test/Lint Entry Points

| Action | Command | Config File |
|--------|---------|-------------|
| Build | `make build` | `Makefile`, `build.zig` |
| Repro | `BACKGROUND_LOAD=1 ./tests/test_count_nodes_no_flake.sh` | `tests/test_count_nodes_no_flake.sh` |
| Unit tests | `make test` | `build.zig` |
| Harness | `cd ../geode-test-harness && make test` | harness repo |

## Reproduction Results

Repro script (unchanged): `tests/test_count_nodes_no_flake.sh`.

- `BACKGROUND_LOAD=1`, 2000-node bulk seed, 8 writer CLIs, 10x `MATCH (n) RETURN count(n)` with `--timeout 5`:
  - **10/10 runs SLOW/RC=1**; min=5063 ms, max=5073 ms; uniformly at the client deadline.
- Scaling sweep (writers vs measurement CLI latency, this repo, current binary):

  | writers | `MATCH … count(n)` | `RETURN 1 AS x` |
  |--------:|-------------------:|----------------:|
  | 0       | 872 ms             | 870 ms          |
  | 1       | 972 ms             | 1172 ms         |
  | 2       | 1271 ms            | 1869 ms         |
  | 4       | 2674 ms            | 2868 ms         |
  | 6       | **6072 ms (TO)**   | **6073 ms (TO)**|
  | 8       | **6078 ms (TO)**   | **6077 ms (TO)**|

  The trivial `RETURN 1` (no storage, no WAL, no mutex beyond a cpu-local ctx) times out **identically** to the full count scan. That conclusively rules out (c) graph_store/catalog contention, (d) fsync serialization, and (e) query-path bugs as the dominant cause.

- Server thread snapshot under 8-writer load: 141 threads total, ~118 sleeping in `futex_wait_queue`. Only ~186 `sendto` + ~170 `poll` syscalls in 3 s of whole-process strace: UDP I/O is near idle. Threads are parked waiting on lane condvars, not doing work.

- Capacity math matches the observed scaling: per-writer penalty ≈ 100–300 ms until the deadline; consistent with a single serializer processing the incoming connection backlog and one writer-cycle (handshake + auth + CREATE + teardown) costing ~200 ms on the wire.

## Scheduling Path Map

`src/server/main.zig` (accept loop):

- Line 776: `pool = ThreadPool.init(gpa, .{ .num_threads = 0 /* auto */, .stack_size = 2 MiB })` → wrapper computes `num_threads = min(cpus, 16) = 16`.
- Line 815: `poll_pool = ThreadPool.init(gpa, .{ .num_threads = 1, .queue_capacity = 4 })` → wrapper bumps to 2 threads (blocking-lane minimum). Runs only the UDP `pollLoop` — not contended.
- Line 858: `transport.accept()` — CV-based 50 ms wait on the endpoint accept_cv.
- Line 900: `pool.submit(work_item)` — submits a single `handleConnectionAsync(ctx)` task per new QUIC connection. **This task owns the entire connection lifetime** (handshake wait up to 500 ms, `acceptStream()`, plus the protobuf read/handle loop until the CLI disconnects).

`src/transport/thread_pool.zig`:

- Line 179–190: every `ThreadPool.init(...)` call sets `.allow_blocking_lane = true` and **`.blocking_workers = 1`** regardless of `num_threads`.
- Line 210–213: **`submit(item)` hardcodes `.lane = .blocking`.**
- Line 216–221: `submitBlocking(item)` also uses `.lane = .blocking`.
- Line 262–267: `effectiveThreadCount` returns `max(min(cpus, 16), 2)` when `num_threads == 0`.

Upstream `thread_pool` dep (`/home/benji/src/devnw/zig/thread-pool/src/pool.zig:1381–1400`, `types.zig:274–287`): `.lane = .blocking` submissions go directly to the **dedicated blocking inject queue**, which is drained only by the `blocking_workers` threads. Default-lane workers never touch it (`cpu_helps_blocking` defaults to `false`, and Geode never sets it). So with `blocking_workers = 1` the effective connection-service parallelism is **exactly 1**, regardless of how many threads the pool actually spawned.

Per-connection inner pools (`src/server/quic_connection_handler.zig`):

- Line 1260: `stream_pool` — per-connection, 4 threads (wrapper forces 1 blocking). For additional multiplexed streams on *this* connection only.
- Line 1273: `acceptor_pool` — per-connection, 1 thread (wrapper forces 2 total + 1 blocking) for the stream acceptor loop.
- Neither is shared across connections, so they don't cross-contend. They contribute to the ~141 total threads observed but are idle w.r.t. cross-connection admission.

## Root Cause

**(a) Worker starvation with extra twist: the main connection pool has 16 worker threads but only 1 is eligible to run connection handlers.** Every `pool.submit(...)` in `src/server/main.zig:900` is routed to `.lane = .blocking` by the Geode wrapper (`src/transport/thread_pool.zig:211`), which upstream sends exclusively to the blocking inject queue served by `blocking_workers = 1` (line 189). The other 15 threads serve the default lane, and Geode never dispatches default-lane work — they idle forever.

Consequently:

1. New QUIC connection accepted → `handleConnectionAsync` enqueued on the single blocking-lane worker.
2. That worker runs the full connection lifetime: handshake poll wait (up to 500 ms) + `acceptStream()` + query loop + teardown. For a one-shot `CREATE` CLI that is typically 150–250 ms, but it serializes end-to-end.
3. Under 8 back-to-back writer CLIs the single blocking worker has a steady queue depth of 6–8 pending connection tasks. A freshly-arriving measurement CLI lands behind them and waits N × mean_lifetime.
4. At 6–8 writers the admission latency crosses the client's 5 s deadline; 10/10 deterministic timeouts.

This fits the fixer's original hypothesis precisely. It is **not** a queue-bloat FIFO issue (the inject queue has plenty of capacity), **not** a fsync/IO issue (trivial `RETURN 1` times out identically), and **not** a graph_store/catalog mutex issue (same reason). The f92af840 `allow_blocking_lane = true, blocking_workers = 1` wiring fixed cert-gen deadlock by guaranteeing at least one lane worker, but it inadvertently shrank effective admission parallelism from "whatever the default pool was" down to 1.

## Type Classification

- **Primary:** `(a) Worker starvation.` Precisely: worker *mis-lane-routing* — all work serialized through a single lane by the submit-site hardcoding `.lane = .blocking`, combined with the lane having only 1 dedicated worker.
- **Architectural gap:** there is no separate "control-plane" (handshake/auth/session-open) pool. Connection acceptance, handshake wait, and the long-lived query loop all occupy one slot.

## Affected Files (fix-site blast radius)

| Layer | File | Lines | Why in scope |
|------|------|------:|-------------|
| Pool wrapper | `src/transport/thread_pool.zig` | 179–190, 210–221, 262–267 | Hardcoded `.lane = .blocking` on `submit`/`submitBlocking`; hardcoded `blocking_workers = 1`; auto thread count tuning |
| Accept loop | `src/server/main.zig` | 776–913 | Decision of whether to submit the whole connection to one pool, or split admission vs long-lived loop across two pools/lanes |
| Per-connection sub-pools | `src/server/quic_connection_handler.zig` | 1260, 1273 | Each also uses the same wrapper; not in the cross-connection hot path but benefits from the same correction |

No changes required in the upstream `thread_pool` dependency. All the primitives we need (`cpu_helps_blocking`, `blocking_workers > 1`, or sending to `.default` lane) are already in the 0.2.0 API.

## Fix-Site Prediction (narrowest viable change)

Ranked cheapest-first. All contained to `src/transport/` + `src/server/`; no upstream dependency bump.

1. **Split the submit API by lane (recommended).** Change `src/transport/thread_pool.zig`:
   - Keep `submit()` / `submitBlocking()` routing to `.lane = .blocking` for long-lived, I/O-bound work (current behavior — what `handleConnectionAsync` really needs once it starts its read loop).
   - Add `submitAdmission(item)` (or similar) that routes to `.lane = .default`, so callers can dispatch new-connection work across the 15 default-lane workers.
   - In `src/server/main.zig:900`, switch the `handleConnectionAsync` dispatch to the new default-lane submit. This immediately restores 15-way parallelism for connection admission and the in-connection query loop. Long runtime cost is absorbed by the bigger default lane; the blocking lane stays reserved for future truly-blocking tasks (cert gen, periodic snapshots).
   - Optional variant: enable `cpu_helps_blocking = true` in the main pool config so default-lane workers can steal from the blocking inject queue when idle. That is a one-line change and preserves the existing lane semantics elsewhere, but is less precise — it also exposes long blocking tasks to CPU workers, which is exactly what the flag's doc warns against.

2. **Raise `blocking_workers` for the main pool only.** Pass a config knob through `ThreadPoolConfig` so the main pool is initialized with e.g. `blocking_workers = max_threads - 1`, leaving one default worker as required. This is the minimum-code-change fix but it abandons the lane-isolation design: every task becomes a blocking task, exactly like pre-lane pools. Acceptable as a stop-gap.

3. **Move the long-running read loop off the admission worker.** Split `handleConnectionAsync` into two phases: (a) handshake + auth + session-open (short, blocking-lane OK) and (b) the per-stream read/execute loop (submitted to a dedicated per-connection or shared default-lane pool). This is the most principled fix — control-plane gets its own reserved lane and cannot be starved by long-lived streams — but it is the most invasive (non-trivial lifetime management around `ConnectionContext`).

I would pick **Option 1** for the fixer: tightest diff, preserves the blocking-lane invariant, and directly proves out in the reproducer with `BACKGROUND_LOAD=1`.

## Dependencies Between Failures

Single root cause; no fix-order dependencies. The count-pushdown fix in `5937c201` (issue #750) is unrelated and already in the release — the repro's matching latency under no load (872 ms) confirms the pushdown is working.

## Security / Data Integrity Concerns

- **Denial-of-service surface.** Any client that opens several short-lived connections in a loop against a single-tenant server can push new-connection admission past arbitrary deadlines. With `blocking_workers = 1`, 6 concurrent hammerers are enough to push admission past 5 s on a 56-core box. On a smaller server the threshold is lower. This does not corrupt data but **does** let an unauthenticated client starve legitimate logins once TLS is terminated, and a trusted CLI-heavy workload (the harness) will regress.
- **Auth rate limiter still protects credential guessing** (brute-force per-IP, `auth_rate_limiter.zig`), so this isn't a bypass — just a latency amplification against accepted clients.
- No data-integrity risk observed. WAL/graph_store are untouched.

## Recommended Fix Order for the Test-Planner + Fixer

1. **Write the regression test first.** `tests/test_count_nodes_no_flake.sh` already reproduces cleanly with `BACKGROUND_LOAD=1`. Promote it (or a twin) into `make verify-fast` so CI catches any regression. A deterministic shell-level check: under 8 writers, a trivial `RETURN 1 AS x` query must complete in < 2 s (not 6+ s). Keep the existing count-pushdown assertion — it still guards #750.
2. **Implement Option 1** in `src/transport/thread_pool.zig` (new `submitAdmission` / `submitDefault` entry point) and switch the one call site in `src/server/main.zig:900`. No changes needed in `quic_connection_handler.zig` sub-pools.
3. **Re-run the full 10-run repro** under `BACKGROUND_LOAD=1`; expect each run under 1.5 s.
4. **Re-run `make test`** (1036 Zig tests) and the harness `test-everything` — the lane change must not regress the cert-gen fix that landed in `f92af840`.
5. **Update `docs/audit/bugfix-session-contention-triage.md`** → add a companion `bugfix-session-contention-report.md` with post-fix measurements (baseline, 1/2/4/6/8 writer scaling, and final p99).

## Appendix: Measured Artifacts

- Full repro log: `/tmp/repro751.out` (10/10 SLOW/RC=1 at ~5073 ms).
- strace summary (server, 3 s under load): 152 TIDs, 243k futex waits, **186 sendto, 170 poll, 0 recvmsg** — server is not processing packets because the admission worker is busy. Longest futex wait 522 ms; bulk of futex waits in 1–5 ms bucket (condvar ticks).
- Active ports: one UDP listener on the ephemeral port; no TCP component. Connection count scales with writer count, not with thread count, confirming admission is the bottleneck.
