// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

const MAX_SKIP_LEVEL = 16;

/// Node for Skip List
fn SkipNode(comptime K: type, comptime V: type) type {
    return struct {
        key: K,
        value: V,
        next: []?*@This(),
    };
}

/// Skip List with probabilistic balancing.
/// Uses deterministic seeded PRNG for reproducible height distribution.
pub fn SkipList(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Node = SkipNode(K, V);
        const CompareFn = *const fn (a: K, b: K) Order;

        allocator: Allocator,
        head: *Node,
        level: usize = 1,
        rng: std.Random.DefaultPrng,
        compare: CompareFn,

        pub fn init(allocator: Allocator, seed: u64, compare: CompareFn) Allocator.Error!Self {
            const head = try allocator.create(Node);
            const next_array = try allocator.alloc(?*Node, MAX_SKIP_LEVEL);
            for (next_array) |*ptr| {
                ptr.* = null;
            }
            head.* = .{
                .key = undefined,
                .value = undefined,
                .next = next_array,
            };

            return Self{
                .allocator = allocator,
                .head = head,
                .rng = std.Random.DefaultPrng.init(seed),
                .compare = compare,
            };
        }

        pub fn deinit(self: *Self) void {
            var current = self.head.next[0];
            while (current) |node| {
                const next = node.next[0];
                self.allocator.free(node.next);
                self.allocator.destroy(node);
                current = next;
            }
            self.allocator.free(self.head.next);
            self.allocator.destroy(self.head);
        }

        fn randomLevel(self: *Self) usize {
            var lvl: usize = 1;
            while (lvl < MAX_SKIP_LEVEL and self.rng.random().int(u32) & 1 == 1) {
                lvl += 1;
            }
            return lvl;
        }

        pub fn search(self: *Self, key: K) ?V {
            var current = self.head;
            var i: usize = self.level;
            while (i > 0) {
                i -= 1;
                while (current.next[i]) |next| {
                    const cmp = self.compare(next.key, key);
                    if (cmp == .lt) {
                        current = next;
                    } else {
                        break;
                    }
                }
            }
            const candidate = current.next[0];
            if (candidate) |node| {
                const cmp = self.compare(key, node.key);
                if (cmp == .eq) return node.value;
            }
            return null;
        }

        pub fn insert(self: *Self, key: K, value: V) Allocator.Error!void {
            var update = [_]?*Node{null} ** MAX_SKIP_LEVEL;

            var current = self.head;
            var i: usize = self.level;
            while (i > 0) {
                i -= 1;
                while (current.next[i]) |next| {
                    const cmp = self.compare(next.key, key);
                    if (cmp == .lt) {
                        current = next;
                    } else {
                        break;
                    }
                }
                update[i] = current;
            }

            // Check if key already exists
            const candidate = current.next[0];
            if (candidate) |node| {
                const cmp = self.compare(key, node.key);
                if (cmp == .eq) {
                    node.value = value;
                    return;
                }
            }

            const new_level = self.randomLevel();
            if (new_level > self.level) {
                i = self.level;
                while (i < new_level) : (i += 1) {
                    update[i] = self.head;
                }
                self.level = new_level;
            }

            const new_node = try self.allocator.create(Node);
            const next_array = try self.allocator.alloc(?*Node, new_level);
            for (next_array) |*ptr| {
                ptr.* = null;
            }
            new_node.* = .{
                .key = key,
                .value = value,
                .next = next_array,
            };

            i = 0;
            while (i < new_level) : (i += 1) {
                if (update[i]) |upd| {
                    new_node.next[i] = upd.next[i];
                    upd.next[i] = new_node;
                }
            }
        }

        pub fn delete(self: *Self, key: K) bool {
            var update = [_]?*Node{null} ** MAX_SKIP_LEVEL;

            var current = self.head;
            var i: usize = self.level;
            while (i > 0) {
                i -= 1;
                while (current.next[i]) |next| {
                    const cmp = self.compare(next.key, key);
                    if (cmp == .lt) {
                        current = next;
                    } else {
                        break;
                    }
                }
                update[i] = current;
            }

            const target = current.next[0] orelse return false;
            const cmp = self.compare(key, target.key);
            if (cmp != .eq) return false;

            i = 0;
            // Only iterate up to the target's level to avoid out-of-bounds access
            while (i < target.next.len) : (i += 1) {
                if (update[i]) |upd| {
                    if (upd.next[i] == target) {
                        upd.next[i] = target.next[i];
                    }
                }
            }

            self.allocator.free(target.next);
            self.allocator.destroy(target);

            while (self.level > 1 and self.head.next[self.level - 1] == null) {
                self.level -= 1;
            }

            return true;
        }
    };
}

fn compareI32(a: i32, b: i32) Order {
    return std.math.order(a, b);
}

test "SkipList - basic operations" {
    const testing = std.testing;
    var list = try SkipList(i32, []const u8).init(testing.allocator, 42, compareI32);
    defer list.deinit();

    try list.insert(5, "five");
    try list.insert(2, "two");
    try list.insert(7, "seven");

    try testing.expectEqualStrings("five", list.search(5).?);
    try testing.expectEqualStrings("two", list.search(2).?);
    try testing.expectEqualStrings("seven", list.search(7).?);
    try testing.expectEqual(@as(?[]const u8, null), list.search(10));
}

test "SkipList - update value" {
    const testing = std.testing;
    var list = try SkipList(i32, []const u8).init(testing.allocator, 42, compareI32);
    defer list.deinit();

    try list.insert(5, "five");
    try list.insert(5, "FIVE"); // Update
    try testing.expectEqualStrings("FIVE", list.search(5).?);
}

test "SkipList - delete" {
    const testing = std.testing;
    var list = try SkipList(i32, []const u8).init(testing.allocator, 42, compareI32);
    defer list.deinit();

    try list.insert(5, "five");
    try list.insert(2, "two");
    try list.insert(7, "seven");

    try testing.expect(list.delete(2));
    try testing.expectEqual(@as(?[]const u8, null), list.search(2));
    try testing.expectEqualStrings("five", list.search(5).?);
    try testing.expect(!list.delete(100));
}
