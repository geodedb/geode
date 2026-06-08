# Bug: an IDLE geode node burns ~810% CPU (QUIC poll-loop + thread-pool idle-park storms)

**Status:** **CORE FIXED — 2026-06-08.** Four independent idle spinners are fixed
geode-side on `main` (≈810% → ≈23% measured by the regression test on a busy
load‑9 build box; a ~35× reduction). One smaller, load‑sensitive residual remains
in a vendored lib (graph_storage's per‑graph owned pool) and is tracked as a
downstream follow‑up (§4). A second downstream improvement (the QUIC library's
256 KB‑per‑poll buffer fill, which taxes *active* polling) is also filed.

Observed on the deployed system service (`/usr/bin/geode`, **v0.6.13**) sitting
**completely idle (0 client connections)**: ~810% CPU (≈8 cores), ~796 threads,
~16 threads at ~40–46% CPU each. Reproduced on current `main` (ReleaseSafe).

---

## 1. Symptom

A geode server with **zero** client connections pins ~8 cores. Per‑thread CPU
attribution shows ~16 worker threads at ~40–56% each plus a long tail of cheaper
threads. No queries run; no connections are open.

## 2. Root cause — FOUR independent idle spinners

Profiled 2026‑06‑08 on a clean ReleaseSafe build: per‑thread `/proc/<tid>/stat`
CPU deltas + `gdb -batch "thread apply all bt"` + per‑TID `strace`. Syscall mix
was **~95% futex** (`poll`/`recvmmsg` negligible — NOT the UDP path). The 801
threads decomposed into: 16 QUIC poll workers, 512 FirstStreamScheduler workers,
~268 thread‑pool workers, 8 ext‑default‑park pool workers (timeseries + graph_storage),
and a few singleton loops.

### 2a. QUIC poll workers spin at 500µs regardless of connection count (~810%)

`QuicTransport.pollLoop` (`src/transport/quic.zig`) runs one task per poll worker
(**16 in ReleaseSafe**, 1 in Debug). Each iteration did `pollOnce(0)` then, on an
empty cycle, slept a **fixed 500µs** — even with 0 connections. And `pollOnce(0)`
is *not* cheap under ReleaseSafe (prod's build): `endpoint.pollWithStats`
stack‑declares a `UdpBatchCap(64) × 4096 = 256 KB` recv buffer `= undefined`,
which the safety machinery `0xAA`‑fills **every call**. 16 workers × ~2000/s ×
(256 KB fill + endpoint walk) ≈ the ~810%. Per‑thread profiling confirmed exactly
**16 threads ≥50% CPU, all in `pollLoop`**.

### 2b. ~800 thread‑pool wrapper workers park at 10ms (~260% residual)

After 2a, the dominant residual was `pool.Core.idle → timedWait` across ~785
wrapper‑pool workers parked on a **10ms** timeout
(`ThreadPoolConfig.idle_park_after_ns`, set to 10ms by GAP‑0807, which assumed
~16 workers). At ~800 workers that is ~80k futex round‑trips/s ≈ ~260% CPU.

### 2c. 512 FirstStreamScheduler workers sweep every 10ms with 0 contexts

`FirstStreamScheduler` is a fixed **512‑worker** cooperative pool
(`src/server/quic_connection_handler.zig`). Each worker's `takeReady` blocks on a
**10ms** `futexWaitTimeout` whose only purpose is the missed‑wake idle sweep —
but `shouldSweepIdleContextsLocked` is a no‑op when there are 0 contexts. So at
idle, 512 workers wake every 10ms for nothing (~51k futex/s).

### 2d. The geode timeseries pool uses the upstream 250µs ext default

`src/timeseries/timeseries.zig` creates a 4‑worker pool via the **ext** thread_pool
directly (the engine's `init` signature requires `*thread_pool.ThreadPool`), so it
does NOT inherit geode's wrapper default and used the upstream **250µs** idle park
— 4 workers each waking ~4000/s. The Store is created unconditionally at startup
(`src/server/main.zig`), even on a server that never touches timeseries.

## 3. Fix (geode‑side, this repo, on `main`)

1. **`src/transport/quic.zig`** — lock‑free `active_connection_count` atomic
   (mirrors `connections.items.len`, maintained under `connections_mutex` at every
   add/remove site). `pollLoop` parks `idle_poll_empty_park_ns` (**250ms**) on an
   empty cycle when `active_connection_count == 0`; keeps the 500µs floor when ≥1
   connection is live. New‑connection latency is unaffected — the accept loop (its
   own ~50ms cadence) drains the first handshake packet and bumps the count, after
   which poll workers resume 500µs within ≤250ms.
2. **`src/transport/thread_pool.zig`** — wrapper `idle_park_after_ns` 10ms →
   **500ms**. Workers wake on task‑submit signal (`notifySubmits`) with zero added
   dispatch latency; `deinit` broadcasts the condvar; geode uses the `global_queue`
   variant (no idle‑re‑poll dependency). 800 × 2/s ≈ negligible.
3. **`src/server/quic_connection_handler.zig`** — `takeReady` parks
   `first_stream_scheduler_idle_park_ns` (**1s**) when `contexts.items.len == 0`
   (nothing to sweep); keeps the 10ms sweep when contexts exist. `enqueueReady`
   bumps `ready_generation` + futexWakes, so new work wakes a worker immediately.
4. **`src/timeseries/timeseries.zig`** — set the ext pool's `idle_park_after_ns`
   to **500ms** (kept the ext type the engine API requires).

Validated: regression test green (§5); all three active‑path queries
(`RETURN 1`, `CREATE`, `MATCH count`) succeed against the fixed binary.

## 4. Downstream follow‑ups (filed separately)

- **graph_storage owned pool (idle residual).** `graph_storage`'s per‑graph
  sharded engine creates a `default_owned_pool_max_threads` (=4) **work‑stealing**
  pool with no `idle_park_after_ns` → the ext **250µs** default, instantiated per
  graph at startup. This is the remaining idle floor (~5% quiet, more under load).
  Root fix options (downstream): set `idle_park_after_ns` on graph_storage's owned
  pool, or raise the ext `thread_pool` default (250µs) so every direct‑ext consumer
  benefits. geode cannot fix this without either a pin bump or injecting
  `GraphConfig.external_thread_pool` (an architectural threading change, out of
  scope for a CPU fix).
- **QUIC 256 KB per‑poll fill (active path).** `endpoint.pollWithStats` should not
  `= undefined` a 256 KB recv batch on the stack every call (ReleaseSafe
  `0xAA`‑fills it). Reusing a per‑endpoint buffer removes a 256 KB memset from the
  **hot poll path** — benefits high‑QPS polling, not just idle.

## 5. Verification

- **Regression test:** `tests/test_quic_idle_cpu.zig` (`zig build test-quic-idle-cpu`)
  boots an idle server and asserts CPU over a 5s window < **50%** (a threshold that
  catches any return of the four >100% spinners while tolerating the graph_storage
  residual + CI load noise). RED before the fix (**670%** on the ReleaseSafe
  binary). GREEN after: **idle server CPU: 22.8%** on a load‑9 build box.
- **Active path:** `RETURN 1`→`{x:1}`, `CREATE (:Person{name:'alice'})`→`{name:'alice'}`,
  `MATCH (n:Person) RETURN count(n)`→`{c:1}` all succeed.

## 6. Before/after (ReleaseSafe, idle, 0 connections)

| stage | idle CPU | threads ≥50% | dominant frame |
|---|---|---|---|
| before (v0.6.13 / main) | 261–810% | 16 | `pollLoop` |
| + poll fix (3.1) | ~224% | 8 | `pool.Core.idle` (scheduler+pools @10ms) |
| + pool/scheduler fixes (3.2, 3.3) | ~48–67% | 8 | `pool.Core.idle` (timeseries+graph_storage @250µs) |
| + timeseries fix (3.4) | **~23–37%** | 4 | `pool.Core.idle` (graph_storage @250µs — §4) |

## 7. Operational note

The deployed `/usr/bin/geode` is **v0.6.13** (stale) and is the user's systemd
service — triaged read‑only, NOT restarted. Recommend upgrading it to the release
carrying this fix to recover the ~8 idle cores.
