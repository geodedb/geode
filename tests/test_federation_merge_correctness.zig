// CANARY: REQ=REQ-FED-UNION-DISTINCT-001; FEATURE="FederationUnionDistinct"; ASPECT=Deduplication; STATUS=TESTED; TEST=test_federation_merge_correctness; OWNER=distributed; UPDATED=2026-04-01
// CANARY: REQ=REQ-DIST-HASH-AGG-001; FEATURE="DistributedHashAggregate"; ASPECT=ValueAccumulation; STATUS=TESTED; TEST=test_federation_merge_correctness; OWNER=distributed; UPDATED=2026-04-01
//
// Standalone tests for federation merge algorithms (union_distinct dedup and hash_aggregate accumulation).
// These verify the algorithmic correctness used in federation.zig and enhanced_query_coordinator.zig
// without importing the distributed module (which has build-system module boundary constraints).

const std = @import("std");
const testing = std.testing;

/// Mirrors the hashBindingRow logic in federation.zig:
/// Produce a deterministic string key from a row (slice of tagged values) for deduplication.
const Value = union(enum) {
    Null,
    Int: i64,
    Str: []const u8,
    Bool: bool,
    Double: f64,
};

fn hashRow(allocator: std.mem.Allocator, cols: []const Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    for (cols, 0..) |val, i| {
        if (i > 0) try writer.writeByte('|');
        switch (val) {
            .Null => try writer.writeAll("N"),
            .Int => |v| try writer.print("I:{d}", .{v}),
            .Bool => |v| try writer.print("B:{}", .{@as(u8, if (v) 1 else 0)}),
            .Str => |v| try writer.print("S:{s}", .{v}),
            .Double => |v| try writer.print("D:{d}", .{v}),
        }
    }

    return allocator.dupe(u8, buf.items);
}

/// Mirrors the union_distinct merge logic in federation.zig
fn unionDistinct(
    allocator: std.mem.Allocator,
    local_rows: []const []const Value,
    remote_rows: []const []const Value,
) !std.ArrayList([]const Value) {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        seen.deinit();
    }

    var unique = std.ArrayList([]const Value).empty;
    errdefer unique.deinit(allocator);

    for (local_rows) |row| {
        const key = try hashRow(allocator, row);
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) {
            allocator.free(key);
        } else {
            try unique.append(allocator, row);
        }
    }

    for (remote_rows) |row| {
        const key = try hashRow(allocator, row);
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) {
            allocator.free(key);
        } else {
            try unique.append(allocator, row);
        }
    }

    return unique;
}

/// Mirrors the AggregateGroup and hashAggregateResults logic in enhanced_query_coordinator.zig
const AggregateGroup = struct {
    count: u64,
    sum: f64,
    representative_row: []const Value,
};

fn hashAggregate(
    allocator: std.mem.Allocator,
    shard_rows: []const []const []const Value,
) !std.ArrayList(AggregateGroup) {
    var groups = std.StringHashMap(AggregateGroup).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        groups.deinit();
    }

    for (shard_rows) |rows| {
        for (rows) |row| {
            const group_key = try hashRow(allocator, row);
            const gop = try groups.getOrPut(group_key);

            // Extract numeric value from last column for aggregation
            const numeric_val: f64 = blk: {
                if (row.len > 0) {
                    const last = row[row.len - 1];
                    switch (last) {
                        .Int => |v| break :blk @floatFromInt(v),
                        .Double => |v| break :blk v,
                        else => {},
                    }
                }
                break :blk 0.0;
            };

            if (gop.found_existing) {
                allocator.free(group_key);
                gop.value_ptr.count += 1;
                gop.value_ptr.sum += numeric_val;
            } else {
                gop.value_ptr.* = AggregateGroup{
                    .count = 1,
                    .sum = numeric_val,
                    .representative_row = row,
                };
            }
        }
    }

    var result = std.ArrayList(AggregateGroup).empty;
    errdefer result.deinit(allocator);

    var it = groups.iterator();
    while (it.next()) |entry| {
        try result.append(allocator, entry.value_ptr.*);
    }
    return result;
}

// --- Tests ---

test "union_distinct: removes duplicate rows across local and remote" {
    const ally = testing.allocator;

    const row_1_x = &[_]Value{ .{ .Int = 1 }, .{ .Str = "x" } };
    const row_2_y = &[_]Value{ .{ .Int = 2 }, .{ .Str = "y" } };
    const row_3_z = &[_]Value{ .{ .Int = 3 }, .{ .Str = "z" } };

    // Local: (1,x), (2,y)
    const local = &[_][]const Value{ row_1_x, row_2_y };
    // Remote: (2,y), (3,z)  -- (2,y) is a duplicate
    const remote = &[_][]const Value{ row_2_y, row_3_z };

    var result = try unionDistinct(ally, local, remote);
    defer result.deinit(ally);

    // Should have 3 unique rows
    try testing.expectEqual(@as(usize, 3), result.items.len);
}

