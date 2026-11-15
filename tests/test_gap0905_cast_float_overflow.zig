// CANARY: REQ=REQ-GAP-0905-CAST-FLOAT-OVERFLOW; FEATURE="TypeCasting"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0905_cast_float_overflow.zig:1; OWNER=eval; UPDATED=2026-07-10
//
// Regression tests for GAP-0905: "`CAST(<huge-float> AS INTEGER)` panics
// (out-of-bounds)".
//
// Two panic sites were involved:
//   1. src/gql/parser.zig — a scientific-notation float literal is converted
//      to a scale-15 Decimal via `@intFromFloat(value * 1e15)` into i128 with
//      no range guard, so `1.0e308` panicked at PARSE time ("integer part of
//      floating point value out of bounds") and killed the server.
//   2. src/eval/call_handlers.zig — Decimal → INTEGER cast did an unchecked
//      `@intCast(coeff)` (i128 → i64), so a representable-but-huge decimal
//      (e.g. `9.9e30`) panicked at EXECUTION time.
//
// Expected behavior after the fix:
//   - Literals whose scale-15 coefficient exceeds i128 fall back to a
//     scale-0 (integer-valued) decimal when representable; a literal that
//     cannot be represented at all is a clean parse error (error.Overflow,
//     matching the pre-existing oversized-integer-literal policy).
//   - Decimal → INTEGER casts whose value exceeds i64 raise
//     EvalError.IntegerOverflow (mapped to SQLSTATE 22003 on the wire)
//     instead of panicking.

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
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

// SONNY-6596: a literal with an exponent is an approximate numeric literal
// (ISO/IEC 39075:2024 21.2), a DOUBLE. 1.0e308 is a DOUBLE value (SR 20), so
// it evaluates; only a literal past the DOUBLE range is refused, still a
// clean parse error. Its CAST to INTEGER is 22003 (IntegerOverflow).
test "GAP-0905: 1.0e308 float literal must not panic the parser" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.IntegerOverflow, h.run("RETURN CAST(1.0e308 AS INTEGER)"));
    try testing.expectError(error.Overflow, h.run("RETURN 1.0e309"));
    try testing.expectError(error.Overflow, h.run("RETURN -1.0e309"));
    const res = try h.run("RETURN -1.0e308");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(f64, -1.0e308), res.rows[0][0].Double);
}

test "GAP-0905: huge-but-representable literal is a DOUBLE" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("RETURN 1.0e30");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(f64, 1.0e30), res.rows[0][0].Double);
}

test "GAP-0905: small scientific literals are exact DOUBLE values" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("RETURN 1.5e3");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(f64, 1500.0), res.rows[0][0].Double);
}

test "GAP-0905: CAST of a > i64 decimal to INTEGER raises IntegerOverflow, not a panic" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // 9.9 x 10^30 as an exact decimal (SONNY-6596: `9.9e30` is a DOUBLE) exceeds
    // i64: the cast must raise a typed error instead of hitting unchecked @intCast.
    try testing.expectError(error.IntegerOverflow, h.run("RETURN CAST(9900000000000000000000000000000.0 AS INTEGER)"));
    try testing.expectError(error.IntegerOverflow, h.run("RETURN CAST(9.9e30 AS INTEGER)"));
}

test "GAP-0905: in-range float-literal CAST to INTEGER still works" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("RETURN CAST(2.0e3 AS INTEGER)");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 2000), res.rows[0][0].Int);
}
