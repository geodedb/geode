const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const sp = gpu.shortest_path_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase4Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_ShortestPath; OWNER=engine; UPDATED=2025-10-26

const NUM_NODES = 100_000; // Scaled up 10x for GPU amortization
const AVG_DEGREE = 10;

fn generateRandomWeightedGraph(allocator: std.mem.Allocator) !sp.SPGraph {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const num_edges = NUM_NODES * AVG_DEGREE;

    var row_offsets = try allocator.alloc(u32, NUM_NODES + 1);
    var col_indices = try allocator.alloc(u32, num_edges);
    var weights = try allocator.alloc(f64, num_edges);

    // Generate random edges
    var edge_idx: u32 = 0;
    for (0..NUM_NODES) |node| {
        row_offsets[node] = edge_idx;

        // Generate random neighbors for this node
        const degree = AVG_DEGREE;
        for (0..degree) |_| {
            if (edge_idx >= num_edges) break;

            // Random neighbor (avoid self-loops)
            var neighbor = rng.intRangeAtMost(u32, 0, NUM_NODES - 1);
            while (neighbor == node) {
                neighbor = rng.intRangeAtMost(u32, 0, NUM_NODES - 1);
            }

            col_indices[edge_idx] = neighbor;
            // Random weight between 1.0 and 10.0
            weights[edge_idx] = 1.0 + rng.float(f64) * 9.0;
            edge_idx += 1;
        }
    }
    row_offsets[NUM_NODES] = edge_idx;

    return sp.SPGraph{
        .row_offsets = row_offsets,
        .col_indices = col_indices[0..edge_idx],
        .weights = weights[0..edge_idx],
        .num_nodes = NUM_NODES,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Removed getStdOut
    // Using std.debug.print instead

    std.debug.print("GPU Shortest Path Benchmark (Phase 4)\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Check GPU availability
    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("GPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("Skipping GPU benchmark - no CUDA device found\n", .{});
        std.debug.print("Running CPU benchmark only...\n\n", .{});
    }

    // Generate random weighted graph
    std.debug.print("Generating random weighted graph ({} nodes, ~{} edges)...\n", .{ NUM_NODES, NUM_NODES * AVG_DEGREE });
    const graph = try generateRandomWeightedGraph(allocator);
    defer {
        allocator.free(graph.row_offsets);
        allocator.free(graph.col_indices);
        allocator.free(graph.weights);
    }

    const start_node: u32 = 0;
    std.debug.print("Computing shortest paths from node {}...\n\n", .{start_node});

    // CPU Dijkstra
    std.debug.print("Running CPU Dijkstra...\n", .{});
    const cpu_start = std.time.nanoTimestamp();
    const cpu_result = try sp.dijkstraCPU(graph, start_node, allocator);
    const cpu_end = std.time.nanoTimestamp();
    const cpu_ms = @as(f64, @floatFromInt(cpu_end - cpu_start)) / 1_000_000.0;

    // Count reachable nodes
    var reachable: u32 = 0;
    for (cpu_result) |dist| {
        if (!std.math.isInf(dist)) reachable += 1;
    }

    std.debug.print("CPU Dijkstra: {} reachable nodes in {d:.2} ms\n", .{ reachable, cpu_ms });

    if (gpu_enabled) {
        std.debug.print("Running GPU Delta-Stepping...\n", .{});
        const gpu_start = std.time.nanoTimestamp();
        const gpu_result = try sp.dijkstraGPU(graph, start_node, allocator);
        const gpu_end = std.time.nanoTimestamp();
        const gpu_ms = @as(f64, @floatFromInt(gpu_end - gpu_start)) / 1_000_000.0;

        // Count GPU reachable nodes
        var gpu_reachable: u32 = 0;
        for (gpu_result) |dist| {
            if (!std.math.isInf(dist)) gpu_reachable += 1;
        }

        std.debug.print("GPU Delta-Stepping: {} reachable nodes in {d:.2} ms\n", .{ gpu_reachable, gpu_ms });

        // Verify correctness (sample nodes)
        var mismatches: u32 = 0;
        for (0..@min(100, cpu_result.len)) |i| {
            const diff = @abs(cpu_result[i] - gpu_result[i]);
            if (diff > 1e-3 and !std.math.isInf(cpu_result[i]) and !std.math.isInf(gpu_result[i])) {
                mismatches += 1;
            }
        }

        if (mismatches > 0) {
            std.debug.print("⚠️  Warning: {} mismatches in sampled nodes\n", .{mismatches});
        } else {
            std.debug.print("✅ Results match (sampled 100 nodes)\n", .{});
        }

        allocator.free(gpu_result);

        const speedup = cpu_ms / gpu_ms;
        std.debug.print("\nSpeedup: {d:.2}x (target: ≥3x)\n", .{speedup});

        if (speedup >= 3.0) {
            std.debug.print("✅ Target speedup achieved!\n", .{});
        } else {
            std.debug.print("⚠️  Below target speedup\n", .{});
        }
    }

    allocator.free(cpu_result);

    std.debug.print("\nBenchmark complete.\n", .{});
}
