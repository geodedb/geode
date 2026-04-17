// Copyright 2024-2026 CodePros
// SPDX-License-Identifier: Apache-2.0
//
// Query deadline watchdog — extracted from src/cli/main.zig so the UAF-lifetime
// regression tests (#746, tests/test_query_deadline_state_lifetime.zig) can link
// against the real `QueryDeadlineState` + `startDeadlineWatchdogTask` entry points
// without dragging in the full CLI module graph.
//
// CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-001; FEATURE="QueryDeadlineWatchdog"; ASPECT=Lifetime; STATUS=TESTED; TEST=tests/test_query_deadline_state_lifetime.zig; OWNER=cli; UPDATED=2026-04-16
//
// Issue #424: Process-level deadline watchdog for the `geode query` command.
// Issue #746 (FIXED):
//   `QueryDeadlineState.finish()` now joins the watchdog thread before
//   returning.  Callers in `cmdQuery` may stack-allocate the state safely —
//   once `finish()` returns, the watchdog is provably no longer running and
//   any subsequent stack reuse cannot be observed.
//
//   Implementation:
//     * `startDeadlineWatchdogTask` uses `std.Thread.spawn` (not the
//       fire-and-forget CLI pool) so we get a joinable handle.
//     * The handle is stored on the `QueryDeadlineState` itself
//       (`watchdog_thread`).
//     * `finish()` sets `done=true`, `join()`s the handle if present, and
//       clears the field so the call is idempotent (cmdQuery has both an
//       `errdefer`-style explicit `finish()` and the `defer { finish() }`
//       chain — the second call is a safe no-op).
//     * Worst-case shutdown latency is bounded by the watchdog's 100 ms
//       nanosleep tick.  If the watchdog ever gains IO dependencies,
//       revisit — for now the bounded tick is sufficient.
//
//   Follow-up (NOT fixed here; see triage §8):
//     QUIC `executeQueryOnConnection` + `QuicProtocolAdapter` in
//     src/cli/main.zig do not wire `.on_progress = touchActiveQueryDeadlineWatchdog`
//     the way the gRPC path does.  Pinned by the opt-in
//     `tests/test_deadline_watchdog_quic_progress_followup.sh` (stays red
//     until the hook is wired).  The lifetime fix here does not depend on it.

const std = @import("std");

// Hard-coded stderr file descriptor for the timeout message.  We avoid
// importing `src/utils/stdio.zig` to keep this module's import surface small
// enough that the unit-test binary does not need the full CLI module graph.
const STDERR_FD: std.Io.File.Handle = 2;

/// Process-exit code the watchdog uses when it trips.  Matches
/// `cli_dispatcher.ExitCode.general_error` (=1).  Duplicated here as a bare
/// constant to avoid a cross-module import.
const EXIT_GENERAL_ERROR: u8 = 1;

pub const QueryDeadlineState = struct {
    last_progress_ns: std.atomic.Value(i64),
    done: std.atomic.Value(bool),
    /// #746 regression-test observability: the watchdog increments this once
    /// per loop iteration.  Production callers ignore it; tests
    /// (tests/test_query_deadline_state_lifetime.zig) assert that after
    /// `finish()` returns the counter STOPS advancing, proving the watchdog
    /// thread has exited.  Adding the hook here (rather than as a test-local
    /// wrapper) lets the test observe the real watchdog loop.
    tick_count: std.atomic.Value(u64),
    /// #746 lifetime fix: joinable handle for the watchdog thread.
    /// `startDeadlineWatchdogTask` sets this on success; `finish()` joins it
    /// and clears it back to null.  Access is single-producer/single-consumer
    /// (cmdQuery owns the state and makes both calls on its own thread), so
    /// no extra synchronization is required beyond the done-flag acquire/release.
    watchdog_thread: ?std.Thread,

    pub fn init() QueryDeadlineState {
        const now_ns: i128 = blk: {
            var ts_tmp: std.os.linux.timespec = undefined;
            const rc = std.os.linux.clock_gettime(.REALTIME, &ts_tmp);
            if (rc != 0) break :blk @as(i128, 0);
            break :blk @as(i128, ts_tmp.sec) * std.time.ns_per_s + @as(i128, ts_tmp.nsec);
        };
        return .{
            .last_progress_ns = std.atomic.Value(i64).init(@as(i64, @intCast(now_ns))),
            .done = std.atomic.Value(bool).init(false),
            .tick_count = std.atomic.Value(u64).init(0),
            .watchdog_thread = null,
        };
    }

    pub fn touch(self: *QueryDeadlineState) void {
        const now_ns: i128 = blk: {
            var ts_tmp: std.os.linux.timespec = undefined;
            const rc = std.os.linux.clock_gettime(.REALTIME, &ts_tmp);
            if (rc != 0) break :blk @as(i128, 0);
            break :blk @as(i128, ts_tmp.sec) * std.time.ns_per_s + @as(i128, ts_tmp.nsec);
        };
        self.last_progress_ns.store(@as(i64, @intCast(now_ns)), .release);
    }

    /// Marks the watchdog as done AND joins its thread.  After this returns
    /// the watchdog is provably no longer running, so the caller may safely
    /// free/pop `self` (the original #746 defect: `finish()` only set
    /// `done=true` and returned, letting the watchdog read stack-reused
    /// memory on its next 100 ms tick).
    ///
    /// Idempotent: the handle is cleared after the first join, so a second
    /// call is a no-op.  Two paths in cmdQuery end up invoking finish() on
    /// success — the explicit `defer { state.finish() }` and the in-line
    /// `finishActiveQueryDeadlineWatchdog()` at the end of the QUIC/gRPC
    /// execute helpers.
    pub fn finish(self: *QueryDeadlineState) void {
        self.done.store(true, .release);
        if (self.watchdog_thread) |thread| {
            // Clear first so a re-entrant `finish()` (e.g. error path + defer)
            // does not attempt a double-join.
            self.watchdog_thread = null;
            // Bounded wait: watchdog tick is 100 ms and the loop checks
            // `done` immediately after each nanosleep.  `std.Thread.join`
            // has no timeout and cannot fail on Linux pthread_join when
            // passed a valid, unjoined handle.
            thread.join();
        }
    }
};

