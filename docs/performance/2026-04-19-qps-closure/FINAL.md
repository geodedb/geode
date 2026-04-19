# QPS Regression Closure — Final Summary (2026-04-19)

**Branch:** `perf/qps-closure-2026-04-19` (18 commits, not yet merged).
**Plan:** `docs/superpowers/plans/2026-04-19-qps-regression-closure.md`
**Baseline evidence:** `docs/audit/LOADTEST_REPORT_2026_04_19_v0.3.8.md`

---

## What the plan aimed for

Close four QPS gaps observed in the v0.3.8 loadtest baseline:

| scenario   | baseline  | plan target       |
|------------|-----------|-------------------|
| point_read | 27.2 QPS @ c=4 | ≥ 100 QPS @ c=4 |
| one_hop    |  3.4 QPS @ c=8 | ≥  25 QPS @ c=8 |
| two_hop    |  1.6 QPS @ c=4 | ≥   5 QPS @ c=4 |
| fan_out    |  2.4 QPS @ c=4 | ≥   5 QPS @ c=4 |

Rebuild the measurement harness first (M0), then iterate per scenario
with before/after A/B evidence (M1–M2), then flip the CI gate from
warning to blocking (M3). Mirror thread-pool's perf-gate.sh discipline.

## What actually landed

### Milestone 0 — measurement harness (COMPLETE, 11 commits)

Every harness piece shipped and was reviewed (spec + quality) before
merging:

| step  | artifact                                                         |
|-------|------------------------------------------------------------------|
| M0.3b | `build.zig` quarantines `bench_quic_stream_registry` (hang) and `benchmark_merge_throughput` (4k teardown leaks) from the `bench` aggregate so the step is green for CI. |
| M0.4  | `benchmarks/bench_schema.zig` (`ResultRow`/`ResultDocument`). `bench-timeseries` now accepts `--output <path>` with median-of-6-after-warmup + stddev. |
| M0.5  | `benchmarks/phase_benchmarks_main.zig` wraps phase1/phase2 test blocks to emit the same schema under `zig build benchmark -- --output <path>`. |
| M0.6  | `zig build compare-bench` — `(scenario, variant, measurement)` matcher with `max(15 %, 3 σ)` noise gate and direction dispatch (`throughput_` / `improvement_` / `latency_` / `wall_time_` / `ns_per_op_` prefixes). 3 unit tests, one live-smoke injected regression. |
| M0.7  | `scripts/perf-gate.sh <step> before\|after` — 3-artifact capture (bench-timeseries, benchmark, merged 5-scenario loadtest), diff.md generation. Retries `zig build benchmark` and honors `PERF_GATE_ALLOW_BENCH_FAIL=1`. |
| M0.8  | `benchmarks/loadtest/compare_ab.py` — loadtest A/B comparator with BLOCK (−5 % QPS or +10 % p99) and warn (3–5 % / 7–10 %) bands. 4 pytest cases. |
| M0.9  | `docs/performance/host-tuning.md` — sysctl rmem/wmem recipe, governor, turbo, data-dir hygiene. |
| M0.10 | Partial loadtest baseline: `ping`, `point_read`, `one_hop` × 6 levels (18 records in `benchmarks/loadtest/baseline.jsonl`). `two_hop` / `fan_out` were blocked by the leak surfaced in Task 1.5 — see below. |
| bonus | `perf-gate.sh` `LOADTEST_SCENARIOS` env override for targeted runs. |
| M0.11 | End-to-end harness self-test. `step-0-m0-closeout-diff.md` shows all three comparator paths exit 0 on a no-op change with an unchanged binary. |

Harness exit criterion met: `./scripts/perf-gate.sh <step> before/after`
produces a valid diff.md, all three comparator paths exit 0 on a no-op.

### Task 1.5 — `materializeNode` leak fix (surfaced during M0.10)

