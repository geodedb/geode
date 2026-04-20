# Step 3 profile — two_hop under c=1 (post-fast-path)

## Setup

- Binary: HEAD `a0a5b8c0` (GAP-0808 fast path enabled, guard reverted).
- Workload: `geode-loadtest -scenario two_hop -levels 1 -duration 60s`.
  - Scenario setup: 2,000 LT_Person nodes + 8,000 LT_KNOWS edges.
  - Observed QPS during profile: ~0.5 c=1, p99 2.4 s.
- Tool: `sudo perf record -F 999 -g --call-graph dwarf -p <geode-pid>
  -- sleep 40` (started ~150 s into the loadtest so setup was complete).
- 767k samples; perf reported 19 % of samples lost (buffer pressure —
  dwarf callchain dumps are expensive). Raw `.perf.data` was 6.5 GB and
  has been deleted; text reports kept.

## What the profile shows

The flat self-time list is dominated by the same parked-worker signal
as M1.1 / M2.1:

| pct    | symbol                                           |
|-------:|:-------------------------------------------------|
| 11.44% | `native_flush_tlb_one_user` (kernel)             |
|  6.20% | `smp_call_function_many_cond` (kernel)           |
|  2.88% | `Io.Threaded.nanosecondsFromPosix` (geode)       |
|  2.68% | `entry_SYSRETQ_unsafe_stack` (kernel)            |
|  2.19% | `sync.Condition.waitInner` (geode)               |
|  1.80% | `pool.Core.nextTask` (geode)                     |
|  1.30% | `debug.Dwarf.SelfUnwinder.nextInner` (geode)     |
|  1.22% | `Io.Threaded.nowPosix` (geode)                   |
|  1.20% | `pool.Core.idle` (geode)                         |
| ...    |                                                  |

And inclusive (children) attribution:

- **74.59 %** of all samples in `pool.Core.workerMain`
  (the thread-pool worker function itself, containing the condvar wait).
- **68.74 %** specifically in `pool.Core.idle` (parked).
- **49.57 %** in `Io.futexWaitTimeout` under `Condition.timedWait`.
- **42.54 %** in `os.linux.futex_4arg` (the actual syscall).

Taken at face value this says two_hop spends 74 % of the time with
workers parked. But we have 16 + 4 + 1 = ~21 parked worker threads on
the server at any given moment, vs. one thread serving the c=1 query.
The perf sampler gives each on-CPU instruction a sample. Since
condvar-waiting threads *do* take samples (they show up on their
CPUs each time a tick fires), **the wait-symbols dominate the flat
profile regardless of where the serving thread actually spends its
time.**

This is the same sample-distribution bias that M1.1's profile showed,
and why point_read's c=1 profile looked dispatch-bound even though the
actual fix (collectStartSlots → merge_prop_index) was a non-dispatch
optimization. The real per-query time distribution for two_hop would
require filtering samples to the single thread actually servicing
the QUIC stream, via `perf record --tid=<serving-thread>` captured
after identifying that thread by PID/TID.

## App-code hotspots (below the worker-parked noise)

Filtering for geode user-space symbols that are *not* infrastructure
(pool / sync / Io.Threaded / time / allocator / compiler_rt):

| pct   | symbol                                                  |
|------:|:--------------------------------------------------------|
| 0.73% | `Io.Clock.now`                                          |
| 0.64% | `queue.ring_queue.RingQueue(u64).pop`                   |
| 0.61% | `Io.Mutex.lockUncancelable`                             |
| 0.53% | `Io.Timeout.toDurationFromNow`                          |
| 0.31% | `hash.wyhash.Wyhash.hash`                               |
| 0.30% | `builtin.returnError` ← **error return path**           |
| 0.29% | `endpoint.Endpoint.pollWithStats`                       |
| 0.14% | `rls_value_bridge.nodePropertiesToRLSRow`               |
| 0.12% | `Io.RwLock.lockSharedUncancelable`                      |
| 0.12% | `execution.match_operations.executeMultiNodeMatch`      |

`builtin.returnError` at 0.30 % is notable — that's the Zig runtime's
error-generation path. It implies queries are *generating* errors
which are then caught somewhere. Combined with the
`debug.Dwarf.SelfUnwinder.nextInner` at 1.30 %, there's a meaningful
amount of error-path + stack-unwind overhead. Finding the site of the
`try` that's throwing repeatedly could be a win, but without a
per-thread profile we cannot tell whether this is on the serving
thread or in a background worker.

## Honest conclusion

`two_hop` at ~0.5 QPS c=1 is not diagnosable from the current
whole-process perf sample because the 20+ parked worker threads
dominate the sample count. The `Dwarf.SelfUnwinder` + `returnError`
pair is a *lead*, not a cause.

The right next step is per-thread profiling:

1. Find the serving thread's TID via `pstack` / `/proc/<pid>/task` /
   `perf top --sort pid,tid` during a live two_hop loadtest.
2. Run `sudo perf record --tid=<serving-tid> -F 999 -g
   --call-graph dwarf -- sleep 30` so only that thread's samples
   land in the output.
3. Then — and only then — can we identify the per-query bottleneck.

Alternatively, add dbg-gated microsecond timers around `exploreHops`,
`materializeEdge`, `collectHopEdges`, and `adapter.getAllNode
Properties` to directly time each phase.

Either approach is out of scope for this iteration — the GAP-0808
fast path shipped in MR !17 already delivers 19-133× QPS wins on the
two scenarios where the single-anchor optimization applies
(point_read, one_hop). two_hop / fan_out need their own follow-up
plan focused on the multi-hop traversal path.

## Artifacts

- `step-3-two-hop-c1-profile-flat.txt` — filtered flat top geode
  symbols (~30 rows, ≥ 0.05 % self).
- `step-3-two-hop-c1-profile-callchains.txt` — inclusive callchain
  ≥ 1 % children, showing the worker-parked dominance.
- Raw `.perf.data` (6.5 GB) deleted. Regenerate with the commands in
  Setup if deep re-analysis is needed.
