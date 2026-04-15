const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const sp = gpu.shortest_path_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase4Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_ShortestPath; OWNER=engine; UPDATED=2025-10-26

const TestConfig = struct {
    nodes: u32,
    avg_degree: u32,
    name: []const u8,
};

fn generateRandomWeightedGraph(config: TestConfig, allocator: std.mem.Allocator) !sp.SPGraph {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const num_edges = config.nodes * config.avg_degree;

    var row_offsets = try allocator.alloc(u32, config.nodes + 1);
    var col_indices = try allocator.alloc(u32, num_edges);
    var weights = try allocator.alloc(f64, num_edges);

    var edge_idx: u32 = 0;
    for (0..config.nodes) |node| {
        row_offsets[node] = edge_idx;

        const degree = config.avg_degree;
        for (0..degree) |_| {
            if (edge_idx >= num_edges) break;

            var neighbor = rng.intRangeAtMost(u32, 0, config.nodes - 1);
            while (neighbor == node) {
                neighbor = rng.intRangeAtMost(u32, 0, config.nodes - 1);
            }

            col_indices[edge_idx] = neighbor;
            weights[edge_idx] = 1.0 + rng.float(f64) * 9.0;
            edge_idx += 1;
        }
    }
    row_offsets[config.nodes] = edge_idx;

    return sp.SPGraph{
        .row_offsets = row_offsets,
        .col_indices = col_indices[0..edge_idx],
        .weights = weights[0..edge_idx],
        .num_nodes = config.nodes,
    };
}

fn runBenchmark(config: TestConfig, gpu_enabled: bool, allocator: std.mem.Allocator) !void {
    std.debug.print("\n{s}:\n", .{config.name});
    std.debug.print("  Graph: {} nodes, ~{} edges\n", .{ config.nodes, config.nodes * config.avg_degree });

    const graph = try generateRandomWeightedGraph(config, allocator);
    defer {
        allocator.free(graph.row_offsets);
        allocator.free(graph.col_indices);
        allocator.free(graph.weights);
    }

    const start_node: u32 = 0;

    // CPU Dijkstra
    const cpu_start = std.time.nanoTimestamp();
    const cpu_result = try sp.dijkstraCPU(graph, start_node, allocator);
    const cpu_end = std.time.nanoTimestamp();
    const cpu_ms = @as(f64, @floatFromInt(cpu_end - cpu_start)) / 1_000_000.0;

    var cpu_reachable: u32 = 0;
    for (cpu_result) |dist| {
        if (!std.math.isInf(dist)) cpu_reachable += 1;
    }

    std.debug.print("  CPU: {d:.2} ms ({} reachable)\n", .{ cpu_ms, cpu_reachable });

    if (gpu_enabled) {
        const gpu_start = std.time.nanoTimestamp();
        const gpu_result = try sp.dijkstraGPU(graph, start_node, allocator);
        const gpu_end = std.time.nanoTimestamp();
        const gpu_ms = @as(f64, @floatFromInt(gpu_end - gpu_start)) / 1_000_000.0;

        var gpu_reachable: u32 = 0;
        for (gpu_result) |dist| {
            if (!std.math.isInf(dist)) gpu_reachable += 1;
        }

        allocator.free(gpu_result);

        const speedup = cpu_ms / gpu_ms;
        std.debug.print("  GPU: {d:.2} ms ({} reachable), speedup: {d:.2}x", .{ gpu_ms, gpu_reachable, speedup });

        if (speedup >= 3.0) {
            std.debug.print(" ✅ Excellent\n", .{});
        } else if (speedup >= 1.5) {
            std.debug.print(" ✓ Good\n", .{});
        } else if (speedup >= 1.0) {
            std.debug.print(" ~ Break-even\n", .{});
        } else {
            std.debug.print(" ⚠️ CPU faster\n", .{});
        }
    }

    allocator.free(cpu_result);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("GPU Shortest Path Benchmark - Comparative Analysis\n", .{});
    std.debug.print("==================================================\n", .{});

    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("\nGPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("\n⚠️  No CUDA device found - running CPU-only benchmarks\n", .{});
    } else {
        std.debug.print("\nTesting multiple graph sizes to show GPU performance characteristics:\n", .{});
    }

    const configs = [_]TestConfig{
        .{
            .nodes = 50_000,
            .avg_degree = 10,
            .name = "Small Graph (overhead dominates)",
        },
        .{
            .nodes = 100_000,
            .avg_degree = 10,
            .name = "Medium Graph (original benchmark)",
        },
        .{
            .nodes = 500_000,
            .avg_degree = 10,
            .name = "Large Graph (GPU target workload)",
        },
        .{
            .nodes = 1_000_000,
            .avg_degree = 10,
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
    std.debug.print("  • Small graphs (<100K nodes): CPU typically faster (overhead dominates)\n", .{});
    std.debug.print("  • Medium graphs (100K-500K): GPU competitive\n", .{});
    std.debug.print("  • Large graphs (500K+ nodes): GPU shows advantage\n", .{});
    std.debug.print("  • Target: ≥3x speedup on large graphs\n", .{});
    std.debug.print("\nBenchmark complete.\n", .{});
}
