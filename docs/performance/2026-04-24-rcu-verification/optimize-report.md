# RCU merge_prop_index — verification on 56-core / 251 GB host

**Status:** COMPLETE — verification confirms regression; **DO NOT MERGE as-is**
**Date:** 2026-04-24
**Branch under test:** `origin/perf/rcu-merge-prop-index` HEAD `27351cd3`
**Baseline ref:** `main` HEAD `ec5bfb26`
**Session kind:** verification, not optimization (`.bench-optimize/session.json`)

## TL;DR

The RCU snapshot scaffolding regression reported in
`docs/performance/2026-04-24-sharding/RCU-MERGE-PROP-VALIDATION.md` reproduces
**at greater magnitude** on this 56-core / 251 GB host. Headline:

| Test | Author (smaller box) | This host (56 cores) | Worse here? |
|---|---|---|---|
| Microbench, 1 thread, RCU vs baseline | −12% throughput | **−23% throughput** | yes |
| Microbench, 16 threads, RCU vs baseline | −83% throughput | **−93% throughput** | yes |
| Microbench, 56 threads, RCU vs baseline | (not measured) | **−95% throughput** (19.7× slower) | new evidence |
| `bench-merge` `bulk_merge_update`, RCU vs baseline | +28% ns/op | +15% ns/op (perf-branch HEAD vs main HEAD) | qualitatively same |
| `bench-merge` `bulk_merge_insert`, RCU vs baseline | wash (−4%) | −6.2% (within noise; spread 45%) | wash |

The single refcount cache line is the bottleneck the author predicted, and 56
cores make it strictly worse — readers serialize harder, not better, as core
count climbs. The microbench's "baseline" mode is `lookupMergeCandidate`'s no-snapshot
fallthrough (a bare `StringHashMap.get` with no locking), so it scales near-linearly
with cores while the RCU path saturates at ~10 M ops/sec regardless of core count.

**Recommendation:** do **not** merge `perf/rcu-merge-prop-index` to `main` as it stands.
The branch is foundation work without an end-to-end win. Acceptable next paths
(deferred per session config — user chose "stop at report"):

1. Replace single-refcount with epoch-based reclamation or per-thread hazard
   pointers, then re-verify; OR
2. Land Task 10 (drop `acquireGraphReadLock` around endpoint resolution in callers)
   and re-measure end-to-end via `msft-graph seed --parallel --workers 16`; OR
3. Shelve the branch and revisit when concurrent endpoint resolution becomes
   the proven bottleneck on a real workload.

## Host

| Item | Value |
|---|---|
| Kernel | Linux 6.12.74+deb13+1-amd64 |
| CPUs | 56 |
| RAM | 251 GiB |
| Zig | 0.16.0 |
| Optimize | ReleaseFast |
| Load avg at start | 2.44 / 4.85 / 3.29 |
| Load avg at end | 3.47 / 13.66 / 11.21 (build noise during bench-merge) |

## Methodology

- Worktree of `origin/perf/rcu-merge-prop-index` at `../geode-rcu-verify` built
  from clean state (`zig build install -Doptimize=ReleaseFast`).
- `bench-merge-prop-lookup` driven by `run-microbench.sh` — thread sweep
  `{1, 4, 8, 16, 32, 56}`, modes `{baseline, rcu}`, 1 warmup + 5 measured
  rounds per (mode, threads), modes alternated per round to interleave drift.
- `bench-merge` (`zig build bench-merge`) run as a `Test`-typed bench;
  5 measured rounds.
- Medians reported, not means. Raw per-round samples retained in `raw/`.

## Microbench: bench-merge-prop-lookup

Source: `benchmarks/merge_prop_snapshot_lookup/main.zig` (perf branch).
Workload: 10k-node store, each thread does 200k random `lookupMergeCandidate`
probes against `User.name` properties. `baseline` mode forces snapshot=null
(falls through to plain `merge_prop_index.get` — **no lock**); `rcu` mode
publishes the snapshot and exercises the lock-free fast path with
acquire/release refcount RMWs.

### Medians (this host, 5 measured rounds, 1 warmup discarded)