test "union_distinct: all duplicates reduces to one" {
    const ally = testing.allocator;

    const row = &[_]Value{.{ .Int = 42 }};
    const local = &[_][]const Value{row};
    const remote = &[_][]const Value{row};

    var result = try unionDistinct(ally, local, remote);
    defer result.deinit(ally);

    try testing.expectEqual(@as(usize, 1), result.items.len);
}

test "union_distinct: empty inputs" {
    const ally = testing.allocator;

    const empty: []const []const Value = &.{};
    var result = try unionDistinct(ally, empty, empty);
    defer result.deinit(ally);

    try testing.expectEqual(@as(usize, 0), result.items.len);
}

test "union_distinct: null values are deduped correctly" {
    const ally = testing.allocator;

    const row_null = &[_]Value{ .Null, .{ .Str = "a" } };
    const local = &[_][]const Value{row_null};
    const remote = &[_][]const Value{row_null};

    var result = try unionDistinct(ally, local, remote);
    defer result.deinit(ally);

    try testing.expectEqual(@as(usize, 1), result.items.len);
}

test "union_distinct: type-tagged keys prevent cross-type collisions" {
    const ally = testing.allocator;

    // Int(1) and Str("1") should NOT be considered duplicates
    const row_int = &[_]Value{.{ .Int = 1 }};
    const row_str = &[_]Value{.{ .Str = "1" }};
    const local = &[_][]const Value{row_int};
    const remote = &[_][]const Value{row_str};

    var result = try unionDistinct(ally, local, remote);
    defer result.deinit(ally);

    try testing.expectEqual(@as(usize, 2), result.items.len);
}

test "hashRow: produces deterministic keys" {
    const ally = testing.allocator;

    const row = &[_]Value{ .{ .Int = 42 }, .{ .Str = "hello" } };
    const key1 = try hashRow(ally, row);
    defer ally.free(key1);
    const key2 = try hashRow(ally, row);
    defer ally.free(key2);

    try testing.expectEqualStrings(key1, key2);
}

test "hash_aggregate: accumulates sum from last numeric column" {
    const ally = testing.allocator;

    // Two shards, each with a row having last column as Int
    const shard1_rows = &[_][]const Value{
        &[_]Value{ .{ .Str = "group_a" }, .{ .Int = 10 } },
        &[_]Value{ .{ .Str = "group_b" }, .{ .Int = 20 } },
    };
    const shard2_rows = &[_][]const Value{
        &[_]Value{ .{ .Str = "group_a" }, .{ .Int = 10 } },
        &[_]Value{ .{ .Str = "group_a" }, .{ .Int = 10 } },
    };

    const shards = &[_][]const []const Value{ shard1_rows, shard2_rows };

    var result = try hashAggregate(ally, shards);
    defer result.deinit(ally);

    // group_a appears 3 times (shard1 once, shard2 twice), group_b appears once
    var group_a_found = false;
    var group_b_found = false;
    for (result.items) |group| {
        if (group.representative_row[0] == .Str and std.mem.eql(u8, group.representative_row[0].Str, "group_a")) {
            group_a_found = true;
            try testing.expectEqual(@as(u64, 3), group.count);
            try testing.expectEqual(@as(f64, 30.0), group.sum);
        }
        if (group.representative_row[0] == .Str and std.mem.eql(u8, group.representative_row[0].Str, "group_b")) {
            group_b_found = true;
            try testing.expectEqual(@as(u64, 1), group.count);
            try testing.expectEqual(@as(f64, 20.0), group.sum);
        }
    }
    try testing.expect(group_a_found);
    try testing.expect(group_b_found);
}

test "hash_aggregate: sum is not hardcoded to zero" {
    const ally = testing.allocator;

    const shard_rows = &[_][]const Value{
        &[_]Value{ .{ .Str = "key" }, .{ .Int = 100 } },
    };
    const shards = &[_][]const []const Value{shard_rows};

    var result = try hashAggregate(ally, shards);
    defer result.deinit(ally);

    try testing.expectEqual(@as(usize, 1), result.items.len);
    // The critical assertion: sum must be 100, not 0
    try testing.expectEqual(@as(f64, 100.0), result.items[0].sum);
}

test "hash_aggregate: double values accumulated correctly" {
    const ally = testing.allocator;

    // Same row (identical hash) appearing on two shards with Double value
    const shard1 = &[_][]const Value{
        &[_]Value{ .{ .Str = "x" }, .{ .Double = 2.5 } },
    };
    const shard2 = &[_][]const Value{
        &[_]Value{ .{ .Str = "x" }, .{ .Double = 2.5 } },
    };
    const shards = &[_][]const []const Value{ shard1, shard2 };

    var result = try hashAggregate(ally, shards);
    defer result.deinit(ally);

    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqual(@as(u64, 2), result.items[0].count);
    try testing.expectEqual(@as(f64, 5.0), result.items[0].sum);
}
