// CANARY: REQ=REQ-QUIC-HC-001; FEATURE="QUIC High-Concurrency Wakeups"; ASPECT=PollSyncFutexWake; STATUS=TESTED; TEST=tests/test_quic_pollsync_wake.zig; OWNER=transport; UPDATED=2026-05-25
//! Regression tests for PollSync's futex-backed poll notification path.

const std = @import("std");
const testing = std.testing;
const quic = @import("transport/quic");

fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

test "PollSync.waitForPoll wakes promptly when notifyPoll advances generation" {
    var sync = quic.PollSync{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ps: *quic.PollSync) void {
            sleepNs(5 * std.time.ns_per_ms);
            ps.notifyPoll();
        }
    }.run, .{&sync});
    defer thread.join();

    const start = monoNanos();
    sync.waitForPoll(1 * std.time.ns_per_s);
    const elapsed = monoNanos() -| start;

    try testing.expect(elapsed < 100 * std.time.ns_per_ms);
}

test "PollSync.notifyPoll wakes a bounded batch of parked stream readers" {
    const waiter_count = 16;
    var sync = quic.PollSync{};
    var ready = std.atomic.Value(u32).init(0);
    var woke = std.atomic.Value(u32).init(0);

    const WaiterCtx = struct {
        sync: *quic.PollSync,
        ready: *std.atomic.Value(u32),
        woke: *std.atomic.Value(u32),
    };

    const worker = struct {
        fn run(ctx: *WaiterCtx) void {
            _ = ctx.ready.fetchAdd(1, .acq_rel);
            ctx.sync.waitForPoll(1 * std.time.ns_per_s);
            _ = ctx.woke.fetchAdd(1, .acq_rel);
        }
    }.run;

    var contexts: [waiter_count]WaiterCtx = undefined;
    var threads: [waiter_count]std.Thread = undefined;
    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .sync = &sync, .ready = &ready, .woke = &woke };
        threads[i] = try std.Thread.spawn(.{}, worker, .{ctx});
    }

    const ready_deadline = monoNanos() + 1 * std.time.ns_per_s;
    while (ready.load(.acquire) < waiter_count and monoNanos() < ready_deadline) {
        sleepNs(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, waiter_count), ready.load(.acquire));

    const start = monoNanos();
    sync.notifyPoll();

    for (&threads) |*thread| thread.join();
    const elapsed = monoNanos() -| start;

    try testing.expectEqual(@as(u32, waiter_count), woke.load(.acquire));
    try testing.expect(elapsed < 250 * std.time.ns_per_ms);
}
