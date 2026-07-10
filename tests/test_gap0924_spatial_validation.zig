// CANARY: REQ=REQ-GAP-0924-SPATIAL-SIMPLE-POLYGON; FEATURE="Spatial"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0924_spatial_validation.zig:1; OWNER=spatial; UPDATED=2026-07-10
//
// Regression tests for GAP-0924: "spatial functions swallow bad geometry to
// NULL; no bowtie check".
//
//   - malformed WKT and a degenerate (too-few-points) ring resolved to NULL
//     at the bare-call level; now they raise a typed error (surfaced as
//     TypeMismatch through the eval dispatch).
//   - self-intersecting ("bowtie") polygons were accepted with no
//     simple-polygon validation; the WKT parser now rejects them
//     (error.SelfIntersectingPolygon).
//
// NOTE: "nonexistent constructor -> NULL" is out of scope — an unknown
// function name resolving to NULL is general (optional-function-probing)
// behavior, not spatial-specific.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const wkt = geode.types.wkt;
const execution = geode.execution;

// ---- WKT-parser-level checks (the validation source of truth) ----

test "GAP-0924: a self-intersecting bowtie polygon is rejected" {
    // (0 0)->(2 2) crosses (2 0)->(0 2) at (1,1): a classic bowtie.
    try testing.expectError(
        error.SelfIntersectingPolygon,
        wkt.parseWktToWkb(testing.allocator, "POLYGON((0 0, 2 2, 2 0, 0 2, 0 0))"),
    );
}

test "GAP-0924: a simple (valid) polygon still parses" {
    const wkb = try wkt.parseWktToWkb(testing.allocator, "POLYGON((0 0, 0 1, 1 1, 1 0, 0 0))");
    defer testing.allocator.free(wkb);
    try testing.expect(wkb.len > 0);
}

test "GAP-0924: a degenerate ring (too few points) is rejected" {
    try testing.expectError(
        error.InvalidWkt,
        wkt.parseWktToWkb(testing.allocator, "POLYGON((0 0, 1 1, 0 0))"),
    );
}

test "GAP-0924: malformed WKT is rejected at the parser" {
    try testing.expectError(
        error.InvalidWkt,
        wkt.parseWktToWkb(testing.allocator, "POLYGON((0 0, notanumber 1, 1 1, 0 0))"),
    );
}

// ---- eval-level check: bad geometry surfaces as an error, not NULL ----

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

test "GAP-0924: bare GeometryFromText('bad') errors instead of returning NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try testing.expectError(error.TypeMismatch, h.run("RETURN GeometryFromText('POLYGON((0 0, 2 2, 2 0, 0 2, 0 0))')"));
    try testing.expectError(error.TypeMismatch, h.run("RETURN GeometryFromText('NOTWKT')"));

    // A valid geometry still constructs (non-null).
    const res = try h.run("RETURN GeometryFromText('POINT(1 2)')");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    switch (res.rows[0][0]) {
        .Null => return error.UnexpectedNull,
        else => {},
    }
}

test "GAP-0924: a nested/composed bad-geometry error propagates (not swallowed to NULL)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // The bare-call error must ALSO surface when GeometryFromText is nested as
    // a function argument — the registry arg-eval used to swallow it to NULL,
    // so ST_AsText(bad)/ST_Contains(bad, …) short-circuited the whole call to
    // NULL instead of raising the error the bare call raises.
    try testing.expectError(error.TypeMismatch, h.run("RETURN ST_AsText(GeometryFromText('POINT(banana)')) AS wkt"));
    try testing.expectError(error.TypeMismatch, h.run("RETURN ST_AsText(GeometryFromText('POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))')) AS g"));
    try testing.expectError(error.TypeMismatch, h.run("RETURN ST_Contains(GeometryFromText('POLYGON((0 0, 10 10))'), ST_Point(5,5)) AS c"));
}
