const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const pagerank = gpu.pagerank_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase2Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_PageRank; OWNER=engine; UPDATED=2025-10-26

const SYNTHETIC_NODES = 100_000;
const EDGES_PER_NODE = 10;
const ITERATIONS = 20;

fn generateSyntheticGraph(allocator: std.mem.Allocator) !struct { row_offsets: []u32, col_indices: []u32 } {
    const num_nodes = SYNTHETIC_NODES;
    const num_edges = num_nodes * EDGES_PER_NODE;

    var row_offsets = try allocator.alloc(u32, num_nodes + 1);
    var col_indices = try allocator.alloc(u32, num_edges);

    var edge_idx: u32 = 0;
    var node: u32 = 0;
    while (node < num_nodes) : (node += 1) {
        row_offsets[node] = edge_idx;
        var i: u32 = 0;
        while (i < EDGES_PER_NODE) : (i += 1) {
            col_indices[edge_idx] = (node + i + 1) % num_nodes;
            edge_idx += 1;
        }
    }
    row_offsets[num_nodes] = edge_idx;

    return .{ .row_offsets = row_offsets, .col_indices = col_indices };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Removed getStdOut
    // Using std.debug.print instead

    std.debug.print("GPU PageRank Benchmark (Phase 2)\n", .{});
    std.debug.print("==================================\n\n", .{});

    // Check GPU availability
    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("GPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("Skipping GPU benchmark - no CUDA device found\n", .{});
        std.debug.print("Running CPU benchmark only...\n\n", .{});
    }

    // Generate synthetic graph
    std.debug.print("Generating synthetic graph ({} nodes, {} edges/node)...\n", .{ SYNTHETIC_NODES, EDGES_PER_NODE });
    const graph = try generateSyntheticGraph(allocator);
    defer allocator.free(graph.row_offsets);
    defer allocator.free(graph.col_indices);

    const pr_graph = pagerank.PRGraph{
        .row_offsets = graph.row_offsets,
        .col_indices = graph.col_indices,
        .num_nodes = SYNTHETIC_NODES,
    };

    // Benchmark CPU path
    std.debug.print("\nRunning CPU PageRank ({} iterations)...\n", .{ITERATIONS});
    const cpu_start = std.time.nanoTimestamp();
    const cpu_ranks = try pagerank.pagerankCPU(pr_graph, ITERATIONS, 0.85, allocator);
    const cpu_end = std.time.nanoTimestamp();
    const cpu_ms = @as(f64, @floatFromInt(cpu_end - cpu_start)) / 1_000_000.0;

    std.debug.print("CPU PageRank completed in {d:.2} ms\n", .{cpu_ms});

    // Verify sum ≈ 1.0
    var cpu_sum: f64 = 0.0;
    for (cpu_ranks) |r| cpu_sum += r;
    std.debug.print("CPU rank sum: {d:.6}\n", .{cpu_sum});
    allocator.free(cpu_ranks);

    // Benchmark GPU path if available
    if (gpu_enabled) {
        std.debug.print("\nRunning GPU PageRank ({} iterations)...\n", .{ITERATIONS});
        const gpu_start = std.time.nanoTimestamp();
        const gpu_ranks = try pagerank.pagerankGPU(pr_graph, ITERATIONS, 0.85, allocator);
        const gpu_end = std.time.nanoTimestamp();
        const gpu_ms = @as(f64, @floatFromInt(gpu_end - gpu_start)) / 1_000_000.0;

        std.debug.print("GPU PageRank completed in {d:.2} ms\n", .{gpu_ms});

        // Verify sum ≈ 1.0
        var gpu_sum: f64 = 0.0;
        for (gpu_ranks) |r| gpu_sum += r;
        std.debug.print("GPU rank sum: {d:.6}\n", .{gpu_sum});
        allocator.free(gpu_ranks);

        // Calculate speedup
        const speedup = cpu_ms / gpu_ms;
        std.debug.print("\nSpeedup: {d:.2}x (target: ≥3x)\n", .{speedup});

        if (speedup >= 3.0) {
            std.debug.print("✅ Target speedup achieved!\n", .{});
        } else {
            std.debug.print("⚠️  Below target speedup (possible reasons: small graph, memory transfer overhead)\n", .{});
        }
    }

    std.debug.print("\nBenchmark complete.\n", .{});
}
