const std = @import("std");
const testing = std.testing;
const mutation_timing = @import("geode").mutation_timing;

test "records lock_wait_ns, execute_ns, release_ns when enabled" {
    mutation_timing.setEnabledForTest(true);
    defer mutation_timing.setEnabledForTest(false);

    var sample = mutation_timing.begin();
    sample.markLockAcquired();
    // Sleep 1 ms between lock-acquired and execute-done so execute_ns >= 1ms.
    // Zig 0.16 removed std.time.sleep; use nanosleep directly.
    const req = std.posix.timespec{ .sec = 0, .nsec = 1_000_000 };
    var rem = req;
    _ = std.os.linux.nanosleep(&req, &rem);
    sample.markExecuteDone();
    sample.markLockReleased();
    sample.record("CREATE (n:T)");

    const last = mutation_timing.lastSampleForTest() orelse return error.NoSample;
    try testing.expect(last.lock_wait_ns < 10 * std.time.ns_per_ms);
    try testing.expect(last.execute_ns >= 1 * std.time.ns_per_ms);
    try testing.expect(last.release_ns < 10 * std.time.ns_per_ms);
}
