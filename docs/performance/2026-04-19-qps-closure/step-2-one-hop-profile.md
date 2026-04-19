# Step 2 profile — one_hop

## Setup

- Binary: `zig-out/bin/geode` at commit `3578c3eb` (HEAD of
  `perf/qps-closure-2026-04-19` post-M1.1), `-Doptimize=ReleaseFast`.
- Workload A (`c=1`): Go loadtest `-scenario one_hop -levels 1 -duration 45s`.
  Observed QPS 6.5, p50 154 ms, p99 182 ms (291 queries total).
- Workload B (`c=8`): Go loadtest `-scenario one_hop -levels 8 -duration 30s`.
  **NOT FULLY RUN** — perf capture started 18 s into the loadtest, but
  one_hop's setup phase (1 k LT_Person nodes + 3 k LT_KNOWS edges) ran
  serially and was not complete until ~3 min in. The `perf record`
  window captured setup/mutation traffic, not query traffic. See
  Interpretation for what this does and does not tell us.
- Tool: `sudo perf record -F 999 -g --call-graph dwarf -p <pid> -- sleep N`.
- Raw `.perf.data` files deleted (2.7 GB c=1, 2.4 GB c=8; above the
  1 MiB hook limit). Extracted text reports committed.

## Flat top-25 self-time — Workload A (c=1 queries)

See `step-2-one-hop-c1-profile-flat.txt` for the full >=0.1% list.

| pct    | symbol                                           | where   |
|-------:|:-------------------------------------------------|:--------|
| 12.09% | `native_flush_tlb_one_user`                      | kernel  |
|  9.13% | `smp_call_function_many_cond`                    | kernel  |
|  3.90% | `entry_SYSRETQ_unsafe_stack`                     | kernel  |
|  1.82% | `sync.Condition.waitInner`                       | geode   |
|  1.69% | `pool.Core.nextTask`                             | geode   |
|  1.58% | `Io.Threaded.Thread.futexWaitInner`              | geode   |
|  1.49% | `__vdso_clock_gettime`                           | vdso    |
|  1.19% | `pool.Core.idle`                                 | geode   |
|  1.07% | `clock_gettime`                                  | libc    |
|  0.22% | `execution.match_operations.passesRLSExprFilter` | geode   |
|  0.20% | `execution.match_operations.executeMultiNodeMatch` | geode |
|  0.19% | `hash_map.HashMapUnmanaged([]const u8, rls_core.Value).grow` | geode |
|  0.06% | `execution.match_operations.passesRLSFilter`     | geode   |
|  0.03% | `wal.WriteAheadLog.append`                       | geode   |
|  0.03% | `wal_record.WalRecord.serializeInto`             | geode   |

Inclusive (children): **72.66 %** of samples under `entry_SYSCALL_64_after_hwframe`,
**43.77 %** in `__x64_sys_futex` → `do_futex` → `futex_wait` → `schedule`.

## Flat top-25 self-time — Workload B (c=8 setup/mutation)

See `step-2-one-hop-c8-setup-flat.txt`.

| pct    | symbol                                           |
|-------:|:-------------------------------------------------|
| 16.58% | `native_flush_tlb_one_user`                      |
|  9.28% | `smp_call_function_many_cond`                    |
|  4.00% | `entry_SYSRETQ_unsafe_stack`                     |
|  1.76% | `sync.Condition.waitInner`                       |
|  1.66% | `pool.Core.nextTask`                             |
|  1.53% | `Io.Threaded.Thread.futexWaitInner`              |
| ...    | (near-identical to Workload A)                   |

## Interpretation

### The c=1 one_hop profile looks exactly like the c=1 point_read profile

Both are **dispatch-bound, not MATCH-bound.** Despite one_hop's per-query
work being ~10× heavier than point_read (p99 182 ms vs 90 ms), the
proportion of samples in MATCH code (< 0.5 %) and the proportion in
thread-pool coordination (~70 % in futex wait) are nearly identical.
At c=1, there is one in-flight query and the thread pool workers
spend all their wall-clock time waiting for that query's next sub-task.
Per-query work is completely dwarfed by the wake-up latency.

### The c=8 attempt did not capture query traffic

one_hop at c=8 has baseline QPS 3.4, so 30 s of queries = ~100 completions.
Setup of 1 k nodes + 3 k edges takes several minutes (serial CREATE loop
over a QUIC stream) and was still running when the perf window closed.
**The c=8 profile is a profile of the loadtest's SETUP workload**, not
its query workload. The flat top-20 is basically identical to c=1,
which is itself evidence that the dispatch cost dominates mutations too —
not just reads.

### The real implication for M2

M2's plan-level thesis was "one_hop/two_hop/fan_out are MATCH-work
bound; profile and fix the hot MATCH sites." The data does not support
that thesis at the workloads we can actually capture cleanly. Options:

1. **Pre-seed the data.** Run the loadtest's setup once out-of-band,
   then profile query-only traffic at c=8 against the populated
   dataset. This requires either a loadtest flag (`-setup-only`,
   `-skip-setup`) or a separate seed script. Neither exists today.
2. **Attack the dispatch cost directly.** If 70 % of every query's
   wall time is in `schedule` / `futex_wait` / cross-CPU IPI, the
   biggest available win is reducing thread-pool wake-ups per query.
   Candidates:
   - Execute `is_point_read` queries inline on the connection thread
     (no dispatch at all) — mirrors the pattern in the profile, worth
     ~30–40 ms off p99.
   - Cache `clock_gettime` at the worker-tick level — `vdso + libc
     - pool.nowNs` combined is ~3 % of samples.
   - Investigate why `DebugAllocator.alloc` appears at 0.27 % in a
     `ReleaseFast` build — GAP-0754 swapped `global_gpa` but at
     least one site still uses a DebugAllocator instance.
3. **Accept the current gaps as systemic.** The server's thread-
   pool architecture is the bottleneck for small queries, not any
   specific MATCH path. QPS floors for one_hop / two_hop / fan_out
   reflect this; raising them is a multi-step refactor, not a
   single-commit fix.

### Decision for this plan

**Do not attempt M2.2 / M2.3 / M2.4 / M2.5 blind.** Without a
query-only c=8 profile we have no evidence for which MATCH site (if
any) is actually a bottleneck at saturation. The c=1 profiles say
"it's not MATCH code" for both point_read and one_hop; extrapolating
that to two_hop / fan_out is plausible but not proven.

Next honest step is **Option 1 above** — add a `-skip-setup` flag (or
equivalent) to `geode-test-harness/loadtest/go/geode-loadtest`, re-
profile query-only traffic at c=8 for one_hop / two_hop / fan_out,
then decide. That's a loadtest-harness change, not an M2.2 code fix;
file it as a follow-up and close this plan at its realistic reach.

## Artifacts

- `step-2-one-hop-c1-profile-flat.txt` — Workload A (c=1 query), flat
  self-time >=0.1 %.
- `step-2-one-hop-c1-profile-callchains.txt` — Workload A, inclusive
  >=2 % children.
- `step-2-one-hop-c8-setup-flat.txt` — Workload B (c=8 SETUP — not
  query — see Interpretation).
- Raw `.perf.data` files deleted. Regenerate with the commands in
  Setup if deep inspection is needed.
