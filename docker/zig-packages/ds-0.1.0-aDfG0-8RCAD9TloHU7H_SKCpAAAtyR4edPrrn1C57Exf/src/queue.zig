// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Queue is a FIFO queue backed by a ring buffer.
///
/// O(1) amortized enqueue and dequeue with no per-element heap allocation.
/// The internal buffer is lazily allocated on first enqueue and doubles in
/// size when full.
///
/// Methods are not concurrency-safe; callers must synchronize externally
/// when sharing across threads (consistent with Stack and Deque).
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        const DEFAULT_CAPACITY = 16;

        allocator: Allocator,
        buf: []T = &[_]T{},
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        /// Initialize a new queue.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
            };
        }

        /// Free all memory used by the queue.
        pub fn deinit(self: *Self) void {
            if (self.buf.len > 0) {
                self.allocator.free(self.buf);
            }
            self.buf = &[_]T{};
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }

        /// Ensure the internal buffer has room for at least one more element.
        /// Lazily allocates on first use; doubles when full.
        fn ensureCapacity(self: *Self) Allocator.Error!void {
            if (self.buf.len == 0) {
                self.buf = try self.allocator.alloc(T, DEFAULT_CAPACITY);
                self.head = 0;
                self.tail = 0;
                return;
            }

            if (self.count < self.buf.len) return;

            // Buffer is full -- double the capacity
            const old_len = self.buf.len;
            const new_cap = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
            const new_buf = try self.allocator.alloc(T, new_cap);

            // Copy elements in logical order (head..tail wrapping)
            for (0..self.count) |i| {
                new_buf[i] = self.buf[(self.head + i) % old_len];
            }

            self.allocator.free(self.buf);
            self.buf = new_buf;
            self.head = 0;
            self.tail = self.count;
        }

        /// Enqueue a value at the back of the queue.
        pub fn enqueue(self: *Self, value: T) Allocator.Error!void {
            try self.ensureCapacity();
            self.buf[self.tail] = value;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;
        }

        /// Dequeue a value from the front of the queue. Returns null if empty.
        pub fn dequeue(self: *Self) ?T {
            if (self.count == 0) return null;
            const value = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;
            return value;
        }

        /// Peek at the front value without removing it. Returns null if empty.
        pub fn peek(self: *Self) ?T {
            if (self.count == 0) return null;
            return self.buf[self.head];
        }

        /// Check if the queue is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.count == 0;
        }

        /// Get the number of items in the queue.
        pub fn len(self: *Self) usize {
            return self.count;
        }

        /// Deprecated: use `len()` instead. Kept for backwards compatibility.
        pub fn getLength(self: *Self) usize {
            return self.len();
        }

        /// Clear all items from the queue.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }

        /// Convert queue to a slice (allocates).
        /// Elements are returned in FIFO order (front to back).
        pub fn toSlice(self: *Self, allocator: Allocator) Allocator.Error![]T {
            const slice = try allocator.alloc(T, self.count);
            errdefer allocator.free(slice);

            if (self.count > 0) {
                const buf_len = self.buf.len;
                for (0..self.count) |i| {
                    slice[i] = self.buf[(self.head + i) % buf_len];
                }
            }
            return slice;
        }

        /// Reverse the queue in-place.
        pub fn reverse(self: *Self) void {
            if (self.count <= 1) return;

            const buf_len = self.buf.len;
            var left: usize = 0;
            var right: usize = self.count - 1;

            while (left < right) {
                const li = (self.head + left) % buf_len;
                const ri = (self.head + right) % buf_len;
                const tmp = self.buf[li];
                self.buf[li] = self.buf[ri];
                self.buf[ri] = tmp;
                left += 1;
                right -= 1;
            }
        }

        /// Apply a function to each element in FIFO order (front to back).
        pub fn forEach(self: *Self, context: anytype, comptime func: fn (@TypeOf(context), T) void) void {
            if (self.count == 0) return;
            const buf_len = self.buf.len;
            for (0..self.count) |i| {
                func(context, self.buf[(self.head + i) % buf_len]);
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "Queue - basic operations" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(usize, 0), queue.getLength());

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);

    try testing.expectEqual(@as(usize, 3), queue.getLength());
    try testing.expectEqual(@as(?i32, 1), queue.peek());

    try testing.expectEqual(@as(?i32, 1), queue.dequeue());
    try testing.expectEqual(@as(?i32, 2), queue.dequeue());
    try testing.expectEqual(@as(?i32, 3), queue.dequeue());
    try testing.expectEqual(@as(?i32, null), queue.dequeue());
}

test "Queue - toSlice" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);

    const slice = try queue.toSlice(testing.allocator);
    defer testing.allocator.free(slice);

    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, slice);
}

test "Queue - reverse" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);

    queue.reverse();

    try testing.expectEqual(@as(?i32, 3), queue.dequeue());
    try testing.expectEqual(@as(?i32, 2), queue.dequeue());
    try testing.expectEqual(@as(?i32, 1), queue.dequeue());
}

test "Queue - len alias" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    try testing.expectEqual(@as(usize, 0), queue.len());
    try queue.enqueue(42);
    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(queue.len(), queue.getLength());
}

