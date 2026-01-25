const std = @import("std");

// CursorContainer: A lightweight, bounds-checked forward cursor over a slice.
// Provides O(1) next/peek/reset operations and remaining count.
// Not thread-safe; intended for single-threaded iteration in planner/executor utilities.
// Generic over element type T.
//
// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=CursorContainer; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_068_Cursor; OWNER=graph; UPDATED=2025-09-23
pub fn CursorContainer(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        index: usize = 0,

        pub fn init(slice: []const T) Self {
            return .{ .slice = slice, .index = 0 };
        }

        pub fn fromEmpty() Self {
            return .{ .slice = &[_]T{}, .index = 0 };
        }

        pub fn reset(self: *Self) void {
            self.index = 0;
        }

        pub fn len(self: *const Self) usize {
            return self.slice.len;
        }

        pub fn remaining(self: *const Self) usize {
            if (self.index >= self.slice.len) return 0;
            return self.slice.len - self.index;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.slice.len == 0;
        }

        pub fn exhausted(self: *const Self) bool {
            return self.index >= self.slice.len;
        }

        // Returns null when exhausted. Advances index if element present.
        pub fn next(self: *Self) ?T {
            if (self.index >= self.slice.len) return null;
            const v = self.slice[self.index];
            self.index += 1;
            return v;
        }

        // Peek at current element without advancing.
        pub fn peek(self: *const Self) ?T {
            if (self.index >= self.slice.len) return null;
            return self.slice[self.index];
        }

        // Collect remaining elements into an ArrayList (allocator provided by caller).
        pub fn collectRemaining(self: *Self, allocator: std.mem.Allocator) ![]T {
            if (self.index >= self.slice.len) return &[_]T{};
            const rem = self.slice[self.index..];
            const buf = try allocator.alloc(T, rem.len);
            std.mem.copy(T, buf, rem);
            self.index = self.slice.len; // mark exhausted
            return buf;
        }
    };
}

// Simple helper to adapt a slice into a cursor without specifying generic explicitly.
pub fn makeCursor(comptime T: type, slice: []const T) CursorContainer(T) {
    return CursorContainer(T).init(slice);
}

// ==================== Unit Tests (GAP-0239) ====================
// CANARY: REQ=REQ-GAP-0239; FEATURE="ContainerUnitTests"; ASPECT=CursorContainer; STATUS=TESTED; TEST=test_cursor_basic; OWNER=containers; UPDATED=2026-01-25

test "CursorContainer init and basic properties" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    var cursor = CursorContainer(i32).init(&data);

    try std.testing.expectEqual(@as(usize, 5), cursor.len());
    try std.testing.expectEqual(@as(usize, 5), cursor.remaining());
    try std.testing.expect(!cursor.isEmpty());
    try std.testing.expect(!cursor.exhausted());
}

test "CursorContainer next advances and returns elements" {
    const data = [_]i32{ 10, 20, 30 };
    var cursor = CursorContainer(i32).init(&data);

    try std.testing.expectEqual(@as(?i32, 10), cursor.next());
    try std.testing.expectEqual(@as(usize, 2), cursor.remaining());
    try std.testing.expectEqual(@as(?i32, 20), cursor.next());
    try std.testing.expectEqual(@as(?i32, 30), cursor.next());
    try std.testing.expectEqual(@as(?i32, null), cursor.next());
    try std.testing.expect(cursor.exhausted());
}

test "CursorContainer peek does not advance" {
    const data = [_]i32{ 100, 200 };
    var cursor = CursorContainer(i32).init(&data);

    try std.testing.expectEqual(@as(?i32, 100), cursor.peek());
    try std.testing.expectEqual(@as(?i32, 100), cursor.peek()); // Still 100
    try std.testing.expectEqual(@as(usize, 2), cursor.remaining());
}

test "CursorContainer reset returns to beginning" {
    const data = [_]i32{ 1, 2, 3 };
    var cursor = CursorContainer(i32).init(&data);

    _ = cursor.next();
    _ = cursor.next();
    try std.testing.expectEqual(@as(usize, 1), cursor.remaining());

    cursor.reset();
    try std.testing.expectEqual(@as(usize, 3), cursor.remaining());
    try std.testing.expectEqual(@as(?i32, 1), cursor.peek());
}

