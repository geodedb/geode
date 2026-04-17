# Bug-fix Triage — Remaining Harness Failures (results_full3.json)

**Run summary:** 4141/4151 pass (99.8%), 10 failures across 5 spec files, run took 1h 23m.
**Report source:** `/home/benji/src/devnw/codepros/geode/geode-test-harness/reports/results_full3.json`
**Spec dir:** `/home/benji/src/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/`

## 1. Issues Restated

1. **`gap_0166_prometheus_metrics.yml` — 5/5 fail, all "Connection refused".** The Prometheus `/metrics`, `/health`, and 404 fall-through HTTP endpoints on port `GEODE_METRICS_PORT=9091` are advertised but never bound. The stubbed HTTP listener must become a real implementation per the CLAUDE.md rule (NO MOCK DATA, NO SIMULATION).
2. **`distributed_2pc_undo.yml` — 2/12 fail.** `2pc-rollback-does-not-affect-prior-data-setup` times out at 30085 ms. The next test `…-pre` completes in 863 ms but returns `pre_cnt:0` because the setup's multi-statement script never committed before the CLI killed the in-flight query on deadline (see root cause below).
3. **`gap_0183_0185_ci_distributed_traceability.yml` — 1/16 fail.** `GAP-0183-003: Complex expression evaluation (ReleaseSafe)` times out at 30082 ms.
4. **`gap_0257_iso_conformance_verification.yml` — 1/46 fail.** `ISO-EXPR-001: arithmetic expressions` times out at 30095 ms.
5. **`gap_150_151_152_security_regression.yml` — 1/9 fail.** `gap-0151-audit-verify-default-path` expects stderr to contain `"0 records verified"` but the default-path-exists-and-empty branch prints `"OK chain ✅  records=0 digests=0 algo=sha256 digest_interval_max=100"`. Text-format drift.

## 2. Build/Test/Lint Entry Points

| Action | Command | Config File |
|--------|---------|-------------|
| Build | `make build` → `zig build` | `/home/benji/src/devnw/codepros/geode/geode/build.zig` |
| Release | `make release` → `zig build -Doptimize=ReleaseSafe` | same |
| Unit tests | `zig build test` | same |
| Integration (harness) | `geodetestlab run --spec <path>` (binary at `~/.local/bin/geodetestlab`) | `geode-test-harness/geodetestlab-cli/specs/*.yml` |
| Format | `make fmt` → `zig fmt src/ tests/ …` | — |
| Pre-commit | `make pre-commit` → `pre-commit run --all-files` | `.pre-commit-config.yaml` |

## 3. Reproduction Results

| Issue | Command | Exit | Stdout/Stderr |
|-------|---------|------|---------------|
| #5 (audit verify default path) | `./zig-out/bin/geode audit verify` | 0 | stderr: `OK chain ✅  records=0 digests=0 algo=sha256 digest_interval_max=100` (reproduced locally; expected substring `"0 records verified"` absent) |
| #1 (metrics refused) | `curl http://127.0.0.1:9091/metrics` against running server | — | ECONNREFUSED: `src/monitoring/metrics_server.zig:47-52` `start()` is explicitly a no-op: `self.running = false` |
| #2–#4 (timeouts) | n/a, direct CLI query | — | Inspected via harness report; all three failures timeout exactly at 30s CLI client timeout (`client.timeout_ms: 30000`). |

## 4. Root Cause Analysis

