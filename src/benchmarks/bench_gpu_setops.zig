const std = @import("std");
const phase0 = @import("../gpu/phase0.zig");
const setops = @import("../gpu/gpu_setops_kernels.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase3Benchmark; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_051_SetOps; OWNER=engine; UPDATED=2025-10-26

const SET_SIZE_A = 1_000_000;
const SET_SIZE_B = 1_000_000;

fn generateSyntheticSets(allocator: std.mem.Allocator) !struct { a: []u32, b: []u32 } {
    var a = try allocator.alloc(u32, SET_SIZE_A);
    var b = try allocator.alloc(u32, SET_SIZE_B);
    
    // Set A: 0, 2, 4, 6, ... (even numbers)
    for (a, 0..) |*val, i| {
        val.* = @intCast(i * 2);
    }
    
    // Set B: 1, 3, 5, 7, ... and some overlap with A
    for (b, 0..) |*val, i| {
        if (i < SET_SIZE_B / 2) {
            val.* = @intCast(i * 2 + 1); // odds
        } else {
            val.* = @intCast((i - SET_SIZE_B / 2) * 2); // evens (overlap)
        }
    }
    
    return .{ .a = a, .b = b };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("GPU Set Operations Benchmark (Phase 3)\n", .{});
    try stdout.print("==========================================\n\n", .{});
    
    // Check GPU availability
    const gpu_enabled = phase0.gpuEnabled();
    try stdout.print("GPU Available: {}\n", .{gpu_enabled});
    
    if (!gpu_enabled) {
        try stdout.print("Skipping GPU benchmark - no CUDA device found\n", .{});
        try stdout.print("Running CPU benchmark only...\n\n", .{});
    }
    
    // Generate synthetic sets
    try stdout.print("Generating synthetic sets ({} elements each)...\n", .{SET_SIZE_A});
    const sets = try generateSyntheticSets(allocator);
    defer allocator.free(sets.a);
    defer allocator.free(sets.b);
    
    // Benchmark UNION DISTINCT
    try stdout.print("\n=== UNION DISTINCT Benchmark ===\n", .{});
    
    try stdout.print("Running CPU UNION DISTINCT...\n", .{});
    const union_cpu_start = std.time.nanoTimestamp();
    const union_cpu_result = try setops.unionDistinctCPU(sets.a, sets.b, allocator);
    const union_cpu_end = std.time.nanoTimestamp();
    const union_cpu_ms = @as(f64, @floatFromInt(union_cpu_end - union_cpu_start)) / 1_000_000.0;
    
    try stdout.print("CPU UNION DISTINCT: {} unique elements in {d:.2} ms\n", .{ union_cpu_result.len, union_cpu_ms });
    allocator.free(union_cpu_result);
    
    if (gpu_enabled) {
        try stdout.print("Running GPU UNION DISTINCT...\n", .{});
        const union_gpu_start = std.time.nanoTimestamp();
        const union_gpu_result = try setops.unionDistinctGPU(sets.a, sets.b, allocator);
        const union_gpu_end = std.time.nanoTimestamp();
        const union_gpu_ms = @as(f64, @floatFromInt(union_gpu_end - union_gpu_start)) / 1_000_000.0;
        
        try stdout.print("GPU UNION DISTINCT: {} unique elements in {d:.2} ms\n", .{ union_gpu_result.len, union_gpu_ms });
        allocator.free(union_gpu_result);
        
        const union_speedup = union_cpu_ms / union_gpu_ms;
        try stdout.print("UNION DISTINCT Speedup: {d:.2}x (target: ≥4x)\n", .{union_speedup});
        
        if (union_speedup >= 4.0) {
            try stdout.print("✅ Target speedup achieved!\n", .{});
        } else {
            try stdout.print("⚠️  Below target speedup\n", .{});
        }
    }
    
    // Benchmark INTERSECT
    try stdout.print("\n=== INTERSECT Benchmark ===\n", .{});
    
    try stdout.print("Running CPU INTERSECT...\n", .{});
    const intersect_cpu_start = std.time.nanoTimestamp();
    const intersect_cpu_result = try setops.intersectCPU(sets.a, sets.b, allocator);
    const intersect_cpu_end = std.time.nanoTimestamp();
    const intersect_cpu_ms = @as(f64, @floatFromInt(intersect_cpu_end - intersect_cpu_start)) / 1_000_000.0;
    
    try stdout.print("CPU INTERSECT: {} common elements in {d:.2} ms\n", .{ intersect_cpu_result.len, intersect_cpu_ms });
    allocator.free(intersect_cpu_result);
    
    if (gpu_enabled) {
        try stdout.print("Running GPU INTERSECT...\n", .{});
        const intersect_gpu_start = std.time.nanoTimestamp();
        const intersect_gpu_result = try setops.intersectGPU(sets.a, sets.b, allocator);
        const intersect_gpu_end = std.time.nanoTimestamp();
        const intersect_gpu_ms = @as(f64, @floatFromInt(intersect_gpu_end - intersect_gpu_start)) / 1_000_000.0;
        
        try stdout.print("GPU INTERSECT: {} common elements in {d:.2} ms\n", .{ intersect_gpu_result.len, intersect_gpu_ms });
        allocator.free(intersect_gpu_result);
        
        const intersect_speedup = intersect_cpu_ms / intersect_gpu_ms;
        try stdout.print("INTERSECT Speedup: {d:.2}x (target: ≥3x)\n", .{intersect_speedup});
        
        if (intersect_speedup >= 3.0) {
            try stdout.print("✅ Target speedup achieved!\n", .{});
        } else {
            try stdout.print("⚠️  Below target speedup\n", .{});
        }
    }
    
    try stdout.print("\nBenchmark complete.\n", .{});
}
