# Bugfix Triage: Spurious `deadlineWatchdog` Timeout (GitLab #746)

## 1. Issues Restated

1. `geode query` prints its correct JSON response to stdout, then immediately emits `Error: query timed out after N seconds` on stderr and exits with a non-zero code.
2. Wall-clock elapsed for the whole process is ~867 ms against a local server, so no real deadline has been tripped — the watchdog is firing spuriously.
3. The fire happens regardless of `--timeout` value (reproduced at 2, 10, 60 — all fire at ~867 ms).

## 2. Build / Test / Lint Entry Points

| Action     | Command                                             | Config File       |
|------------|-----------------------------------------------------|-------------------|
| Build      | `zig build install`                                 | `build.zig`       |
| Test       | `zig build test` / `python3 scripts/test/extended_test_runner.py` | `build.zig` |
| Repro      | `./tests/test_quic_handshake_stall_regression.sh`   | shell script      |
| Format     | `make fmt`                                          | `Makefile`        |
| Pre-commit | `make pre-commit`                                   | `.pre-commit-config.yaml` |

## 3. Reproduction Results

| Issue | Command | Exit | Elapsed | Error Summary |
|-------|---------|------|---------|---------------|
| #746  | `geode query --server 127.0.0.1:58700 --insecure-tls-skip-verify -U geode -P ... --timeout 10 "RETURN 1"` | 1 | 867 ms | stdout: correct JSON; stderr: `Error: query timed out after 10 seconds` |
| #746  | same, `--timeout 2`  | 1 | 867 ms | stderr: `...after 2 seconds`  |
| #746  | same, `--timeout 60` | 1 | 868 ms | stderr: `...after 60 seconds` |

Evidence of the underlying failure captured via temporary instrumentation in `/home/benji/src/devnw/codepros/geode/geode/src/cli/main.zig` (reverted after diagnosis):

```
TRIAGE init: now_ns=1776439536162318161 i64_cast=1776439536162318161        <- init() computed correctly
TRIAGE post-init-copy: last_progress_ns=1776439536162318161                  <- cmdQuery's stack var holds correct value
  addr_state=QueryDeadlineState@7ffdcd4a2928
TRIAGE post-submit:    last_progress_ns=1776439536162318161                  <- still correct just after pool.submit()
TRIAGE watchdog fire:  now_ns=1776439536963982424
                        last_progress_ns=140139352909432                      <- **garbage**; stack has been overwritten
                        timeout_ns=10000000000
                        diff=1776299397611072992                               <- ~1.78e18 ns > timeout_ns -> fires
Error: query timed out after 10 seconds
```

`0x7F7547F067B8 == 140139352909432` — this is a classic heap-region pointer-sized value that has replaced the stack slot `7ffdcd4a2928` after `cmdQuery` returned.

## 4. Root Cause

Classification: **(b) watchdog lifetime bug — use-after-free on a stack-allocated `QueryDeadlineState`.**

### Mechanism (single-query path)

`src/cli/main.zig:1525-1532`:

```zig
var query_deadline_state = QueryDeadlineState.init();     // stack-allocated
active_query_deadline_state = &query_deadline_state;
defer {
    query_deadline_state.finish();                         // sets done=true
    active_query_deadline_state = null;
}
startDeadlineWatchdogTask(allocator, timeout_secs, &query_deadline_state);
```

The watchdog thread, via `runDeadlineWatchdogTask`, runs `deadlineWatchdog` (`src/cli/main.zig:810-842`) which loops on 100 ms `nanosleep` steps and reads `state.done` / `state.last_progress_ns` through the raw `*QueryDeadlineState` pointer.

Happy path:

1. `collectQuery` returns in ~800 ms with a successful result.
2. `executeQueryOnConnection`'s `defer finishActiveQueryDeadlineWatchdog()` (`src/cli/main.zig:2531`) runs → sets `done=true` **but does not wait for the watchdog to observe it.**
3. `cmdQuery` returns. Its defers (1528-1531) run, then the function pops its stack frame.
4. Subsequent teardown (`gpa.deinit`, etc.) reuses the same stack region, overwriting the bytes that held `query_deadline_state.last_progress_ns` with whatever the next frame stores — in this build, a heap pointer.
5. The watchdog thread, mid-`nanosleep`, wakes up. The `if (state.done.load(.acquire)) return;` check reads the `done` byte from the overwritten slot; it happens to read 0 (the race) and the watchdog proceeds.
6. It loads `state.last_progress_ns` — now `140139352909432` — and computes `now_ns − 140139352909432 ≈ 1.78 × 10¹⁸ ns`, trivially exceeding any `timeout_ns`.
7. Watchdog writes "Error: query timed out after N seconds" and calls `std.process.exit(general_error)` — beating `main`'s normal return.

