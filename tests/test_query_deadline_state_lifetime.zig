// Copyright 2024-2026 CodePros
// SPDX-License-Identifier: Apache-2.0
//
// Issue #746 regression — `QueryDeadlineState.finish()` must join the watchdog.
//
// Pre-fix bug: `finish()` sets `done=true` but does NOT wait for the watchdog
// thread to observe it.  In `cmdQuery` the state is stack-allocated, so after
// `finish()` returns and `cmdQuery` pops its frame, the watchdog's next 100 ms
// tick reads freed stack memory, computes a nonsense `now - last_progress_ns`
// that trivially exceeds `timeout_ns`, and calls `std.process.exit(1)` AFTER
// stdout has already carried a correct JSON response.
//
// Contract the fix must establish:
//
//   After `QueryDeadlineState.finish(&state)` returns, the background
//   watchdog thread MUST be in a terminal state — no further reads of
//   `state`, no further wakeups, no further chance of calling
//   `std.process.exit`.
//
// How this test proves the contract:
//
//   * Constructs a heap-backed `QueryDeadlineState` (so we outlive any stack
//     frame and can observe state fields across the `finish()` boundary).
//   * Spawns the real watchdog via the real `startDeadlineWatchdogTask`
//     entry point (same path `cmdQuery` uses).
//   * Waits long enough for the watchdog to complete at least two 100 ms
//     ticks (so `tick_count >= 2`).
//   * Calls `state.finish()`.
//   * Observes `tick_count` for 250 ms after `finish()` returns.  Post-fix:
//     the counter MUST be stable — the watchdog has exited.  Pre-fix: the
//     watchdog is still mid-nanosleep when `finish()` returns; its next wake
//     will bump `tick_count` by one (and in the production `cmdQuery` path
//     it would also read freed stack memory).
//
// Also asserts the "stack-reuse analogue": `last_progress_ns` in the
// test-owned heap buffer must still equal the sentinel we wrote — if the
// watchdog ever gained write access (it does not), or if the extraction
// wired the wrong field, this would catch it.
//
// CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-001; FEATURE="QueryDeadlineWatchdog"; ASPECT=LifetimeRegression; STATUS=TESTED; TEST=tests/test_query_deadline_state_lifetime.zig; OWNER=cli; UPDATED=2026-04-16

const std = @import("std");
const testing = std.testing;
const qd = @import("query_deadline");

fn sleepMs(ms: u64) void {
    const ns: i64 = @intCast(ms * std.time.ns_per_ms);
    const req = std.os.linux.timespec{
        .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

test "QueryDeadlineState.finish joins the watchdog thread (regression #746)" {
    // Use the page allocator (no leak-tracking).  The CLI background thread
    // pool this test touches is a process-wide singleton — it cannot be
    // cleanly torn down at the end of the test, so `testing.allocator` would
    // spuriously flag the pool's allocations as leaks.  This is unrelated to
    // the bug under test.
    const allocator = std.heap.page_allocator;

    // Heap-allocate so the state's lifetime is controlled by the test, not
    // by any stack frame.  In production (pre-fix) the state is a local in
    // `cmdQuery` — this test's heap backing makes the observation possible
    // without tripping literal UAF and crashing the test runner.
    const state_ptr = try allocator.create(qd.QueryDeadlineState);
    // Intentionally do NOT `defer destroy` — the pre-fix watchdog may still
    // be mid-tick reading this slot.  Leaking the state_ptr once per test is
    // acceptable: the test process exits immediately after and the OS reaps.

    state_ptr.* = qd.QueryDeadlineState.init();

    // Capture the init()-timestamp as our sentinel.  We assert it remains
    // unchanged across the `finish()` boundary (the watchdog never writes
    // `last_progress_ns` — only reads it — so any mutation would indicate a
    // field-wiring regression).  Using init's own timestamp keeps the value
    // "recent" so the 10s timeout below never fires during the test.
    const sentinel: i64 = state_ptr.last_progress_ns.load(.acquire);

    // Install the state in the global slot that the production touch/finish
    // helpers use (same slot `cmdQuery` writes at src/cli/main.zig:1416).
    qd.active_query_deadline_state = state_ptr;
    defer qd.active_query_deadline_state = null;

    // 10 s timeout so the watchdog won't fire its own exit(1) during the
    // test — we're only interested in its liveness, not its timeout logic.
    const timeout_secs: u32 = 10;
    qd.startDeadlineWatchdogTask(allocator, timeout_secs, state_ptr);

    // Let the watchdog run for ~250 ms — enough for at least 2 ticks.
    sleepMs(250);

    const ticks_before_finish = state_ptr.tick_count.load(.acquire);
    try testing.expect(ticks_before_finish >= 2); // watchdog is confirmed alive

    // Call under test — the production `finish()`.  Post-fix this must
    // block until the watchdog has returned from its loop.
    state_ptr.finish();

    // Immediately after finish() returns, snapshot the tick count.
    const ticks_at_finish_return = state_ptr.tick_count.load(.acquire);

    // Wait long enough for TWO more watchdog ticks (200 ms) plus slack.
    // Post-fix: watchdog has exited, so tick_count will be frozen.
    // Pre-fix: watchdog may be mid-nanosleep when finish() returned; it
    //          will wake up and bump tick_count at least once.
    sleepMs(300);

    const ticks_after_wait = state_ptr.tick_count.load(.acquire);

    // Primary regression assertion: no further ticks after `finish()` returned.
    if (ticks_after_wait != ticks_at_finish_return) {
        std.debug.print(
            "REGRESSION #746: watchdog kept ticking after finish() returned.\n" ++
                "  ticks_before_finish={d} ticks_at_finish_return={d} ticks_after_wait={d}\n" ++
                "  finish() did NOT join the watchdog thread.\n",
            .{ ticks_before_finish, ticks_at_finish_return, ticks_after_wait },
        );
        return error.WatchdogNotJoined;
    }

    // Secondary assertion: the test-owned `last_progress_ns` is the
    // sentinel we wrote (no stack-reuse analogue could have corrupted it,
    // because we use heap allocation — this is a smoke check that the
    // extracted struct layout is intact).
    try testing.expectEqual(sentinel, state_ptr.last_progress_ns.load(.acquire));
}

test "QueryDeadlineState.finish is safe to call before the watchdog takes its first tick" {
    // Edge case: finish() called before the watchdog has a chance to run.
    // Post-fix this must still block correctly (or return immediately once
    // it observes the thread has already exited).  Pre-fix this is trivially
    // fine because finish() is a no-op store.  Keeping as a unit test guard
    // so the fix doesn't regress the fast path.
    const allocator = std.heap.page_allocator;
    const state_ptr = try allocator.create(qd.QueryDeadlineState);
    // See note in previous test re: no `defer destroy`.

    state_ptr.* = qd.QueryDeadlineState.init();
    qd.active_query_deadline_state = state_ptr;
    defer qd.active_query_deadline_state = null;

    const timeout_secs: u32 = 10;
    qd.startDeadlineWatchdogTask(allocator, timeout_secs, state_ptr);
    state_ptr.finish();

    // Give 300 ms for any lingering watchdog to wake up and observe done.
    sleepMs(300);

    const ticks_a = state_ptr.tick_count.load(.acquire);
    sleepMs(250);
    const ticks_b = state_ptr.tick_count.load(.acquire);

    if (ticks_a != ticks_b) {
        std.debug.print(
            "REGRESSION #746 (edge case): watchdog kept ticking after finish(): a={d} b={d}\n",
            .{ ticks_a, ticks_b },
        );
        return error.WatchdogNotJoined;
    }
}
