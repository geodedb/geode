const std = @import("std");
const testing = std.testing;
const cursor_mod = @import("../src/containers/cursor_container.zig");

// Test for CursorContainer basic iteration, peek, reset, exhaustion, empty slice behavior.
// CANARY evidence test for REQ-GQL-068 CursorContainer
// Naming must align with CANARY line: TestCANARY_REQ_GQL_068_Cursor

pub fn makeU32Cursor(slice: []const u32) cursor_mod.CursorContainer(u32) {
    return cursor_mod.CursorContainer(u32).init(slice);
}

fn collectAll(alloc: std.mem.Allocator, cur_ptr: anytype) ![]u32 {
    return try cur_ptr.collectRemaining(alloc);
}

// Ensures: next advances, peek does not advance, reset returns to start, remaining/exhausted correct, empty slice safe.
test "TestCANARY_REQ_GQL_068_Cursor" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var data: [5]u32 = .{ 10, 20, 30, 40, 50 };
    var cur = makeU32Cursor(&data);

    try testing.expect(!cur.isEmpty());
    try testing.expectEqual(@as(usize, 5), cur.len());
    try testing.expectEqual(@as(usize, 5), cur.remaining());
    try testing.expect(!cur.exhausted());

    // Peek first
    try testing.expectEqual(@as(?u32, 10), cur.peek());
    try testing.expectEqual(@as(usize, 5), cur.remaining());

    // Iterate two
    try testing.expectEqual(@as(?u32, 10), cur.next());
    try testing.expectEqual(@as(?u32, 20), cur.next());
    try testing.expectEqual(@as(usize, 3), cur.remaining());
    try testing.expectEqual(@as(?u32, 30), cur.peek());

    // Reset
    cur.reset();
    try testing.expectEqual(@as(?u32, 10), cur.peek());
    try testing.expectEqual(@as(usize, 5), cur.remaining());

    // Collect remaining from start
    var cur2 = makeU32Cursor(&data);
    const collected = try collectAll(allocator, &cur2);
    defer allocator.free(collected);
    try testing.expectEqual(@as(usize, 5), collected.len);
    try testing.expect(cur2.exhausted());
    try testing.expectEqual(@as(usize, 0), cur2.remaining());
    try testing.expectEqual(@as(?u32, null), cur2.next());

    // Empty slice
    var empty_cur = makeU32Cursor(&[_]u32{});
    try testing.expect(empty_cur.isEmpty());
    try testing.expect(empty_cur.exhausted());
    try testing.expectEqual(@as(usize, 0), empty_cur.len());
    try testing.expectEqual(@as(?u32, null), empty_cur.peek());
    try testing.expectEqual(@as(?u32, null), empty_cur.next());

    // Partial consume then collect
    var cur3 = makeU32Cursor(&data);
    _ = cur3.next(); // consume 10
    const remaining_collected = try collectAll(allocator, &cur3);
    defer allocator.free(remaining_collected);
    try testing.expectEqual(@as(usize, 4), remaining_collected.len);
    try testing.expect(cur3.exhausted());
}
