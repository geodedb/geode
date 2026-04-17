# Bug-fix Reproduction Tests — GitLab #749: Prometheus `/metrics` + `/health` HTTP Endpoints

**Scope:** Reproduction tests only. The fix (~180 LOC in `src/monitoring/metrics_server.zig`) is the next step.
**Triage source:** `docs/audit/bugfix-prometheus-http-triage.md`.
**Primary pin (unchanged):** `../geode-test-harness/geodetestlab-cli/specs/gap_0166_prometheus_metrics.yml` — already 5/5 red.
**Date:** 2026-04-16

---

## Test Plan

### Bug: `MetricsServer.start()` is a Zig 0.16 migration stub — never binds a TCP listener

`src/monitoring/metrics_server.zig:47-52` body in full:

```zig
pub fn start(self: *MetricsServer) !void {
    _ = resolveMetricsBindAddress();
    self.running = false;
}
```

Any HTTP probe against the configured `GEODE_METRICS_PORT` returns `ECONNREFUSED` at the kernel layer. Prometheus scrape and `/health` endpoints are dark.

---

#### Regression Test 1 — Runtime integration (shell)

- **Name:** `test_metrics_server_endpoints`
- **File:** `tests/test_metrics_server_endpoints.sh`
- **Harness:** real `./zig-out/bin/geode serve` binary, real curl, real TCP — no mocks.
- **Fixture:** bootstraps admin password `GeodeTestPassword123!`, allocates two free ports via Python, exports `GEODE_METRICS_PORT`.
- **Waits:** on the main QUIC UDP socket (via `ss -lun`), **not** on the metrics TCP port — waiting on the metrics port would mask the bug by stalling the whole startup budget.
- **Probes (all 4 must succeed post-fix; all 4 fail pre-fix with curl exit 7):**

  | # | Command | Expected (post-fix) | Current (pre-fix) |
  |---|---------|---------------------|-------------------|
  | A | `curl http://127.0.0.1:$PORT/metrics` | `200`, `Content-Type: text/plain*`, body contains `# HELP` + `# TYPE` | curl exit 7 (ECONNREFUSED) |
  | B | `curl http://127.0.0.1:$PORT/health` | `200`, body contains `ok` | curl exit 7 |
  | C | `curl -i http://127.0.0.1:$PORT/nonexistent` | status line matches `^HTTP/1\.[01] 404` | curl exit 7 |
  | D | `curl --resolve metrics.local:$PORT:127.0.0.1 http://metrics.local:$PORT/metrics` | `200`, body contains `# HELP` (proves Host-header independence) | curl exit 7 |

- **Cleanup:** `trap` kills the server PID and `rm -rf` the mktemp data dir on exit.

#### Regression Test 2 — Zig unit lifecycle

