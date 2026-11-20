// SONNY-6518 item 3: the standalone `gql` tool's ORDER BY (src/exec.zig
// `stableOrderByTemporal`) orders as the server's full sort does.
//
// The server orders sort keys by `return_and_sorting`'s reference
// comparison (numbers by exact value across INT and DECIMAL, strings by
// their NFC forms) with NULLS FIRST by default in either direction (ISO/IEC
// 39075:2024 14.9 <order by and page statement> leaves the default null
// ordering implementation-defined; Geode's is NULLS FIRST). The exec tool
// compared every non-temporal key by its printed text, so 10 sorted before
// 9 and -1 after 1, and put NULLs last ascending and first descending.
//
// CANARY: REQ=REQ-SONNY-6518-EXEC-ORDER; FEATURE="StandaloneExec"; ASPECT=ReferenceOrder; STATUS=TESTED; TEST=tests/test_sonny6518_exec_order.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const exec = geode.exec;
const planner = geode.planner;
const ast = geode.ast;

fn order(keys: []const ast.Expr, desc: bool, nulls: ?ast.OrderBy.NullsPolicy) ![]usize {
    const allocator = std.testing.allocator;
    const rows = try allocator.alloc(exec.Row, keys.len);
    defer allocator.free(rows);
    for (keys, rows, 0..) |k, *r, i| r.* = .{ .id = i, .key = k };
    try exec.stableOrderByTemporal(rows, desc, nulls, planner.SessionContext{ .session_offset_minutes = 0 }, allocator);
    const ids = try allocator.alloc(usize, keys.len);
    for (rows, ids) |r, *id| id.* = r.id;
    return ids;
}

fn expectOrder(keys: []const ast.Expr, desc: bool, nulls: ?ast.OrderBy.NullsPolicy, want: []const usize) !void {
    const got = try order(keys, desc, nulls);
    defer std.testing.allocator.free(got);
    std.testing.expectEqualSlices(usize, want, got) catch |err| {
        std.debug.print("desc={} nulls={any}: want {any}, got {any}\n", .{ desc, nulls, want, got });
        return err;
    };
}

test "SONNY-6518: exec orders numbers by value, not by their text" {
    const keys = [_]ast.Expr{ .{ .Int = 10 }, .{ .Int = 9 }, .{ .Int = 100 }, .{ .Int = -1 } };
    try expectOrder(&keys, false, null, &.{ 3, 1, 0, 2 });
    try expectOrder(&keys, true, null, &.{ 2, 0, 1, 3 });
    // INT and DECIMAL by exact value: 1.5 between 1 and 2.
    const mixed = [_]ast.Expr{ .{ .Int = 2 }, .{ .Decimal = .{ .coeff = 15, .scale = 1 } }, .{ .Int = 1 } };
    try expectOrder(&mixed, false, null, &.{ 2, 1, 0 });
}

test "SONNY-6518: exec puts NULLs first by default in either direction, as the server does" {
    const keys = [_]ast.Expr{ .{ .Int = 2 }, .Null, .{ .Int = 1 } };
    try expectOrder(&keys, false, null, &.{ 1, 2, 0 });
    try expectOrder(&keys, true, null, &.{ 1, 0, 2 });
    try expectOrder(&keys, false, .last, &.{ 2, 0, 1 });
    try expectOrder(&keys, true, .last, &.{ 0, 2, 1 });
    try expectOrder(&keys, true, .first, &.{ 1, 0, 2 });
}
