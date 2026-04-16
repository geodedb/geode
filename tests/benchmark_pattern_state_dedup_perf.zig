const std = @import("std");
const constraints = @import("../src/storage/constraints.zig");

// BenchmarkCANARY_REQ_GQL_032_PatternStateDedupPerf
// Measures performance impact of visited-state dedup in patternMatch by running
// a set of patterns that would otherwise explode combinatorially.

test "BenchmarkCANARY_REQ_GQL_032_PatternStateDedupPerf" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Rough memory accounting snapshot before
    const before_ast = gpa.getStats();

    const patterns = [_][]const u8{
        // Highly branching patterns with wildcards & classes
        "^[a-z0-9]*[A-Z]?xyz$",
        "^([a-z]?)*xyz$", // repeated optional
        "^[^0-9]*[0-9]*$",
        "^a.*b.*c.*d$",
        "^[a-zA-Z0-9]{0,}xyz$", // braces not implemented -> treated literally (stress unmatched chars)
    };

    const inputs = [_][]const u8{
        "aabbccddeeffAxyz",
        "zzzaaaabbbbcccddxyz",
        "noDigitsHereButLongSequenceOfLettersXYZ",
        "abcddddd",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaxyz",
    };

    var total_matches: usize = 0;
    const start = std.time.nanoTimestamp();
    var p_i: usize = 0;
    while (p_i < patterns.len) : (p_i += 1) {
        var i_i: usize = 0;
        while (i_i < inputs.len) : (i_i += 1) {
            // Call underlying patternMatch via public checkPattern entry using a dummy constraint harness.
            total_matches += if (constraints.SchemaConstraints.patternMatch(inputs[i_i], patterns[p_i])) 1 else 0;
        }
    }
    const end = std.time.nanoTimestamp();
    const elapsed = end - start;
    const after_ast = gpa.getStats();
    const used_bytes = after_ast.allocated - before_ast.allocated; // net allocated (approx)
    const stdout = std.Io.getStdOut().writer();
    try stdout.print("{\"benchmark\":\"BenchmarkCANARY_REQ_GQL_032_PatternStateDedupPerf\",\"elapsed_ns\":{d},\"matches\":{d},\"net_alloc_bytes\":{d}}\n", .{ elapsed, total_matches, used_bytes });
    _ = allocator;
}
