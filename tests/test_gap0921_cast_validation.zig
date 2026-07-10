// CANARY: REQ=REQ-GAP-0921-CAST-SEMANTIC-VALIDATION; FEATURE="TypeCasting"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0921_cast_validation.zig:1; OWNER=eval; UPDATED=2026-07-10
//
// Regression tests for GAP-0921: "CAST performs no semantic value
// validation".
//
// Before the fix, CAST('abc' AS INTEGER), casts to unsupported target types,
// and numeric overflow all silently returned NULL / 00000 rather than a
// typed error. CAST only rejected at parse time (missing type name → 42000).
//
// Expected after the fix (all in the `cast` eval branch; the Cypher-style
// toInteger/toBoolean helpers are intentionally left NULL-returning):
//   - unconvertible value → EvalError.InvalidCast (SQLSTATE 22018)
//   - unsupported target type → EvalError.UnsupportedCastTarget (0A000)
//   - numeric overflow → EvalError.IntegerOverflow (22003)
//   - CAST(null AS X) → NULL (unchanged), valid conversions unchanged

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
    fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "GAP-0921: unconvertible string CAST raises InvalidCast" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.InvalidCast, h.run("RETURN CAST('abc' AS INTEGER)"));
    try testing.expectError(error.InvalidCast, h.run("RETURN CAST('12.34.56' AS DECIMAL(10,2))"));
    try testing.expectError(error.InvalidCast, h.run("RETURN CAST('notabool' AS BOOLEAN)"));
    try testing.expectError(error.InvalidCast, h.run("RETURN CAST('not-a-date' AS TIMESTAMP)"));
}

test "GAP-0921: unsupported target type raises UnsupportedCastTarget" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.UnsupportedCastTarget, h.run("RETURN CAST('42' AS BANANA)"));
}

test "GAP-0921: numeric overflow raises IntegerOverflow" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.IntegerOverflow, h.run("RETURN CAST('99999999999999999999999999999' AS INTEGER)"));
}

test "GAP-0921: valid conversions and CAST(null) are unchanged" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Positive control.
    const ok = try h.run("RETURN CAST('42' AS INTEGER)");
    try testing.expectEqual(@as(usize, 1), ok.rows.len);
    try testing.expectEqual(@as(i64, 42), ok.rows[0][0].Int);

    // CAST(null) stays NULL (00000), not an error.
    const nul = try h.run("RETURN CAST(null AS INTEGER)");
    try testing.expectEqual(@as(usize, 1), nul.rows.len);
    switch (nul.rows[0][0]) {
        .Null => {},
        else => return error.ExpectedNull,
    }

    // A valid boolean/decimal conversion still works.
    const b = try h.run("RETURN CAST('true' AS BOOLEAN)");
    try testing.expectEqual(true, b.rows[0][0].Bool);
}
