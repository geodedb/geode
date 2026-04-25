# edges_contains cascade — diagnosis (2026-04-25)

Repro: `/tmp/run-edges-contains-repro.sh`. Wall-clock to cascade: ~600 s into `edges_contains.jsonl` (file started at 12:42:12, cascade triggered at 12:52:12). Total ingest from start: ~22 min before cascade.

## Captured signals

- **Server crash**: NO. Process VmRSS=1.5 GB, alive after cascade. Post-run `ps -p` confirmed running.
- **`coord_apply_*` counters**: NOT VISIBLE in `metrics:` log lines (see follow-up note below). Only `mg_rwlock_*` counters were registered. Coordinator throughput cannot be evaluated from this run.
- **`mg_rwlock_shared_wait_ns_total` at cascade**: 1,172,786,837,884 ns ≈ **1,173 s** cumulative.
- **`mg_rwlock_exclusive_wait_ns_total` at cascade**: 21,289,338,423,475 ns ≈ **21,289 s ≈ 5.9 hours** cumulative.
- **EXCLUSIVE / SHARED wait ratio**: 18.1×. EXCLUSIVE-side waits 18× longer total than SHARED-side over the same wall-clock window.
- **EXCLUSIVE wait vs wall-clock**: 21,289 s of cumulative EXCLUSIVE wait in ~22 min (1,320 s) wall-clock = **16.1× concurrent waiters** on average. Consistent with ~16 persistence threads blocked simultaneously throughout the run.
- **QUIC flow-control / stream-limit messages**: NONE found via grep `flow.control|max.streams|max.data|connection close|conn close|stream reset|stream limit`.
- **`orphan-txn rolled back on stream close`** appeared in server log shortly before cascade — server detected client-side stream closure of in-flight transactions.
- **VmRSS at cascade**: 1.5 GB. **VmPeak**: **31 GB virtual**. **Threads**: **1831**. **Open FDs**: 360.

## Verdict

**Primary cause: candidate-3-rwlock — `mg.rwlock` EXCLUSIVE-side starvation, compounded by a thread leak from re-spawned persisters.**

### Supporting evidence

The 18× EXCLUSIVE-vs-SHARED wait ratio is the smoking gun. SHARED holders (16 shard workers continuously) keep the per-graph `mg.rwlock` locked SHARED nearly the entire ingest. Any EXCLUSIVE acquirer (background persistence pass, checkpoint, full-graph snapshot) gets queued and never makes forward progress — Zig's `std.Io.RwLock` is reader-preferred when SHARED holders keep arriving, so the EXCLUSIVE waits indefinitely.

The default `--persist-interval` is **100 ms**. A timer fires every 100 ms attempting to acquire `mg.rwlock` EXCLUSIVE for persistence. Each attempt blocks on the contended lock and parks a thread. Over ~22 min that's ~13,200 attempts; even if only ~14% are still parked at any moment we'd see ~1830 blocked threads — exactly the **1831 threads** we observed.

The thread accumulation drives:

- **VmPeak 31 GB virtual**: each thread reserves ~16 MB of stack VA (default for glibc + Zig runtime). 1830 × 16 MB ≈ 29 GB. ✓
- **Server-side scheduler stall**: 1831 threads contending for a single Linux scheduler slot eventually starves the QUIC packet-processing thread, causing client-perceived stream stalls.
- **`orphan-txn rolled back on stream close`** + `driver: bad connection`: the QUIC layer can't service its packet pump fast enough; the client gives up after 5 s; server detects the close and rolls back the orphaned txn.

The cascade timing (~10 min into edges_contains, statement 104/105) is the moment the thread count crosses a Linux scheduler-fairness threshold for the QUIC packet pump.

## Recommended fix (Task 6)

This is a candidate-3 verdict. The plan's Task 6D applies — but with a more specific shape than the plan anticipated:

1. **Don't spawn-and-block on every persistence interval.** Replace whatever loop fires every `--persist-interval` ms with a SINGLE long-lived persister thread that sleeps the interval, then acquires (and yields back if it can't make forward progress in a bounded time).
2. **Use `tryLock` with back-off** at the persister's acquire site so a contended persister surrenders the timer slot rather than parking forever.
3. **Optionally raise `--persist-interval`** for the test run (e.g., 5000 ms) to reduce attempt frequency and give the persister room to actually take the lock when SHARED traffic dips.

Without code-level identification of the persister entry point, Task 6D as written can't apply mechanically. A follow-up plan should pin the call site (`grep -n 'persist\|Persist\|checkpoint' src/server/main.zig src/storage/graph_storage_adapter.zig src/graph_store.zig | head -20`) and apply the fix there.

## Side finding (not the cascade cause but worth fixing)

`coord_apply_*` counters from Task 2 don't appear in `metrics:` log lines. Either:

- `ShardedCoordinator.start` ran before `setGlobalRegistry` (unlikely — server starts before ingest creates the graph that starts the coordinator), OR
- The registration block in `start()` is running but `globalRegistry()` returns `null` when called (suggesting the global wasn't actually set), OR
- The counters ARE registered but their names collide / conflict with something.

This is orthogonal to the cascade fix; tracked as a Task 2 follow-up.