`src/execution/planned_read_runtime.zig` leaked the Node's interior
bytes (`graph_name` dupe, labels + label strings, property keys,
property values) on every returned row. `OwnedGraphEntities.deinit`
destroys only the Node struct; the interior bytes lived on the
caller's allocator forever. Under DebugAllocator the M0.10 baseline
run accumulated **3,422 leak stacks** over 90 min; the server pegged
at 8 cores (DebugAllocator bookkeeping cost) and had to be SIGKILL'd.

Fixed by routing interior dupes through the per-query arena
(`query_arena.scratchAllocatorOr`, GAP-0755). Node struct itself
stays caller-owned. Regression test `tests/test_match_row_no_leak.zig`
asserts zero leaks under `std.testing.allocator`.

End-to-end confirmation: the M1.4 post-fix loadtest left **0** leak
lines in the server log (vs. 3,422 pre-fix on a shorter run).

### Milestone 1 — point_read (PARTIAL)

| step | artifact |
|------|----------|
| M1.1 | `sudo perf record` of point_read at c=1. 417k samples, 319G events. Flat + call-chain reports archived. `step-1-profile.md` interprets. |
| M1.2 | `PointReadView` zero-copy read view next to `QueryReadSession` in `src/graph_store.zig`. Captures mutation epoch, no deep clone, caller-owned lock. 2 tests (zero-copy + mutation-invalidation). |
| M1.3 | 3-way dispatch in QUIC + gRPC handlers: write-lock / point-read view / snapshot session. Conservative `isPointReadQuery` detector in `src/query/query_traits.zig` with 14 unit tests. Fallback on `PointReadView.init` error. |
| M1.4 | Before/after perf-gate, isolated for PointReadView effect (Task 1.5 fix present in both phases). Integration QPS floor `tests/integration/scripts/point_read_qps_floor.sh` enforces `FLOOR_QPS=25`. |

**Result — modest, smaller than the plan predicted:**

| metric | before | after | delta |
|:-------|-------:|------:|:------|
| point_read c=4 QPS  | 27.2  | 30.0  | **+10.3 %** |
| point_read c=4 p99  | 403 ms | 336 ms | **−16.5 %** |
| point_read c=2 p99  | 270 ms | 140 ms | **−48.1 %** |
| ping (all levels)   | —     | —     | flat ±2 % (expected — no MATCH) |

p99 wins are real — the clone was on the synchronous path and
removing it directly shrank the slow tail. QPS improvements are far
short of the plan's `c=4 ≥ 100` target.

### M1.1 profile surfaces the real bottleneck

`docs/performance/2026-04-19-qps-closure/step-1-profile.md`:

- **72.98 %** of samples in `entry_SYSCALL_64_after_hwframe` →
  **43.98 %** specifically in `__x64_sys_futex` → `do_futex` →
  `futex_wait` → `schedule`.
- Top kernel symbols are TLB shootdown (16.97 %) and cross-CPU IPI
  (9.47 %) — symptoms of a worker pool that wakes on every query.
- Combined `clock_gettime` call sites (vdso + libc + `pool.nowNs`) hit
  **2.48 %** of samples.
- App-level MATCH code is below **0.5 %** aggregate.
  `materializeNode` does not appear at the ≥ 0.1 % threshold —
  consistent with Task 1.5 having eliminated its interior-dupe cost.

The per-query wall clock is dominated by thread-pool coordination
(worker park → futex wake → cross-CPU IPI → TLB flush → context
switch → worker run → signal back → park again), not by query logic.
The clone was _a_ cost; the scheduler round trip is the _dominant_
cost. PointReadView removed the clone; the round trip is still
there.

### Milestone 2 — one_hop profile (M2.1 ONLY; M2.2–M2.5 NOT RUN)

Profiled one_hop at c=1 with the same `sudo perf record` pattern;
attempted c=8 but the loadtest's serial setup (1 k nodes + 3 k edges)
outran the perf window — that capture is of setup/mutation traffic,
not query traffic. `step-2-one-hop-profile.md` documents both runs
honestly.

