// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

/// Node for Red-Black Tree
/// Colors: red=true, black=false
fn RBNode(comptime T: type) type {
    return struct {
        value: T,
        left: ?*@This() = null,
        right: ?*@This() = null,
        parent: ?*@This() = null,
        red: bool = false,
    };
}

/// Red-Black Tree with insertion, search, and deletion.
pub fn RBTree(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = RBNode(T);
        const CompareFn = *const fn (a: T, b: T) Order;

        allocator: Allocator,
        root: ?*Node = null,
        compare: CompareFn,
        size: usize = 0,

        pub fn init(allocator: Allocator, compare: CompareFn) Self {
            return Self{
                .allocator = allocator,
                .compare = compare,
            };
        }

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

        pub fn insert(self: *Self, value: T) Allocator.Error!void {
            if (self.root == null) {
                const node = try self.allocator.create(Node);
                node.* = .{ .value = value, .red = false };
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
                            node.* = .{ .value = value, .parent = current, .red = true };
                            current.left = node;
                            self.size += 1;
                            self.fixInsert(node);
                            return;
                        }
                        current = current.left.?;
                    },
                    .gt => {
                        if (current.right == null) {
                            const node = try self.allocator.create(Node);
                            node.* = .{ .value = value, .parent = current, .red = true };
                            current.right = node;
                            self.size += 1;
                            self.fixInsert(node);
                            return;
                        }
                        current = current.right.?;
                    },
                }
            }
        }

        fn rotateLeft(self: *Self, x: *Node) void {
            const y = x.right orelse return;
            x.right = y.left;
            if (y.left) |left| {
                left.parent = x;
            }
            y.parent = x.parent;
            if (x.parent == null) {
                self.root = y;
            } else if (x.parent.?.left == x) {
                x.parent.?.left = y;
            } else {
                x.parent.?.right = y;
            }
            y.left = x;
            x.parent = y;
        }

        fn rotateRight(self: *Self, x: *Node) void {
            const y = x.left orelse return;
            x.left = y.right;
            if (y.right) |right| {
                right.parent = x;
            }
            y.parent = x.parent;
            if (x.parent == null) {
                self.root = y;
            } else if (x.parent.?.right == x) {
                x.parent.?.right = y;
            } else {
                x.parent.?.left = y;
            }
            y.right = x;
            x.parent = y;
        }

        fn fixInsert(self: *Self, z_param: *Node) void {
            var z = z_param;
            while (z.parent != null and z.parent.?.red) {
                const grandparent = z.parent.?.parent orelse break;
                if (z.parent == grandparent.left) {
                    const y = grandparent.right;
                    if (y != null and y.?.red) {
                        z.parent.?.red = false;
                        y.?.red = false;
                        grandparent.red = true;
                        z = grandparent;
                        continue;
                    }
                    if (z == z.parent.?.right) {
                        z = z.parent.?;
                        self.rotateLeft(z);
                    }
                    z.parent.?.red = false;
                    z.parent.?.parent.?.red = true;
                    self.rotateRight(z.parent.?.parent.?);
                } else {
                    const y = grandparent.left;
                    if (y != null and y.?.red) {
                        z.parent.?.red = false;
                        y.?.red = false;
                        grandparent.red = true;
                        z = grandparent;
                        continue;
                    }
                    if (z == z.parent.?.left) {
                        z = z.parent.?;
                        self.rotateRight(z);
                    }
                    z.parent.?.red = false;
                    z.parent.?.parent.?.red = true;
                    self.rotateLeft(z.parent.?.parent.?);
                }
            }
            self.root.?.red = false;
        }

        pub fn delete(self: *Self, value: T) bool {
            var z = self.root;
            while (z != null) {
                const cmp = self.compare(value, z.?.value);
                if (cmp == .eq) break;
                z = if (cmp == .lt) z.?.left else z.?.right;
            }
            if (z == null) return false;

            self.size -= 1;
            const y = z.?;
            const y_original_red = y.red;
            var x: ?*Node = null;
            var parent: ?*Node = null;

            if (z.?.left == null) {
                x = z.?.right;
                parent = z.?.parent;
                self.rbTransplant(z.?, z.?.right);
            } else if (z.?.right == null) {
                x = z.?.left;
                parent = z.?.parent;
                self.rbTransplant(z.?, z.?.left);
            } else {
                const min_node = self.minimum(z.?.right.?);
                const y_red = min_node.red;
                x = min_node.right;
                if (min_node.parent == z) {
                    parent = min_node;
                } else {
                    parent = min_node.parent;
                    self.rbTransplant(min_node, min_node.right);
                    min_node.right = z.?.right;
                    min_node.right.?.parent = min_node;
                }
                self.rbTransplant(z.?, min_node);
                min_node.left = z.?.left;
                min_node.left.?.parent = min_node;
                min_node.red = z.?.red;
                if (!y_red) {
                    self.fixDelete(x, parent.?);
                }
                self.allocator.destroy(z.?);
                return true;
            }

            self.allocator.destroy(z.?);
            if (!y_original_red and parent != null) {
                self.fixDelete(x, parent.?);
            }
            return true;
        }

        fn rbTransplant(self: *Self, u: *Node, v: ?*Node) void {
            if (u.parent == null) {
                self.root = v;
            } else if (u == u.parent.?.left) {
                u.parent.?.left = v;
            } else {
                u.parent.?.right = v;
            }
            if (v) |node| {
                node.parent = u.parent;
            }
        }

        fn minimum(self: *Self, n_param: *Node) *Node {
            _ = self;
            var n = n_param;
            while (n.left != null) {
                n = n.left.?;
            }
            return n;
        }

        fn fixDelete(self: *Self, x_param: ?*Node, parent_param: *Node) void {
            var x = x_param;
            var parent = parent_param;

            while (x != self.root and (x == null or !x.?.red)) {
                if (x == parent.left) {
                    var w = parent.right;
                    if (w != null and w.?.red) {
                        w.?.red = false;
                        parent.red = true;
                        self.rotateLeft(parent);
                        w = parent.right;
                    }
                    if (w == null or ((w.?.left == null or !w.?.left.?.red) and (w.?.right == null or !w.?.right.?.red))) {
                        if (w) |node| node.red = true;
                        x = parent;
                        parent = x.?.parent orelse break;
                    } else {
                        if (w.?.right == null or !w.?.right.?.red) {
                            if (w.?.left) |left| left.red = false;
                            w.?.red = true;
                            self.rotateRight(w.?);
                            w = parent.right;
                        }
                        if (w) |node| {
                            node.red = parent.red;
                            if (node.right) |right| right.red = false;
                        }
                        parent.red = false;
                        self.rotateLeft(parent);
                        x = self.root;
                        break;
                    }
                } else {
                    var w = parent.left;
                    if (w != null and w.?.red) {
                        w.?.red = false;
                        parent.red = true;
                        self.rotateRight(parent);
                        w = parent.left;
                    }
                    if (w == null or ((w.?.right == null or !w.?.right.?.red) and (w.?.left == null or !w.?.left.?.red))) {
                        if (w) |node| node.red = true;
                        x = parent;
                        parent = x.?.parent orelse break;
                    } else {
                        if (w.?.left == null or !w.?.left.?.red) {
                            if (w.?.right) |right| right.red = false;
                            w.?.red = true;
                            self.rotateLeft(w.?);
                            w = parent.left;
                        }
                        if (w) |node| {
                            node.red = parent.red;
                            if (node.left) |left| left.red = false;
                        }
                        parent.red = false;
                        self.rotateRight(parent);
                        x = self.root;
                        break;
                    }
                }
                if (x == null) break;
            }
            if (x) |node| node.red = false;
        }

        pub fn inOrder(self: *Self, context: anytype, comptime func: fn (@TypeOf(context), T) bool) void {
            self.walkInOrder(self.root, context, func);
        }

        fn walkInOrder(_: *Self, node: ?*Node, context: anytype, comptime func: fn (@TypeOf(context), T) bool) bool {
            if (node == null) return true;
            const n = node.?;
            if (!walkInOrder(undefined, n.left, context, func)) return false;
            if (!func(context, n.value)) return false;
            return walkInOrder(undefined, n.right, context, func);
        }

        /// Get the number of elements in the tree.
        pub fn len(self: *Self) usize {
            return self.size;
        }

        /// Alias for len() for backwards compatibility.
        pub fn getSize(self: *Self) usize {
            return self.len();
        }

        /// Check if the tree is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.size == 0;
        }

        /// Check if the tree contains a value.
        pub fn contains(self: *Self, value: T) bool {
            return self.search(value) != null;
        }

        /// Get the minimum value in the tree.
        pub fn min(self: *Self) ?T {
            var current = self.root orelse return null;
            while (current.left) |left| {
                current = left;
            }
            return current.value;
        }

        /// Get the maximum value in the tree.
        pub fn max(self: *Self) ?T {
            var current = self.root orelse return null;
            while (current.right) |right| {
                current = right;
            }
            return current.value;
        }
    };
}

