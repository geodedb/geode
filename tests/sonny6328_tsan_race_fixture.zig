// SONNY-6328: a deliberate data race, built exactly like the TSan companion
// steps build their test files (`build.zig`, see test-sonny6328-tsan-detects-race).
// Under a working ThreadSanitizer this binary reports the race and exits 66;
// uninstrumented it passes. tests/test_sonny6328_tsan_detects_race.zig runs it
// and requires the report. Not a test of geode code: never run it on its own.
const std = @import("std");

var counter: usize = 0;

fn bump() void {
    for (0..100_000) |_| {
        // Unsynchronized read-modify-write from two threads.
        const v = @as(*volatile usize, &counter).*;
        @as(*volatile usize, &counter).* = v + 1;
    }
}

test "SONNY-6328 fixture: two threads write one variable without synchronization" {
    const a = try std.Thread.spawn(.{}, bump, .{});
    const b = try std.Thread.spawn(.{}, bump, .{});
    a.join();
    b.join();
    try std.testing.expect(counter > 0);
}
