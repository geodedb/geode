//! RLS Value Bridge — converts execution-layer values to rls_core.Value for policy evaluation.
//!
//! CANARY: REQ=REQ-SEC-RLS-WIRE-010; FEATURE="RLS Expression Wiring"; ASPECT=ValueBridge; STATUS=TESTED; TEST=src/security/rls_value_bridge.zig; OWNER=security; UPDATED=2026-04-06
//!
//! GAP-0510 Task 1: The RLS expression engine (rls_core.zig) uses its own Value union,
//! while the execution engine uses value_types.Value and graph_store.PropertyValue.
//! This module provides the conversion bridge so production code paths can call
//! checkRowAccess() with node/edge properties translated to RLS-compatible rows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rls = @import("rls");
const geode = @import("geode");
const graph_store = geode.graph_store;
const value_types = geode.value_types;

/// Convert an execution-engine Value to an rls_core.Value.
///
/// Mapping:
///   .Null                  → .{ .null = {} }
///   .Int(v)                → .{ .integer = v }
///   .Bool(v)               → .{ .boolean = v }
///   .Str(v)                → .{ .string = v }
///   .Decimal{coeff,scale}  → .{ .float = coeff / 10^scale }
///   everything else        → .{ .null = {} }  (Node, Edge, Path, List, Map, ExtValue)
pub fn toRLSValue(val: value_types.Value) rls.Value {
    return switch (val) {
        .Null => .{ .null = {} },
        .Int => |v| .{ .integer = v },
        .Bool => |v| .{ .boolean = v },
        .Str => |v| .{ .string = v },
        .Decimal => |d| blk: {
            // coeff * 10^-scale → f64
            const divisor = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
            const float_val = @as(f64, @floatFromInt(d.coeff)) / divisor;
            break :blk .{ .float = float_val };
        },
        // Node, Edge, Path, List, Map, ExtValue — no sensible scalar representation
        else => .{ .null = {} },
    };
}

/// Convert a node's property map to an RLS-compatible row suitable for checkRowAccess().
///
/// Returns a new StringHashMap(rls.Value) where each PropertyValue is converted:
///   .String(s)  → .{ .string = s }   (slice points into original; no copy)
///   .Int(v)     → .{ .integer = v }
///   .Float(v)   → .{ .float = v }
///   .Bool(v)    → .{ .boolean = v }
///   .Null       → .{ .null = {} }
///   .Decimal    → .{ .float = coeff / 10^scale }
///   .ExtValue   → .{ .null = {} }    (opaque; cannot map to scalar)
///
/// Caller owns the returned map (must call .deinit()).
pub fn nodePropertiesToRLSRow(
    allocator: Allocator,
    properties: *const std.StringHashMap(graph_store.PropertyValue),
) !std.StringHashMap(rls.Value) {
    var row = std.StringHashMap(rls.Value).init(allocator);
    errdefer row.deinit();

    // Pre-size to property count to eliminate per-put rehash. Saves the
    // 0->16->32->... allocator calls observed in the H5a T2 stack
    // (HashMap.allocate frame). Each rehash was an O(n) memcpy.
    try row.ensureTotalCapacity(@as(u32, @intCast(properties.count())));

    var it = properties.iterator();
    while (it.next()) |entry| {
        const rls_val = propertyValueToRLS(entry.value_ptr.*);
        row.putAssumeCapacityNoClobber(entry.key_ptr.*, rls_val);
    }

    return row;
}

/// Reusable variant of `nodePropertiesToRLSRow`: caller owns and reuses
/// `row` across many invocations. Clears the row's contents (retaining
/// the backing buffer) before populating, then ensures capacity for the
/// new property count and inserts each property without bounds checks.
///
/// Use this from per-node loops (`executeMultiNodeMatch` et al.) to
/// avoid one HashMap init/deinit per matched node.
pub fn nodePropertiesToRLSRowInto(
    row: *std.StringHashMap(rls.Value),
    properties: *const std.StringHashMap(graph_store.PropertyValue),
) !void {
    row.clearRetainingCapacity();
    try row.ensureTotalCapacity(@as(u32, @intCast(properties.count())));

    var it = properties.iterator();
    while (it.next()) |entry| {
        const rls_val = propertyValueToRLS(entry.value_ptr.*);
        row.putAssumeCapacityNoClobber(entry.key_ptr.*, rls_val);
    }
}

