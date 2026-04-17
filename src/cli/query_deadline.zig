// Copyright 2024-2026 CodePros
// SPDX-License-Identifier: Apache-2.0
//
// Query deadline watchdog — extracted from src/cli/main.zig so the UAF-lifetime
// regression tests (#746, tests/test_query_deadline_state_lifetime.zig) can link
// against the real `QueryDeadlineState` + `startDeadlineWatchdogTask` entry points
// without dragging in the full CLI module graph.
//
// CANARY: REQ=REQ-CLI-DEADLINE-WATCHDOG-001; FEATURE="QueryDeadlineWatchdog"; ASPECT=Lifetime; STATUS=IMPL; OWNER=cli; UPDATED=2026-04-16
//
// Issue #424: Process-level deadline watchdog for the `geode query` command.
// Issue #746 (pending fix):
//   `QueryDeadlineState.finish()` sets `done = true` but does not join the
//   watchdog thread.  Callers in `cmdQuery` stack-allocate the state, so after
//   the function returns the stack slot is reused and the watchdog reads
//   garbage on its next ~100 ms tick — leading to spurious
//   `Error: query timed out after N seconds` prints and exit(1) _after_
//   stdout has already carried a correct JSON response.
//
//   Tests pinning the bug:
//     - tests/test_deadline_watchdog_false_positive.sh (shell, visible symptom)
//     - tests/test_query_deadline_state_lifetime.zig   (Zig unit, `finish` must join)
//
//   This module intentionally exposes the watchdog types publicly so the Zig
//   unit test can construct a heap-backed `QueryDeadlineState`, spawn the real
//   background task via `startDeadlineWatchdogTask`, and observe post-`finish`
//   thread behaviour.  Keep the public surface minimal.

const std = @import("std");
const pooled = @import("transport/thread_pool");

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

    /// Marks the watchdog as done.  **Does NOT currently wait for the
    /// watchdog thread to observe `done=true`** — this is the bug tracked by
    /// #746.  After the fix lands, this comment and the test should flip.
    pub fn finish(self: *QueryDeadlineState) void {
        self.done.store(true, .release);
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

pub const DeadlineWatchdogCtx = struct {
    allocator: std.mem.Allocator,
    timeout_secs: u32,
    state: *QueryDeadlineState,
};

var g_cli_background_pool_mu: std.Io.Mutex = std.Io.Mutex.init;
var g_cli_background_pool: ?*pooled.ThreadPool = null;

fn getCliBackgroundPool(allocator: std.mem.Allocator) !*pooled.ThreadPool {
    g_cli_background_pool_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_cli_background_pool_mu.unlock(std.Io.Threaded.global_single_threaded.io());

    if (g_cli_background_pool == null) {
        g_cli_background_pool = try pooled.ThreadPool.init(allocator, .{
            .num_threads = 2,
            .queue_capacity = 8,
        });
    }
    return g_cli_background_pool.?;
}

pub fn startDeadlineWatchdogTask(allocator: std.mem.Allocator, timeout_secs: u32, state: *QueryDeadlineState) void {
    const pool = getCliBackgroundPool(allocator) catch return;
    const ctx = allocator.create(DeadlineWatchdogCtx) catch return;
    ctx.* = .{
        .allocator = allocator,
        .timeout_secs = timeout_secs,
        .state = state,
    };
    if (!pool.submit(.{
        .context = @ptrCast(ctx),
        .callback = runDeadlineWatchdogTask,
    })) {
        allocator.destroy(ctx);
    }
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

pub fn runDeadlineWatchdogTask(context: *anyopaque) void {
    const ctx: *DeadlineWatchdogCtx = @ptrCast(@alignCast(context));
    defer ctx.allocator.destroy(ctx);
    deadlineWatchdog(ctx.timeout_secs, ctx.state);
}
