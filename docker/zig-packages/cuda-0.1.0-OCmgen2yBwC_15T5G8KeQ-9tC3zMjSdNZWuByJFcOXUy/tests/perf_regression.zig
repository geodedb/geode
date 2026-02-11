//! Performance Regression Tests
//!
//! Tests to detect performance regressions in the CUDA library.
//! These tests measure baseline operations and verify they complete
//! within acceptable time bounds.
//!
//! Note: These tests measure CPU-side operations only when CUDA
//! is not available, to ensure consistent CI behavior.

const std = @import("std");
const cuda = @import("cuda");
const types = cuda.types;
const memory = cuda.memory;
const module = cuda.module;
const stream = cuda.stream;
const device = cuda.device;
const driver = cuda.driver;
const profiler = cuda.profiler;

const ns_per_ms = 1_000_000;

// ============================================================================
// Benchmark Utilities
// ============================================================================

/// Measures execution time of a function in nanoseconds
fn measureNs(comptime func: anytype, args: anytype) u64 {
    var timer = std.time.Timer.start() catch return 0;
    @call(.auto, func, args);
    return timer.read();
}

/// Runs a benchmark multiple times and returns statistics
fn benchmark(comptime iterations: usize, comptime func: anytype, args: anytype) BenchStats {
    var times: [iterations]u64 = undefined;
    var total: u64 = 0;

    for (&times) |*t| {
        t.* = measureNs(func, args);
        total += t.*;
    }

    // Sort for percentiles
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));

    return BenchStats{
        .min_ns = times[0],
        .max_ns = times[iterations - 1],
        .mean_ns = total / iterations,
        .p50_ns = times[iterations / 2],
        .p99_ns = times[@min(iterations - 1, iterations * 99 / 100)],
        .iterations = iterations,
    };
}

const BenchStats = struct {
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p99_ns: u64,
    iterations: usize,

    pub fn meanMs(self: BenchStats) f64 {
        return @as(f64, @floatFromInt(self.mean_ns)) / @as(f64, ns_per_ms);
    }

    pub fn p99Ms(self: BenchStats) f64 {
        return @as(f64, @floatFromInt(self.p99_ns)) / @as(f64, ns_per_ms);
    }
};

// ============================================================================
// LaunchConfig Performance
// ============================================================================

fn benchLaunchConfig1D() void {
    const config = types.LaunchConfig.for1D(1_000_000, 256);
    std.mem.doNotOptimizeAway(&config);
}

test "LaunchConfig.for1D performance" {
    const stats = benchmark(10000, benchLaunchConfig1D, .{});

    // Should complete in microseconds (< 1ms)
    try std.testing.expect(stats.p99Ms() < 1.0);
}

fn benchLaunchConfig2D() void {
    const config = types.LaunchConfig.for2D(1920, 1080, 16, 16);
    std.mem.doNotOptimizeAway(&config);
}

test "LaunchConfig.for2D performance" {
    const stats = benchmark(10000, benchLaunchConfig2D, .{});

    // Should complete in microseconds (< 1ms)
    try std.testing.expect(stats.p99Ms() < 1.0);
}

fn benchLaunchConfigThreads() void {
    const config = types.LaunchConfig{
        .grid = .{ 1000, 1000, 10 },
        .block = .{ 256, 1, 1 },
    };
    const total = config.totalThreads();
    std.mem.doNotOptimizeAway(&total);
}

test "LaunchConfig.totalThreads performance" {
    const stats = benchmark(10000, benchLaunchConfigThreads, .{});

    // Should complete in microseconds (< 1ms)
    try std.testing.expect(stats.p99Ms() < 1.0);
}

// ============================================================================
// Buffer Operations Performance
// ============================================================================

fn benchBufferValidation() void {
    const buf = memory.Buffer{
        .ptr = 0x10000,
        .size = 1024,
        .kind = .device,
        .allocated = true,
    };
    const valid = buf.isValid();
    std.mem.doNotOptimizeAway(&valid);
}