fn compareI32(a: i32, b: i32) Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

test "RBTree - basic operations" {
    const testing = std.testing;
    var tree = RBTree(i32).init(testing.allocator, compareI32);
    defer tree.deinit();

    try tree.insert(5);
    try tree.insert(3);
    try tree.insert(7);
    try tree.insert(1);
    try tree.insert(9);

    try testing.expectEqual(@as(usize, 5), tree.getSize());
    try testing.expectEqual(@as(?i32, 5), tree.search(5));
    try testing.expectEqual(@as(?i32, 3), tree.search(3));
    try testing.expectEqual(@as(?i32, null), tree.search(10));
}

test "RBTree - delete" {
    const testing = std.testing;
    var tree = RBTree(i32).init(testing.allocator, compareI32);
    defer tree.deinit();

    try tree.insert(5);
    try tree.insert(3);
    try tree.insert(7);
    try tree.insert(1);
    try tree.insert(9);

    try testing.expect(tree.delete(3));
    try testing.expectEqual(@as(usize, 4), tree.getSize());
    try testing.expectEqual(@as(?i32, null), tree.search(3));
    try testing.expectEqual(@as(?i32, 5), tree.search(5));
}

test "RBTree - contains, isEmpty, min, max" {
    const testing = std.testing;
    var tree = RBTree(i32).init(testing.allocator, compareI32);
    defer tree.deinit();

    try testing.expect(tree.isEmpty());
    try testing.expectEqual(@as(?i32, null), tree.min());
    try testing.expectEqual(@as(?i32, null), tree.max());

    try tree.insert(5);
    try tree.insert(3);
    try tree.insert(7);
    try tree.insert(1);
    try tree.insert(9);

    try testing.expect(!tree.isEmpty());
    try testing.expect(tree.contains(5));
    try testing.expect(tree.contains(1));
    try testing.expect(!tree.contains(100));
    try testing.expectEqual(@as(?i32, 1), tree.min());
    try testing.expectEqual(@as(?i32, 9), tree.max());
    try testing.expectEqual(@as(usize, 5), tree.len());
}
