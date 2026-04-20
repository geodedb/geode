# Step 4 profile — two_hop (post fast-path correctness fix)

Captured 2026-04-20 on `perf/qps-closure-2026-04-19` at commit
`a4478e94` (GAP-0808 fast path switched from the store's
unpersisted `merge_prop_index` to the adapter's persisted
`exact_node_property_index` — see commit message for the bug).

## Setup

- Loadtest: `geode-loadtest -scenario two_hop -skip-setup
  -skip-teardown -levels 1 -duration 45s` (using the new P1 flags
  against data seeded by an earlier `-setup-only` pass of two_hop:
  2,000 LT_Person + ~1,000 LT_KNOWS edges).
- Observed during profile: QPS 0.8 c=1, p50 1.22 s, p99 1.40 s.
  That is a **~5× improvement over the pre-fix 4.2-5.0 s-per-query**
  measurements — the store-side `merge_prop_index.not_found` was
  forcing the fallback path into some expensive branch. Once the
  adapter index returns a real candidate, the query completes
  correctly in ~1 s.
- `sudo perf record -F 999 -g --call-graph dwarf -p <geode-pid>
  -- sleep 30` captured 522 k samples / 4.2 GB.
- `top -H -p <pid>` during the loadtest showed ~10 threads
  uniformly at 9.1 % CPU each (≈ 1 CPU-core-equivalent of real work
  spread across the pool), not a single hot thread.

## Flat top self-time (≥ 0.1 %)

See `step-4-two-hop-fixed-flat.txt` for the full list.

| pct    | symbol                                                         |
|-------:|:---------------------------------------------------------------|
|  7.66% | `native_flush_tlb_one_user` (kernel)                           |
|  4.60% | `smp_call_function_many_cond` (kernel)                         |
|  2.77% | `Io.Threaded.nanosecondsFromPosix` (geode)                     |
|  2.62% | `entry_SYSRETQ_unsafe_stack` (kernel)                          |
|  2.43% | `debug.Dwarf.SelfUnwinder.nextInner` (geode)                   |
|  2.06% | `sync.Condition.waitInner` (geode)                             |
|  1.45% | `dequeue_entity` (kernel)                                      |
|  1.44% | `pool.Core.nextTask` (geode)                                   |
|  1.38% | `Io.Threaded.nowPosix` (geode)                                 |
|  1.28% | `__vdso_clock_gettime` (vdso)                                  |
|  1.20% | `pool.Core.idle` (geode)                                       |
|  1.11% | `Io.Threaded.Thread.futexWaitInner` (geode)                    |
|  1.02% | `debug.cpu_context.X86_64.dwarfRegisterBytes` (geode)          |

## Diagnosed noise sources (NOT the query hot path)

### DWARF unwinder — worker-loop errors, not query errors

The `returnError` inclusive callstack (`step-4-two-hop-fixed-
callchains.txt`) resolves to `pool.Core.workerMain → pool.Core.idle
→ sync.Condition.timedWait`. Idle workers return an error from the
condvar wait when they time out waiting for tasks, and the Zig
runtime captures a stack trace (`returnError` + `Dwarf.SelfUnwinder`

- `dwarfRegisterBytes`) on every such return.

Combined overhead: ≈ **3.8 %** of all samples. This is infrastructure
noise unrelated to query work — fixable by either:

1. Switching the worker idle wait to a variant that returns `bool`
   (timeout vs. woken) rather than an error union, so the stack-
   trace capture is avoided entirely; or
2. Tuning `idle_park_after_ns` up further (currently 10 ms, set by
   GAP-0807) to reduce the error-return rate linearly.

### Clock reads — 5.4 % of CPU on `clock_gettime`

`Io.Threaded.nanosecondsFromPosix` + `Io.Threaded.nowPosix` +
`__vdso_clock_gettime` + `clock.nanoTimestamp` = **≈ 5.4 %** of
samples. For a 1.2 s-wall-clock query that is ~65 ms spent reading
the clock. Candidates for reduction:

