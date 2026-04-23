const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const mutation_timing = @import("geode").mutation_timing;

test "records lock_wait_ns, execute_ns, release_ns when enabled" {
    mutation_timing.clearLastSampleForTest();
    mutation_timing.setEnabledForTest(true);
    defer mutation_timing.setEnabledForTest(false);

    var sample = mutation_timing.begin();
    sample.markLockAcquired();
    // Sleep 1 ms between lock-acquired and execute-done so execute_ns >= 1ms.
    if (comptime builtin.os.tag == .linux) {
        const req = std.posix.timespec{ .sec = 0, .nsec = 1_000_000 };
        var rem = req;
        _ = std.os.linux.nanosleep(&req, &rem);
    } else {
        // Portable spin-wait fallback for non-Linux platforms.
        const deadline = monoNanos() + 1 * std.time.ns_per_ms;
        while (monoNanos() < deadline) std.atomic.spinLoopHint();
    }
    sample.markExecuteDone();
    sample.markLockReleased();
    sample.record("CREATE (n:T)");

    const last = mutation_timing.lastSampleForTest() orelse return error.NoSample;
    try testing.expect(last.lock_wait_ns < 10 * std.time.ns_per_ms);
    try testing.expect(last.execute_ns >= 1 * std.time.ns_per_ms);
    try testing.expect(last.release_ns < 10 * std.time.ns_per_ms);
}

fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
