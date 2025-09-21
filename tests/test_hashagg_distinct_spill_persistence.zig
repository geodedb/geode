// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggDistinctSpillPersistence; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_HashAggDistinctSpillPersistence; OWNER=engine; UPDATED=2025-09-21
const std = @import("std");
const exec = @import("../src/exec.zig");
const ast = @import("../src/gql/ast.zig");
const eval = @import("../src/eval.zig");

// Build synthetic rows with many duplicates to force COUNT DISTINCT spill across segments.
// We configure a very small memory limit so first flush occurs quickly.
// Then we ensure final COUNT DISTINCT equals number of unique non-null values.

test "TestCANARY_REQ_GQL_012_HashAggDistinctSpillPersistence" {
    const ally = std.testing.allocator;
    var agg = exec.HashAggregator.init(ally, 512); // tiny memory limit
    defer agg.deinit();

    // One grouping key constant so all rows belong to same group, counting distinct over value column.
    const key_val = exec.BindingValue{ .Int = 1 };
    const agg_spec = [_]exec.Agg{.CountDistinct};

    // Generate values 0..199 (200 distinct) each repeated twice to enlarge input.
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const v: i64 = @intCast(i % 200);
        var key_slice = [_]exec.BindingValue{key_val};
        var agg_inputs = [_]exec.BindingValue{.{ .Int = v }};
        try agg.addRow(&key_slice, &agg_inputs, &agg_spec);
    }

    // Force a final flush to ensure any remaining groups serialized
    try agg.flushSegment(&agg_spec);

    const rows = try agg.getResults();
    defer ally.free(rows);
    try std.testing.expect(rows.len == 1);
    // Single row: key + COUNT DISTINCT result
    const r = rows[0];
    try std.testing.expect(r.len == 2);
    try std.testing.expect(r[1] == .Int and r[1].Int == 200);
}