test "Queue - clear" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try testing.expectEqual(@as(usize, 3), queue.getLength());

    queue.clear();
    try testing.expectEqual(@as(usize, 0), queue.getLength());
    try testing.expect(queue.isEmpty());
    try testing.expectEqual(@as(?i32, null), queue.dequeue());
}

test "Queue - forEach" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);

    var sum: i32 = 0;
    queue.forEach(&sum, struct {
        fn call(ctx: *i32, value: i32) void {
            ctx.* += value;
        }
    }.call);

    try testing.expectEqual(@as(i32, 6), sum);
}

test "Queue - grow past initial capacity" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    // Enqueue more than DEFAULT_CAPACITY (16) items to trigger growth
    var i: i32 = 0;
    while (i < 20) : (i += 1) {
        try queue.enqueue(i);
    }

    try testing.expectEqual(@as(usize, 20), queue.getLength());

    // Verify FIFO order is preserved after growth
    i = 0;
    while (i < 20) : (i += 1) {
        try testing.expectEqual(@as(?i32, i), queue.dequeue());
    }
    try testing.expectEqual(@as(?i32, null), queue.dequeue());
}

test "Queue - wrap-around ring buffer correctness" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    // Enqueue and dequeue to advance head, then enqueue more to wrap around
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        try queue.enqueue(i);
    }
    // Dequeue 8 elements, advancing head
    i = 0;
    while (i < 8) : (i += 1) {
        try testing.expectEqual(@as(?i32, i), queue.dequeue());
    }
    // Now head is advanced, 2 elements remain
    try testing.expectEqual(@as(usize, 2), queue.getLength());

    // Enqueue more to wrap tail around
    i = 100;
    while (i < 120) : (i += 1) {
        try queue.enqueue(i);
    }

    // Verify remaining original elements come first
    try testing.expectEqual(@as(?i32, 8), queue.dequeue());
    try testing.expectEqual(@as(?i32, 9), queue.dequeue());
    // Then the new elements
    i = 100;
    while (i < 120) : (i += 1) {
        try testing.expectEqual(@as(?i32, i), queue.dequeue());
    }
    try testing.expect(queue.isEmpty());
}

test "Queue - toSlice with wrapped buffer" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    // Fill and partially drain to create a wrapped state
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        try queue.enqueue(i);
    }
    i = 0;
    while (i < 8) : (i += 1) {
        _ = queue.dequeue();
    }
    // head advanced, elements are [8, 9]
    try queue.enqueue(10);
    try queue.enqueue(11);

    const slice = try queue.toSlice(testing.allocator);
    defer testing.allocator.free(slice);

    try testing.expectEqualSlices(i32, &[_]i32{ 8, 9, 10, 11 }, slice);
}

test "Queue - reverse with wrapped buffer" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    // Create a wrapped buffer state
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        try queue.enqueue(i);
    }
    i = 0;
    while (i < 8) : (i += 1) {
        _ = queue.dequeue();
    }
    try queue.enqueue(10);
    try queue.enqueue(11);
    // Queue contains [8, 9, 10, 11] with wrap-around

    queue.reverse();

    try testing.expectEqual(@as(?i32, 11), queue.dequeue());
    try testing.expectEqual(@as(?i32, 10), queue.dequeue());
    try testing.expectEqual(@as(?i32, 9), queue.dequeue());
    try testing.expectEqual(@as(?i32, 8), queue.dequeue());
    try testing.expectEqual(@as(?i32, null), queue.dequeue());
}

test "Queue - empty toSlice" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    const slice = try queue.toSlice(testing.allocator);
    defer testing.allocator.free(slice);

    try testing.expectEqual(@as(usize, 0), slice.len);
}

test "Queue - repeated enqueue dequeue cycles" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    // Many small cycles to exercise wrap-around
    var i: i32 = 0;
    while (i < 1000) : (i += 1) {
        try queue.enqueue(i);
        try testing.expectEqual(@as(?i32, i), queue.dequeue());
        try testing.expect(queue.isEmpty());
    }
}

test "Queue - deinit without prior enqueue" {
    var queue = Queue(i32).init(std.testing.allocator);
    // deinit on a queue that never had enqueue should not crash or leak
    queue.deinit();
}

test "Queue - string type" {
    const testing = std.testing;
    var queue = Queue([]const u8).init(testing.allocator);
    defer queue.deinit();

    try queue.enqueue("hello");
    try queue.enqueue("world");

    try testing.expectEqual(@as(?[]const u8, "hello"), queue.dequeue());
    try testing.expectEqual(@as(?[]const u8, "world"), queue.dequeue());
}

test "Queue - forEach on empty queue" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    var sum: i32 = 0;
    queue.forEach(&sum, struct {
        fn call(ctx: *i32, value: i32) void {
            ctx.* += value;
        }
    }.call);

    try testing.expectEqual(@as(i32, 0), sum);
}

test "Queue - reverse empty and single element" {
    const testing = std.testing;
    var queue = Queue(i32).init(testing.allocator);
    defer queue.deinit();

    // Reverse empty queue -- should not crash
    queue.reverse();
    try testing.expect(queue.isEmpty());

    // Reverse single element
    try queue.enqueue(42);
    queue.reverse();
    try testing.expectEqual(@as(?i32, 42), queue.dequeue());
}
