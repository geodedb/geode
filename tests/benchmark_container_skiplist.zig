const std = @import("std");
const g = @import("../src/lib.zig");

// BenchmarkCANARY_REQ_GQL_068_SkipList
// Measures bulk insert + search workload; average time bound set for CI host slack.

test "BenchmarkCANARY_REQ_GQL_068_SkipList" {
    const List = g.skiplist.SkipList(u64, u64, struct {
        fn lt(a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    const gpa = std.testing.allocator;
    var sl = try List.init(gpa, 0xdeadbeefcafebabe);
    defer sl.deinit();

    const N: usize = 5000;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < N) : (i += 1) try sl.insert(@as(u64, @intCast(i * 2)), @as(u64, @intCast(i)));
    // Searches (hits + misses)
    i = 0;
    while (i < N) : (i += 1) {
        _ = sl.search(@as(u64, @intCast(i * 2)));
        _ = sl.search(@as(u64, @intCast(i * 2 + 1))); // miss
    }
    const elapsed = timer.read();
    const avg = elapsed / @as(u64, @intCast(N));
    // Guard: ensure per-op avg < 18000 ns on reference hardware (inserts+searches)
    try std.testing.expect(avg < 18_000);
}
