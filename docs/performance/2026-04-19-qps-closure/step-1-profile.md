# Step 1 profile — point_read under c=1

## Setup

- Binary: `zig-out/bin/geode` at commit `62536b9e` (HEAD of
  `perf/qps-closure-2026-04-19` post-M1.4), `-Doptimize=ReleaseFast`.
- Workload: Go loadtest `-scenario point_read -levels 1 -duration 45s`
  against a fresh data dir (500 `LT_Person` nodes, 5s setup included).
- Observed c=1 QPS during profile: **11.7** (lower than M1.4's 17.6 —
  `perf record` with dwarf callchains adds measurable overhead).
- Tool: `sudo perf record -F 999 -g --call-graph dwarf -p <pid> -- sleep 30`.
- Capture: 417 k samples, 319 G event counts. Raw `.perf.data` not
  committed (3.6 GB, above the 1 MiB hook limit). Extracted text
  reports archived as `step-1-profile-flat.txt` (flat, > 0.1 %
  self-time) and `step-1-profile-callchains.txt` (inclusive,
  > 1 % children).

## Flat top-20 self-time (see `step-1-profile-flat.txt` for full list)

| pct    | symbol                                           | where        |
|-------:|:-------------------------------------------------|:-------------|
| 16.97% | `native_flush_tlb_one_user`                      | kernel       |
|  9.47% | `smp_call_function_many_cond`                    | kernel       |
|  3.54% | `entry_SYSRETQ_unsafe_stack`                     | kernel       |
|  1.89% | `sched_balance_update_blocked_averages`          | kernel       |
|  1.68% | `sync.Condition.waitInner`                       | geode (Zig)  |
|  1.65% | `syscall_return_via_sysret`                      | kernel       |
|  1.60% | `pool.Core.nextTask`                             | geode        |
|  1.58% | `Io.Threaded.Thread.futexWaitInner`              | geode        |
|  1.53% | `psi_group_change`                               | kernel       |
|  1.52% | `dequeue_entity`                                 | kernel       |
|  1.51% | `entry_SYSCALL_64`                               | kernel       |
|  1.46% | `__update_load_avg_cfs_rq`                       | kernel       |
|  1.44% | `update_curr`                                    | kernel       |
|  1.42% | `__vdso_clock_gettime`                           | vdso         |
|  1.39% | `perf_iterate_ctx`                               | kernel       |
|  1.23% | `update_load_avg`                                | kernel       |
|  1.18% | `__update_load_avg_se`                           | kernel       |
|  1.08% | `pool.Core.idle`                                 | geode        |
|  1.06% | `clock_gettime`                                  | libc         |
|  1.03% | `__calc_delta.constprop.0`                       | kernel       |

## Inclusive stack dominance

From `--children --percent-limit 1.0`:

- **72.98 % of samples** land inside `entry_SYSCALL_64_after_hwframe` →
  **43.98 %** in `__x64_sys_futex` → **41.94 %** in `do_futex` →
  **40.39 %** in `__futex_wait` → **37.24 %** in `futex_wait_queue` →
  **34.20 %** in `schedule` → **33.98 %** in `__schedule`.
- Within `__schedule`: **12.69 %** `dequeue_task_fair`, **8.13 %**
  `finish_task_switch.isra.0` (which itself cascades into **4.84 %**
  `asm_sysvec_call_function` → **4.56 %**
  `__flush_smp_call_function_queue` → **4.47 %** `flush_tlb_func`).

Translated to wall-clock: about **1/3 of a point-read's p99** (c=1 was
~90 ms in M1.4's `after` phase) is thread-pool worker wake-up latency
— futex park, schedule, cross-CPU IPI, TLB shootdown, task switch.

## App-code hotspots

Below are the top geode-binary symbols that are *not* thread-pool /
scheduler / clock infrastructure:

| pct   | symbol                                                   |
|------:|:---------------------------------------------------------|
| 0.43% | `memory.scratch.WorkerScratch.purge`                     |
| 0.27% | `DebugAllocator(.{ ... .page_size = 131072 }).alloc`     |
| 0.09% | same DebugAllocator's `.free`                            |
| 0.06% | `label_store.LabelStore.getLabels`                       |
| 0.06% | `buffer_pool.BufferPool.pin`                             |
| 0.05% | `graph_storage_adapter.StorageAdapter.getNodeLabels`     |
| 0.04% | `prop_store.PropStore.PropIterator.next`                 |
| 0.03% | `execution.planned_read_runtime.propsMatch`              |
| 0.02% | `execution.planned_read_runtime.freeStoragePropertyMap`  |
| 0.02% | `execution.planned_read_runtime.nodeMatchesPatternBySlot`|
| 0.02% | `execution.planned_read_runtime.executeProfiledIfSupported` |
| 0.02% | `node_store.NodeStore.getNode`                           |
| 0.01% | `graph_storage_adapter.StorageAdapter.getAllNodeProperties` |
| 0.01% | `hash_map.HashMap(...).put`                              |
| 0.01% | `eval.evalExpr`                                          |

