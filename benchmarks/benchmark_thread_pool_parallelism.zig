// Thread-Pool Parallel Wrapper Benchmarks
// Validates performance of the shared parallel wrapper vs sequential execution.
//
// CANARY: REQ=REQ-PERF-SPICE-027; FEATURE="ParallelWrapperBenchmarks"; ASPECT=Performance; STATUS=IMPL; OWNER=performance; UPDATED=2026-04-12

const std = @import("std");
const testing = std.testing;
const parallel_wrapper = @import("parallel/thread_pool_parallel");
const ParallelPool = parallel_wrapper.ParallelPool;
const Task = parallel_wrapper.Task;
const Thresholds = parallel_wrapper.Thresholds;

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// =============================================================================
// Benchmark Configuration
// =============================================================================

const BenchmarkConfig = struct {
    name: []const u8,
    iterations: usize = 10,
    warmup_iterations: usize = 3,
};

// =============================================================================
// Benchmark Utilities
// =============================================================================

fn runBenchmark(
    comptime name: []const u8,
    comptime func: fn (usize) u64,
    size: usize,
    iterations: usize,
) struct { mean_ns: u64, min_ns: u64, max_ns: u64 } {
    _ = name;
    var times: [100]u64 = undefined;
    const actual_iterations = @min(iterations, 100);

    // Warmup
    for (0..3) |_| {
        _ = func(size);
    }

    // Benchmark
    for (0..actual_iterations) |i| {
        const start = nowNs();
        _ = func(size);
        const end = nowNs();
        times[i] = end - start;
    }

    // Calculate stats
    var sum: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    for (times[0..actual_iterations]) |t| {
        sum += t;
        min = @min(min, t);
        max = @max(max, t);
    }

    return .{
        .mean_ns = sum / actual_iterations,
        .min_ns = min,
        .max_ns = max,
    };
}

// =============================================================================
// Sequential Implementations (Baseline)
// =============================================================================

fn sequentialMapSquare(items: []const u32, results: []u64) void {
    for (items, 0..) |item, i| {
        results[i] = @as(u64, item) * item;
    }
}

fn sequentialSum(items: []const u64) u64 {
    var sum: u64 = 0;
    for (items) |item| {
        sum += item;
    }
    return sum;
}

fn sequentialVectorDot(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0.0;
    for (a, b) |av, bv| {
        dot += av * bv;
    }
    return dot;
}

// =============================================================================
// Benchmark: Parallel Map
// =============================================================================

var global_pool: ?ParallelPool = null;
var global_items: []u32 = &[_]u32{};
var global_results: []u64 = &[_]u64{};

fn initGlobalMapBenchmark(allocator: std.mem.Allocator, size: usize) !void {
    if (global_pool == null) {
        global_pool = ParallelPool.init(allocator, null);
        global_pool.?.start();
    }

    if (global_items.len != size) {
        if (global_items.len > 0) {
            allocator.free(global_items);
            allocator.free(global_results);
        }
        global_items = try allocator.alloc(u32, size);
        global_results = try allocator.alloc(u64, size);
        for (global_items, 0..) |*item, i| {
            item.* = @intCast(i + 1);
        }
    }
}

fn benchmarkSequentialMap(size: usize) u64 {
    const start = nowNs();
    sequentialMapSquare(global_items[0..size], global_results[0..size]);
    const end = nowNs();
    return end - start;
}

fn benchmarkParallelMap(size: usize) u64 {
    const mapSquare = struct {
        fn map(_: *Task, x: u32) u64 {
            return @as(u64, x) * x;
        }
    }.map;

    const start = nowNs();
    const results = parallel_wrapper.parallelMap(u32, u64, &global_pool.?, global_items[0..size], mapSquare, Thresholds.map) catch return 0;
    const end = nowNs();

    global_pool.?.allocator.free(results);
    return end - start;
}

// =============================================================================
// Benchmark: Parallel Reduce
// =============================================================================

var global_sum_items: []u64 = &[_]u64{};

fn initGlobalReduceBenchmark(allocator: std.mem.Allocator, size: usize) !void {
    if (global_pool == null) {
        global_pool = ParallelPool.init(allocator, null);
        global_pool.?.start();
    }

    if (global_sum_items.len != size) {
        if (global_sum_items.len > 0) {
            allocator.free(global_sum_items);
        }
        global_sum_items = try allocator.alloc(u64, size);
        for (global_sum_items, 0..) |*item, i| {
            item.* = @intCast(i + 1);
        }
    }
}

fn benchmarkSequentialReduce(size: usize) u64 {
    const start = nowNs();
    _ = sequentialSum(global_sum_items[0..size]);
    const end = nowNs();
    return end - start;
}

fn benchmarkParallelReduce(size: usize) u64 {
    const add = struct {
        fn reduce(_: *Task, a: u64, b: u64) u64 {
            return a + b;
        }
    }.reduce;

    const start = nowNs();
    _ = parallel_wrapper.parallelReduce(u64, &global_pool.?, global_sum_items[0..size], 0, add, Thresholds.reduce);
    const end = nowNs();
    return end - start;
}

// =============================================================================
// Benchmark: Vector Operations (HNSW-like)
// =============================================================================

var global_vectors_a: []f32 = &[_]f32{};
var global_vectors_b: []f32 = &[_]f32{};
const VECTOR_DIM: usize = 128;

