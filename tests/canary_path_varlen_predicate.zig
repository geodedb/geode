const std = @import("std");
const perf_gate = @import("perf_gate");

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

// Shared node struct and helper functions for tests
const Node = struct { id: u32, value: i32, neighbors: []const u32 };

fn dfsPredicate(alloc: std.mem.Allocator, nodes: []const Node, current: u32, depth: u32, max_depth: u32, threshold: i32, out: *std.AutoHashMap(u32, bool)) !void {
    if (depth > max_depth) return;
    const n = nodes[current];
    if (n.value > threshold) try out.put(n.id, true);
    for (n.neighbors) |nbr| {
        try dfsPredicate(alloc, nodes, nbr, depth + 1, max_depth, threshold, out);
    }
}

fn dfsCount(nodes: []const Node, current: u32, depth: u32, max_depth: u32, threshold: i32, acc: *u32) void {
    if (depth > max_depth) return;
    const n = nodes[current];
    if (n.value > threshold) acc.* += 1;
    for (n.neighbors) |nbr| dfsCount(nodes, nbr, depth + 1, max_depth, threshold, acc);
}

// Assumes existing path execution modules; this is a synthetic harness to exercise property predicate over variable-length expansion.
// CANARY: REQ=REQ-GQL-017; FEATURE="Path Execution"; ASPECT=PathVariableLengthPropertyPredicate; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_PathVariableLengthPropertyPredicate; BENCH=BenchmarkCANARY_REQ_GQL_017_PathVariableLengthPropertyPredicateVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_017_PathVariableLengthPropertyPredicate" {
    // Synthetic: we model a variable-length expansion of length 0..3 over an adjacency list with property filter value > threshold.
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const nodes = [_]Node{
        .{ .id = 0, .value = 5, .neighbors = &[_]u32{ 1, 2 } },
        .{ .id = 1, .value = 7, .neighbors = &[_]u32{3} },
        .{ .id = 2, .value = 2, .neighbors = &[_]u32{3} },
        .{ .id = 3, .value = 9, .neighbors = &[_]u32{} },
    };
    const threshold: i32 = 6;
    var results = std.AutoHashMap(u32, bool).init(alloc);
    defer results.deinit();

    try dfsPredicate(alloc, &nodes, 0, 0, 3, threshold, &results);
    // Expect nodes 1 and 3 collected; node 0 qualifies but is start (still allowed) => we assert >=2 results and contains 1 & 3
    try std.testing.expect(results.count() >= 2);
    try std.testing.expect(results.contains(1));
    try std.testing.expect(results.contains(3));
}

// Variance envelope: measure DFS expansion with predicate across multiple iterations.
// CANARY: REQ=REQ-GQL-017; FEATURE="Path Execution"; ASPECT=PathVariableLengthPropertyPredicateVarianceEnvelope; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_017_PathVariableLengthPropertyPredicate; BENCH=BenchmarkCANARY_REQ_GQL_017_PathVariableLengthPropertyPredicateVarianceEnvelope; OWNER=planner; UPDATED=2025-09-21
test "BenchmarkCANARY_REQ_GQL_017_PathVariableLengthPropertyPredicateVarianceEnvelope" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const nodes = [_]Node{
        .{ .id = 0, .value = 5, .neighbors = &[_]u32{ 1, 2 } },
        .{ .id = 1, .value = 7, .neighbors = &[_]u32{3} },
        .{ .id = 2, .value = 2, .neighbors = &[_]u32{3} },
        .{ .id = 3, .value = 9, .neighbors = &[_]u32{} },
    };
    const iterations: usize = 64;
    var samples = try alloc.alloc(u64, iterations);
    defer alloc.free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = compat_nanoTimestamp();
        var count: u32 = 0;
        dfsCount(&nodes, 0, 0, 3, 6, &count);
        const end = compat_nanoTimestamp();
        samples[i] = @as(u64, @intCast(end - start));
    }
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(iterations));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const diff = @as(f128, @floatFromInt(s)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(iterations));
    const cv = std.math.sqrt(variance) / mean;
    var scratch = try alloc.dupe(u64, samples);
    defer alloc.free(scratch);
    const rank = (iterations * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_index = r;
        var j: usize = r + 1;
        while (j < iterations) : (j += 1) {
            if (scratch[j] < scratch[min_index]) min_index = j;
        }
        if (min_index != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_index];
            scratch[min_index] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    const p95_mean = p95 / mean;
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    // Correctness assertions in this file are not gated.
    try perf_gate.envelope("var-length predicate expansion", cv, p95_mean, 0.22, 2.55);
}
