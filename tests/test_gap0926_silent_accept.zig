// CANARY: REQ=REQ-GAP-0926-NESTED-AGGREGATE; FEATURE="Aggregation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0926_silent_accept.zig:1; OWNER=execution; UPDATED=2026-07-10
//
// Regression tests for the SAFE subset of GAP-0926's "silent-accept family":
//
//   - Out-of-range POSITIONAL parameter ($2 with one param) → error.MissingParameter
//     (SQLSTATE 22023) instead of silent NULL. (Missing NAMED params keep NULL —
//     documented residual; rejecting those risks breaking optional-param queries.)
//   - Nested aggregate (sum(avg(...))) → error.NestedAggregate (SQLSTATE 42803)
//     instead of silent NULL. Nested aggregates are always invalid in GQL/SQL.
//
// The other GAP-0926 sub-items (WHERE unbound variable, MERGE null/unbound key,
// missing named param, CREATE INDEX on a nonexistent label/property,
// non-grouped column, HAVING on an unknown alias) are INTENTIONALLY RETAINED as
// silent-accept: they are non-corrupting (the gap notes "no data corruption"),
// and forcing rejection risks breaking legitimate queries / the existing test
// suite — the same lesson learned when over-strict policy validation broke 14
// GPS tests (GAP-0923a). See docs/ENTERPRISE_GAPS.md for the per-item rationale.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .ctx = .{ .catalog = catalog } };
    }
    fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        self.arena.deinit();
    }
    fn run(self: *Harness, query: []const u8, param_names: []const []const u8, param_values: []const geode.protocol.Value) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        var ctx = self.ctx;
        ctx.query_param_names = param_names;
        ctx.query_param_values = param_values;
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }
};

test "GAP-0926: an out-of-range positional parameter raises MissingParameter" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Only $1 supplied; referencing $2 is an error, not NULL.
    const one_param = [_][]const u8{"1"};
    const one_val = [_]geode.protocol.Value{.{ .Int = 10 }};
    try testing.expectError(
        error.MissingParameter,
        h.run("RETURN $2 AS x", &one_param, &one_val),
    );

    // $1 (in range) still resolves.
    const res = try h.run("RETURN $1 AS x", &one_param, &one_val);
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 10), res.rows[0][0].Int);
}

test "GAP-0926: a missing NAMED parameter keeps the documented NULL behavior" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // No params supplied; a NAMED param resolves to NULL (retained residual).
    const res = try h.run("RETURN $missing AS x", &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    switch (res.rows[0][0]) {
        .Null => {},
        else => return error.ExpectedNull,
    }
}

test "GAP-0926: a nested aggregate is rejected" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(
        error.NestedAggregate,
        h.run("MATCH (n) RETURN sum(avg(n.v)) AS x", &.{}, &.{}),
    );
    // A binary expression hiding a nested aggregate is also caught.
    try testing.expectError(
        error.NestedAggregate,
        h.run("MATCH (n) RETURN sum(avg(n.v) + 1) AS x", &.{}, &.{}),
    );
}

test "GAP-0926: a normal single-level aggregate still works" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("MATCH (n) RETURN count(n) AS c", &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), res.rows.len);
}
