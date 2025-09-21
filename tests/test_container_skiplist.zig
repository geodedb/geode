const std = @import("std");
const g = @import("../src/lib.zig");

// TestCANARY_REQ_GQL_068_SkipList

test "TestCANARY_REQ_GQL_068_SkipList basic ops & edge cases" {
    const List = g.skiplist.SkipList(u32, i64, struct {
        fn lt(a: u32, b: u32) bool {
            return a < b;
        }
    }.lt);
    const gpa = std.testing.allocator;
    var sl = try List.init(gpa, 777);
    defer sl.deinit();

    // Insert duplicates (update value) and growing sequence
    try sl.insert(10, 100);
    try sl.insert(5, 50);
    try sl.insert(20, 200);
    try sl.insert(10, 111); // update
    try std.testing.expect(sl.search(10).?.* == 111);

    // Bulk insert
    var i: u32 = 0;
    while (i < 200) : (i += 1) try sl.insert(i + 1000, @as(i64, @intCast(i)));

    // Search hits and misses
    try std.testing.expect(sl.search(5).?.* == 50);
    try std.testing.expect(sl.search(12345) == null);

    // Remove existing and non-existing
    try std.testing.expect(sl.remove(5));
    try std.testing.expect(!sl.remove(5));

    // Ordered iteration check
    var prev: u32 = 0;
    var first = true;
    var it = sl.iterator();
    while (it.next()) |entry| {
        if (!first) try std.testing.expect(prev < entry.key);
        first = false;
        prev = entry.key;
    }
}