| threads | mode     | ops/sec      | elapsed ms | rcu/baseline | rcu vs baseline |
|--------:|----------|-------------:|-----------:|-------------:|----------------:|
|       1 | baseline | 10,998,739   | 18.18      | —            | —               |
|       1 | rcu      | 8,467,735    | 23.62      | 0.770        | **−23.0%**      |
|       4 | baseline | 40,032,204   | 19.98      | —            | —               |
|       4 | rcu      | 10,083,024   | 79.34      | 0.252        | **−74.8%**      |
|       8 | baseline | 79,560,884   | 20.11      | —            | —               |
|       8 | rcu      | 10,723,883   | 149.20     | 0.135        | **−86.5%**      |
|      16 | baseline | 143,018,390  | 22.37      | —            | —               |
|      16 | rcu      | 10,368,848   | 308.62     | 0.073        | **−92.7%**      |
|      32 | baseline | 190,232,715  | 33.64      | —            | —               |
|      32 | rcu      | 7,206,592    | 888.08     | 0.038        | **−96.2%**      |
|      56 | baseline | 274,459,103  | 40.81      | —            | —               |
|      56 | rcu      | 13,945,383   | 803.13     | 0.051        | **−94.9%**      |

**Two patterns:**

1. The `baseline` (no-snapshot) path scales nearly linearly with cores: 11 M
   (1 thread) → 274 M (56 threads) ≈ 25× scaling. This path is `lookupMergeCandidate`
   falling through to plain `StringHashMap.get` with no lock and no atomics —
   embarrassingly parallel.
2. The `rcu` path *flatlines* between 7 M and 14 M ops/sec across the entire
   thread sweep. Adding more readers does not improve throughput; in fact 32
   threads is the worst-case (7.2 M) because of refcount RMW thrashing on the
   single `MergePropSnapshot.refcount` cache line.

This is the textbook RCU-with-shared-refcount failure mode the author called
out as "well-known." 56-core hardware confirms it without ambiguity.

### Comparison vs author's published numbers

| threads | author baseline ops/s | this host baseline | author rcu ops/s | this host rcu |
|--------:|----------------------:|-------------------:|-----------------:|--------------:|
|       1 | 16.7 M                | 11.0 M             | 14.8 M           | 8.5 M         |
|      16 | 163.9 M               | 143.0 M            | 28.3 M           | 10.4 M        |

**Note:** absolute baseline numbers are *lower* on this host than on the
author's box (11 M vs 16.7 M at 1 thread). This isn't a host weakness — it's
either a different Zig minor (we ran 0.16.0), or NUMA effects on a 56-core
EPYC-class chip versus a smaller machine. The *direction* and magnitude of
the rcu/baseline regression are what matters, and both worsen here.

## End-to-end: bench-merge

Source: `benchmarks/benchmark_merge_throughput.zig`. Single-threaded.
Author's two-commit comparison (Task-5 baseline vs Task-9 RCU) showed:

- `bulk_merge_insert (2000 new nodes)`: 3184 → 3064 ns/op (wash)
- `bulk_merge_update (2000 existing-node MERGEs)`: 96 → 123 ns/op (**+28%**)

This-host median across 5 measured rounds, both branches built fresh:

| Benchmark         | main ns/op | perf-branch ns/op | delta   | main spread% | perf spread% |
|-------------------|-----------:|------------------:|--------:|-------------:|-------------:|
| bulk_merge_insert | 6034       | 5662              | −6.2%   | 44.8%        | 7.6%         |
| bulk_merge_update | 203        | 233               | **+14.8%** | 36.0%        | 11.2%        |

Raw samples (perf branch HEAD `27351cd3` vs main HEAD `ec5bfb26`):

```
bulk_merge_insert  main: [6034, 5451, 4515, 7218, 6094]   median 6034
bulk_merge_insert  perf: [5727, 5298, 5662, 5652, 5726]   median 5662
bulk_merge_update  main: [203, 162, 144, 217, 206]        median 203
bulk_merge_update  perf: [220, 246, 233, 233, 233]        median 233
```

**Direction agrees with author**: `bulk_merge_insert` is a wash (and main's
spread is so wide — 44.8% — that the −6.2% delta is firmly inside noise).
`bulk_merge_update` is the regression case, +14.8% per op; the author saw
+28% on a smaller box. The smaller magnitude here is consistent with this host's
slower per-op baseline (the single-thread `lookupMergeCandidate` cost is
fixed by the bench, but the surrounding insert work is slower, diluting the delta).

The `bulk_merge_update` per-round spread is also visibly *narrower* on the perf
branch than on main (11% vs 36%). This is the snapshot machinery acting as a
"floor" — even the fastest update is now bottlenecked by the refcount + verify
overhead, removing the variability the cheaper unlocked path showed.

## Verdict

**The author's "honest bottom line" is confirmed and amplified.**
Quote from `RCU-MERGE-PROP-VALIDATION.md`:

> *Net win in this branch today: no — single-thread workloads pay ~28%
> more per MERGE-update, with unmeasured multi-thread upside.*