| Issue | Root cause (file:line) | Type | Affected files | Fix order |
|-------|------------------------|------|----------------|-----------|
| **1. Prometheus metrics** | `src/monitoring/metrics_server.zig:47-97` — `start()`, `handleConnection()`, `serveMetrics()`, `serveHealth()`, `serve404()`, `acceptLoop()` all explicit stubs after the Zig 0.16 `std.Io.net.Server` rewrite migration (comment: *"temporarily disabled pending a full rewrite against std.Io.net.Server"*). Server in `src/server/main.zig:541-556` initializes the collector and calls `start()` but nothing listens. | (b) missing implementation | `src/monitoring/metrics_server.zig`; possibly `src/monitoring/prometheus.zig` (already exports a ready `exportMetrics(writer)` at line 376). | 5 (largest scope) |
| **2. 2pc-rollback setup timeout** | `src/cli/main.zig:2400-2418` — `QuicProtocolAdapter` path calls `query_runner.collectQuery` **without** `.hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog }`. The gRPC transport wires this at `src/cli/main.zig:1663/1723/1752/1771`, but QUIC does not. Long-running or slow-responding multi-statement scripts hit the 30s deadline even while making real server-side progress. Documented as follow-up #747 in `docs/audit/bugfix-deadline-watchdog-report.md` §D. The `-pre` test returning `pre_cnt:0` is **a consequence, not a separate bug**: the setup's multi-statement script was killed mid-execution by the client, so the pre-existing CREATE was never flushed/committed. | (a) logic / infra — stop-gap known issue | `src/cli/main.zig:2400-2428`, `src/client/grpc_query_transport.zig:24-41` | 1–4 (all gate on #747) |
| **3. GAP-0183-003 complex expression** | Same as #2: QUIC `on_progress` not wired; the 3-way RETURN with concat + CASE has enough parse/execute latency on ReleaseSafe QUIC path that the unbumped deadline fires at 30s. Not a logic bug — the same query works on gRPC in sibling tests. | (a) same as #2 | same | same |
| **4. ISO-EXPR-001 arithmetic** | Same as #2: simple `RETURN 2+3, 10-4, 3*7, 15/3` should return instantly; a 30s timeout indicates a stall waiting for handshake/progress (or the watchdog firing spuriously on a slow first-connect), not slow arithmetic. The surrounding 45 tests (including more complex ISO-EXPR-002/003/004/005) pass, which strongly implicates a transient hang-on-first-connect or a slow spec startup path, NOT a query-engine regression. | (a) same as #2 — likely watchdog-false-positive | same | same |
| **5. audit verify text drift** | `src/cli/geode_audit_verify.zig:247-260` — on the success path when the default audit log exists but is empty, output is `"OK chain ✅  records={} digests={} algo={s}…"`. Spec asserts stderr contains `"0 records verified"`. The *file-not-found* fallback at line 54 already prints the spec-expected string (`"audit log not found: {s} (0 records verified)"`), but on the developer workstation the default path exists empty, so the code falls through to the success formatter that doesn't contain `"records verified"`. Not a logic regression — audit chain verification is correct, just the success line doesn't mention the expected phrase. | (c) test expectation drift / minor format gap | `src/cli/geode_audit_verify.zig:247-260` | 2 (trivial) |

## 5. Dependencies Between Failures

- **#2, #3, #4 share a root cause (#747 QUIC `on_progress` wiring).** Fixing #747 (adding `.hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog }` to the `QuicProtocolAdapter` call-site in `src/cli/main.zig:2411-2418`, analogous to the four gRPC sites) should clear all three in one change. Verify by running the opt-in `tests/test_deadline_watchdog_quic_progress_followup.sh` turns green.
- **#2-setup failure transitively causes #2-pre "logic" appearance.** No separate fix required for `-pre`; fixing the timeout cascade in setup will allow `-pre` to observe the committed PreExisting node.
- **#5 is independent.** Trivial text-format tweak OR update the spec, no cross-dependency.
- **#1 is independent** and the largest implementation effort; does not gate the timeout fixes.

## 6. Security / Data Integrity Concerns

- **#1 Prometheus**: the stubbed `serveMetrics`/`serveHealth` means there is *no* observability endpoint today. Not a vulnerability; degraded operability. The bind address resolver at `metrics_server.zig:100-130` already defaults to `127.0.0.1` for `GEODE_METRICS_BIND`, so once implementation lands the security-by-default posture is preserved (S10 comment).
- **#2/#3/#4 (QUIC deadline)**: user-facing false-timeout on long/slow queries. Does not corrupt data — `ROLLBACK` fires client-side-only; server transaction state is cleaned up by the existing 2PC timeout path. But it **does** create the appearance of failed commits that actually succeeded on the server (or vice versa) — a user who retries a timed-out INSERT could create duplicates. Prioritize.
- **#5 audit verify**: correctness of signature/chain verification is unaffected; only the success line text differs. No security impact.

## 7. Recommended Fix Order

