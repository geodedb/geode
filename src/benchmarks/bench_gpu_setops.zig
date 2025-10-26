const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const setops = gpu.gpu_setops_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase3Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_SetOps; OWNER=engine; UPDATED=2025-10-26

const SET_SIZE_A = 10_000_000; // Scaled up 10x for GPU amortization
const SET_SIZE_B = 10_000_000;

fn generateSyntheticSets(allocator: std.mem.Allocator) !struct { a: []u32, b: []u32 } {
    const a = try allocator.alloc(u32, SET_SIZE_A);
    const b = try allocator.alloc(u32, SET_SIZE_B);

    // Set A: 0 to SET_SIZE_A-1
    for (a, 0..) |*val, i| {
        val.* = @intCast(i);
    }

    // Set B: SET_SIZE_B/2 to SET_SIZE_B/2 + SET_SIZE_B - 1
    // This gives 50% overlap: elements [SET_SIZE_B/2 .. SET_SIZE_A-1] are in both
    for (b, 0..) |*val, i| {
        val.* = @intCast(i + SET_SIZE_B / 2);
    }

    return .{ .a = a, .b = b };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Removed getStdOut
    // Using std.debug.print instead

    std.debug.print("GPU Set Operations Benchmark (Phase 3)\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Check GPU availability
    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("GPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("Skipping GPU benchmark - no CUDA device found\n", .{});
        std.debug.print("Running CPU benchmark only...\n\n", .{});
    }

    // Generate synthetic sets
    std.debug.print("Generating synthetic sets ({} elements each)...\n", .{SET_SIZE_A});
    const sets = try generateSyntheticSets(allocator);
    defer allocator.free(sets.a);
    defer allocator.free(sets.b);

    // Benchmark UNION DISTINCT
    std.debug.print("\n=== UNION DISTINCT Benchmark ===\n", .{});

    std.debug.print("Running CPU UNION DISTINCT...\n", .{});
    const union_cpu_start = std.time.nanoTimestamp();
    const union_cpu_result = try setops.unionDistinctCPU(sets.a, sets.b, allocator);
    const union_cpu_end = std.time.nanoTimestamp();
    const union_cpu_ms = @as(f64, @floatFromInt(union_cpu_end - union_cpu_start)) / 1_000_000.0;

    std.debug.print("CPU UNION DISTINCT: {} unique elements in {d:.2} ms\n", .{ union_cpu_result.len, union_cpu_ms });
    allocator.free(union_cpu_result);

    if (gpu_enabled) {
        std.debug.print("Running GPU UNION DISTINCT...\n", .{});
        const union_gpu_start = std.time.nanoTimestamp();
        const union_gpu_result = try setops.unionDistinctGPU(sets.a, sets.b, allocator);
        const union_gpu_end = std.time.nanoTimestamp();
        const union_gpu_ms = @as(f64, @floatFromInt(union_gpu_end - union_gpu_start)) / 1_000_000.0;

        std.debug.print("GPU UNION DISTINCT: {} unique elements in {d:.2} ms\n", .{ union_gpu_result.len, union_gpu_ms });
        allocator.free(union_gpu_result);

        const union_speedup = union_cpu_ms / union_gpu_ms;
        std.debug.print("UNION DISTINCT Speedup: {d:.2}x (target: ≥4x)\n", .{union_speedup});

        if (union_speedup >= 4.0) {
            std.debug.print("✅ Target speedup achieved!\n", .{});
        } else {
            std.debug.print("⚠️  Below target speedup\n", .{});
        }
    }

    // Benchmark INTERSECT
    std.debug.print("\n=== INTERSECT Benchmark ===\n", .{});

    std.debug.print("Running CPU INTERSECT...\n", .{});
    const intersect_cpu_start = std.time.nanoTimestamp();
    const intersect_cpu_result = try setops.intersectCPU(sets.a, sets.b, allocator);
    const intersect_cpu_end = std.time.nanoTimestamp();
    const intersect_cpu_ms = @as(f64, @floatFromInt(intersect_cpu_end - intersect_cpu_start)) / 1_000_000.0;

    std.debug.print("CPU INTERSECT: {} common elements in {d:.2} ms\n", .{ intersect_cpu_result.len, intersect_cpu_ms });
    allocator.free(intersect_cpu_result);

    if (gpu_enabled) {
        std.debug.print("Running GPU INTERSECT...\n", .{});
        const intersect_gpu_start = std.time.nanoTimestamp();
        const intersect_gpu_result = try setops.intersectGPU(sets.a, sets.b, allocator);
        const intersect_gpu_end = std.time.nanoTimestamp();
        const intersect_gpu_ms = @as(f64, @floatFromInt(intersect_gpu_end - intersect_gpu_start)) / 1_000_000.0;

        std.debug.print("GPU INTERSECT: {} common elements in {d:.2} ms\n", .{ intersect_gpu_result.len, intersect_gpu_ms });
        allocator.free(intersect_gpu_result);

        const intersect_speedup = intersect_cpu_ms / intersect_gpu_ms;
        std.debug.print("INTERSECT Speedup: {d:.2}x (target: ≥3x)\n", .{intersect_speedup});

        if (intersect_speedup >= 3.0) {
            std.debug.print("✅ Target speedup achieved!\n", .{});
        } else {
            std.debug.print("⚠️  Below target speedup\n", .{});
        }
    }

    std.debug.print("\nBenchmark complete.\n", .{});
}
