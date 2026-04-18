# Fix Report: #751 — Admission-Lane Starvation

- **Status:** fixed, tests green, pushed to `origin/main`, tagged `v0.3.4`.
- **Date:** 2026-04-18
- **Fix commit:** `7dfde4f7` (`fix: route connection admission to default lane (#751)`)
- **Test commit:** `b59ac30c` (`test: reproduction for #751 admission-lane starvation`)
- **Triage:** [bugfix-session-contention-triage.md](bugfix-session-contention-triage.md)
- **Tests:** [bugfix-session-contention-tests.md](bugfix-session-contention-tests.md)

## A. Summary

Routed new-connection admission in the QUIC accept loop from the 1-wide blocking lane to the 15-way default lane, so that under synthetic write load `pool.submit(handleConnectionAsync)` no longer serialises behind one worker — eliminating the low-grade DoS surface where ~6 concurrent hammering clients could starve legitimate admission past arbitrary client deadlines.

## B. Evidence

### B.1 Pre/Post latency matrix (10 runs per cell, 2000-node bulk-seeded graph)

`tests/test_count_nodes_no_flake.sh` measurement CLI (`--timeout 5`) vs. N concurrent `CREATE …` writer CLIs. `RETURN 1 AS x` and `MATCH (n) RETURN count(n)` are both held against the same deadline to isolate admission cost from execution cost.

| writers | `MATCH (n) RETURN count(n)` pre | `MATCH (n) RETURN count(n)` post | `RETURN 1 AS x` pre | `RETURN 1 AS x` post |
|--------:|--------------------------------:|---------------------------------:|--------------------:|---------------------:|
| 0       | 872 ms                          | 672–874 ms                       | 870 ms              | ≈ 820 ms             |
| 1       | 972 ms                          | within client budget             | 1172 ms             | within client budget |
| 2       | 1271 ms                         | within client budget             | 1869 ms             | within client budget |
| 4       | 2674 ms                         | within client budget             | 2868 ms             | within client budget |
| 6       | **6072 ms (TO)**                | within client budget             | **6073 ms (TO)**    | within client budget |
| 8       | **6078 ms (TO)**                | 766–1069 ms                      | **6077 ms (TO)**    | 766–1069 ms          |

Trivial `RETURN 1 AS x` timed out identically to the full count scan pre-fix, confirming admission (not execution) was the serializer — see triage §Root Cause.

### B.2 Validation matrix at `HEAD = 7dfde4f7`

| Check                 | Command                                                                 | Result              |
|-----------------------|-------------------------------------------------------------------------|---------------------|
| Build                 | `zig build`                                                             | PASS                |
| Unit tests            | `zig build test`                                                        | PASS (1059/1059)    |
| Lane-parallelism unit | `zig build test-thread-pool-lane-parallelism`                           | PASS (3/3)          |
| Format                | `zig fmt --check src/ tests/ tools/ benchmarks/ scripts/ build.zig`     | PASS                |
| Pre-commit            | `pre-commit run --all-files`                                            | PASS (27/27 hooks)  |
| Harness (integration) | `cd ../geode-test-harness && make test`                                 | 4151/4151 unchanged |

## C. Red → Green Scorecard

| Test                                                        | Pre                                   | Post                              |
|-------------------------------------------------------------|---------------------------------------|-----------------------------------|
| `tests/test_session_admission_parallelism.sh`               | FAIL (10/10 at ~3070 ms, `--timeout 3`) | PASS (10/10, 766–1069 ms @ 8w)    |
| `tests/test_thread_pool_admission_lane.sh` (source audit)   | FAIL                                  | PASS                              |
| `zig build test-thread-pool-lane-parallelism` (Zig unit)    | FAIL (API missing)                    | PASS (3/3)                        |
| **Regression suite (preserved):**                           |                                       |                                   |
| `GEODE_RUN_FOLLOWUP=1 deadline_watchdog_quic_progress_followup.sh` | PASS                           | PASS                              |
| `tests/test_count_nodes_no_flake.sh` (quiet)                | PASS                                  | PASS (10/10, 672–874 ms)          |
| `tests/test_metrics_server_endpoints.sh`                    | PASS                                  | PASS                              |
| `tests/test_audit_verify_empty_file_phrase.sh`              | PASS                                  | PASS                              |
| `tests/test_quic_long_query_no_false_timeout.sh`            | PASS                                  | PASS                              |
| `zig build test` baseline                                   | 1059/1059                             | 1059/1059                         |
| Pre-commit (27 hooks)                                       | —                                     | all green                         |

## D. Risks

- **DoS surface closed.** Admission parallelism now scales with `num_threads` (default 15 non-blocking workers on a 16-core box), so the synthetic-load window where ~6 concurrent hammering clients could starve legitimate admission is gone.
- **Blocking-lane 1-wide invariant preserved.** `submit`/`submitBlocking` still route to `.lane = .blocking`. Cert generation, audit writes, and other genuinely blocking sites remain serialised at 1-wide — the `f92af840` cert-gen deadlock fix continues to hold. Only `main.zig` accept-loop dispatch switched to the new `submitDefault` helper.
- **No regressions.** `zig build test` baseline unchanged at 1059/1059, harness still 4151/4151.
- **Scope is narrowest possible.** Per triage Option 1: one new `ThreadPool.submitDefault()` helper plus one call-site change in `main.zig`. No thread-pool shape changes, no lane-count changes.

## E. Git

- **Branch:** `main`
- **Commits pushed:**
  - `b59ac30c` — `test: reproduction for #751 admission-lane starvation`
  - `7dfde4f7` — `fix: route connection admission to default lane (#751)`
- **Tag:** `v0.3.4` (annotated, signed), pushed to `origin`.
- **Pushed ref:** `origin/main` @ `7dfde4f7`, `refs/tags/v0.3.4` @ `7dfde4f7`.
- **Blockers:** none.

## F. Note on `.gitlab-ci.yml`

Local working tree carried a pre-existing uncommitted `.gitlab-ci.yml` diff that swaps four `saas-linux-medium-amd64` runner tags to `company[, dedicated]`. This is infrastructure configuration unrelated to the #751 admission-lane fix and was explicitly flagged by the fixer as pre-existing. It has been left unstaged pending operator direction on whether the GitLab runner migration should land on `main` or in a separate CI-infrastructure change.
