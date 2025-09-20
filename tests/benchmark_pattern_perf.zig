const std = @import("std");
const constraints_mod = @import("../src/storage/constraints.zig");
const protocol = @import("../src/protocol.zig");

// BenchmarkCANARY_REQ_GQL_032_PatternPerf
// Measures throughput of pattern matching across mixed patterns.

test "BenchmarkCANARY_REQ_GQL_032_PatternPerf" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var sc = constraints_mod.SchemaConstraints.init(ally);
    defer sc.deinit();

    const patterns = [_][]const u8{ "^a.*z$", "^ab.?c[0-9]$", "foo", "^x[abc]*y$", "^h.*world$" };
    const inputs = [_][]const u8{ "ab123z", "abzc9", "foo", "xaby", "hello world", "a_bc8", "xcccdy", "nomatch" };

    const pc = constraints_mod.SchemaConstraints.PropertyConstraint{ .name = "p", .type = .string, .nullable = false, .default_value = null, .min_value = null, .max_value = null, .pattern = null };
    const node_constraints = constraints_mod.SchemaConstraints.NodeConstraints{ .label = "Perf", .required_properties = &[_]constraints_mod.SchemaConstraints.PropertyConstraint{pc}, .unique_properties = &[_][]const u8{}, .check_constraints = &[_]constraints_mod.SchemaConstraints.CheckConstraint{} };
    try sc.addNodeConstraint("Perf", node_constraints);

    const iterations: usize = 20_000; // keep runtime low
    const start_ns = std.time.nanoTimestamp();
    var outer: usize = 0;
    while (outer < iterations) : (outer += 1) {
        for (patterns) |pat| {
            for (inputs) |inp| {
                // Direct call to matcher via checkPattern by forging a property constraint per pattern
                var props = std.StringHashMap(protocol.Value).init(ally);
                defer props.deinit();
                try props.put("p", protocol.Value{ .string = inp });
                // mutate pattern on constraint
                sc.node_constraints.getPtr("Perf").?.required_properties[0].pattern = pat;
                _ = try sc.validateNode(1, "Perf", props);
            }
        }
    }
    const end_ns = std.time.nanoTimestamp();
    const elapsed = end_ns - start_ns;
    const ops = iterations * patterns.len * inputs.len;
    const ops_per_sec = @as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_032_PatternPerf\",\"ops\":{d},\"ns\":{d},\"ops_per_sec\":{d:.2}}\n", .{ ops, elapsed, ops_per_sec });
}
