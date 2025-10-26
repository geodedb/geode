const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const phase1 = gpu.phase1_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase1Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_BFS; OWNER=engine; UPDATED=2025-10-26

const SYNTHETIC_NODES = 1_000_000;
const EDGES_PER_NODE = 10;

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

    std.debug.print("GPU BFS Benchmark (Phase 1)\n", .{});
    std.debug.print("===========================\n\n", .{});

    // Check GPU availability
    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("GPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("Skipping GPU benchmark - no CUDA device found\n", .{});
        return;
    }

    // Generate synthetic graph
    std.debug.print("Generating synthetic graph ({} nodes, {} edges/node)...\n", .{ SYNTHETIC_NODES, EDGES_PER_NODE });
    const graph = try generateSyntheticGraph(allocator);
    defer allocator.free(graph.row_offsets);
    defer allocator.free(graph.col_indices);

    const csr = phase1.CSR{ .row_offsets = graph.row_offsets, .col_indices = graph.col_indices };

    // Benchmark CPU path
    std.debug.print("\nRunning CPU BFS...\n", .{});
    const cpu_start = std.time.nanoTimestamp();
    const cpu_count = try phase1.bfsFrontierCount(csr, 0, 5, allocator);
    const cpu_end = std.time.nanoTimestamp();
    const cpu_ms = @as(f64, @floatFromInt(cpu_end - cpu_start)) / 1_000_000.0;

    std.debug.print("CPU BFS completed in {d:.2} ms, visited {} nodes\n", .{ cpu_ms, cpu_count });

    // Note: GPU path currently falls back to CPU
    std.debug.print("\nGPU kernel implementation: TODO (currently falls back to CPU)\n", .{});
    std.debug.print("Target speedup: ≥5x over CPU baseline\n", .{});

    std.debug.print("\nBenchmark complete.\n", .{});
}