- **Name:** `test "MetricsServer.start binds a TCP listener (regression #749)"` + two sibling tests in the same file
- **File:** `tests/test_metrics_server_lifecycle.zig`
- **Build step:** `zig build test-metrics-server` (wired in `build.zig` lines around 1708–1723, pattern mirrors the deadline-watchdog test).
- **Allocator pattern:** follows `src/tools/cert_gen.zig:17-18` — local `std.Io.Threaded` via `std.heap.smp_allocator`, never the global-single-threaded `failing` allocator. Collector uses `std.heap.page_allocator` to avoid tripping the leak detector on an unrelated known-prod leak of `name`/`help` strings in `PrometheusExporter.deinit()` (outside #749 scope).
- **Hard timeout guarantee:** `std.Io.net.IpAddress.connect` in Zig 0.16 panics with `"TODO implement netConnectIpPosix with timeout"` when `ConnectOptions.timeout != .none`. Test uses non-blocking `std.os.linux.connect` + `std.posix.poll` with a 1000 ms budget (500 ms for the "listener went away" check). Even if a fix regresses into an infinite accept loop, CI reports red in <3 s.
- **Assertions:**
  1. After `start()`, `tryConnect(port, 1000)` succeeds. *Pre-fix: `error.ConnectionRefused`.*
  2. After `stop()`, `tryConnect(port, 500)` returns `error.ConnectionRefused` — catches a fix that leaks the listen fd.
  3. `start → stop → start → stop` cycle is idempotent (test harness rerun scenario).

---

## Test Execution (red, before fix)

### Shell test

```
$ bash tests/test_metrics_server_endpoints.sh ; echo EXIT=$?
[metrics-endpoints] booting geode serve on 127.0.0.1:36695 (metrics on :54059)
[metrics-endpoints] waiting for main UDP listen on :36695
[metrics-endpoints] GET /metrics → curl_rc=7 body_bytes=91
FAIL(A): curl exit=7 for /metrics. Pre-fix symptom: ECONNREFUSED.
[metrics-endpoints] GET /health  → curl_rc=7 body='curl: (7) Failed to connect to 127.0.0.1 port 54059 after 0 ms: Could not connect to server'
FAIL(B): curl exit=7 for /health. Pre-fix symptom: ECONNREFUSED.
[metrics-endpoints] GET /nonexistent → curl_rc=7
FAIL(C): curl exit=7 for /nonexistent. Pre-fix symptom: ECONNREFUSED.
[metrics-endpoints] GET /metrics (Host=metrics.local) → curl_rc=7 body_bytes=95
FAIL(D): curl exit=7 with Host=metrics.local. Pre-fix symptom: ECONNREFUSED.

RESULT: 4 probe failure(s). Pre-fix: expected 4+ failures because
        MetricsServer.start() is a stub and no TCP listener binds.
EXIT=1
```

### Zig unit test

```
$ zig build test-metrics-server
error: 'test_metrics_server_lifecycle.test.MetricsServer.start binds a TCP listener (regression #749)' failed:
       REGRESSION #749: MetricsServer.start() did NOT bind 127.0.0.1:39460 — connect failed with ConnectionRefused.
       Pre-fix symptom: Prometheus scrape + /health endpoint are dark.

error: 'test_metrics_server_lifecycle.test.MetricsServer.stop closes the listener (regression #749)' failed:
       REGRESSION #749: server never bound before stop() — ConnectionRefused.

error: 'test_metrics_server_lifecycle.test.MetricsServer start/stop/start is idempotent (regression #749)' failed:
       REGRESSION #749: server never bound before stop() — ConnectionRefused.
       (second start attempt; same root cause — start() never opens a socket)

Build Summary: 2/4 steps succeeded (1 failed); 0/3 tests passed (3 failed)
error: the following build command failed with exit code 1
```

### Summary table

| Test | Category | Status (pre-fix) | Exit |
|------|----------|-------------------|------|
| `tests/test_metrics_server_endpoints.sh` — probe A (`/metrics`) | Integration | **FAIL** (curl exit 7 ECONNREFUSED) | shell exit 1 |
| `tests/test_metrics_server_endpoints.sh` — probe B (`/health`) | Integration | **FAIL** (curl exit 7) | (as above) |
| `tests/test_metrics_server_endpoints.sh` — probe C (`/nonexistent`) | Integration | **FAIL** (curl exit 7) | (as above) |
| `tests/test_metrics_server_endpoints.sh` — probe D (Host=metrics.local) | Integration | **FAIL** (curl exit 7) | (as above) |
| `test "MetricsServer.start binds a TCP listener"` | Unit (Zig) | **FAIL** (`error.MetricsListenerNotBound`) | `zig build` exit 1 |
| `test "MetricsServer.stop closes the listener"` | Unit (Zig) | **FAIL** (`error.MetricsListenerNotBound`) | (as above) |
| `test "MetricsServer start/stop/start is idempotent"` | Unit (Zig) | **FAIL** (`error.MetricsListenerNotBound`) | (as above) |
| `gap_0166_prometheus_metrics.yml` (spec pin, unchanged) | Harness | **FAIL 5/5** | harness non-zero |

**All 8 failing assertions are deterministic** — every run reproduces the same `ConnectionRefused` from a kernel that has no listener on the metrics port.

---

## Files Added (tests-only commit)

- `tests/test_metrics_server_endpoints.sh` — shell integration reproducer (4 HTTP probes).
- `tests/test_metrics_server_lifecycle.zig` — Zig unit lifecycle reproducer (3 tests).
- `build.zig` — new `test-metrics-server` step that wires `tests/test_metrics_server_lifecycle.zig` (follows the deadline-watchdog pattern added for issue #746).
- `docs/audit/bugfix-prometheus-http-tests.md` — this file.

No changes to `src/monitoring/metrics_server.zig`, `src/monitoring/prometheus.zig`, or `src/server/main.zig` — those are the fix surface and stay untouched until the follow-up commit.