**Finding:** one_hop's c=1 profile is nearly identical to point_read's.
Both are dispatch-bound, both show <0.5 % in MATCH code, both show
70 %+ in `futex_wait → schedule`. The plan's thesis "one_hop /
two_hop / fan_out are MATCH-work bound" is **not supported** by the
data we could capture cleanly.

**Decision:** not proceeding with M2.2 / M2.3 / M2.4 / M2.5 blind. A
speculative fix to a MATCH hot site is at best a small percentage
win, and at worst no-op or a regression. The honest follow-up path
requires a harness change (see below).

## Follow-ups this plan did NOT close

1. **`loadtest -skip-setup` (or `-setup-only`) flag** in
   `geode-test-harness/loadtest/go/geode-loadtest`. Without it, every
   profile run spends several minutes in serial dataset setup, which
   outstrips any realistic perf-record window for one_hop / two_hop /
   fan_out at saturation. Blocker for c=8 query-only profiling of
   those three scenarios.
2. **Execute `is_point_read` queries inline on the connection thread.**
   The profile suggests ~30–40 ms of p99 at c=1 is the worker
   wake-up round trip. The handler already takes the shared read
   lock for the point-read branch (M1.3); extending that to skip
   thread-pool dispatch entirely is the obvious next perf move.
   Expected additional win: unknown without measurement, but the
   profile says the worker round trip is real.
3. **`clock_gettime` cached per worker tick.** `vdso` + libc +
   `pool.nowNs` is ~3 % of samples. Low-hanging if a single worker-
   loop read can cover N tasks.
4. **`DebugAllocator` appearing in `ReleaseFast`.** 0.27 % of
   samples in `DebugAllocator(.{ ... .page_size = 131072 }).alloc`.
   GAP-0754 swapped `global_gpa` to `smp_allocator`, but at least
   one site still uses a DebugAllocator instance. Audit target.
5. **`bench_quic_stream_registry` hangs** (M0.3b quarantine).
   Replace the `sleepNs` + `ready.load(.acquire)` polling loop with
   `std.Thread.Futex` or a waitgroup from `transport/thread_pool`.
6. **`benchmark_merge_throughput` 4,000 teardown leaks** (M0.3b
   quarantine). Audit the bulk-MERGE bench's teardown order.
