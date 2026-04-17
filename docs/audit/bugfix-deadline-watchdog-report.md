# Bug-fix Report — GitLab #746: deadlineWatchdog spurious timeout

## A) Summary

`QueryDeadlineState.finish()` did not join its watchdog thread before returning, leading to a cross-thread read of a freed stack slot. Fix: store the `std.Thread` handle in the state struct and `thread.join()` on `finish()`. One commit, no upstream changes.

## B) Evidence

| Check | Command | Result |
|---|---|---|
| Build | `zig build` | exit 0 |
| Tests (full) | `zig build test` | exit 0 — 1059/1059, no regression |
| Unit regression (new) | `zig build test-deadline-watchdog` | PASS (was FAIL `error.WatchdogNotJoined`) |
| Shell regression (new) | `./tests/test_deadline_watchdog_false_positive.sh` | exit 0 in ~765 ms (was exit 1 with spurious stderr in ~870 ms) |
| Handshake-stall pin (pre-existing) | `./tests/test_quic_handshake_stall_regression.sh` | exit 0 in ~768 ms (was exit 1 with spurious stderr in ~864 ms) |
| Follow-up opt-in | `GEODE_RUN_FOLLOWUP=1 ./tests/test_deadline_watchdog_quic_progress_followup.sh` | Red by design — tracks secondary bug |
| Format | `zig fmt --check src/ tests/ tools/ benchmarks/ scripts/ build.zig` | exit 0 |
| Pre-commit | `pre-commit run --all-files` (via pre-push) | 24/24 hooks green |
| Cross-compile | pre-push `cross-compile-check` | PASS |
| Sync | `git rev-parse origin/main HEAD` | `40b0333477c20d40592fef43eed6f46f6a51f5eb` (local == origin) |

## C) Red→Green

| Test | Pre-fix | Post-fix |
|---|---|---|
| `QueryDeadlineState.finish joins the watchdog thread (#746)` unit | FAIL | PASS |
| `QueryDeadlineState.finish early-finish fast-path` unit | FAIL | PASS |
| `test_deadline_watchdog_false_positive.sh` | FAIL | PASS |
| `test_quic_handshake_stall_regression.sh` | FAIL | PASS |
| `test_deadline_watchdog_quic_progress_followup.sh` (opt-in) | Red by design | Still red — pins follow-up |

## D) Risks

- **Zero risk to the happy path.** `finish()` was already called on every return path; adding `thread.join()` inside it just guarantees the watchdog is no longer reading the state when the caller's stack frame unwinds.
- **Worst-case shutdown latency = 1 tick (~100 ms).** If the watchdog is ever extended to do blocking IO, revisit the join model.
- **Secondary follow-up (#747):** on the QUIC transport path, `QuicProtocolAdapter` (`src/cli/main.zig:2412-2539`) does not wire `.on_progress = touchActiveQueryDeadlineWatchdog`, unlike gRPC (`:1774/1834/1863/1882`). Long queries on QUIC will therefore hit `timeout_secs` even while making real progress. This is a separate bug, pre-existing; pinned red by `test_deadline_watchdog_quic_progress_followup.sh` (opt-in) until closed.

## E) Git

- Branch: `main`.
- Commits landed this session:
  - `7956b93f` — `test: add reproduction for deadlineWatchdog UAF (#746)` (tests + new module `src/cli/query_deadline.zig` + triage/evidence docs)
  - `40b03334` — `fix: join watchdog thread in QueryDeadlineState.finish (#746)`
- Pushed ref: `origin/main` == local `HEAD` == `40b0333477c20d40592fef43eed6f46f6a51f5eb`.
- Closed: GitLab issue #746.
- Opened: follow-up issue for the QUIC `.on_progress` wiring (see section D).
- Blockers: none.

## Artifacts

- `docs/audit/bugfix-deadline-watchdog-triage.md`
- `docs/audit/bugfix-deadline-watchdog-tests.md`
- `docs/audit/bugfix-deadline-watchdog-report.md` (this file)
- `src/cli/query_deadline.zig` (extracted + fixed module)
- `tests/test_query_deadline_state_lifetime.zig`
- `tests/test_deadline_watchdog_false_positive.sh`
- `tests/test_deadline_watchdog_quic_progress_followup.sh`
