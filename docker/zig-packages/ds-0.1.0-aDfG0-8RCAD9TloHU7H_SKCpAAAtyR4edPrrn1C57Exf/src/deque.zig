// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Deque is a double-ended queue using a ring buffer.
/// Methods are not concurrency-safe.
pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        const MIN_CAPACITY = 4;

        allocator: Allocator,
        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        /// Initialize a new deque with the given capacity.
        pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            const cap = @max(capacity, MIN_CAPACITY);
            return Self{
                .allocator = allocator,
                .buf = try allocator.alloc(T, cap),
            };
        }

        /// Free all memory used by the deque.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
        }

        /// Grow the internal buffer to double its current size.
        fn grow(self: *Self) Allocator.Error!void {
            const n = self.buf.len;
            const new_cap = std.math.mul(usize, n, 2) catch return error.OutOfMemory;
            const new_buf = try self.allocator.alloc(T, new_cap);

            // Copy elements in order
            for (0..self.count) |i| {
                new_buf[i] = self.buf[(self.head + i) % n];
            }

            self.allocator.free(self.buf);
            self.buf = new_buf;
            self.head = 0;
            self.tail = self.count;
        }

        /// Push a value to the back of the deque.
        pub fn pushBack(self: *Self, value: T) Allocator.Error!void {
            if (self.count == self.buf.len) {
                try self.grow();
            }
            self.buf[self.tail] = value;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;
        }

        /// Push a value to the front of the deque.
        pub fn pushFront(self: *Self, value: T) Allocator.Error!void {
            if (self.count == self.buf.len) {
                try self.grow();
            }
            self.head = if (self.head == 0) self.buf.len - 1 else self.head - 1;
            self.buf[self.head] = value;
            self.count += 1;
        }

        /// Pop a value from the front of the deque. Returns null if empty.
        pub fn popFront(self: *Self) ?T {
            if (self.count == 0) return null;
            const value = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;
            return value;
        }

        /// Pop a value from the back of the deque. Returns null if empty.
        pub fn popBack(self: *Self) ?T {
            if (self.count == 0) return null;
            self.tail = if (self.tail == 0) self.buf.len - 1 else self.tail - 1;
            const value = self.buf[self.tail];
            self.count -= 1;
            return value;
        }

        /// Peek at the front value without removing it. Returns null if empty.
        pub fn peekFront(self: *Self) ?T {
            if (self.count == 0) return null;
            return self.buf[self.head];
        }

        /// Peek at the back value without removing it. Returns null if empty.
        pub fn peekBack(self: *Self) ?T {
            if (self.count == 0) return null;
            const back_idx = if (self.tail == 0) self.buf.len - 1 else self.tail - 1;
            return self.buf[back_idx];
        }

        /// Get the number of items in the deque.
        pub fn len(self: *Self) usize {
            return self.count;
        }

        /// Check if the deque is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.count == 0;
        }

        /// Clear all items from the deque.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }
    };
}

test "Deque - basic operations" {
    const testing = std.testing;
    var deque = try Deque(i32).init(testing.allocator, 4);
    defer deque.deinit();

    try testing.expect(deque.isEmpty());
    try testing.expectEqual(@as(usize, 0), deque.len());

    try deque.pushBack(1);
    try deque.pushBack(2);
    try deque.pushFront(0);

    try testing.expectEqual(@as(usize, 3), deque.len());
    try testing.expectEqual(@as(?i32, 0), deque.popFront());
    try testing.expectEqual(@as(?i32, 2), deque.popBack());
    try testing.expectEqual(@as(?i32, 1), deque.popFront());
    try testing.expectEqual(@as(?i32, null), deque.popFront());
}

test "Deque - grow" {
    const testing = std.testing;
    var deque = try Deque(i32).init(testing.allocator, 4);
    defer deque.deinit();

    // Fill beyond initial capacity to trigger grow
    try deque.pushBack(1);
    try deque.pushBack(2);
    try deque.pushBack(3);
    try deque.pushBack(4);
    try deque.pushBack(5); // Should trigger grow

    try testing.expectEqual(@as(usize, 5), deque.len());
    try testing.expectEqual(@as(?i32, 1), deque.popFront());
    try testing.expectEqual(@as(?i32, 2), deque.popFront());
    try testing.expectEqual(@as(?i32, 3), deque.popFront());
    try testing.expectEqual(@as(?i32, 4), deque.popFront());
    try testing.expectEqual(@as(?i32, 5), deque.popFront());
}

test "Deque - clear" {
    const testing = std.testing;
    var deque = try Deque(i32).init(testing.allocator, 4);
    defer deque.deinit();

    try deque.pushBack(1);
    try deque.pushBack(2);
    try deque.pushFront(0);
    try testing.expectEqual(@as(usize, 3), deque.len());

    deque.clear();
    try testing.expectEqual(@as(usize, 0), deque.len());
    try testing.expect(deque.isEmpty());
}

test "Deque - peekFront and peekBack" {
    const testing = std.testing;
    var deque = try Deque(i32).init(testing.allocator, 4);
    defer deque.deinit();

    // Empty deque returns null
    try testing.expectEqual(@as(?i32, null), deque.peekFront());
    try testing.expectEqual(@as(?i32, null), deque.peekBack());

    try deque.pushBack(1);
    try deque.pushBack(2);
    try deque.pushBack(3);

    // Peek doesn't remove elements
    try testing.expectEqual(@as(?i32, 1), deque.peekFront());
    try testing.expectEqual(@as(?i32, 3), deque.peekBack());
    try testing.expectEqual(@as(usize, 3), deque.len());

    // Multiple peeks return same value
    try testing.expectEqual(@as(?i32, 1), deque.peekFront());
    try testing.expectEqual(@as(?i32, 3), deque.peekBack());
}
