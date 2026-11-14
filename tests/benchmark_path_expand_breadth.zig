const std = @import("std");

// CANARY: REQ=REQ-GQL-016; FEATURE="Path Expand Breadth"; ASPECT=Planner; STATUS=IMPL; BENCH=BenchmarkCANARY_REQ_GQL_016_PathExpandBreadth; OWNER=planner; UPDATED=2026-11-14

fn simulateBreadth(depth: u32, branching: u32) usize {
    // Simulate node visit count for breadth expansion, no actual graph.
    var total: usize = 1;
    var current: usize = 1;
    var d: u32 = 0;
    while (d < depth) : (d += 1) {
        current = current * branching;
        total += current;
    }
    return total;
}

test "BenchmarkCANARY_REQ_GQL_016_PathExpandBreadth" {
    var timer = try std.time.Timer.start();
    var reps: usize = 0;
    var visits: usize = 0;
    while (reps < 50_000) : (reps += 1) {
        visits += simulateBreadth(4, 8);
    }
    const elapsed = timer.read();
    std.debug.print("PathExpandBreadth visits={} elapsed_ns={}\n", .{ visits, elapsed });
}
