// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Hot-path coverage for nodePropertiesToRLSRow + nodePropertiesToRLSRowInto.
//! Pins the H5a primary-fix part A behaviour: pre-sized fresh-row path
//! produces correct output, reusable variant is semantically equivalent,
//! and reuse across 1000 cycles does not leak.
//!
//! CANARY: REQ=REQ-PERF-RLS-ROW-BUILD-001; FEATURE="RLSRowBuildHotPath"; ASPECT=PreSizeAndReuse; STATUS=TESTED; TEST=tests/test_rls_row_build_hot_path.zig; OWNER=performance; UPDATED=2026-04-26

const std = @import("std");
const geode = @import("geode");
const rls = @import("rls");
const graph_store = geode.graph_store;
const rls_value_bridge = @import("rls_value_bridge");

fn buildPropertyMap(allocator: std.mem.Allocator, n: usize) !graph_store.CompactPropertyMap {
    var props = graph_store.CompactPropertyMap.init(allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "k{d}", .{i});
        try props.put(key, .{ .Int = @as(i64, @intCast(i)) });
    }
    return props;
}

fn freePropertyMap(allocator: std.mem.Allocator, props: *graph_store.CompactPropertyMap) void {
    var it = props.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    props.deinit();
}

test "nodePropertiesToRLSRow: pre-sized path produces correct output for 100 properties" {
    const allocator = std.testing.allocator;
    var props = try buildPropertyMap(allocator, 100);
    defer freePropertyMap(allocator, &props);

    var row = try rls_value_bridge.nodePropertiesToRLSRow(allocator, &props);
    defer row.deinit();

    try std.testing.expectEqual(@as(usize, 100), row.count());
    // Spot-check: k42 maps to integer 42.
    const v = row.get("k42") orelse return error.MissingKey;
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "nodePropertiesToRLSRowInto: produces identical output to nodePropertiesToRLSRow" {
    const allocator = std.testing.allocator;
    var props = try buildPropertyMap(allocator, 50);
    defer freePropertyMap(allocator, &props);

    var fresh_row = try rls_value_bridge.nodePropertiesToRLSRow(allocator, &props);
    defer fresh_row.deinit();

    var reused_row = std.StringHashMap(rls.Value).init(allocator);
    defer reused_row.deinit();
    try rls_value_bridge.nodePropertiesToRLSRowInto(&reused_row, &props);

    try std.testing.expectEqual(fresh_row.count(), reused_row.count());

    var it = fresh_row.iterator();
    while (it.next()) |entry| {
        const reused_val = reused_row.get(entry.key_ptr.*) orelse return error.MissingKey;
        // Both paths use propertyValueToRLS, so the discriminant + value match.
        try std.testing.expectEqual(std.meta.activeTag(entry.value_ptr.*), std.meta.activeTag(reused_val));
        switch (entry.value_ptr.*) {
            .integer => |v| try std.testing.expectEqual(v, reused_val.integer),
            else => {}, // 50-property fixture is all .Int — no other branches hit
        }
    }
}

test "nodePropertiesToRLSRowInto: reuse 1000 cycles does not leak" {
    const allocator = std.testing.allocator;
    var props = try buildPropertyMap(allocator, 20);
    defer freePropertyMap(allocator, &props);

    var row = std.StringHashMap(rls.Value).init(allocator);
    defer row.deinit();

    var cycle: usize = 0;
    while (cycle < 1000) : (cycle += 1) {
        try rls_value_bridge.nodePropertiesToRLSRowInto(&row, &props);
        try std.testing.expectEqual(@as(usize, 20), row.count());
    }
    // std.testing.allocator panics at the test runner level if anything leaked.
}

test "nodePropertiesToRLSRow: empty property map produces empty row" {
    const allocator = std.testing.allocator;
    var props = graph_store.CompactPropertyMap.init(allocator);
    defer props.deinit();

    var row = try rls_value_bridge.nodePropertiesToRLSRow(allocator, &props);
    defer row.deinit();

    try std.testing.expectEqual(@as(usize, 0), row.count());
}
