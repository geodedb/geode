// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Node for the linked list based queue.
fn Node(comptime T: type) type {
    return struct {
        value: T,
        next: ?*@This() = null,
    };
}

/// Queue is a FIFO queue using a singly-linked list.
///
/// ## Thread Safety
///
/// Individual operations are protected by a mutex and are atomic. However, there are
/// important caveats when using pointer types:
///
/// **WARNING: Pointer Types Require External Synchronization**
///
/// If `T` is a pointer type (or contains pointers), the Queue only manages the pointer
/// value itself, NOT the pointed-to data. This means:
///
/// - `peek()` returns a copy of the pointer, but another thread may `dequeue()` that
///   element immediately after, potentially freeing the data the pointer references.
/// - `dequeue()` returns ownership of the value, but if the pointed-to data has shared
///   ownership, you must ensure proper lifecycle management.
///
/// **Safe Usage Patterns:**
///
/// 1. **Value types (i32, structs without pointers)**: Fully thread-safe.
/// 2. **Pointer types with single producer/consumer**: Safe if only one thread enqueues
///    and one thread dequeues.
/// 3. **Pointer types with multiple consumers**: Use external synchronization or
///    reference counting (e.g., `std.atomic.Value`).
///
/// **Example of UNSAFE usage:**
/// ```zig
/// // Thread 1:
/// const ptr = queue.peek(); // Gets pointer
/// // Thread 2 dequeues and frees the data
/// ptr.?.doSomething(); // USE-AFTER-FREE!
/// ```
///
/// **Example of SAFE usage:**
/// ```zig
/// // Use dequeue() for exclusive ownership:
/// if (queue.dequeue()) |item| {
///     defer allocator.destroy(item);
///     item.doSomething(); // Safe - we own it
/// }
/// ```
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        const NodeType = Node(T);

        allocator: Allocator,
        head: ?*NodeType = null,
        tail: ?*NodeType = null,
        length: usize = 0,
        mutex: std.Thread.Mutex = .{},

        /// Initialize a new queue.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
            };
        }

        /// Free all memory used by the queue.
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.head = null;
            self.tail = null;
            self.length = 0;
        }

        /// Enqueue a value at the back of the queue.
        pub fn enqueue(self: *Self, value: T) Allocator.Error!void {
            const node = try self.allocator.create(NodeType);
            node.* = .{ .value = value, .next = null };

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head == null) {
                self.head = node;
                self.tail = node;
            } else {
                self.tail.?.next = node;
                self.tail = node;
            }
            self.length += 1;
        }

        /// Dequeue a value from the front of the queue. Returns null if empty.
        pub fn dequeue(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const head = self.head orelse return null;
            const value = head.value;
            self.head = head.next;
            if (self.head == null) {
                self.tail = null;
            }
            self.length -= 1;
            self.allocator.destroy(head);
            return value;
        }

        /// Peek at the front value without removing it. Returns null if empty.
        ///
        /// **Thread Safety Warning:** If T is a pointer type, the returned value may become
        /// invalid if another thread calls `dequeue()` before you finish using it.
        /// Consider using `dequeue()` for exclusive ownership instead.
        pub fn peek(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head) |head| {
                return head.value;
            }
            return null;
        }

        /// Check if the queue is empty.
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.head == null;
        }

        /// Get the number of items in the queue.
        pub fn getLength(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.length;
        }

        /// Clear all items from the queue.
        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.head = null;
            self.tail = null;
            self.length = 0;
        }

        /// Convert queue to a slice (allocates).
        pub fn toSlice(self: *Self, allocator: Allocator) Allocator.Error![]T {
            self.mutex.lock();
            defer self.mutex.unlock();

            var list: std.ArrayListUnmanaged(T) = .{};
            try list.ensureTotalCapacity(allocator, self.length);
            errdefer list.deinit(allocator);

            var current = self.head;
            while (current) |node| {
                list.appendAssumeCapacity(node.value);
                current = node.next;
            }
            return list.toOwnedSlice(allocator);
        }

        /// Reverse the queue in-place.
        pub fn reverse(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var prev: ?*NodeType = null;
            var current = self.head;
            self.tail = self.head;

            while (current) |node| {
                const next = node.next;
                node.next = prev;
                prev = node;
                current = next;
            }
            self.head = prev;
        }

        /// Apply a function to each element.
        pub fn forEach(self: *Self, context: anytype, comptime func: fn (@TypeOf(context), T) void) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var current = self.head;
            while (current) |node| {
                func(context, node.value);
                current = node.next;
            }
        }
    };
}

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