test "Buffer.isValid performance" {
    const stats = benchmark(100000, benchBufferValidation, .{});

    // Should be extremely fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// KernelArgs Performance
// ============================================================================

fn benchKernelArgsAdd() void {
    var val: u32 = 42;
    var args = module.KernelArgs(16){};
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    std.mem.doNotOptimizeAway(&args);
}

test "KernelArgs.addPtr performance" {
    const stats = benchmark(100000, benchKernelArgsAdd, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

fn benchKernelArgsReset() void {
    var val: u32 = 42;
    var args = module.KernelArgs(16){};
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    args.reset();
    std.mem.doNotOptimizeAway(&args);
}

test "KernelArgs.reset performance" {
    const stats = benchmark(100000, benchKernelArgsReset, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// TypedKernelArgs Performance
// ============================================================================

const TestArgs = struct {
    input: u64,
    output: u64,
    size: u32,
    scale: f32,
};

fn benchTypedKernelArgsInit() void {
    var args = module.TypedKernelArgs(TestArgs).init(.{
        .input = 0x1000,
        .output = 0x2000,
        .size = 1024,
        .scale = 1.5,
    });
    std.mem.doNotOptimizeAway(&args);
}

test "TypedKernelArgs.init performance" {
    const stats = benchmark(100000, benchTypedKernelArgsInit, .{});

    // Should be very fast (< 0.5ms)
    try std.testing.expect(stats.p99Ms() < 0.5);
}

fn benchTypedKernelArgsGet() void {
    var args = module.TypedKernelArgs(TestArgs).init(.{
        .input = 0x1000,
        .output = 0x2000,
        .size = 1024,
        .scale = 1.5,
    });
    const size = args.get("size");
    std.mem.doNotOptimizeAway(&size);
}

test "TypedKernelArgs.get performance" {
    const stats = benchmark(100000, benchTypedKernelArgsGet, .{});

    // Should be very fast (< 0.5ms)
    try std.testing.expect(stats.p99Ms() < 0.5);
}

// ============================================================================
// NvrtcOptions Performance
// ============================================================================

fn benchNvrtcOptionsBuilder() void {
    var opts = module.NvrtcOptions.forArch(.{ .major = 8, .minor = 6 });
    _ = opts.maxPerformance();
    std.mem.doNotOptimizeAway(&opts);
}

test "NvrtcOptions builder performance" {
    const stats = benchmark(10000, benchNvrtcOptionsBuilder, .{});

    // Should be fast (< 1ms)
    try std.testing.expect(stats.p99Ms() < 1.0);
}

// ============================================================================
// ComputeArch Performance
// ============================================================================

fn benchComputeArchName() void {
    const arch = types.ComputeArch{ .major = 8, .minor = 6 };
    const name = arch.name();
    std.mem.doNotOptimizeAway(name.ptr);
}

test "ComputeArch.name performance" {
    const stats = benchmark(100000, benchComputeArchName, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

fn benchComputeArchSmString() void {
    const arch = types.ComputeArch{ .major = 9, .minor = 0 };
    const sm = arch.smString();
    std.mem.doNotOptimizeAway(sm.ptr);
}

test "ComputeArch.smString performance" {
    const stats = benchmark(100000, benchComputeArchSmString, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// CudaError Performance
// ============================================================================

fn benchCudaErrorHandling() void {
    const err: types.CudaError = error.NoDevice;
    const is_no_device = err == error.NoDevice;
    std.mem.doNotOptimizeAway(&is_no_device);
}

test "CudaError handling performance" {
    const stats = benchmark(100000, benchCudaErrorHandling, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// Profiler CPU-side Performance
// ============================================================================

fn benchProfileTimerStart() void {
    var timer = profiler.ProfileTimer.start("test_operation");
    std.mem.doNotOptimizeAway(&timer);
}

test "ProfileTimer.start performance" {
    const stats = benchmark(10000, benchProfileTimerStart, .{});

    // Should be fast (< 1ms)
    try std.testing.expect(stats.p99Ms() < 1.0);
}

fn benchProfileTimerFull() void {
    var timer = profiler.ProfileTimer.start("test_operation");
    const result = timer.finish();
    std.mem.doNotOptimizeAway(&result);
}

test "ProfileTimer full cycle performance" {
    const stats = benchmark(10000, benchProfileTimerFull, .{});

    // Should be fast (< 2ms including timing overhead)
    try std.testing.expect(stats.p99Ms() < 2.0);
}

fn benchPerformanceProfileFinalize() void {
    var profile = profiler.PerformanceProfile{
        .total_ms = 100.0,
        .host_to_device_ms = 10.0,
        .device_to_host_ms = 10.0,
        .kernel_ms = 70.0,
    };
    profile.finalize();
    std.mem.doNotOptimizeAway(&profile);
}

test "PerformanceProfile.finalize performance" {
    const stats = benchmark(100000, benchPerformanceProfileFinalize, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// Memory Stats Performance
// ============================================================================

fn benchMemoryStatsFormat() void {
    const stats = memory.MemoryStats{
        .device_allocs = 100,
        .device_bytes_allocated = 1024 * 1024 * 100,
        .pool_hits = 50,
        .h2d_transfers = 200,
        .h2d_bytes = 1024 * 1024 * 50,
    };
    const formatted = stats.format(std.testing.allocator) catch "";
    defer if (formatted.len > 0) std.testing.allocator.free(formatted);
    std.mem.doNotOptimizeAway(formatted.ptr);
}

test "MemoryStats.format performance" {
    const stats = benchmark(1000, benchMemoryStatsFormat, .{});

    // Formatting with allocation should be < 10ms
    try std.testing.expect(stats.p99Ms() < 10.0);
}

// ============================================================================
// Device Operations Performance
// ============================================================================

fn benchDeviceGetName() void {
    var dev = device.Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
    };
    const name_bytes = "NVIDIA GeForce RTX 3090";
    @memcpy(dev.name[0..name_bytes.len], name_bytes);
    dev.name_len = name_bytes.len;
    const name = dev.getName();
    std.mem.doNotOptimizeAway(name.ptr);
}

test "Device.getName performance" {
    const stats = benchmark(100000, benchDeviceGetName, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

fn benchDeviceGetMemory() void {
    var dev = device.Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
        .total_memory = 24 * 1024 * 1024 * 1024, // 24 GB
    };
    const gb = dev.getTotalMemoryGB();
    std.mem.doNotOptimizeAway(&gb);
}

test "Device.getTotalMemoryGB performance" {
    const stats = benchmark(100000, benchDeviceGetMemory, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// DeviceList Performance
// ============================================================================

fn benchDeviceListGet() void {
    const items = [_]device.Device{
        .{ .ordinal = 0, .handle = 0, .drv = driver.getDriver() },
        .{ .ordinal = 1, .handle = 1, .drv = driver.getDriver() },
        .{ .ordinal = 2, .handle = 2, .drv = driver.getDriver() },
        .{ .ordinal = 3, .handle = 3, .drv = driver.getDriver() },
    };
    var list = device.DeviceList{
        .items = @constCast(&items),
        .allocator = std.testing.allocator,
        .drv = driver.getDriver(),
    };
    const dev = list.get(2);
    std.mem.doNotOptimizeAway(&dev);
}

test "DeviceList.get performance" {
    const stats = benchmark(100000, benchDeviceListGet, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// PoolStats Performance
// ============================================================================

fn benchPoolStatsCreation() void {
    const stats = memory.PoolStats{
        .total_buffers = 1000,
        .allocated_buffers = 500,
        .free_buffers = 500,
        .total_bytes = 1024 * 1024 * 1024,
        .allocated_bytes = 512 * 1024 * 1024,
        .free_bytes = 512 * 1024 * 1024,
        .fragmentation_ratio = 0.15,
        .largest_free_block = 64 * 1024 * 1024,
    };
    std.mem.doNotOptimizeAway(&stats);
}

test "PoolStats creation performance" {
    const stats = benchmark(100000, benchPoolStatsCreation, .{});

    // Should be very fast (< 0.1ms)
    try std.testing.expect(stats.p99Ms() < 0.1);
}

// ============================================================================
// Regression Baseline Verification
// ============================================================================

test "All benchmarks complete without timeout" {
    // This test ensures the benchmark suite itself runs quickly
    var timer = std.time.Timer.start() catch return;

    // Run a subset of benchmarks
    _ = benchmark(100, benchLaunchConfig1D, .{});
    _ = benchmark(100, benchBufferValidation, .{});
    _ = benchmark(100, benchKernelArgsAdd, .{});
    _ = benchmark(100, benchComputeArchName, .{});
    _ = benchmark(100, benchCudaErrorHandling, .{});

    const elapsed_ms = timer.read() / ns_per_ms;

    // All benchmarks together should complete in < 100ms
    try std.testing.expect(elapsed_ms < 100);
}

test "Performance characteristics are consistent" {
    // Run same benchmark multiple times, variance should be low
    const run1 = benchmark(1000, benchBufferValidation, .{});
    const run2 = benchmark(1000, benchBufferValidation, .{});
    const run3 = benchmark(1000, benchBufferValidation, .{});

    // Means should be within 10x of each other (very loose bound)
    const max_mean = @max(@max(run1.mean_ns, run2.mean_ns), run3.mean_ns);
    const min_mean = @min(@min(run1.mean_ns, run2.mean_ns), run3.mean_ns);

    // Avoid division by zero
    if (min_mean > 0) {
        try std.testing.expect(max_mean / min_mean < 10);
    }
}
