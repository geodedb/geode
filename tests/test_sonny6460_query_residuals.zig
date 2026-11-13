// SONNY-6460 regressions.
//
//   3. `src/exec.zig` `groupAndAggregate` (the `gql` executable's GROUP BY
//      engine) never freed a group's accumulators, its key slice or its
//      COUNT DISTINCT sets, so the `gql` executable leaked on every grouped
//      query. Its COUNT DISTINCT set was also read through an `undefined`
//      pointer (the "not yet allocated" check compared it with 0) and kept
//      keys it had already freed. The caller owns the returned rows and the
//      slice that holds them, and frees both with `exec.freeGroupedRows`.
//
// Leak-checked with std.testing.allocator. No mocks.
//
// CANARY: REQ=REQ-SONNY-6460-QUERY-RESIDUALS; FEATURE="GqlEngineAggregation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6460_query_residuals.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const exec = geode.exec;
const BV = exec.BindingValue;

/// The caller owns the returned rows and the slice holding them.
fn freeOut(allocator: std.mem.Allocator, out: []const []const BV) void {
    for (out) |row| allocator.free(row);
    allocator.free(out);
}

fn findGroup(out: []const []const BV, key: []const u8) ?[]const BV {
    for (out) |row| {
        if (row[0] == .Str and std.mem.eql(u8, row[0].Str, key)) return row;
    }
    return null;
}

test "SONNY-6460 (3): groupAndAggregate frees each group's accumulators and key" {
    const allocator = testing.allocator;
    const rows: []const []const BV = &.{
        &.{ .{ .Str = "a" }, .{ .Int = 1 } },
        &.{ .{ .Str = "b" }, .{ .Int = 2 } },
        &.{ .{ .Str = "a" }, .{ .Int = 3 } },
    };
    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = &.{ .Sum, .CountStar } };
    const out = try exec.groupAndAggregate(allocator, rows, spec, &.{ 1, 1 });
    defer freeOut(allocator, out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(i64, 4), findGroup(out, "a").?[1].Int);
    try testing.expectEqual(@as(i64, 2), findGroup(out, "a").?[2].Int);
    try testing.expectEqual(@as(i64, 2), findGroup(out, "b").?[1].Int);
}

test "SONNY-6460 (3): groupAndAggregate frees its accumulators, keys and COUNT DISTINCT sets" {
    const allocator = testing.allocator;
    const rows: []const []const BV = &.{
        &.{ .{ .Str = "a" }, .{ .Int = 1 }, .{ .Str = "x" } },
        &.{ .{ .Str = "a" }, .{ .Int = 2 }, .{ .Str = "x" } },
        &.{ .{ .Str = "a" }, .{ .Int = 2 }, .{ .Str = "y" } },
        &.{ .{ .Str = "b" }, .{ .Null = {} }, .{ .Str = "z" } },
        &.{ .{ .Str = "c" }, .{ .Decimal = .{ .coeff = 150, .scale = 2 } }, .{ .Null = {} } },
    };
    const spec = exec.GroupSpec{
        .key_idxs = &.{0},
        .aggs = &.{ .Count, .CountStar, .CountDistinct, .Sum, .Avg, .Min, .Max, .CountDistinct },
    };
    const out = try exec.groupAndAggregate(allocator, rows, spec, &.{ 1, 1, 2, 1, 1, 1, 1, 1 });
    defer freeOut(allocator, out);

    try testing.expectEqual(@as(usize, 3), out.len);
    const a = findGroup(out, "a").?;
    try testing.expectEqual(@as(i64, 3), a[1].Int); // COUNT(v)
    try testing.expectEqual(@as(i64, 3), a[2].Int); // COUNT(*)
    try testing.expectEqual(@as(i64, 2), a[3].Int); // COUNT(DISTINCT s): x, y
    try testing.expectEqual(@as(i64, 5), a[4].Int); // SUM
    try testing.expectEqual(@as(i64, 1), a[5].Int); // AVG (integer, truncated)
    try testing.expectEqual(@as(i64, 1), a[6].Int); // MIN
    try testing.expectEqual(@as(i64, 2), a[7].Int); // MAX
    try testing.expectEqual(@as(i64, 2), a[8].Int); // COUNT(DISTINCT v): 1, 2

    const b = findGroup(out, "b").?;
    try testing.expectEqual(@as(i64, 0), b[1].Int);
    try testing.expectEqual(@as(i64, 1), b[2].Int);
    try testing.expectEqual(@as(i64, 1), b[3].Int);
    try testing.expect(b[4] == .Null);
    try testing.expectEqual(@as(i64, 0), b[8].Int);

    const c = findGroup(out, "c").?;
    try testing.expectEqual(@as(i128, 150), c[4].Decimal.coeff);
    try testing.expectEqual(@as(i64, 0), c[3].Int); // COUNT(DISTINCT NULL)
}

test "SONNY-6460 (3): groupAndAggregate frees what it built when an allocation fails" {
    const rows: []const []const BV = &.{
        &.{ .{ .Str = "a" }, .{ .Int = 1 } },
        &.{ .{ .Str = "b" }, .{ .Int = 2 } },
        &.{ .{ .Str = "a" }, .{ .Int = 3 } },
    };
    const spec = exec.GroupSpec{ .key_idxs = &.{0}, .aggs = &.{ .Sum, .CountDistinct } };
    const Run = struct {
        fn go(allocator: std.mem.Allocator, r: []const []const BV, s: exec.GroupSpec) !void {
            const out = try exec.groupAndAggregate(allocator, r, s, &.{ 1, 1 });
            freeOut(allocator, out);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.go, .{ rows, spec });
}
