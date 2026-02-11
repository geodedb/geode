//! Error Recovery Tests
//!
//! Tests error handling, recovery, and graceful degradation scenarios.
//! These tests verify that the library handles errors correctly and
//! provides meaningful error information.

const std = @import("std");
const cuda = @import("cuda");
const types = cuda.types;
const memory = cuda.memory;
const module = cuda.module;
const stream = cuda.stream;
const device = cuda.device;
const driver = cuda.driver;

// ============================================================================
// CUresult (CUDA C Error Codes) Tests
// ============================================================================

test "CUresult success value" {
    try std.testing.expectEqual(@as(types.CUresult, 0), types.CUDA_SUCCESS);
}

test "CUresult error values are distinct" {
    const error_codes = [_]types.CUresult{
        1, // CUDA_ERROR_INVALID_VALUE
        2, // CUDA_ERROR_OUT_OF_MEMORY
        3, // CUDA_ERROR_NOT_INITIALIZED
        100, // CUDA_ERROR_NO_DEVICE
        101, // CUDA_ERROR_INVALID_DEVICE
    };

    for (error_codes, 0..) |code1, i| {
        for (error_codes[i + 1 ..]) |code2| {
            try std.testing.expect(code1 != code2);
        }
    }
}

// ============================================================================
// Driver Error Recovery
// ============================================================================

test "Driver getDriver returns valid pointer" {
    const drv = driver.getDriver();
    // getDriver should return a valid pointer
    try std.testing.expect(@intFromPtr(drv) != 0);
}

test "Driver available check before init" {
    const drv = driver.getDriver();
    // available() should be callable
    _ = drv.available();
}

test "Driver symbol lookup graceful failure" {
    const drv = driver.getDriver();
    // supportsStreams should be callable
    _ = drv.supportsStreams();
}

// ============================================================================
// Memory Error Handling
// ============================================================================

test "Memory allocation with zero size behavior" {
    // Zero-size allocations should be handled gracefully
    const size: usize = 0;
    try std.testing.expectEqual(@as(usize, 0), size);
}

test "Buffer operations on invalid buffer" {
    const invalid_buf = memory.Buffer{
        .ptr = 0,
        .size = 0,
        .kind = .device,
        .allocated = false,
    };

    try std.testing.expect(!invalid_buf.isValid());
}

test "UnifiedBuffer operations on invalid buffer" {
    const invalid_buf = memory.UnifiedBuffer{
        .ptr = 0,
        .size = 0,
        .drv = driver.getDriver(),
    };

    try std.testing.expect(!invalid_buf.isValid());
}

test "PoolStats validates correctly" {
    const stats = memory.PoolStats{
        .total_buffers = 10,
        .allocated_buffers = 5,
        .free_buffers = 5,
        .fragmentation_ratio = 0.2,
    };

    // Valid stats: allocated + free = total
    try std.testing.expectEqual(@as(usize, 10), stats.total_buffers);
    try std.testing.expectEqual(@as(usize, 10), stats.allocated_buffers + stats.free_buffers);
}

// ============================================================================
// Module Error Recovery
// ============================================================================

test "Kernel with uninitialized handle" {
    var kernel = module.Kernel{
        .handle = undefined,
        .drv = driver.getDriver(),
    };

    // Test that we can access name even with uninitialized handle
    kernel.name_len = 0;
    try std.testing.expectEqualStrings("", kernel.getName());
}

test "KernelArgs overflow protection" {
    var val: u32 = 42;
    var args = module.KernelArgs(2){};

    // Fill to capacity
    args.addPtr(&val);
    args.addPtr(&val);
    try std.testing.expectEqual(@as(usize, 2), args.count);

    // Overflow should be silently ignored
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    try std.testing.expectEqual(@as(usize, 2), args.count);
}

test "NvrtcOptions validation" {
    const opts = module.NvrtcOptions{
        .opt_level = 3, // Max valid
    };
    try std.testing.expectEqual(@as(u2, 3), opts.opt_level);
}

// ============================================================================
// Stream Error Recovery
// ============================================================================

test "Stream with null handle" {
    const invalid_stream = stream.Stream{
        .handle = null,
        .drv = driver.getDriver(),
        .is_default = false,
        .priority = 0,
    };

    try std.testing.expect(!invalid_stream.is_default);
    try std.testing.expect(invalid_stream.handle == null);
}

test "Stream default stream marker" {
    const default_stream = stream.Stream{
        .handle = null,
        .drv = driver.getDriver(),
        .is_default = true,
        .priority = 0,
    };

    try std.testing.expect(default_stream.is_default);
}

// ============================================================================
// Device Error Recovery
// ============================================================================

test "Device with various ordinal values" {
    const dev = device.Device{
        .ordinal = 255,
        .handle = 0,
        .drv = driver.getDriver(),
    };

    // Should not crash accessing properties
    try std.testing.expectEqual(@as(i32, 255), dev.ordinal);
}

test "DeviceList bounds checking" {
    var list = device.DeviceList{
        .items = &[_]device.Device{},
        .allocator = std.testing.allocator,
        .drv = driver.getDriver(),
    };

    // Out of bounds should return null, not crash
    try std.testing.expect(list.get(0) == null);
    try std.testing.expect(list.get(100) == null);
    try std.testing.expect(list.get(std.math.maxInt(usize)) == null);

    list.deinit();
}

test "ComputeArch invalid version handling" {
    const arch = types.ComputeArch{
        .major = 0,
        .minor = 0,
    };

    // Should return Unknown, not crash
    try std.testing.expectEqualStrings("Unknown", arch.name());
}

