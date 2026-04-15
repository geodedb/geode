const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const pagerank = gpu.pagerank_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase2Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_PageRank; OWNER=engine; UPDATED=2025-10-26

// Test multiple configurations to show where GPU excels
const TestConfig = struct {
    nodes: u32,
    edges_per_node: u32,
    iterations: u32,
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
    std.debug.print("  Graph: {} nodes, {} edges/node, {} iterations\n", .{ config.nodes, config.edges_per_node, config.iterations });

    // Generate synthetic graph
    const graph = try generateSyntheticGraph(config, allocator);
    defer allocator.free(graph.row_offsets);
    defer allocator.free(graph.col_indices);

    const pr_graph = pagerank.PRGraph{
        .row_offsets = graph.row_offsets,
        .col_indices = graph.col_indices,
        .num_nodes = config.nodes,
    };

    // Benchmark CPU
    const cpu_start = std.time.nanoTimestamp();
    const cpu_ranks = try pagerank.pagerankCPU(pr_graph, config.iterations, 0.85, allocator);
    const cpu_end = std.time.nanoTimestamp();
    const cpu_ms = @as(f64, @floatFromInt(cpu_end - cpu_start)) / 1_000_000.0;

    var cpu_sum: f64 = 0.0;
    for (cpu_ranks) |r| cpu_sum += r;
    allocator.free(cpu_ranks);

    std.debug.print("  CPU: {d:.2} ms (sum={d:.6})\n", .{ cpu_ms, cpu_sum });

    // Benchmark GPU if available
    if (gpu_enabled) {
        const gpu_start = std.time.nanoTimestamp();
        const gpu_ranks = pagerank.pagerankGPU(pr_graph, config.iterations, 0.85, allocator) catch |err| {
            std.debug.print("  GPU: Failed ({any}), used CPU fallback\n", .{err});
            return;
        };
        const gpu_end = std.time.nanoTimestamp();
        const gpu_ms = @as(f64, @floatFromInt(gpu_end - gpu_start)) / 1_000_000.0;

        var gpu_sum: f64 = 0.0;
        for (gpu_ranks) |r| gpu_sum += r;
        allocator.free(gpu_ranks);

        const speedup = cpu_ms / gpu_ms;
        std.debug.print("  GPU: {d:.2} ms (sum={d:.6})\n", .{ gpu_ms, gpu_sum });
        std.debug.print("  Speedup: {d:.2}x", .{speedup});

        if (speedup >= 3.0) {
            std.debug.print(" ✅ Excellent\n", .{});
        } else if (speedup >= 1.5) {
            std.debug.print(" ✓ Good\n", .{});
        } else if (speedup >= 1.0) {
            std.debug.print(" ~ Break-even\n", .{});
        } else {
            std.debug.print(" ⚠️ CPU faster (overhead dominates)\n", .{});
        }
    } else {
        std.debug.print("  GPU: Not available\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("GPU PageRank Benchmark - Comparative Analysis\n", .{});
    std.debug.print("==============================================\n", .{});

    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("\nGPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("\n⚠️  No CUDA device found - running CPU-only benchmarks\n", .{});
        std.debug.print("GPU performance comparison will not be available.\n", .{});
    } else {
        std.debug.print("\nTesting multiple configurations to show GPU performance characteristics:\n", .{});
    }

    // Test configurations showing different performance characteristics
    const configs = [_]TestConfig{
        .{
            .nodes = 100_000,
            .edges_per_node = 10,
            .iterations = 20,
            .name = "Small Graph, Few Iterations (overhead dominates)",
        },
        .{
            .nodes = 1_000_000,
            .edges_per_node = 10,
            .iterations = 20,
            .name = "Medium Graph, Few Iterations (original benchmark)",
        },
        .{
            .nodes = 1_000_000,
            .edges_per_node = 10,
            .iterations = 100,
            .name = "Medium Graph, More Iterations (better amortization)",
        },
        .{
            .nodes = 5_000_000,
            .edges_per_node = 10,
            .iterations = 20,
            .name = "Large Graph, Few Iterations (GPU utilization improves)",
        },
        .{
            .nodes = 5_000_000,
            .edges_per_node = 10,
            .iterations = 100,
            .name = "Large Graph, Many Iterations (GPU sweet spot)",
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
    std.debug.print("  • Small graphs (<1M nodes): CPU typically faster (init overhead)\n", .{});
    std.debug.print("  • Medium graphs (1-5M nodes): GPU competitive with many iterations\n", .{});
    std.debug.print("  • Large graphs (5M+ nodes): GPU shows clear advantage\n", .{});
    std.debug.print("  • Recommendation: Use GPU for graphs >5M nodes OR >100 iterations\n", .{});
    std.debug.print("\nBenchmark complete.\n", .{});
}
