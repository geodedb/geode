const std = @import("std");
const phase0 = @import("phase0.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase2PageRank; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUPageRankSmallGraph; OWNER=engine; UPDATED=2025-10-26

pub const PRGraph = struct {
    row_offsets: []const u32,
    col_indices: []const u32,
    num_nodes: u32,
};

pub fn pagerankCPU(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
    var ranks = try allocator.alloc(f64, g.num_nodes);
    var new_ranks = try allocator.alloc(f64, g.num_nodes);
    for (ranks) |*r| r.* = 1.0 / @as(f64, @floatFromInt(g.num_nodes));
    var it: u32 = 0;
    while (it < iterations) : (it += 1) {
        for (new_ranks) |*nr| nr.* = 0;
        // distribute rank
        var v: u32 = 0;
        while (v < g.num_nodes) : (v += 1) {
            const start = g.row_offsets[v];
            const end = g.row_offsets[v + 1];
            const out_deg = end - start;
            if (out_deg == 0) continue;
            const share = ranks[v] / @as(f64, @floatFromInt(out_deg));
            var i: usize = start;
            while (i < end) : (i += 1) {
                const nbr = g.col_indices[i];
                new_ranks[nbr] += share;
            }
        }
        // apply damping & dangling mass redistribution
        var sum_new: f64 = 0;
        for (new_ranks) |nr| sum_new += nr;
        const leak = 1.0 - sum_new;
        const base = (1.0 - d) / @as(f64, @floatFromInt(g.num_nodes));
        var idx: usize = 0;
        while (idx < g.num_nodes) : (idx += 1) {
            ranks[idx] = base + d * (new_ranks[idx] + leak / @as(f64, @floatFromInt(g.num_nodes)));
        }
    }
    allocator.free(new_ranks);
    return ranks;
}

pub fn pagerankGPU(g: PRGraph, iterations: u32, d: f64, allocator: std.mem.Allocator) ![]f64 {
    // Phase2 scaffold: call CPU implementation; later replace with GPU kernel
    return pagerankCPU(g, iterations, d, allocator);
}

test "TestCANARY_REQ_GQL_051_GPUPageRankSmallGraph" {
    // Graph: 0->1,2 ; 1->2 ; 2->0 ; 2->3 ; 3->2
    const row_offsets = &[_]u32{0,2,3,5,6};
    const col_indices = &[_]u32{1,2,2,0,3,2};
    const g = PRGraph{ .row_offsets = row_offsets, .col_indices = col_indices, .num_nodes = 4 };
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const cpu = try pagerankCPU(g, 20, 0.85, alloc);
    defer alloc.free(cpu);
    const gpu = try pagerankGPU(g, 20, 0.85, alloc);
    defer alloc.free(gpu);
    var sum_cpu: f64 = 0;
    var sum_gpu: f64 = 0;
    var i: usize = 0;
    while (i < g.num_nodes) : (i += 1) {
        sum_cpu += cpu[i];
        sum_gpu += gpu[i];
        const diff = @abs(cpu[i] - gpu[i]);
        try std.testing.expect(diff < 1e-9);
    }
    // sum of ranks approx 1.0
    try std.testing.expect(@abs(sum_cpu - 1.0) < 1e-9);
    try std.testing.expect(@abs(sum_gpu - 1.0) < 1e-9);
}