### Why the earlier fix for the `.touch()` hook doesn't help here

The QUIC path (`executeQueryOnConnection`, `src/cli/main.zig:2412-2539`) does **not** pass `.on_progress = touchActiveQueryDeadlineWatchdog` into its send/recv — only the gRPC path does (four call sites at lines 1774, 1834, 1863, 1882). That would matter if a genuinely long query needed progress keep-alives, but the current bug reproduces with `last_progress_ns` correctly initialized and no touches needed — the spurious fire is 100% post-return memory corruption, not a stale-progress condition. Missing `.touch()` on QUIC is a **real but secondary bug** that will surface once the lifetime bug is fixed and a query actually runs longer than `timeout_secs`.

### Why `finish()` isn't a real shutdown

`finish()` only sets `done = true`. It never **joins** the watchdog thread nor waits for it to observe `done=true`. The 100 ms `nanosleep` between checks is wall-clock; if main returns before the watchdog's next tick (which it does, at ~867 ms with a 100 ms watchdog tick), the watchdog reads freed stack memory.

## 5. Affected Files

| File | Lines | What |
|------|-------|------|
| `src/cli/main.zig` | 726-770  | `QueryDeadlineState` struct + `finish()` that only sets a flag, never joins |
| `src/cli/main.zig` | 791-848  | `startDeadlineWatchdogTask` (submit, no handle kept) + `deadlineWatchdog` loop |
| `src/cli/main.zig` | 1476-1482 | Chunked-query watchdog (same stack-lifetime bug) |
| `src/cli/main.zig` | 1525-1532 | Single-query watchdog (primary repro site) |
| `src/cli/main.zig` | 2412-2539 | `executeQueryOnConnection` — missing `.on_progress` hooks (secondary) |

## 6. Dependencies Between Failures

- Lifetime bug (primary) masks any other timing behaviour — fix first.
- Missing `.touch()` hooks on the QUIC path (secondary) only becomes observable on queries longer than `--timeout`. Fix after the lifetime bug so it can be tested with a real slow query.

## 7. Security / Data-Integrity Concerns

- No data-integrity concern — query results are fully produced on stdout before the spurious error.
- Operational concern: any caller that treats non-zero exit as "query failed" (CI pipelines, geodetestlab harness, shell scripts using `set -e`) will incorrectly report successful queries as failures. This is the mechanism by which `test_quic_handshake_stall_regression.sh` and downstream suites currently show red.
- Minor: the watchdog thread reads freed stack memory — technically UB. In release builds this is usually benign because the pool thread isn't writing the stack, but a more adversarial layout could cause reads of sensitive data.

## 8. Recommended Fix Site — Narrow Prediction

**Single function to patch: the `QueryDeadlineState` + watchdog lifetime contract, centered in `src/cli/main.zig` around lines 726-848 and both call sites (1476, 1526).**

Two acceptable shapes, picking one:

1. **Heap-allocate + watchdog owns** (smallest diff): `startDeadlineWatchdogTask` takes ownership of a heap-allocated `*QueryDeadlineState`. `finish()` becomes a signal-and-join that waits for the watchdog's next tick to observe `done=true` (or a 1-shot eventfd/condvar). The struct is freed by the watchdog thread after it returns. Remove `var query_deadline_state = QueryDeadlineState.init()` on the stack.
2. **Join in defer** (slightly larger): keep stack allocation, but `startDeadlineWatchdogTask` returns a handle; the defer in `cmdQuery` calls `finish()` **and then joins** the handle before the stack frame unwinds. Requires `pooled.ThreadPool.submit` to expose a join primitive (it already has `wait(handle)` via `submitTask`).

Both fixes must be applied to **both** watchdog call sites (lines 1476 and 1526). The chunked path (1476) has the same bug — the `chunked_deadline_state` is also a stack local.

Secondary follow-up (same file, not part of the minimal fix): wire `touchActiveQueryDeadlineWatchdog` into the QUIC send/recv path — the `QuicProtocolAdapter` in `executeQueryOnConnection` (lines 2496-2520) and the handshake `writeProtoMessageViaZigClient` / `readProtoMessageViaZigClient` calls that bookend it. Without this, post-fix a slow query will still false-timeout.

## 9. Other Commands Sharing This Code

Audited via `grep startDeadlineWatchdog|QueryDeadlineState\.init`:

- `cmdQuery` only. `cmdShell`, `cmdAuth`, `cmdFLE`, `cmdLsp`, `cmdServe` do not spawn a `deadlineWatchdog`, so they are **not** affected by this specific bug.
- `finishActiveQueryDeadlineWatchdog` is called from `executeQueryOnGrpc` (gRPC path, line 1878) and `executeQueryOnConnection` (QUIC path, line 2531) — both reachable only through `cmdQuery`.