pub var active_query_deadline_state: ?*QueryDeadlineState = null;

pub fn touchActiveQueryDeadlineWatchdog() void {
    if (active_query_deadline_state) |state| {
        state.touch();
    }
}

pub fn finishActiveQueryDeadlineWatchdog() void {
    if (active_query_deadline_state) |state| {
        state.finish();
    }
}

const WatchdogThreadCtx = struct {
    timeout_secs: u32,
    state: *QueryDeadlineState,
};

pub fn startDeadlineWatchdogTask(allocator: std.mem.Allocator, timeout_secs: u32, state: *QueryDeadlineState) void {
    _ = allocator; // no longer needed — std.Thread.spawn handles its own stack
    // #746: spawn the watchdog as a real thread so `finish()` can `join()` it.
    // The thread-pool-based path was fire-and-forget, which is precisely what
    // allowed the UAF: the pool never exposed a join handle back to cmdQuery.
    const thread = std.Thread.spawn(.{}, runDeadlineWatchdogThread, .{ timeout_secs, state }) catch {
        // On spawn failure the watchdog simply doesn't run.  This is a
        // graceful degradation — the query still executes, just without a
        // client-side timeout.  Matches the previous pool.submit() failure
        // behaviour, which also silently dropped the task.
        return;
    };
    state.watchdog_thread = thread;
}

fn runDeadlineWatchdogThread(timeout_secs: u32, state: *QueryDeadlineState) void {
    deadlineWatchdog(timeout_secs, state);
}

/// Issue #424: Process-level deadline watchdog for the query command.
/// Fires only when no transport-level progress has been observed for
/// `timeout_secs`, instead of enforcing a hard wall-clock deadline.
pub fn deadlineWatchdog(timeout_secs: u32, state: *QueryDeadlineState) void {
    const timeout_ns = @as(i64, @intCast(timeout_secs)) * std.time.ns_per_s;

    while (!state.done.load(.acquire)) {
        {
            const ns: i64 = 100 * std.time.ns_per_ms;
            const req = std.os.linux.timespec{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
        }
        // #746 test hook: bump after each wake-up so tests can observe
        // watchdog liveness post-finish().  This atomic is otherwise unused
        // in production code paths.
        _ = state.tick_count.fetchAdd(1, .monotonic);
        if (state.done.load(.acquire)) return;

        const now_ns: i128 = blk: {
            var ts_tmp: std.os.linux.timespec = undefined;
            const rc = std.os.linux.clock_gettime(.REALTIME, &ts_tmp);
            if (rc != 0) break :blk @as(i128, 0);
            break :blk @as(i128, ts_tmp.sec) * std.time.ns_per_s + @as(i128, ts_tmp.nsec);
        };
        const last_progress_ns = state.last_progress_ns.load(.acquire);
        if (@as(i64, @intCast(now_ns)) - last_progress_ns < timeout_ns) continue;

        const stderr = std.Io.File{ .handle = STDERR_FD, .flags = .{ .nonblocking = false } };
        const io_wd = std.Io.Threaded.global_single_threaded.io();
        stderr.writeStreamingAll(io_wd, "Error: query timed out after ") catch {};
        var buf: [20]u8 = undefined;
        const timeout_str = std.fmt.bufPrint(&buf, "{d}", .{timeout_secs}) catch "?";
        stderr.writeStreamingAll(io_wd, timeout_str) catch {};
        stderr.writeStreamingAll(io_wd, " seconds\n") catch {};
        std.process.exit(EXIT_GENERAL_ERROR);
    }
}
