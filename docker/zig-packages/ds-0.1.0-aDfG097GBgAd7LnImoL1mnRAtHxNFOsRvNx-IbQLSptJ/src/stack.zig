// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Stack is a simple LIFO generic stack backed by ArrayListUnmanaged.
/// Methods are not concurrency-safe.
pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();

        data: std.ArrayListUnmanaged(T),
        allocator: Allocator,

        /// Initialize a new stack with the given allocator.
        pub fn init(allocator: Allocator) Self {
            return Self{
                .data = .{},
                .allocator = allocator,
            };
        }

        /// Initialize a new stack with a capacity hint.
        pub fn initCapacity(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            return Self{
                .data = try std.ArrayListUnmanaged(T).initCapacity(allocator, capacity),
                .allocator = allocator,
            };
        }

        /// Free all memory used by the stack.
        pub fn deinit(self: *Self) void {
            self.data.deinit(self.allocator);
        }

        /// Push a value onto the stack.
        pub fn push(self: *Self, value: T) Allocator.Error!void {
            try self.data.append(self.allocator, value);
        }

        /// Pop a value from the stack. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.data.items.len == 0) return null;
            return self.data.pop();
        }

        /// Peek at the top value without removing it. Returns null if empty.
        pub fn peek(self: *Self) ?T {
            if (self.data.items.len == 0) return null;
            return self.data.items[self.data.items.len - 1];
        }

        /// Get the number of items in the stack.
        pub fn len(self: *Self) usize {
            return self.data.items.len;
        }

        /// Check if the stack is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.data.items.len == 0;
        }

        /// Clear all items from the stack.
        pub fn clear(self: *Self) void {
            self.data.clearRetainingCapacity();
        }
    };
}

test "Stack - basic operations" {
    const testing = std.testing;
    var stack = Stack(i32).init(testing.allocator);
    defer stack.deinit();

    try testing.expect(stack.isEmpty());
    try testing.expectEqual(@as(usize, 0), stack.len());

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);

    try testing.expectEqual(@as(usize, 3), stack.len());
    try testing.expectEqual(@as(?i32, 3), stack.peek());

    try testing.expectEqual(@as(?i32, 3), stack.pop());
    try testing.expectEqual(@as(?i32, 2), stack.pop());
    try testing.expectEqual(@as(?i32, 1), stack.pop());
    try testing.expectEqual(@as(?i32, null), stack.pop());
}

test "Stack - clear" {
    const testing = std.testing;
    var stack = Stack(i32).init(testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    try testing.expectEqual(@as(usize, 3), stack.len());

    stack.clear();
    try testing.expectEqual(@as(usize, 0), stack.len());
    try testing.expect(stack.isEmpty());
}
