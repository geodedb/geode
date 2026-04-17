# deadlineWatchdog UAF — Reproduction Tests

Failing reproduction tests for the primary defect described in
[bugfix-deadline-watchdog-triage.md](./bugfix-deadline-watchdog-triage.md)
(GitLab issue #746). The secondary QUIC `.on_progress` wiring bug is pinned
as a follow-up test that does **not** block the primary red→green cycle.

All primary tests must FAIL on the current tree (evidence below) and must
PASS once `QueryDeadlineState.finish()` joins its watchdog thread.

## Summary Table

| # | Test | File | Category | Scope | Pre-fix outcome |
|---|------|------|----------|-------|-----------------|
| 1 | `test_deadline_watchdog_false_positive.sh` | `tests/test_deadline_watchdog_false_positive.sh` | End-to-end regression (real `geode serve` + `geode query`, real UDP, real QUIC+TLS) | Primary defect — visible symptom on stderr | exit=1, stderr has `Error: query timed out after 10 seconds` after a successful stdout response, elapsed=864ms |
| 2 | `test_query_deadline_state_lifetime.zig` | `tests/test_query_deadline_state_lifetime.zig` | Unit regression (calls the real `startDeadlineWatchdogTask` against a heap-backed `QueryDeadlineState`) | Primary defect — `finish()` must join the watchdog | FAIL (`error.WatchdogNotJoined` — watchdog tick_count advanced from 2 → 3 after `finish()` returned) |
| 3 | `test_deadline_watchdog_quic_progress_followup.sh` | `tests/test_deadline_watchdog_quic_progress_followup.sh` | Follow-up source audit (grep for `on_progress` in `QuicProtocolAdapter`) | Secondary defect — missing progress hook on the QUIC path | Skipped by default; `GEODE_RUN_FOLLOWUP=1` forces FAIL until the hook is wired |

## Pre-fix extraction for unit-test linkage

The triage calls for exposing `QueryDeadlineState + startDeadlineWatchdogTask

+ deadlineWatchdog` minimally so a unit test can exercise them. Rather than
bulk-publishing internals of `src/cli/main.zig`, those symbols were moved to a
small new module`src/cli/query_deadline.zig` that imports only `std` +
`transport/thread_pool`.`src/cli/main.zig` now imports the new module and
aliases the public names; the two `cmdQuery` call sites (chunked at `:1366`,
single-query at`:1416`) continue to use the types unchanged. The unit test
links directly against the extracted module via`b.createModule` wired in
`build.zig` under the new `test-deadline-watchdog` step.

A single-field observability hook `tick_count: std.atomic.Value(u64)` was
added to `QueryDeadlineState`. The watchdog bumps it once per 100 ms loop
iteration (see `deadlineWatchdog` in `src/cli/query_deadline.zig`). Production
code paths do not read the field — it exists solely so the unit test can
assert "after `finish()` returns, the counter stops advancing."

## Evidence — Both Primary Tests FAIL Before Fix

### Test 1 — Shell end-to-end

```
$ bash tests/test_deadline_watchdog_false_positive.sh
[watchdog-false-positive] starting geode serve on 127.0.0.1:53279
[watchdog-false-positive] server listening; issuing trivial RETURN 1 with --timeout 10
[watchdog-false-positive] client exit=1 elapsed_ms=864
[watchdog-false-positive] client stdout:
  | {"status_class":"00000","ordered":false,"order_keys":[],"columns":[{"name":"x","type":"INTEGER"}],"rows":[{"x":1}],"additional_statuses":[],"flagger_findings":["I:PropertyOrderingEnabled","U:NullsFirstPolicy"]}
[watchdog-false-positive] client stderr:
  | Error: query timed out after 10 seconds
FAIL: client exit=1 (expected 0). Pre-fix symptom: spurious watchdog exit(1).
FAIL: stderr contains 'query timed out' after a successful query — #746 regression.
$ echo $?
1
```

**What the failure proves:** a real localhost `RETURN 1` completes in 864 ms
and produces a correct JSON response on stdout — then the watchdog thread,
still alive after `cmdQuery` returned, reads the reused stack slot, sees a
garbage `last_progress_ns`, computes `now - garbage >> 10 s`, prints the
error on stderr, and calls `std.process.exit(1)`. The wall-clock (864 ms) is
well under the `--timeout 10` budget, so the timeout "firing" is entirely
spurious.

### Test 2 — Zig unit test

```
$ zig build test-deadline-watchdog
test-deadline-watchdog
+- run test 1 pass, 1 fail (2 total)
error: 'test_query_deadline_state_lifetime.test.QueryDeadlineState.finish joins the watchdog thread (regression #746)' failed:
       REGRESSION #746: watchdog kept ticking after finish() returned.
         ticks_before_finish=2 ticks_at_finish_return=2 ticks_after_wait=3
         finish() did NOT join the watchdog thread.
       tests/test_query_deadline_state_lifetime.zig:121:9: 0x125fd68 in test.QueryDeadlineState.finish joins the watchdog thread (regression #746) (test_query_deadline_state_lifetime.zig)
               return error.WatchdogNotJoined;
Build Summary: 2/4 steps succeeded (1 failed); 1/2 tests passed (1 failed)
```

**What the failure proves:** against a heap-backed `QueryDeadlineState`, the
watchdog's `tick_count` went `2 → 2` across the `finish()` call (= finish()
returned immediately, watchdog still mid-nanosleep) and then advanced to `3`
during the 300 ms observation window. In production, that "one more tick"
after `finish()` is precisely when the watchdog reads the freed stack slot
and mis-fires. The edge-case sibling test (`finish is safe to call before
the watchdog takes its first tick`) passes — the bug needs the watchdog to
already be mid-cycle to manifest.