test "CursorContainer fromEmpty creates empty cursor" {
    const cursor = CursorContainer(i32).fromEmpty();
    try std.testing.expect(cursor.isEmpty());
    try std.testing.expect(cursor.exhausted());
    try std.testing.expectEqual(@as(usize, 0), cursor.len());
}

test "makeCursor helper function works" {
    const data = [_]u8{ 'a', 'b', 'c' };
    var cursor = makeCursor(u8, &data);

    try std.testing.expectEqual(@as(?u8, 'a'), cursor.next());
    try std.testing.expectEqual(@as(?u8, 'b'), cursor.next());
    try std.testing.expectEqual(@as(?u8, 'c'), cursor.next());
    try std.testing.expectEqual(@as(?u8, null), cursor.next());
}

test "CursorContainer with single element" {
    const data = [_]i32{42};
    var cursor = CursorContainer(i32).init(&data);

    try std.testing.expectEqual(@as(usize, 1), cursor.len());
    try std.testing.expectEqual(@as(?i32, 42), cursor.next());
    try std.testing.expectEqual(@as(?i32, null), cursor.next());
}

test "CursorContainer peek on exhausted returns null" {
    const data = [_]i32{1};
    var cursor = CursorContainer(i32).init(&data);

    _ = cursor.next();
    try std.testing.expectEqual(@as(?i32, null), cursor.peek());
}

test "CursorContainer multiple resets" {
    const data = [_]i32{ 1, 2 };
    var cursor = CursorContainer(i32).init(&data);

    _ = cursor.next();
    cursor.reset();
    _ = cursor.next();
    _ = cursor.next();
    cursor.reset();

    try std.testing.expectEqual(@as(usize, 2), cursor.remaining());
    try std.testing.expectEqual(@as(?i32, 1), cursor.peek());
}

test "CursorContainer with struct type" {
    const Point = struct { x: i32, y: i32 };
    const data = [_]Point{
        .{ .x = 1, .y = 2 },
        .{ .x = 3, .y = 4 },
    };
    var cursor = CursorContainer(Point).init(&data);

    const p1 = cursor.next().?;
    try std.testing.expectEqual(@as(i32, 1), p1.x);

    const p2 = cursor.next().?;
    try std.testing.expectEqual(@as(i32, 3), p2.x);
}

test "CursorContainer remaining decreases correctly" {
    const data = [_]i32{ 1, 2, 3, 4, 5 };
    var cursor = CursorContainer(i32).init(&data);

    try std.testing.expectEqual(@as(usize, 5), cursor.remaining());
    _ = cursor.next();
    try std.testing.expectEqual(@as(usize, 4), cursor.remaining());
    _ = cursor.next();
    try std.testing.expectEqual(@as(usize, 3), cursor.remaining());
    _ = cursor.next();
    _ = cursor.next();
    _ = cursor.next();
    try std.testing.expectEqual(@as(usize, 0), cursor.remaining());
}

test "CursorContainer exhausted state" {
    const data = [_]i32{1};
    var cursor = CursorContainer(i32).init(&data);

    try std.testing.expect(!cursor.exhausted());
    _ = cursor.next();
    try std.testing.expect(cursor.exhausted());
}

test "CursorContainer with large slice" {
    var data: [1000]i32 = undefined;
    for (&data, 0..) |*v, i| {
        v.* = @intCast(i);
    }
    var cursor = CursorContainer(i32).init(&data);

    try std.testing.expectEqual(@as(usize, 1000), cursor.len());
    try std.testing.expectEqual(@as(?i32, 0), cursor.next());

    // Skip to near end
    var i: usize = 1;
    while (i < 999) : (i += 1) {
        _ = cursor.next();
    }
    try std.testing.expectEqual(@as(?i32, 999), cursor.next());
    try std.testing.expect(cursor.exhausted());
}
