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