## Follow-up — QUIC `.on_progress` (secondary bug, not blocking)

```
$ bash tests/test_deadline_watchdog_quic_progress_followup.sh
SKIP: follow-up test for QUIC .on_progress — set GEODE_RUN_FOLLOWUP=1 to run
$ GEODE_RUN_FOLLOWUP=1 bash tests/test_deadline_watchdog_quic_progress_followup.sh
FAIL: src/cli/main.zig: QuicProtocolAdapter block does NOT wire .on_progress.
      Secondary bug from #746 triage is still open.
```

Source-grep audit of the `QuicProtocolAdapter` block in
`executeQueryOnConnection` (`src/cli/main.zig:2385..2410`). It does not wire
`.on_progress = touchActiveQueryDeadlineWatchdog`, while the gRPC path does
so at four call sites (`:1663 :1723 :1752 :1771`). Skipped by default so
the pre-fix #746 test run does not depend on this. Once the lifetime fix
lands, this test is the right place to drive the follow-up patch.

## How to Run

```bash
cd /home/benji/src/devnw/codepros/geode/geode

# 1 — end-to-end shell regression
bash tests/test_deadline_watchdog_false_positive.sh

# 2 — Zig unit regression
zig build test-deadline-watchdog

# 3 — secondary QUIC progress-hook audit (opt-in)
GEODE_RUN_FOLLOWUP=1 bash tests/test_deadline_watchdog_quic_progress_followup.sh
```

## Files Added / Modified

| File | Change |
|------|--------|
| `src/cli/query_deadline.zig` | **NEW** — extracted `QueryDeadlineState` + watchdog entry points; added `tick_count` liveness hook |
| `src/cli/main.zig` | Replaced inline watchdog definitions with imports from `query_deadline.zig`; updated `active_query_deadline_state` references at the two `cmdQuery` call sites |
| `tests/test_query_deadline_state_lifetime.zig` | **NEW** — Zig unit regression |
| `tests/test_deadline_watchdog_false_positive.sh` | **NEW** — end-to-end shell regression |
| `tests/test_deadline_watchdog_quic_progress_followup.sh` | **NEW** — secondary defect source-audit (skip-by-default) |
| `build.zig` | Added `test-deadline-watchdog` step wiring for the Zig unit test |