- Per-worker-tick time cache (read once per tick, reuse for N tasks).
- Switch log timestamps from wall-clock to a monotonic counter where
  full precision isn't needed.
- Reuse the query-start timestamp for derived `elapsed` checks inside
  the query instead of re-reading.

### Kernel TLB shootdown — 12 % of samples

`native_flush_tlb_one_user` + `smp_call_function_many_cond` are the
same cross-CPU IPI / TLB-flush signature from M1.1 (thread pool
waking idle workers). GAP-0807 already raised `idle_park_after_ns`
to 10 ms; further increases or switching to a spin-on-wakeup
primitive would reduce this further.

## App-level work (genuinely on the query path)

The remaining top hits below infrastructure:

| pct   | symbol                                                    |
|------:|:----------------------------------------------------------|
| 0.62% | `queue.ring_queue.RingQueue(u64).pop` (thread-pool queue) |
| 0.33% | `endpoint.Endpoint.pollWithStats` (QUIC poll loop)        |
| 0.33% | `hash.wyhash.Wyhash.hash` (hashmap probes)                |
| 0.25% | `Io.RwLock.lockSharedUncancelable` (per-query read lock)  |
| 0.10% | `execution.match_operations.executeMultiChainRelationshipMatch` |
| 0.06% | `hash_map.HashMapUnmanaged(...).Iterator.next` (prop map iter) |

Aggregate app-code signal < 2 %. The real work is
`executeMultiChainRelationshipMatch` and the materialization path
(`materializeNode` / `materializeEdge` / `materializePathRow`), but
each is under 0.2 % self-time — classic "flat distribution" of work
where no single symbol dominates.

## Interpretation

- **Correctness win is real and substantial.** 5× faster (5.0 → 1.0 s)
  just from fixing the index choice. That's pure correctness, not
  perf.
- **Infrastructure noise is ~10–15 % of CPU** (clock reads + DWARF
  unwinder + TLB shootdown). Fixable without touching query logic.
- **No single hot query site.** Multi-hop traversal work is
  genuinely distributed across materialize / adapter / hash ops,
  each < 0.2 %. To make a further dent, we need *algorithmic*
  changes (batch materialization, bulk edge-fetch API, arena-scope
  the path-row construction), not micro-optimizations.
- **Per-query wall clock (1.0 s) is still ~10× the CPU cost (100 ms
  on ~1 core).** The gap is probably QUIC round-trips and connection
  handler flush cadence — the `.poll()` call sites in
  `src/transport/quic.zig` use 5-10 ms timeouts; a 20-row two_hop
  response may require many server→client flushes, each waiting
  for the next poll tick.

## Follow-ups (ordered by expected QPS impact)

1. **Audit QUIC poll/flush cadence in the geode response path**
   (`src/transport/quic.zig` has 5-10 ms `api.poll()` calls across
   15+ sites). For response-heavy queries, each flush stalls for
   the next poll tick. Consider a dedicated response-flush poll
   invoked immediately after each row append, with a shorter
   timeout.
2. **Fix the idle-worker error-return hot spot** (GAP-0807
   follow-up): switch the condvar wait to a `bool` return so
   timeouts don't invoke the DWARF unwinder. Est. ~3–5 % CPU
   reclaimed across all scenarios.
3. **Bulk materialization API** for multi-hop path rows: instead
   of N per-hop `materializeNode` calls (each doing one
   `getNodeLabels` + one `getAllNodeProperties` adapter call),
   a single `materializePath(allocator, path_slots)` call that
   fetches labels+properties for all nodes/edges in one
   adapter round-trip. Expected: 2-5× on multi-hop latency.
4. **Per-worker clock cache**: read `clock_gettime` once per tick,
   reuse for tasks scheduled on that tick. Est. 5 % CPU reclaimed.

## Artifacts

- `step-4-two-hop-fixed-flat.txt` — flat self-time ≥ 0.1 %.
- `step-4-two-hop-fixed-callchains.txt` — inclusive children ≥ 1 %.
- Raw `.perf.data` (4.2 GB) deleted — regenerate with the commands
  in Setup if deep re-analysis is needed.