fn initGlobalVectorBenchmark(allocator: std.mem.Allocator, num_vectors: usize) !void {
    if (global_pool == null) {
        global_pool = ParallelPool.init(allocator, null);
        global_pool.?.start();
    }

    const total_size = num_vectors * VECTOR_DIM;
    if (global_vectors_a.len != total_size) {
        if (global_vectors_a.len > 0) {
            allocator.free(global_vectors_a);
            allocator.free(global_vectors_b);
        }
        global_vectors_a = try allocator.alloc(f32, total_size);
        global_vectors_b = try allocator.alloc(f32, total_size);

        // Initialize with random-ish values
        var rng = std.Random.DefaultPrng.init(12345);
        const random = rng.random();
        for (global_vectors_a) |*v| {
            v.* = random.float(f32) * 2.0 - 1.0;
        }
        for (global_vectors_b) |*v| {
            v.* = random.float(f32) * 2.0 - 1.0;
        }
    }
}

fn benchmarkSequentialVectorDots(num_vectors: usize) u64 {
    const start = nowNs();
    var total: f32 = 0.0;
    for (0..num_vectors) |i| {
        const a = global_vectors_a[i * VECTOR_DIM .. (i + 1) * VECTOR_DIM];
        const b = global_vectors_b[i * VECTOR_DIM .. (i + 1) * VECTOR_DIM];
        total += sequentialVectorDot(a, b);
    }
    // Prevent optimizer from eliminating the loop
    std.mem.doNotOptimizeAway(&total);
    const end = nowNs();
    return end - start;
}

// =============================================================================
// Main Benchmark Runner
// =============================================================================

pub fn main() !void {
    // Zig 0.16 compat: GeneralPurposeAllocator renamed to DebugAllocator.
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;

    std.debug.print("\n=== Thread-Pool Parallel Wrapper Benchmarks ===\n\n", .{});

    // Map Benchmarks
    std.debug.print("--- Parallel Map (squaring integers) ---\n", .{});
    const map_sizes = [_]usize{ 1000, 10000, 100000, 1000000 };
    for (map_sizes) |size| {
        try initGlobalMapBenchmark(allocator, size);

        const seq_result = runBenchmark("sequential_map", benchmarkSequentialMap, size, 10);
        const par_result = runBenchmark("parallel_map", benchmarkParallelMap, size, 10);

        const speedup = if (par_result.mean_ns > 0)
            @as(f64, @floatFromInt(seq_result.mean_ns)) / @as(f64, @floatFromInt(par_result.mean_ns))
        else
            0.0;

        std.debug.print("  Size {d:>8}: seq={d:>10}ns, par={d:>10}ns, speedup={d:.2}x\n", .{
            size,
            seq_result.mean_ns,
            par_result.mean_ns,
            speedup,
        });
    }

    // Reduce Benchmarks
    std.debug.print("\n--- Parallel Reduce (summing u64) ---\n", .{});
    const reduce_sizes = [_]usize{ 1000, 10000, 100000, 1000000 };
    for (reduce_sizes) |size| {
        try initGlobalReduceBenchmark(allocator, size);

        const seq_result = runBenchmark("sequential_reduce", benchmarkSequentialReduce, size, 10);
        const par_result = runBenchmark("parallel_reduce", benchmarkParallelReduce, size, 10);

        const speedup = if (par_result.mean_ns > 0)
            @as(f64, @floatFromInt(seq_result.mean_ns)) / @as(f64, @floatFromInt(par_result.mean_ns))
        else
            0.0;

        std.debug.print("  Size {d:>8}: seq={d:>10}ns, par={d:>10}ns, speedup={d:.2}x\n", .{
            size,
            seq_result.mean_ns,
            par_result.mean_ns,
            speedup,
        });
    }

    // Vector Benchmarks (HNSW-like workload)
    std.debug.print("\n--- Vector Dot Products (128-dim, HNSW-like) ---\n", .{});
    const vec_counts = [_]usize{ 100, 1000, 10000 };
    for (vec_counts) |count| {
        try initGlobalVectorBenchmark(allocator, count);

        const seq_result = runBenchmark("sequential_vectors", benchmarkSequentialVectorDots, count, 10);

        std.debug.print("  Vectors {d:>6}: seq={d:>10}ns ({d:.2} ns/vec)\n", .{
            count,
            seq_result.mean_ns,
            @as(f64, @floatFromInt(seq_result.mean_ns)) / @as(f64, @floatFromInt(count)),
        });
    }

    // Cleanup
    if (global_pool) |*pool| {
        pool.deinit();
    }
    if (global_items.len > 0) allocator.free(global_items);
    if (global_results.len > 0) allocator.free(global_results);
    if (global_sum_items.len > 0) allocator.free(global_sum_items);
    if (global_vectors_a.len > 0) allocator.free(global_vectors_a);
    if (global_vectors_b.len > 0) allocator.free(global_vectors_b);

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

// =============================================================================
// Unit Tests for Benchmark Correctness
// =============================================================================

test "sequential map produces correct results" {
    var items = [_]u32{ 1, 2, 3, 4, 5 };
    var results: [5]u64 = undefined;
    sequentialMapSquare(&items, &results);

    try testing.expectEqual(@as(u64, 1), results[0]);
    try testing.expectEqual(@as(u64, 4), results[1]);
    try testing.expectEqual(@as(u64, 9), results[2]);
    try testing.expectEqual(@as(u64, 16), results[3]);
    try testing.expectEqual(@as(u64, 25), results[4]);
}

test "sequential sum produces correct results" {
    const items = [_]u64{ 1, 2, 3, 4, 5 };
    const sum = sequentialSum(&items);
    try testing.expectEqual(@as(u64, 15), sum);
}

test "sequential vector dot produces correct results" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    const dot = sequentialVectorDot(&a, &b);
    // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    try testing.expectApproxEqRel(@as(f32, 32.0), dot, 0.001);
}