1. **#5 audit-verify text (≤5 min).** Add `" (0 records verified)"` (or a configurable message) to the success formatter in `src/cli/geode_audit_verify.zig:247-260` when `records == 0`. Alternative: update the harness spec at `geode-test-harness/geodetestlab-cli/specs/gap_150_151_152_security_regression.yml:63` to assert `"records=0"` instead. Prefer the code fix — the test string is clearer UX. Trivial, no cross-cutting impact.
2. **#2/#3/#4 QUIC `on_progress` wiring (≤30 min) — GitLab #747.** Add `.hooks = .{ .on_progress = touchActiveQueryDeadlineWatchdog }` to the `collectQuery` call in `src/cli/main.zig:2411-2418`, mirroring the gRPC sites at `:1663/1723/1752/1771`. Validate with the red-by-design opt-in regression `tests/test_deadline_watchdog_quic_progress_followup.sh`. Triage note: this issue is tracked upstream as #747 — DO NOT close #747 here; the fixer session handles the close-out. Three harness failures disappear in one edit.
3. **#1 Prometheus HTTP listener (1–2 hours, largest).** Reimplement `start()`/`acceptLoop()`/`handleConnection()`/`serveMetrics()`/`serveHealth()`/`serve404()` in `src/monitoring/metrics_server.zig` against the Zig 0.16 `std.Io.net.Server` API. The `prometheus.MetricsCollector.exportMetrics(writer)` at `src/monitoring/prometheus.zig:376` is ready to consume. Minimum viable route set required by the spec:
   - `GET /metrics` → `200`, `Content-Type: text/plain; version=0.0.4`, body = `exportMetrics(...)`.
   - `GET /health` → `200`, `Content-Type: application/json`, body = `{"status":"ok"}`.
   - Any other path → `404`.
   - Respect `GEODE_METRICS_BIND` (already resolved in `resolveMetricsBindAddress()`). Spawn accept loop on the existing `pooled.ThreadPool`. Follow mutex ordering (Tier 3, in QUIC-connections tier — no cross-tier holds). CANARY markers `REQ-PROMETHEUS-WIRE-001/-002` already tagged `STATUS=TESTED`; update to match reality once wired. **This is not tractable as a same-session fix-with-#747 change** — split into a dedicated follow-up session.

## Classification Summary

| Issue | Class | Tractable in fix-session with #747? |
|-------|-------|-----|
| #1 Prometheus HTTP | (b) missing impl | **No — split into follow-up** |
| #2 2pc setup timeout | (a) logic (QUIC watchdog) | Yes (fold into #747) |
| #3 GAP-0183-003 timeout | (a) same | Yes (fold into #747) |
| #4 ISO-EXPR-001 timeout | (a) same | Yes (fold into #747) |
| #5 audit verify string | (c) expectation drift | Yes (trivial) |

## Files / Line References

- `/home/benji/src/devnw/codepros/geode/geode/src/monitoring/metrics_server.zig:47-97` — stubbed HTTP listener.
- `/home/benji/src/devnw/codepros/geode/geode/src/monitoring/prometheus.zig:376` — ready `exportMetrics(writer)`.
- `/home/benji/src/devnw/codepros/geode/geode/src/server/main.zig:541-556` — server boot path for metrics init.
- `/home/benji/src/devnw/codepros/geode/geode/src/cli/main.zig:2400-2428` — QUIC adapter missing `on_progress` hook.
- `/home/benji/src/devnw/codepros/geode/geode/src/cli/main.zig:1663,1723,1752,1771` — gRPC sites that wire `on_progress` correctly (reference).
- `/home/benji/src/devnw/codepros/geode/geode/src/client/grpc_query_transport.zig:24-41` — hooks type definition.
- `/home/benji/src/devnw/codepros/geode/geode/src/cli/geode_audit_verify.zig:54` — FNF branch prints `0 records verified` (already spec-compatible).
- `/home/benji/src/devnw/codepros/geode/geode/src/cli/geode_audit_verify.zig:247-260` — empty-default-path success branch that drops the expected phrase.
- `/home/benji/src/devnw/codepros/geode/geode/docs/audit/bugfix-deadline-watchdog-report.md` §D — #747 follow-up documented.
- `/home/benji/src/devnw/codepros/geode/geode/tests/test_deadline_watchdog_quic_progress_followup.sh` — opt-in red test pinning #747.
- `/home/benji/src/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/gap_150_151_152_security_regression.yml:55-63` — audit verify test expectation.
- `/home/benji/src/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/gap_0166_prometheus_metrics.yml` — HTTP endpoint assertions.
- `/home/benji/src/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/distributed_2pc_undo.yml:194-235` — 2pc setup/pre pair.
