# Bug-fix Report — Harness Failures (#747 QUIC on_progress + #748 audit-verify phrase)

Companion to `docs/audit/bugfix-harness-failures-triage.md` and `docs/audit/bugfix-harness-failures-tests.md`. Scope: triage issues #2/#3/#4 (rolled up as GitLab #747) and #5 (GitLab #748). Triage issue #1 (Prometheus `/metrics` HTTP listener) is deferred to its own follow-up — see §D.

## A) Summary

Two harness gaps closed in this session:

- **#747 — QUIC `executeQueryOnConnection` missing `.on_progress` wiring.** The gRPC transport path wires `.hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog }` at four sites in `src/cli/main.zig`; the QUIC path at `:2411-2418` did not, so `last_progress_ns` stayed pinned at query start. Long QUIC queries false-timed-out at `--timeout` seconds even while the server was actively streaming frames back. Fix adds the one-line hook to the `collectQuery` call inside the `QuicProtocolAdapter` path. This single fix clears three harness failures (one timeout in each of `distributed_2pc_undo`, `gap_0183_0185_ci_distributed_traceability`, `gap_0257_iso_conformance_verification`).
- **#748 — `geode audit verify` empty-file success formatter dropped the `"0 records verified"` phrase.** The `FileNotFound` branch at `src/cli/geode_audit_verify.zig:54` already emitted the phrase, but when the default audit log exists and is empty the success formatter at `:247-260` printed only `"OK chain ✅  records=0 digests=0 algo=sha256 digest_interval_max=100"`. Fix appends `" (0 records verified)"` to the success line when `records == 0`, matching the FileNotFound branch and the harness spec expectation.

No functional regressions: `zig build test` remains 1059/1059 pass before and after.

## B) Evidence

| Check | Command | Result |
|---|---|---|
| Build | `zig build` | exit 0 |
| Tests (full) | `zig build test` | exit 0 — 1059/1059, no regression |
| Format | `zig fmt --check src/ tests/ tools/ benchmarks/ scripts/ build.zig` | exit 0 |
| Pre-commit | `pre-commit run --all-files` | 27/27 hooks green |
| Pre-push hooks (enforced by push) | `zig build`, `cross-compile`, `zig build test`, `no-feature-flags`, `CANARY lint`, `CANARY verify`, `status.csv sync`, `MATCH ops campaign`, `canaryscan GAP verify` | all PASS |
| Push | `git push origin main` | `a2b4c21f..38e2d6dd  main -> main` |
| Sync | `git fetch && git rev-parse HEAD origin/main` | `38e2d6dd02261eb9a08c0631e45eb8c777778545` (local == origin) |

## C) Red→Green Scorecard (from fixer)

| Test | Pre-fix | Post-fix |
|---|---|---|
| `tests/test_deadline_watchdog_quic_progress_followup.sh` (GEODE_RUN_FOLLOWUP=1) | FAIL | PASS |
| `tests/test_quic_long_query_no_false_timeout.sh` | FAIL (5073 ms timeout) | PASS (5789 ms clean) |
| `tests/test_audit_verify_empty_file_phrase.sh` | FAIL (missing phrase) | PASS |
| `geodetestlab-cli/specs/gap_0257_iso_conformance_verification.yml` | 45/46 | 46/46 |
| `geodetestlab-cli/specs/gap_150_151_152_security_regression.yml` | 8/9 | 9/9 |
| `geodetestlab-cli/specs/gap_0183_0185_ci_distributed_traceability.yml` | 15/16 | 16/16 |
| `zig build test` baseline | 1059/1059 | 1059/1059 (no regression) |

Three harness specs now at 100%; 1059-test unit suite unchanged.

## D) Risks & Deferred Work

- **#747 fix is minimal and symmetric with gRPC.** The hook pointer `touchActiveQueryDeadlineWatchdog` is exactly what the four gRPC call-sites already pass (`src/cli/main.zig:1663/1723/1752/1771`). The watchdog itself has no UAF since #746 closed that class of defect. No new mutex ordering, no new threads, no new lifetime concerns. Worst case if watchdog logic changes upstream: parity with gRPC is trivial to restore by touching one more line.
- **#748 fix is a string append, no control-flow change.** Audit chain/signature correctness is unaffected; only the success-line text now matches the FileNotFound branch and the harness spec substring.
- **CLOSED — Prometheus `/metrics` + `/health` HTTP listener (GitLab #749).** Resolved 2026-04-16 by commit `838f755a` (`fix: real HTTP /metrics + /health listener in metrics_server (#749)`) plus reproducer commit `c6dbfaee`. `MetricsServer.start()` now builds a local `std.Io.Threaded` (smp_allocator, mirroring `src/tools/cert_gen.zig:17-18`), calls `std.Io.net.IpAddress.listen()`, and spawns a single accept thread; `stop()` closes the listener, joins, and deinits the Threaded backend. Minimal HTTP parser routes `GET /metrics` → 200 `text/plain; version=0.0.4` + `collector.exportMetrics()` body; `GET /health` → 200 `application/json {"status":"ok"}`; everything else → 404. Bind default (`127.0.0.1`) and `GEODE_METRICS_BIND` override untouched. Regression cover: `tests/test_metrics_server_lifecycle.zig` (3/3) + `tests/test_metrics_server_endpoints.sh` (4/4 probes) + harness `gap_0166_prometheus_metrics.yml` (5/5). See `docs/audit/bugfix-prometheus-http-report.md` for full evidence.

## E) Git & Issues

- **Branch:** `main`
- **Commits landed this session (all pushed):**
  - `c446c4ff` — `test: add reproduction for long-query false-timeout (#747) + audit-verify empty-file phrase (#748)`
  - `eb267a68` — `fix: wire on_progress to QUIC executeQueryOnConnection (#747)`
  - `38e2d6dd` — `fix: emit "records verified" phrase in audit-verify empty-file branch (#748)`
- **Pushed ref:** `origin/main` == local `HEAD` == `38e2d6dd02261eb9a08c0631e45eb8c777778545`
- **Closed this session:** GitLab #747 (QUIC `on_progress` wiring), GitLab #748 (audit-verify empty-file phrase)
- **Opened this session:** GitLab #749 — "Implement Prometheus /metrics and /health HTTP endpoints in metrics_server (replace Zig 0.16 stub)"
- **Blockers:** none

## Artifacts

- `docs/audit/bugfix-harness-failures-triage.md`
- `docs/audit/bugfix-harness-failures-tests.md`
- `docs/audit/bugfix-harness-failures-report.md` (this file)
- `src/cli/main.zig` (QUIC `on_progress` wiring at `:2411-2418`)
- `src/cli/geode_audit_verify.zig` (empty-file success formatter at `:247-260`)
- `tests/test_deadline_watchdog_quic_progress_followup.sh`
- `tests/test_quic_long_query_no_false_timeout.sh`
- `tests/test_audit_verify_empty_file_phrase.sh`
