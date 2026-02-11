// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

/// Node for Binary Search Tree
fn BSTNode(comptime T: type) type {
    return struct {
        value: T,
        left: ?*@This() = null,
        right: ?*@This() = null,
        parent: ?*@This() = null,
    };
}

/// Generic Binary Search Tree (unbalanced).
/// Comparator function returns Order: .lt if a<b, .eq if equal, .gt if a>b.
pub fn BST(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = BSTNode(T);
        const CompareFn = *const fn (a: T, b: T) Order;

        allocator: Allocator,
        root: ?*Node = null,
        compare: CompareFn,
        size: usize = 0,

        /// Initialize a new BST with the given comparator.
        pub fn init(allocator: Allocator, compare: CompareFn) Self {
            return Self{
                .allocator = allocator,
                .compare = compare,
            };
        }

        /// Free all memory used by the BST.
        pub fn deinit(self: *Self) void {
            self.destroySubtree(self.root);
            self.root = null;
            self.size = 0;
        }

        fn destroySubtree(self: *Self, node: ?*Node) void {
            if (node) |n| {
                self.destroySubtree(n.left);
                self.destroySubtree(n.right);
                self.allocator.destroy(n);
            }
        }

        /// Insert a value into the BST. Replaces if equal.
        pub fn insert(self: *Self, value: T) Allocator.Error!void {
            if (self.root == null) {
                const node = try self.allocator.create(Node);
                node.* = .{ .value = value };
                self.root = node;
                self.size = 1;
                return;
            }

            var current = self.root.?;
            while (true) {
                const cmp = self.compare(value, current.value);
                switch (cmp) {
                    .eq => {
                        current.value = value;
                        return;
                    },
                    .lt => {
                        if (current.left == null) {
                            const node = try self.allocator.create(Node);
                            node.* = .{ .value = value, .parent = current };
                            current.left = node;
                            self.size += 1;
                            return;
                        }
                        current = current.left.?;
                    },
                    .gt => {
                        if (current.right == null) {
                            const node = try self.allocator.create(Node);
                            node.* = .{ .value = value, .parent = current };
                            current.right = node;
                            self.size += 1;
                            return;
                        }
                        current = current.right.?;
                    },
                }
            }
        }

        /// Search for a value in the BST. Returns null if not found.
        pub fn search(self: *Self, value: T) ?T {
            var current = self.root;
            while (current) |node| {
                const cmp = self.compare(value, node.value);
                switch (cmp) {
                    .eq => return node.value,
                    .lt => current = node.left,
                    .gt => current = node.right,
                }
            }
            return null;
        }

        /// In-order traversal. Calls fn for each value until false is returned.
        pub fn inOrder(self: *Self, context: anytype, comptime func: fn (@TypeOf(context), T) bool) void {
            _ = self.walkInOrder(self.root, context, func);
        }

        fn walkInOrder(_: *Self, node: ?*Node, context: anytype, comptime func: fn (@TypeOf(context), T) bool) bool {
            if (node == null) return true;
            const n = node.?;
            if (!walkInOrder(undefined, n.left, context, func)) return false;
            if (!func(context, n.value)) return false;
            return walkInOrder(undefined, n.right, context, func);
        }

        /// Get the number of nodes in the tree.
        pub fn getSize(self: *Self) usize {
            return self.size;
        }
    };
}

fn compareI32(a: i32, b: i32) Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

test "BST - basic operations" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try bst.insert(3);
    try bst.insert(7);
    try bst.insert(1);
    try bst.insert(9);

    try testing.expectEqual(@as(usize, 5), bst.getSize());
    try testing.expectEqual(@as(?i32, 5), bst.search(5));
    try testing.expectEqual(@as(?i32, 3), bst.search(3));
    try testing.expectEqual(@as(?i32, 7), bst.search(7));
    try testing.expectEqual(@as(?i32, null), bst.search(10));
}

test "BST - in-order traversal" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try bst.insert(3);
    try bst.insert(7);
    try bst.insert(1);
    try bst.insert(9);

    var values: std.ArrayListUnmanaged(i32) = .{};
    defer values.deinit(testing.allocator);

    const Context = struct {
        list: *std.ArrayListUnmanaged(i32),
        alloc: std.mem.Allocator,
    };
    var ctx = Context{ .list = &values, .alloc = testing.allocator };

    bst.inOrder(&ctx, struct {
        fn collect(context: *Context, value: i32) bool {
            context.list.append(context.alloc, value) catch return false;
            return true;
        }
    }.collect);

    try testing.expectEqualSlices(i32, &[_]i32{ 1, 3, 5, 7, 9 }, values.items);
}

test "BST - replace value" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try testing.expectEqual(@as(usize, 1), bst.getSize());

    try bst.insert(5); // Replace
    try testing.expectEqual(@as(usize, 1), bst.getSize());
    try testing.expectEqual(@as(?i32, 5), bst.search(5));
}