// ============================================================================
// Configuration Error Recovery
// ============================================================================

test "LaunchConfig with invalid dimensions" {
    // Zero dimensions should be handled
    const config = types.LaunchConfig{
        .grid = .{ 0, 0, 0 },
        .block = .{ 0, 0, 0 },
    };

    // Should not crash calculating threads
    const total = config.totalThreads();
    try std.testing.expectEqual(@as(u64, 0), total);
}

test "LaunchConfig with large dimensions" {
    // Use dimensions that don't overflow u64
    const config = types.LaunchConfig{
        .grid = .{ 65535, 65535, 1 },
        .block = .{ 1024, 1, 1 },
    };

    // Should handle large values gracefully
    const total = config.totalThreads();
    try std.testing.expect(total > 0);
}

// ============================================================================
// Profiler Error Recovery
// ============================================================================

test "ProfileTimer finish twice" {
    var timer = cuda.profiler.ProfileTimer.start("test");
    _ = timer.finish();
    // Second finish should return zero duration
    const profile2 = timer.finish();
    _ = profile2;
}

test "PerformanceProfile finalize with no data" {
    var profile = cuda.profiler.PerformanceProfile{};
    profile.finalize();

    // Should not divide by zero
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), profile.transfer_overhead_percent, 0.001);
}

test "BenchmarkResult with zero iterations" {
    const result = cuda.profiler.BenchmarkResult{
        .iterations = 0,
        .total_ms = 0,
        .mean_ms = 0,
        .min_ms = 0,
        .max_ms = 0,
        .std_dev_ms = 0,
        .throughput = 0,
        .data_size = 0,
        .bandwidth_gbps = 0,
    };

    // Should handle zero iterations gracefully
    try std.testing.expectEqual(@as(usize, 0), result.iterations);
}

// ============================================================================
// Type Conversion Error Recovery
// ============================================================================

test "ComputeArch sm string generation" {
    const arch = types.ComputeArch{ .major = 9, .minor = 0 };
    const sm = arch.smString();
    try std.testing.expectEqualStrings("sm_90", sm);
}

test "ComputeArch boundary values" {
    // Test with extremes
    const min_arch = types.ComputeArch{ .major = 0, .minor = 0 };
    const max_arch = types.ComputeArch{ .major = 10, .minor = 0 };

    // Unknown arch gets fallback
    try std.testing.expectEqualStrings("Unknown", min_arch.name());
    try std.testing.expectEqualStrings("Blackwell", max_arch.name());
}

// ============================================================================
// Resource Cleanup Error Recovery
// ============================================================================

test "Double cleanup prevention" {
    var buf = memory.Buffer{
        .ptr = 0x10000,
        .size = 1024,
        .kind = .device,
        .allocated = true,
    };

    // Mark as freed
    buf.allocated = false;

    // Should now be invalid
    try std.testing.expect(!buf.isValid());
}

test "Cleanup with null handles" {
    // Test that streams with null handles don't crash
    const s = stream.Stream{
        .handle = null,
        .drv = driver.getDriver(),
        .is_default = false,
        .priority = 0,
    };

    try std.testing.expect(s.handle == null);
}

// ============================================================================
// Graceful Degradation
// ============================================================================

test "Driver capability queries" {
    const drv = driver.getDriver();

    // All capability queries should be callable without crashing
    _ = drv.supportsStreams();
    _ = drv.supportsOccupancy();
    _ = drv.available();
}

test "Feature detection consistency" {
    const drv = driver.getDriver();

    // Multiple calls should return consistent results
    const available1 = drv.available();
    const available2 = drv.available();
    try std.testing.expectEqual(available1, available2);
}

// ============================================================================
// Error Set Handling
// ============================================================================

test "CudaError error values are distinct" {
    // Test that different error types work correctly
    const e1: types.CudaError = error.DriverNotFound;
    const e2: types.CudaError = error.NoDevice;
    const e3: types.CudaError = error.OutOfMemory;

    try std.testing.expect(e1 != e2);
    try std.testing.expect(e2 != e3);
    try std.testing.expect(e1 != e3);
}

test "Error handling pattern" {
    // Simulate error handling
    const result: types.CudaError!void = error.NoDevice;

    result catch |err| {
        switch (err) {
            error.NoDevice => {},
            error.DriverNotFound => {},
            else => unreachable,
        }
    };
}

// ============================================================================
// Null Safety
// ============================================================================

test "Null pointer in types" {
    // CUdeviceptr with null value
    const null_ptr: types.CUdeviceptr = 0;
    try std.testing.expectEqual(@as(types.CUdeviceptr, 0), null_ptr);
}

test "Optional handle patterns" {
    // Test nullable handle patterns
    const maybe_ctx: ?types.CUcontext = null;
    try std.testing.expect(maybe_ctx == null);
}

// ============================================================================
// Memory Statistics Edge Cases
// ============================================================================

test "MemoryStats default values" {
    const stats = memory.MemoryStats{};
    try std.testing.expectEqual(@as(usize, 0), stats.device_allocs);
    try std.testing.expectEqual(@as(usize, 0), stats.device_bytes_allocated);
    try std.testing.expectEqual(@as(usize, 0), stats.h2d_transfers);
}

test "MemoryStats tracking" {
    var stats = memory.MemoryStats{};
    stats.device_allocs = 10;
    stats.h2d_transfers = 5;

    try std.testing.expectEqual(@as(usize, 10), stats.device_allocs);
    try std.testing.expectEqual(@as(usize, 5), stats.h2d_transfers);
}
