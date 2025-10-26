const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const phase1 = gpu.phase1_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase1Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_BFS; OWNER=engine; UPDATED=2025-10-26

const TestConfig = struct {
    nodes: u32,
    edges_per_node: u32,
    max_depth: u32,
    name: []const u8,
};

fn generateSyntheticGraph(config: TestConfig, allocator: std.mem.Allocator) !struct { row_offsets: []u32, col_indices: []u32 } {
    const num_nodes = config.nodes;
    const num_edges = num_nodes * config.edges_per_node;

    var row_offsets = try allocator.alloc(u32, num_nodes + 1);
    var col_indices = try allocator.alloc(u32, num_edges);

    var edge_idx: u32 = 0;
    var node: u32 = 0;
    while (node < num_nodes) : (node += 1) {
        row_offsets[node] = edge_idx;
        var i: u32 = 0;
        while (i < config.edges_per_node) : (i += 1) {
            col_indices[edge_idx] = (node + i + 1) % num_nodes;
            edge_idx += 1;
        }
    }
    row_offsets[num_nodes] = edge_idx;

    return .{ .row_offsets = row_offsets, .col_indices = col_indices };
}

fn runBenchmark(config: TestConfig, gpu_enabled: bool, allocator: std.mem.Allocator) !void {
    std.debug.print("\n{s}:\n", .{config.name});
    std.debug.print("  Graph: {} nodes, {} edges/node, depth={}\n", .{ config.nodes, config.edges_per_node, config.max_depth });

    const graph = try generateSyntheticGraph(config, allocator);
    defer allocator.free(graph.row_offsets);
    defer allocator.free(graph.col_indices);

    const csr = phase1.CSR{ .row_offsets = graph.row_offsets, .col_indices = graph.col_indices };

    // Benchmark CPU
    const cpu_start = std.time.nanoTimestamp();
    const cpu_count = try phase1.bfsFrontierCount(csr, 0, config.max_depth, allocator);
    const cpu_end = std.time.nanoTimestamp();
    const cpu_ms = @as(f64, @floatFromInt(cpu_end - cpu_start)) / 1_000_000.0;

    std.debug.print("  CPU: {d:.2} ms (visited {} nodes)\n", .{ cpu_ms, cpu_count });

    if (gpu_enabled) {
        // Note: GPU BFS currently falls back to CPU
        std.debug.print("  GPU: Not implemented yet (falls back to CPU)\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("GPU BFS Benchmark - Comparative Analysis\n", .{});
    std.debug.print("=========================================\n", .{});

    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("\nGPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("\n⚠️  No CUDA device found - running CPU-only benchmarks\n", .{});
    } else {
        std.debug.print("\n⚠️  GPU BFS kernels not yet implemented - showing CPU baseline\n", .{});
    }

    const configs = [_]TestConfig{
        .{
            .nodes = 100_000,
            .edges_per_node = 10,
            .max_depth = 5,
            .name = "Small Graph (overhead would dominate)",
        },
        .{
            .nodes = 1_000_000,
            .edges_per_node = 10,
            .max_depth = 5,
            .name = "Medium Graph (baseline)",
        },
        .{
            .nodes = 5_000_000,
            .edges_per_node = 10,
            .max_depth = 5,
            .name = "Large Graph (GPU target workload)",
        },
        .{
            .nodes = 10_000_000,
            .edges_per_node = 10,
            .max_depth = 5,
            .name = "Very Large Graph (GPU sweet spot)",
        },
    };

    for (configs) |config| {
        runBenchmark(config, gpu_enabled, allocator) catch |err| {
            std.debug.print("\n  Error running benchmark: {}\n", .{err});
            continue;
        };
    }

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("Summary:\n", .{});
    std.debug.print("  • Target: 5x speedup on large graphs (5M+ nodes)\n", .{});
    std.debug.print("  • Status: GPU BFS kernels not yet implemented\n", .{});
    std.debug.print("  • Expected: Similar patterns to PageRank (overhead vs compute)\n", .{});
    std.debug.print("\nBenchmark complete.\n", .{});
}
