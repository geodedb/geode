const std = @import("std");
const range = @import("../types/range.zig");

pub fn IntervalTree(comptime T: type) type {
    return struct {
        const Self = @This();
        const RangeType = range.Range(T);

        root: ?*Node,
        allocator: std.mem.Allocator,

        const Node = struct {
            interval: RangeType,
            max_upper: ?T,
            left: ?*Node,
            right: ?*Node,
            data: usize,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .root = null, .allocator = allocator };
        }

        pub fn insert(self: *Self, interval: RangeType, data: usize) !void {
            const node = try self.allocator.create(Node);
            node.* = Node{
                .interval = interval,
                .max_upper = interval.upper,
                .left = null,
                .right = null,
                .data = data,
            };

            self.root = try insertNode(self.allocator, self.root, node);
        }

        pub fn queryContains(self: Self, value: T, allocator: std.mem.Allocator) ![]usize {
            var results = std.ArrayList(usize).initCapacity(allocator, 0) catch return error.OutOfMemory;
            try queryContainsRec(allocator, self.root, value, &results);
            return results.toOwnedSlice(allocator);
        }

        pub fn queryOverlaps(self: Self, query_range: RangeType, allocator: std.mem.Allocator) ![]usize {
            var results = std.ArrayList(usize).initCapacity(allocator, 0) catch return error.OutOfMemory;
            try queryOverlapsRec(allocator, self.root, query_range, &results);
            return results.toOwnedSlice(allocator);
        }

        fn insertNode(allocator: std.mem.Allocator, node: ?*Node, new_node: *Node) !?*Node {
            if (node == null) return new_node;

            const n = node.?;
            const cmp = compareLower(T, new_node.interval, n.interval);

            if (cmp <= 0) {
                n.left = try insertNode(allocator, n.left, new_node);
            } else {
                n.right = try insertNode(allocator, n.right, new_node);
            }

            updateMaxUpper(n);
            return n;
        }

        fn queryContainsRec(allocator: std.mem.Allocator, node: ?*Node, value: T, results: *std.ArrayList(usize)) !void {
            if (node == null) return;
            const n = node.?;

            if (n.interval.contains(value)) {
                try results.append(allocator, n.data);
            }

            if (n.left != null and (n.left.?.max_upper == null or compare(T, value, n.left.?.max_upper.?) <= 0)) {
                try queryContainsRec(allocator, n.left, value, results);
            }
            if (n.right != null) {
                try queryContainsRec(allocator, n.right, value, results);
            }
        }

        fn queryOverlapsRec(allocator: std.mem.Allocator, node: ?*Node, query_range: RangeType, results: *std.ArrayList(usize)) !void {
            if (node == null) return;
            const n = node.?;

            if (n.interval.overlaps(query_range)) {
                try results.append(allocator, n.data);
            }

            if (n.left != null) {
                try queryOverlapsRec(allocator, n.left, query_range, results);
            }
            if (n.right != null and shouldSearchRight(n, query_range)) {
                try queryOverlapsRec(allocator, n.right, query_range, results);
            }
        }

        fn shouldSearchRight(node: *Node, query_range: RangeType) bool {
            if (query_range.lower == null) return true;
            if (node.interval.lower == null) return true;
            return compare(T, query_range.lower.?, node.interval.lower.?) >= 0;
        }

        fn updateMaxUpper(node: *Node) void {
            node.max_upper = node.interval.upper;

            if (node.left) |left| {
                if (left.max_upper != null and (node.max_upper == null or
                    compare(T, left.max_upper.?, node.max_upper.?) > 0))
                {
                    node.max_upper = left.max_upper;
                }
            }

            if (node.right) |right| {
                if (right.max_upper != null and (node.max_upper == null or
                    compare(T, right.max_upper.?, node.max_upper.?) > 0))
                {
                    node.max_upper = right.max_upper;
                }
            }
        }

        fn compareLower(comptime ValueType: type, a: RangeType, b: RangeType) i8 {
            if (a.lower == null and b.lower == null) return 0;
            if (a.lower == null) return -1;
            if (b.lower == null) return 1;
            return compare(ValueType, a.lower.?, b.lower.?);
        }

        fn compare(comptime ValueType: type, a: ValueType, b: ValueType) i8 {
            return switch (@typeInfo(ValueType)) {
                .int, .float => if (a < b) -1 else if (a > b) 1 else 0,
                else => @compileError("Unsupported type for comparison"),
            };
        }

        pub fn deinit(self: *Self) void {
            deinitNode(self.allocator, self.root);
        }

        fn deinitNode(allocator: std.mem.Allocator, node: ?*Node) void {
            if (node) |n| {
                deinitNode(allocator, n.left);
                deinitNode(allocator, n.right);
                allocator.destroy(n);
            }
        }
    };
}

pub const IntIntervalTree = IntervalTree(i32);

test "interval tree operations" {
    const allocator = std.testing.allocator;
    var tree = IntIntervalTree.init(allocator);
    defer tree.deinit();

    const r1 = try range.IntRange.init(1, 5, .inclusive_exclusive);
    const r2 = try range.IntRange.init(3, 8, .inclusive_exclusive);

    try tree.insert(r1, 100);
    try tree.insert(r2, 200);

    const results = try tree.queryContains(4, allocator);
    defer allocator.free(results);

    std.testing.expect(results.len == 2) catch unreachable;
}
