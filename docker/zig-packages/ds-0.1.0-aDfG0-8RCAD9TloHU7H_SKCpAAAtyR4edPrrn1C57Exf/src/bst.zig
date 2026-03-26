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

        /// Iterative tree destruction. Flattens the tree into a right-only
        /// chain via right rotations (no extra allocation), then frees linearly.
        /// This avoids unbounded recursion on degenerate (sorted-insert) trees.
        fn destroySubtree(self: *Self, node: ?*Node) void {
            var current = node;
            while (current) |n| {
                if (n.left) |left| {
                    // Right rotation: move left child up to flatten
                    n.left = left.right;
                    left.right = n;
                    current = left;
                } else {
                    // No left child -- safe to free this node, advance right
                    const right = n.right;
                    self.allocator.destroy(n);
                    current = right;
                }
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

        /// Delete a value from the BST. Returns true if the value was found and removed.
        pub fn delete(self: *Self, value: T) bool {
            var current = self.root;
            while (current) |node| {
                const cmp = self.compare(value, node.value);
                switch (cmp) {
                    .eq => {
                        self.removeNode(node);
                        self.size -= 1;
                        return true;
                    },
                    .lt => current = node.left,
                    .gt => current = node.right,
                }
            }
            return false;
        }

        /// Remove a node from the tree (leaf / one-child / two-child with in-order successor).
        fn removeNode(self: *Self, node: *Node) void {
            if (node.left != null and node.right != null) {
                // Two children: find in-order successor (leftmost in right subtree)
                var successor = node.right.?;
                while (successor.left) |left| {
                    successor = left;
                }
                node.value = successor.value;
                self.removeNode(successor);
                return;
            }

            const child: ?*Node = node.left orelse node.right;

            if (node.parent) |parent| {
                if (parent.left == node) {
                    parent.left = child;
                } else {
                    parent.right = child;
                }
            } else {
                self.root = child;
            }

            if (child) |c| {
                c.parent = node.parent;
            }

            self.allocator.destroy(node);
        }

        /// In-order traversal. Calls fn for each value until false is returned.
        pub fn inOrder(self: *Self, context: anytype, comptime func: fn (@TypeOf(context), T) bool) void {
            _ = walkInOrderImpl(self.root, context, func);
        }

        fn walkInOrderImpl(node: ?*Node, context: anytype, comptime func: fn (@TypeOf(context), T) bool) bool {
            const n = node orelse return true;
            if (!walkInOrderImpl(n.left, context, func)) return false;
            if (!func(context, n.value)) return false;
            return walkInOrderImpl(n.right, context, func);
        }

        /// Collect all values in-order into a newly allocated slice.
        /// Caller owns the returned slice and must free it with `allocator.free()`.
        pub fn toArray(self: *Self, allocator: Allocator) Allocator.Error![]T {
            var list: std.ArrayListUnmanaged(T) = .{};
            errdefer list.deinit(allocator);
            try list.ensureTotalCapacity(allocator, self.size);

            try collectInOrderImpl(self.root, &list, allocator);
            return list.toOwnedSlice(allocator);
        }

        fn collectInOrderImpl(node: ?*Node, list: *std.ArrayListUnmanaged(T), allocator: Allocator) Allocator.Error!void {
            const n = node orelse return;
            try collectInOrderImpl(n.left, list, allocator);
            try list.append(allocator, n.value);
            try collectInOrderImpl(n.right, list, allocator);
        }

        /// Get the number of nodes in the tree.
        pub fn len(self: *Self) usize {
            return self.size;
        }

        /// Deprecated: use `len()` instead.
        pub fn getSize(self: *Self) usize {
            return self.size;
        }
    };
}

fn compareI32(a: i32, b: i32) Order {
    return std.math.order(a, b);
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

    try testing.expectEqual(@as(usize, 5), bst.len());
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
    try testing.expectEqual(@as(usize, 1), bst.len());

    try bst.insert(5); // Replace
    try testing.expectEqual(@as(usize, 1), bst.len());
    try testing.expectEqual(@as(?i32, 5), bst.search(5));
}

test "BST - toArray returns sorted values" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try bst.insert(3);
    try bst.insert(7);
    try bst.insert(1);
    try bst.insert(9);

    const array = try bst.toArray(testing.allocator);
    defer testing.allocator.free(array);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 3, 5, 7, 9 }, array);
}

test "BST - toArray on empty tree" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    const array = try bst.toArray(testing.allocator);
    defer testing.allocator.free(array);
    try testing.expectEqual(@as(usize, 0), array.len);
}

test "BST - delete leaf node" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try bst.insert(3);
    try bst.insert(7);

    try testing.expect(bst.delete(3));
    try testing.expectEqual(@as(usize, 2), bst.len());
    try testing.expectEqual(@as(?i32, null), bst.search(3));
    try testing.expectEqual(@as(?i32, 5), bst.search(5));
    try testing.expectEqual(@as(?i32, 7), bst.search(7));
}

test "BST - delete node with one child" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try bst.insert(3);
    try bst.insert(1);

    try testing.expect(bst.delete(3));
    try testing.expectEqual(@as(usize, 2), bst.len());

    const array = try bst.toArray(testing.allocator);
    defer testing.allocator.free(array);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 5 }, array);
}

test "BST - delete node with two children" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try bst.insert(3);
    try bst.insert(7);
    try bst.insert(1);
    try bst.insert(4);

    try testing.expect(bst.delete(3));
    try testing.expectEqual(@as(usize, 4), bst.len());

    const array = try bst.toArray(testing.allocator);
    defer testing.allocator.free(array);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 4, 5, 7 }, array);
}

test "BST - delete root" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try bst.insert(3);
    try bst.insert(7);

    try testing.expect(bst.delete(5));
    try testing.expectEqual(@as(usize, 2), bst.len());

    const array = try bst.toArray(testing.allocator);
    defer testing.allocator.free(array);
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 7 }, array);
}

test "BST - delete nonexistent value" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try testing.expect(!bst.delete(10));
    try testing.expectEqual(@as(usize, 1), bst.len());
}

test "BST - delete only node" {
    const testing = std.testing;
    var bst = BST(i32).init(testing.allocator, compareI32);
    defer bst.deinit();

    try bst.insert(5);
    try testing.expect(bst.delete(5));
    try testing.expectEqual(@as(usize, 0), bst.len());
    try testing.expectEqual(@as(?i32, null), bst.search(5));
}
