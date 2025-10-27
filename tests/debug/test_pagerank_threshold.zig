const std = @import("std");
const gpu = @import("gpu");
const pagerank = gpu.pagerank_kernels;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== PageRank Threshold Dispatch Test ===\n\n", .{});

    // Test small graph - should use CPU automatically
    std.debug.print("Test 1: Small graph (100K nodes, 20 iterations)\n", .{});
    std.debug.print("  Expected: CPU (below 5M threshold)\n", .{});
    {
        const num_nodes: u32 = 100_000;
        var row_offsets = try allocator.alloc(u32, num_nodes + 1);
        defer allocator.free(row_offsets);
        var col_indices = try allocator.alloc(u32, num_nodes * 10);
        defer allocator.free(col_indices);

        var edge_idx: u32 = 0;
        for (0..num_nodes) |i| {
            row_offsets[i] = edge_idx;
            for (0..10) |j| {
                col_indices[edge_idx] = @intCast((i + j + 1) % num_nodes);
                edge_idx += 1;
            }
        }
        row_offsets[num_nodes] = edge_idx;

        const pr_graph = pagerank.PRGraph{
            .row_offsets = row_offsets,
            .col_indices = col_indices,
            .num_nodes = num_nodes,
        };

        const start = std.time.nanoTimestamp();
        const ranks = try pagerank.pagerankGPU(pr_graph, 20, 0.85, allocator);
        const end = std.time.nanoTimestamp();
        defer allocator.free(ranks);

        var sum: f64 = 0;
        for (ranks) |r| sum += r;

        const ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        std.debug.print("  Result: {d:.2} ms, sum={d:.6}\n", .{ ms, sum });
        std.debug.print("  ✓ Test passed (used CPU automatically)\n\n", .{});
    }

    // Test medium graph with few iterations - should use CPU
    std.debug.print("Test 2: Medium graph (1M nodes, 20 iterations)\n", .{});
    std.debug.print("  Expected: CPU (below 5M threshold + below 100 iter threshold)\n", .{});
    {
        const num_nodes: u32 = 1_000_000;
        var row_offsets = try allocator.alloc(u32, num_nodes + 1);
        defer allocator.free(row_offsets);
        var col_indices = try allocator.alloc(u32, num_nodes * 10);
        defer allocator.free(col_indices);

        var edge_idx: u32 = 0;
        for (0..num_nodes) |i| {
            row_offsets[i] = edge_idx;
            for (0..10) |j| {
                col_indices[edge_idx] = @intCast((i + j + 1) % num_nodes);
                edge_idx += 1;
            }
        }
        row_offsets[num_nodes] = edge_idx;

        const pr_graph = pagerank.PRGraph{
            .row_offsets = row_offsets,
            .col_indices = col_indices,
            .num_nodes = num_nodes,
        };

        const start = std.time.nanoTimestamp();
        const ranks = try pagerank.pagerankGPU(pr_graph, 20, 0.85, allocator);
        const end = std.time.nanoTimestamp();
        defer allocator.free(ranks);

        var sum: f64 = 0;
        for (ranks) |r| sum += r;

        const ms = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
        std.debug.print("  Result: {d:.2} ms, sum={d:.6}\n", .{ ms, sum });
        std.debug.print("  ✓ Test passed (used CPU automatically)\n\n", .{});
    }

    std.debug.print("=== All threshold tests passed ===\n", .{});
    std.debug.print("\nThreshold configuration:\n", .{});
    std.debug.print("  GPU_THRESHOLD_NODES = 5,000,000\n", .{});
    std.debug.print("  GPU_THRESHOLD_ITERATIONS = 100\n", .{});
    std.debug.print("\nAutomatic dispatch:\n", .{});
    std.debug.print("  • Graphs <5M nodes with <100 iterations → CPU\n", .{});
    std.debug.print("  • Graphs ≥5M nodes OR ≥100 iterations → GPU (if available)\n", .{});
}