This verification adds the missing multi-thread evidence: the upside is
**not there**. At every measured thread count between 4 and 56, the RCU path
is 5–20× slower than the no-snapshot fallthrough. The refcount cache line is
the bottleneck, exactly as the author hypothesised.

The reason this looks paradoxical (RCU is supposed to *help* concurrency) is that
the microbench's `baseline` mode is not "the live-map under a per-graph
rwlock" — it's the post-Task-6 fallthrough that takes no lock at all.
`lookupMergeCandidate` is `*const GraphStore`, so when the snapshot is null it
just hits `StringHashMap.get` directly. The RCU work doesn't compete with a
locked path; it competes with a *lock-free* path. And against a lock-free
path, adding two atomic RMWs per call is pure overhead.

The design is only a win when callers (a) currently hold a per-graph rwlock
SHARED while doing endpoint resolution, and (b) update to drop that lock and
rely on RCU + strong-verify. That's Task 10, which isn't on this branch.

### Decision

Per session config, user chose **Stop at report — don't iterate.**

Recommendation: do **not** merge `perf/rcu-merge-prop-index` to `main` as it
stands. The branch is correct (stress test passes, unit tests pass, no
correctness regression), but it's a measurable single-thread perf regression
on `bulk_merge_update` (+14.8% on this host, +28% on the author's host) with
no end-to-end win to offset it.

## Recommendation

Three viable paths, listed in increasing scope:

1. **Shelve the branch** as a foundation reference. The `MergePropSnapshot`
   primitive, `verifyMergeCandidate` helper, and the writer-trigger
   plumbing are correct and reusable. Document in `docs/performance/`
   that the branch is parked pending either #2 or #3, then continue
   higher-leverage work.

2. **Land Task 10 (caller updates) on a fresh branch.** Drop
   `acquireGraphReadLock` around endpoint resolution in
   `bulk_match_create_edge` and `lookupNodeByMergeKey`, relying on RCU +
   strong-verify. Re-measure end-to-end via `msft-graph seed --parallel
   --workers 16` from
   `docs/performance/2026-04-24-sharding/PHASE2-SUMMARY.md`. If the
   end-to-end wall-clock improves, the refcount overhead is justified.
   Carries risk: callers that drop the rwlock also expose `nodes.get`
   to writer races (ShardedStore rehash) — so this likely needs an
   accompanying `nodes`-map RCU or per-shard rwlock pattern.

3. **Replace the single refcount with epoch-based reclamation or
   per-thread hazard pointers** before doing #2. Eliminates the
   cache-line bottleneck this verification just confirmed. ~weeks of
   work but the only path to RCU readers actually scaling on a 56-core
   box.

The user's stated next step is to digest this report and pick one.

## Decision artifact

- **Parking note:** [`branch-shelved.md`](branch-shelved.md) — explicit
  resurrection criteria and pointer to the next-step plan
  (`docs/superpowers/plans/2026-04-24-per-shard-coordinator-wiring.md`).

## Artifacts

- Raw microbench output: `raw/microbench-raw.log` (66 measured invocations + 12 warmup)
- Raw bench-merge output: `raw/bench-merge-rcu.log`, `raw/bench-merge-main.log` (5 measured + 1 warmup each)
- Aggregated microbench: `medians.tsv`
- Aggregated bench-merge: `bench-merge-rcu-medians.tsv`, `bench-merge-comparison.tsv`
- Driver: `run-microbench.sh`
- Session config: `../../../.bench-optimize/session.json`
- Author's prior validation: `../2026-04-24-sharding/RCU-MERGE-PROP-VALIDATION.md`

## Reproduction

```bash
# From geode repo root, with worktree of perf branch at ../geode-rcu-verify:
git worktree add ../geode-rcu-verify origin/perf/rcu-merge-prop-index
cd ../geode-rcu-verify && zig build install -Doptimize=ReleaseFast && cd -
zig build install -Doptimize=ReleaseFast    # main HEAD
bash docs/performance/2026-04-24-rcu-verification/run-microbench.sh \
     ../geode-rcu-verify/zig-out/bin/bench-merge-prop-lookup \
     docs/performance/2026-04-24-rcu-verification

# bench-merge per branch (manual, 6 rounds = 1 warmup + 5 measured):
( cd ../geode-rcu-verify && for r in 0 1 2 3 4 5; do
    echo "--- ROUND ${r} ---"; zig build bench-merge -Doptimize=ReleaseFast 2>&1 \
      | grep -E '^(=== Benchmark|  Avg per op)'; done )
for r in 0 1 2 3 4 5; do
    echo "--- ROUND ${r} ---"; zig build bench-merge -Doptimize=ReleaseFast 2>&1 \
      | grep -E '^(=== Benchmark|  Avg per op)'; done
```