**Aggregate MATCH-path self-time: well under 1 %.** `materializeNode`
itself does not appear at the ≥ 0.1 % threshold — the Task 1.5 arena
fix is consistent with the cost being dominated by its callees, not
the function itself.

## Interpretation

### The clone WAS a cost but it wasn't the biggest cost

M1.4 already proved this quantitatively: PointReadView (which removes
the `QueryReadSession.initIfAvailable` deep-clone) gave +10.3 % QPS
and -16.5 % p99 at c=4. That's consistent with the clone being on the
order of 5–10 ms per query. What remains (~90 ms p99 at c=1) is
something else.

The profile says that "something else" is **thread-pool dispatch
overhead**, not MATCH work:

1. Every incoming query is handed off from the QUIC connection thread
   to a worker in `pool.Core` via a condvar.
2. Workers sit on `Condition.waitInner` → `Io.Threaded.futexWait` and
   wake on `futex_wake` from the submitter.
3. Each wake triggers a cross-CPU migration → TLB shootdown
   (`__flush_smp_call_function_queue` → `flush_tlb_func` →
   `native_flush_tlb_one_user`).
4. The scheduler bookkeeping (`dequeue_entity`, `update_curr`,
   `update_load_avg`) runs on every wake.

At c=1 there is literally one in-flight query. The round trip
(submit → wake worker → run → signal back → return to client) spends
more time in kernel coordination than in MATCH code. Raising c
amortizes this over multiple concurrent queries — exactly what M1.4's
p99 improvements at c=2 (-48 %) and c=4 (-16 %) show.

### Why M1.4 QPS didn't hit the plan's 100 QPS target

The plan extrapolated "clone is 10–30 ms, remove it and we get 3×+
QPS". The actual clone cost (~10 ms) turned out to be only a fraction
of the ~60–90 ms per-query budget. The majority of the budget is
scheduler overhead that PointReadView cannot address by itself.

## Design implications

### Option A (recommended follow-up): bypass the worker pool for point reads

The QUIC handler already holds the shared read lock for the
`is_point_read` branch (per M1.3). Extend the PointReadView path to
**execute inline on the connection thread** instead of dispatching to
the worker pool. That eliminates the futex wake, cross-CPU IPI, TLB
flush, and context switch on every point read — roughly 30–40 ms of
the p99 at c=1.

Risk: connection thread isolation. If one slow query blocks a
connection handler, other clients on the same connection wait. For
point reads (< 10 ms of real work) this is a fine trade-off; the
detection rule from M1.3 (`analysis.is_point_read`) is already
conservative enough to gate.

### Option B (broader): reduce worker wake-up cost

- Cache `clock_gettime` values per tick inside the worker loop —
  combined 2.48 % of samples sits in `__vdso_clock_gettime` +
  `clock_gettime` + `pool.nowNs`.
- Replace condvar-per-queue with an LMAX-style MPSC ring + thread-
  parked spin for submit-time (lower wake-up latency but higher
  idle CPU).

Both are larger changes than Option A.

### Investigate: DebugAllocator appears in ReleaseFast

`heap.debug_allocator.DebugAllocator(.{ ... .page_size = 131072 })`
accounts for ~0.36 % combined (alloc + free). In a ReleaseFast
build this allocator should not be active — GAP-0754 swapped the
`global_gpa` to `smp_allocator`. Some path still uses a DebugAllocator
instance. Low priority but worth a separate audit — if it's on the
hot path, removing it is free perf.

### For M2 scenarios (one_hop / two_hop / fan_out)

At c=1, `one_hop` p99 was already **746 ms** in the M0.10 baseline.
That's an order of magnitude larger than `point_read` (~90 ms). The
scheduler overhead is roughly a constant per-query cost, so its
fraction shrinks as per-query work grows. M2 profiles will look very
different: expect MATCH path symbols (`materializeNode`, edge lookup,
path traversal) to dominate instead of scheduler bookkeeping.

Do not extrapolate from this M1 profile to M2. Capture a fresh
one_hop flamegraph before cutting M2 fixes.

## Artifacts

- `step-1-profile-flat.txt` — flat self-time, ≥ 0.1 % rows (40 lines).
- `step-1-profile-callchains.txt` — inclusive-time callchains, ≥ 1.0 %
  (200 lines).
- Raw `step-1-profile.perf.data` deleted (was 3.6 GB; regenerate with
  the command in the Setup section above if deep inspection is
  needed).