/// Convert a single PropertyValue to rls.Value.
fn propertyValueToRLS(pv: graph_store.PropertyValue) rls.Value {
    return switch (pv) {
        .String => |s| .{ .string = s },
        .Int => |v| .{ .integer = v },
        .Float => |v| .{ .float = v },
        .Bool => |v| .{ .boolean = v },
        .Null => .{ .null = {} },
        .Decimal => |d| blk: {
            const divisor = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
            const float_val = @as(f64, @floatFromInt(d.coeff)) / divisor;
            break :blk .{ .float = float_val };
        },
        .ExtValue => .{ .null = {} },
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "toRLSValue: Null maps to rls null" {
    const result = toRLSValue(.Null);
    try std.testing.expectEqual(rls.ValueType.null, std.meta.activeTag(result));
}

test "toRLSValue: Int maps to rls integer" {
    const result = toRLSValue(.{ .Int = 42 });
    try std.testing.expectEqual(rls.ValueType.integer, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(i64, 42), result.integer);
}

test "toRLSValue: Bool true maps to rls boolean" {
    const result = toRLSValue(.{ .Bool = true });
    try std.testing.expectEqual(rls.ValueType.boolean, std.meta.activeTag(result));
    try std.testing.expect(result.boolean);
}

test "toRLSValue: Bool false maps to rls boolean" {
    const result = toRLSValue(.{ .Bool = false });
    try std.testing.expectEqual(rls.ValueType.boolean, std.meta.activeTag(result));
    try std.testing.expect(!result.boolean);
}

test "toRLSValue: Str maps to rls string" {
    const result = toRLSValue(.{ .Str = "hello" });
    try std.testing.expectEqual(rls.ValueType.string, std.meta.activeTag(result));
    try std.testing.expectEqualStrings("hello", result.string);
}

test "toRLSValue: Decimal maps to rls float" {
    // 123 * 10^-2 = 1.23
    const result = toRLSValue(.{ .Decimal = .{ .coeff = 123, .scale = 2 } });
    try std.testing.expectEqual(rls.ValueType.float, std.meta.activeTag(result));
    try std.testing.expectApproxEqAbs(@as(f64, 1.23), result.float, 1e-9);
}

test "toRLSValue: Decimal scale=0 maps to integer-valued float" {
    const result = toRLSValue(.{ .Decimal = .{ .coeff = 7, .scale = 0 } });
    try std.testing.expectEqual(rls.ValueType.float, std.meta.activeTag(result));
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), result.float, 1e-9);
}

test "toRLSValue: List maps to rls null (fallthrough)" {
    const list: []value_types.Value = &[_]value_types.Value{};
    const result = toRLSValue(.{ .List = list });
    try std.testing.expectEqual(rls.ValueType.null, std.meta.activeTag(result));
}

test "nodePropertiesToRLSRow: converts all property variants" {
    const allocator = std.testing.allocator;

    var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props.deinit();

    try props.put("name", .{ .String = "Alice" });
    try props.put("age", .{ .Int = 30 });
    try props.put("score", .{ .Float = 9.5 });
    try props.put("active", .{ .Bool = true });
    try props.put("nothing", .Null);
    try props.put("amount", .{ .Decimal = .{ .coeff = 1999, .scale = 2 } });

    var row = try nodePropertiesToRLSRow(allocator, &props);
    defer row.deinit();

    try std.testing.expectEqual(@as(usize, 6), row.count());

    const name_val = row.get("name") orelse return error.MissingKey;
    try std.testing.expectEqualStrings("Alice", name_val.string);

    const age_val = row.get("age") orelse return error.MissingKey;
    try std.testing.expectEqual(@as(i64, 30), age_val.integer);

    const score_val = row.get("score") orelse return error.MissingKey;
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), score_val.float, 1e-9);

    const active_val = row.get("active") orelse return error.MissingKey;
    try std.testing.expect(active_val.boolean);

    const nothing_val = row.get("nothing") orelse return error.MissingKey;
    try std.testing.expectEqual(rls.ValueType.null, std.meta.activeTag(nothing_val));

    const amount_val = row.get("amount") orelse return error.MissingKey;
    try std.testing.expectApproxEqAbs(@as(f64, 19.99), amount_val.float, 1e-9);
}

test "nodePropertiesToRLSRow: empty properties produces empty row" {
    const allocator = std.testing.allocator;
    var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props.deinit();

    var row = try nodePropertiesToRLSRow(allocator, &props);
    defer row.deinit();

    try std.testing.expectEqual(@as(usize, 0), row.count());
}