7. **Full `benchmarks/loadtest/baseline.jsonl`.** Currently covers
   3 of 5 scenarios × 6 levels (18 rows). `two_hop` and `fan_out`
   baselines need a post-Task-1.5 loadtest run; the server no
   longer spirals with the leak fixed, but capture time is still
   significant (setup is the bottleneck per #1).
8. **M3.2 — flip `loadtest-regression` / `bench-timeseries` CI jobs
   from `allow_failure: true` to blocking.** Intentionally NOT done
   in this plan: the baseline is partial, and flipping today would
   reject MRs that merely touch `two_hop` / `fan_out`. Revisit after
   #1 and #7.
9. **Raise `tests/integration/scripts/point_read_qps_floor.sh` from
   25 QPS.** Currently set below the measured 30 QPS. Raise once a
   follow-up closes more of the c=4 gap.

## Per-step ledger

| step   | commit     | artifact                                                                                                                                                   |
|--------|------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| M0.3b  | `701a2c8e` | `docs/performance/2026-04-19-qps-closure/post-port/M0_3_CONCERNS.md`                                                                                       |
| M0.4   | `38bc7b79` | `benchmarks/bench_schema.zig`, `src/benchmarks/bench_timeseries.zig`                                                                                       |
| M0.5   | `21f509dc` | `benchmarks/phase_benchmarks_main.zig`                                                                                                                     |
| M0.6   | `8fcd2442` | `benchmarks/compare_bench.zig`, `tests/perf/test_compare_bench.zig`                                                                                        |
| M0.7   | `3d0358dd` / `a2ae0613` | `scripts/perf-gate.sh` + retry fix                                                                                                       |
| M0.8   | `d78aa80f` | `benchmarks/loadtest/compare_ab.py`, `tests/perf/test_compare_ab_py.py`                                                                                    |
| M0.9   | `dc92ef41` | `docs/performance/host-tuning.md`                                                                                                                          |
| M0.10  | `7a2eadb3` | `benchmarks/loadtest/baseline.jsonl` (partial) + `docs/performance/2026-04-19-qps-closure/m0-baseline-raw/` (M0_10_CONCERNS.md, 3 loadtest JSONs, server log head) |
| env    | `7bc687a9` | `LOADTEST_SCENARIOS` override                                                                                                                              |
| M0.11  | `7e4f966c` | `step-0-m0-closeout-*` artifacts, flat before→after diff.md                                                                                                |
| M1.2   | `0bb9c61c` | `src/graph_store.zig` + 2 tests                                                                                                                            |
| plan   | `a453c7b3` | Task 1.5 insert                                                                                                                                            |
| M1.3   | `31e6ef34` | QUIC + gRPC handler wire, `src/query/query_traits.zig` detector, handler test                                                                              |
| 1.5    | `62536b9e` | `src/execution/planned_read_runtime.zig` arena fix, `tests/test_match_row_no_leak.zig`                                                                     |
| M1.4   | `3788946f` | `step-1-point-read-view-*` before/after + diff.md, `tests/integration/scripts/point_read_qps_floor.sh`                                                     |
| M1.1   | `3578c3eb` | `step-1-profile.md`, flat + call-chain reports                                                                                                             |
| M2.1   | `0b60e009` | `step-2-one-hop-profile.md`, c=1 flat/callchain + c=8 setup flat                                                                                           |
| FINAL  | (this)     | `docs/performance/2026-04-19-qps-closure/FINAL.md`                                                                                                         |

## Honest assessment against plan exit criteria

| criterion                                                                                | status          |
|------------------------------------------------------------------------------------------|-----------------|
| Harness rebuilt, mirrors thread-pool pattern, diff.md generated on no-op run             | ✅ done (M0.11)  |
| `point_read c=4 QPS ≥ 100` with `p99 ≤ 100 ms`                                           | ❌ NOT met (30 QPS / 336 ms) |
| `one_hop c=8 QPS ≥ 25`                                                                   | ❌ NOT attempted (profile inconclusive — see M2.1) |
| `two_hop c=4 QPS ≥ 5`                                                                    | ❌ NOT attempted |
| `fan_out c=4 QPS ≥ 5`                                                                    | ❌ NOT attempted |
| CI `loadtest-regression` flipped to blocking                                             | ❌ NOT done (baseline partial) |
| Integration QPS floor for point_read                                                     | ✅ done at 25 QPS (M1.4) |
| Materialize-node leak fixed                                                              | ✅ done (Task 1.5) |

The plan's harness goal landed in full. The per-scenario QPS goals
did not — the profile data says closing them requires attacking the
dispatch cost systemically, not per-scenario MATCH fixes.

## Test health

- Full suite at HEAD: **1089/1089 tests passed**.
- 6 pre-existing binary-level failures (audit chain, migration,
  HNSW, FTS persist) are UNCHANGED across M1.2 / M1.3 / Task 1.5.
  None were introduced by this plan.

## Recommendation for the next plan

Not "M2 iterations" — the data says those would be speculation.
Instead:

1. Add `-skip-setup` to the loadtest harness (1-day harness task).
2. Profile `one_hop` / `two_hop` / `fan_out` at saturation against
   a pre-seeded dataset. Decide whether MATCH fixes or dispatch
   fixes dominate at saturation.
3. If dispatch dominates (likely): implement inline-dispatch for
   `is_point_read`, audit DebugAllocator in Release, cache
   `clock_gettime`.
4. Then refresh the full `baseline.jsonl` and flip CI to blocking.

This plan's measurement infrastructure is ready to gate all of it.
