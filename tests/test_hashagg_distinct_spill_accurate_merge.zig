// CANARY: REQ=REQ-GQL-012; FEATURE="GROUP BY/Aggregation"; ASPECT=HashAggDistinctSpillAccurateMerge; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_012_HashAggDistinctSpillAccurateMerge; OWNER=engine; UPDATED=2025-09-21
const std = @import("std");
const exec = @import("../src/exec.zig");

// This test ensures the precise distinct merge logic does not overcount when segments share overlapping distinct values.
// We generate two phases of rows causing two spill segments with 150 distinct integers each, where 100 overlap.
// Expected final COUNT DISTINCT = 200 unique values (0..199).

test "TestCANARY_REQ_GQL_012_HashAggDistinctSpillAccurateMerge" {
    const ally = std.testing.allocator;
    var agg = exec.HashAggregator.init(ally, 512); // tiny limit to force multiple segments
    defer agg.deinit();

    const key_val = exec.BindingValue{ .Int = 42 };
    const agg_spec = [_]exec.Agg{ .CountDistinct };

    // First phase: values 0..149
    var i: usize = 0;
    while (i < 150) : (i += 1) {
        var key_slice = [_]exec.BindingValue{key_val};
    var inputs = [_]exec.BindingValue{ .{ .Int = @intCast(i) } };
        try agg.addRow(&key_slice, &inputs, &agg_spec);
    }
    try agg.flushSegment(&agg_spec); // spill segment 1

    // Second phase: values 50..199 (overlap 50..149)
    i = 50;
    while (i < 200) : (i += 1) {
        var key_slice2 = [_]exec.BindingValue{key_val};
    var inputs2 = [_]exec.BindingValue{ .{ .Int = @intCast(i) } };
        try agg.addRow(&key_slice2, &inputs2, &agg_spec);
    }
    try agg.flushSegment(&agg_spec); // spill segment 2

    const rows = try agg.getResults();
    defer ally.free(rows);
    try std.testing.expect(rows.len == 1);
    const r = rows[0];
    try std.testing.expect(r.len == 2);
    try std.testing.expect(r[1] == .Int and r[1].Int == 200);
}
