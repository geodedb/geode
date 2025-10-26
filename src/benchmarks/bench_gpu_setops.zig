const std = @import("std");
const gpu = @import("gpu");
const phase0 = gpu.phase0;
const setops = gpu.gpu_setops_kernels;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase3Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_SetOps; OWNER=engine; UPDATED=2025-10-26

const TestConfig = struct {
    size: u32,
    overlap_percent: u32,
    name: []const u8,
};

fn generateSyntheticSets(config: TestConfig, allocator: std.mem.Allocator) !struct { a: []u32, b: []u32 } {
    const a = try allocator.alloc(u32, config.size);
    const b = try allocator.alloc(u32, config.size);

    // Set A: 0 to size-1
    for (a, 0..) |*val, i| {
        val.* = @intCast(i);
    }

    // Set B: offset to create desired overlap
    const offset = config.size - (config.size * config.overlap_percent / 100);
    for (b, 0..) |*val, i| {
        val.* = @intCast(i + offset);
    }

    return .{ .a = a, .b = b };
}

fn runBenchmark(config: TestConfig, gpu_enabled: bool, allocator: std.mem.Allocator) !void {
    std.debug.print("\n{s}:\n", .{config.name});
    std.debug.print("  Sets: {} elements each, {}% overlap\n", .{ config.size, config.overlap_percent });

    const sets = try generateSyntheticSets(config, allocator);
    defer allocator.free(sets.a);
    defer allocator.free(sets.b);

    // UNION DISTINCT benchmark
    const union_cpu_start = std.time.nanoTimestamp();
    const union_cpu_result = try setops.unionDistinctCPU(sets.a, sets.b, allocator);
    const union_cpu_end = std.time.nanoTimestamp();
    const union_cpu_ms = @as(f64, @floatFromInt(union_cpu_end - union_cpu_start)) / 1_000_000.0;
    const union_size = union_cpu_result.len;
    allocator.free(union_cpu_result);

    std.debug.print("  UNION CPU: {d:.2} ms ({} unique)\n", .{ union_cpu_ms, union_size });

    if (gpu_enabled) {
        const union_gpu_start = std.time.nanoTimestamp();
        const union_gpu_result = try setops.unionDistinctGPU(sets.a, sets.b, allocator);
        const union_gpu_end = std.time.nanoTimestamp();
        const union_gpu_ms = @as(f64, @floatFromInt(union_gpu_end - union_gpu_start)) / 1_000_000.0;
        allocator.free(union_gpu_result);

        const union_speedup = union_cpu_ms / union_gpu_ms;
        std.debug.print("  UNION GPU: {d:.2} ms, speedup: {d:.2}x", .{ union_gpu_ms, union_speedup });
        
        if (union_speedup >= 4.0) {
            std.debug.print(" ✅ Excellent\n", .{});
        } else if (union_speedup >= 2.0) {
            std.debug.print(" ✓ Good\n", .{});
        } else if (union_speedup >= 1.0) {
            std.debug.print(" ~ Break-even\n", .{});
        } else {
            std.debug.print(" ⚠️ CPU faster\n", .{});
        }
    }

    // INTERSECT benchmark
    const intersect_cpu_start = std.time.nanoTimestamp();
    const intersect_cpu_result = try setops.intersectCPU(sets.a, sets.b, allocator);
    const intersect_cpu_end = std.time.nanoTimestamp();
    const intersect_cpu_ms = @as(f64, @floatFromInt(intersect_cpu_end - intersect_cpu_start)) / 1_000_000.0;
    const intersect_size = intersect_cpu_result.len;
    allocator.free(intersect_cpu_result);

    std.debug.print("  INTERSECT CPU: {d:.2} ms ({} common)\n", .{ intersect_cpu_ms, intersect_size });

    if (gpu_enabled) {
        const intersect_gpu_start = std.time.nanoTimestamp();
        const intersect_gpu_result = try setops.intersectGPU(sets.a, sets.b, allocator);
        const intersect_gpu_end = std.time.nanoTimestamp();
        const intersect_gpu_ms = @as(f64, @floatFromInt(intersect_gpu_end - intersect_gpu_start)) / 1_000_000.0;
        allocator.free(intersect_gpu_result);

        const intersect_speedup = intersect_cpu_ms / intersect_gpu_ms;
        std.debug.print("  INTERSECT GPU: {d:.2} ms, speedup: {d:.2}x", .{ intersect_gpu_ms, intersect_speedup });
        
        if (intersect_speedup >= 3.0) {
            std.debug.print(" ✅ Excellent\n", .{});
        } else if (intersect_speedup >= 1.5) {
            std.debug.print(" ✓ Good\n", .{});
        } else if (intersect_speedup >= 1.0) {
            std.debug.print(" ~ Break-even\n", .{});
        } else {
            std.debug.print(" ⚠️ CPU faster\n", .{});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("GPU Set Operations Benchmark - Comparative Analysis\n", .{});
    std.debug.print("===================================================\n", .{});

    const gpu_enabled = phase0.gpuEnabled();
    std.debug.print("\nGPU Available: {}\n", .{gpu_enabled});

    if (!gpu_enabled) {
        std.debug.print("\n⚠️  No CUDA device found - running CPU-only benchmarks\n", .{});
    } else {
        std.debug.print("\nTesting multiple set sizes to show GPU performance characteristics:\n", .{});
    }

    const configs = [_]TestConfig{
        .{
            .size = 1_000_000,
            .overlap_percent = 50,
            .name = "Small Sets (overhead dominates)",
        },
        .{
            .size = 10_000_000,
            .overlap_percent = 50,
            .name = "Medium Sets (original benchmark)",
        },
        .{
            .size = 50_000_000,
            .overlap_percent = 50,
            .name = "Large Sets (GPU target workload)",
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
    std.debug.print("  • Small sets (<5M): CPU typically faster (overhead dominates)\n", .{});
    std.debug.print("  • Medium sets (10M): GPU competitive for UNION, memory-bound for INTERSECT\n", .{});
    std.debug.print("  • Large sets (50M+): GPU shows clear advantage\n", .{});
    std.debug.print("  • Targets: UNION ≥4x, INTERSECT ≥3x (on large sets)\n", .{});
    std.debug.print("\nBenchmark complete.\n", .{});
}
