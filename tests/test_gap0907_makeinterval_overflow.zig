// CANARY: REQ=REQ-GAP-0907-MAKEINTERVAL-OVERFLOW; FEATURE="IntervalConstruction"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0907_makeinterval_overflow.zig:1; OWNER=eval; UPDATED=2026-07-10
//
// Regression tests for GAP-0907: "`MakeInterval(2147483648, …)` panics
// (unchecked `@intCast`)".
//
// Root cause: the `makeinterval` handler (src/eval/call_handlers.zig)
// narrowed its i64 months/days arguments to the Interval's i32 fields with
// unchecked `@intCast`, so any argument outside i32 range panicked and
// killed the server.
//
// Expected behavior after the fix: out-of-range months/days raise
// EvalError.IntegerOverflow (SQLSTATE 22003 on the wire) — never a panic.

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

test "GAP-0907: months argument beyond i32 raises IntegerOverflow, not a panic" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.IntegerOverflow, h.run("RETURN MakeInterval(2147483648, 1, 1)"));
}

test "GAP-0907: days argument beyond i32 raises IntegerOverflow, not a panic" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.IntegerOverflow, h.run("RETURN MakeInterval(1, 2147483648, 1)"));
}

test "GAP-0907: boundary values are accepted" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("RETURN MakeInterval(2147483647, 2147483647, 9000000)");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    switch (res.rows[0][0]) {
        .Interval => |iv| {
            try testing.expectEqual(@as(i32, 2_147_483_647), iv.months);
            try testing.expectEqual(@as(i32, 2_147_483_647), iv.days);
            try testing.expectEqual(@as(i64, 9_000_000), iv.micros);
        },
        else => return error.ExpectedInterval,
    }
}

test "GAP-0907: ordinary MakeInterval still works" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("RETURN MakeInterval(12, 30, 500000)");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    switch (res.rows[0][0]) {
        .Interval => |iv| {
            try testing.expectEqual(@as(i32, 12), iv.months);
            try testing.expectEqual(@as(i32, 30), iv.days);
            try testing.expectEqual(@as(i64, 500_000), iv.micros);
        },
        else => return error.ExpectedInterval,
    }
}
