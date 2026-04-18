# Reproduction Tests: #751 — CLI session admission starvation

- **Status:** failing-red before fix; tests committed as proof of coverage.
- **Date:** 2026-04-16
- **Triage:** [docs/audit/bugfix-session-contention-triage.md](./bugfix-session-contention-triage.md)
- **Branch:** main @ commit pre-fix.

## Summary

Three tests pin the #751 admission-lane starvation contract from three
independent angles. Each is designed to be deterministically RED on the
current binary and GREEN once the fix lands.

## Tests Written

### 1. Runtime integration — `tests/test_session_admission_parallelism.sh`

Boots `geode serve`, spawns 8 concurrent `CREATE (:W {i: $i}) RETURN count(*)`
CLI writers, then measures 10 trivial `RETURN 1 AS x` queries with a 3 s
client deadline. Asserts every measurement completes in < 2000 ms.

- **Pre-fix evidence (this run):** 10/10 failed. All runs clipped at the
  `--timeout 3` client deadline (~3070 ms, RC=1). Matches the triage
  matrix: `RETURN 1` under 8 writers = ~6 s if the client allowed, bounded
  by the deadline when it doesn't.
- **Exit code:** `1`.
- **Summary line:** `min=3067ms max=3073ms over_bar=10/10 (bar=2000ms)`.

### 2. Source audit — `tests/test_thread_pool_admission_lane.sh`

Greps `src/transport/thread_pool.zig` and `src/server/main.zig` for the
fix shape required by the triage:

1. `pub fn submitDefault` exists in `thread_pool.zig`.
2. That function body routes work to `.lane = .default`.
3. `main.zig` accept loop calls `pool.submitDefault(...)`.

- **Pre-fix evidence:** assertions 1 and 3 fail. `submitDefault` does
  not exist in the pool wrapper; `main.zig:900` still calls `pool.submit(...)`.
- **Exit code:** `1`.

### 3. Zig unit test — `tests/test_thread_pool_lane_parallelism.zig`

Three sub-tests wired under `zig build test-thread-pool-lane-parallelism`:

1. `submitDefault: API exists on ThreadPool` — `@hasDecl(ThreadPool, "submitDefault")`.
2. `submitDefault: 8-way parallelism via default-lane workers` —
   submits 8 barrier-style tasks and observes max-concurrency >= 8.
3. `submitBlocking: blocking lane remains 1-wide (no regression)` —
   submits 4 tasks via the blocking lane and observes max-concurrency == 1.

- **Pre-fix evidence:** test 1 FAILS with diagnostic
  `MISSING: ThreadPool.submitDefault — #751 fix not applied.`
  Test 2 SKIPS (because `@hasDecl` short-circuits before referencing the
  missing method — test 2 reports `error.SkipZigTest`). Test 3 PASSES
  (blocking lane is already 1-wide, which is correct; the fix must
  preserve this).
- **Exit code:** `1` (1 pass, 1 skip, 1 fail of 3 total).

## Red-State Evidence Summary

| Test | File | Exit | Signal |
|------|------|------|--------|
| Runtime integration | `tests/test_session_admission_parallelism.sh` | 1 | 10/10 SLOW, min=3067ms, max=3073ms |
| Source audit | `tests/test_thread_pool_admission_lane.sh` | 1 | `submitDefault` missing in pool wrapper + main.zig |
| Zig unit | `zig build test-thread-pool-lane-parallelism` | 1 | 1 pass, 1 skip, 1 fail (API absence) |

## Why these three and not more

- Test 1 catches the *observable* regression: a real CLI, real server, real
  QUIC handshake, real client deadline.
- Test 2 catches the *structural* regression: a future refactor that
  reverts the lane routing would fail this even without running the full
  server.
- Test 3 catches the *API* regression: the pool wrapper itself must expose
  a non-blocking-lane entry point and default-lane submissions must
  actually parallelise; test 3 proves both via a raw pool (no server)
  and uses `@hasDecl` as a build-time gate so pre-fix fails cleanly.

## Build wiring

`build.zig` change, inserted next to the #749 / #746 regression blocks
(~L1708):

```zig
// GitLab #751: connection-admission thread-pool lane regression
const thread_pool_lane_tests = b.addTest(.{ ... });
thread_pool_lane_tests.root_module.addImport("transport/thread_pool", thread_pool_mod);
const run_thread_pool_lane_tests = b.addRunArtifact(thread_pool_lane_tests);
const thread_pool_lane_test_step = b.step("test-thread-pool-lane-parallelism", ...);
thread_pool_lane_test_step.dependOn(&run_thread_pool_lane_tests.step);
test_step.dependOn(&thread_pool_lane_tests.step);
```

## Next Step

Fix per the triage's Option 1 (add `submitDefault` in
`src/transport/thread_pool.zig`; switch the `pool.submit(...)` at
`src/server/main.zig:900` to call it). After the fix, all three tests
should flip to PASS with no assertion changes.
