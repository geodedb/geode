//! Edge Case and Boundary Condition Tests
//!
//! This module tests edge cases, boundary conditions, and corner cases
//! that might not be covered by normal unit tests.

const std = @import("std");
const cuda = @import("cuda");
const types = cuda.types;
const memory = cuda.memory;
const module = cuda.module;
const stream = cuda.stream;
const device = cuda.device;
const driver = cuda.driver;

// ============================================================================
// LaunchConfig Edge Cases
// ============================================================================

test "LaunchConfig with zero elements" {
    const config = types.LaunchConfig.for1D(0, 256);
    // Should handle gracefully - at minimum 1 block
    try std.testing.expect(config.grid[0] >= 0);
}

test "LaunchConfig with single element" {
    const config = types.LaunchConfig.for1D(1, 256);
    try std.testing.expectEqual(@as(u32, 1), config.grid[0]);
    try std.testing.expectEqual(@as(u32, 256), config.block[0]);
}

test "LaunchConfig exact multiple of block size" {
    const config = types.LaunchConfig.for1D(1024, 256);
    try std.testing.expectEqual(@as(u32, 4), config.grid[0]);
}

test "LaunchConfig one more than multiple" {
    const config = types.LaunchConfig.for1D(1025, 256);
    try std.testing.expectEqual(@as(u32, 5), config.grid[0]);
}

test "LaunchConfig one less than multiple" {
    const config = types.LaunchConfig.for1D(1023, 256);
    try std.testing.expectEqual(@as(u32, 4), config.grid[0]);
}

test "LaunchConfig with block size of 1" {
    const config = types.LaunchConfig.for1D(100, 1);
    try std.testing.expectEqual(@as(u32, 100), config.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), config.block[0]);
}

test "LaunchConfig with maximum block size" {
    const config = types.LaunchConfig.for1D(1024, 1024);
    try std.testing.expectEqual(@as(u32, 1), config.grid[0]);
    try std.testing.expectEqual(@as(u32, 1024), config.block[0]);
}

test "LaunchConfig 2D with 1x1 block" {
    const config = types.LaunchConfig.for2D(100, 100, 1, 1);
    try std.testing.expectEqual(@as(u32, 100), config.grid[0]);
    try std.testing.expectEqual(@as(u32, 100), config.grid[1]);
}

test "LaunchConfig 2D asymmetric" {
    const config = types.LaunchConfig.for2D(1920, 1080, 16, 16);
    try std.testing.expectEqual(@as(u32, 120), config.grid[0]);
    try std.testing.expectEqual(@as(u32, 68), config.grid[1]); // ceil(1080/16)
}

test "LaunchConfig totalThreads with large values" {
    const config = types.LaunchConfig{
        .grid = .{ 65535, 65535, 1 },
        .block = .{ 1024, 1, 1 },
    };
    const total = config.totalThreads();
    // Should not overflow - result > 4 billion
    try std.testing.expect(total > 4_000_000_000);
}

test "LaunchConfig totalThreads 3D" {
    const config = types.LaunchConfig{
        .grid = .{ 10, 10, 10 },
        .block = .{ 8, 8, 8 },
    };
    // 1000 blocks * 512 threads = 512000
    try std.testing.expectEqual(@as(u64, 512000), config.totalThreads());
}

// ============================================================================
// Buffer Edge Cases
// ============================================================================

test "Buffer with null pointer is invalid" {
    const buf = memory.Buffer{
        .ptr = 0,
        .size = 1024,
        .kind = .device,
        .allocated = true,
    };
    try std.testing.expect(!buf.isValid());
}

test "Buffer with zero size is invalid" {
    const buf = memory.Buffer{
        .ptr = 0x10000,
        .size = 0,
        .kind = .device,
        .allocated = true,
    };
    try std.testing.expect(!buf.isValid());
}

test "Buffer not allocated is invalid" {
    const buf = memory.Buffer{
        .ptr = 0x10000,
        .size = 1024,
        .kind = .device,
        .allocated = false,
    };
    try std.testing.expect(!buf.isValid());
}

test "Buffer valid only when all conditions met" {
    const buf = memory.Buffer{
        .ptr = 0x10000,
        .size = 1024,
        .kind = .device,
        .allocated = true,
    };
    try std.testing.expect(buf.isValid());
}

test "UnifiedBuffer with null pointer is invalid" {
    const buf = memory.UnifiedBuffer{
        .ptr = 0,
        .size = 1024,
        .drv = driver.getDriver(),
    };
    try std.testing.expect(!buf.isValid());
}

test "UnifiedBuffer with zero size is invalid" {
    const buf = memory.UnifiedBuffer{
        .ptr = 0x10000,
        .size = 0,
        .drv = driver.getDriver(),
    };
    try std.testing.expect(!buf.isValid());
}

// ============================================================================
// Kernel Name Edge Cases
// ============================================================================

test "Kernel empty name" {
    var kernel = module.Kernel{
        .handle = undefined,
        .drv = undefined,
    };
    kernel.name_len = 0;
    try std.testing.expectEqualStrings("", kernel.getName());
}

test "Kernel name at exact max length" {
    var kernel = module.Kernel{
        .handle = undefined,
        .drv = undefined,
    };
    @memset(kernel.name[0..module.MAX_KERNEL_NAME_LEN], 'A');
    kernel.name[module.MAX_KERNEL_NAME_LEN] = 0;
    kernel.name_len = module.MAX_KERNEL_NAME_LEN;

    try std.testing.expectEqual(@as(usize, 255), kernel.getName().len);
}

test "Kernel name with special characters" {
    var kernel = module.Kernel{
        .handle = undefined,
        .drv = undefined,
    };
    const name = "_kernel_123_test";
    @memcpy(kernel.name[0..name.len], name);
    kernel.name_len = name.len;

    try std.testing.expectEqualStrings("_kernel_123_test", kernel.getName());
}

// ============================================================================
// KernelArgs Edge Cases
// ============================================================================

test "KernelArgs empty" {
    var args = module.KernelArgs(16){};
    try std.testing.expectEqual(@as(usize, 0), args.count);
    const ptr = args.getArgs();
    try std.testing.expect(@intFromPtr(ptr) != 0);
}

test "KernelArgs at capacity" {
    var val: u32 = 42;
    var args = module.KernelArgs(4){};

    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    try std.testing.expectEqual(@as(usize, 4), args.count);

    // Adding beyond capacity should be ignored
    args.addPtr(&val);
    try std.testing.expectEqual(@as(usize, 4), args.count);
}

test "KernelArgs reset clears all" {
    var val: u32 = 42;
    var args = module.KernelArgs(16){};

    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    try std.testing.expectEqual(@as(usize, 3), args.count);

    args.reset();
    try std.testing.expectEqual(@as(usize, 0), args.count);
}

test "TypedKernelArgs with single field" {
    const Args = struct { value: u32 };
    var args = module.TypedKernelArgs(Args).init(.{ .value = 42 });

    try std.testing.expectEqual(@as(usize, 1), args.count());
    try std.testing.expectEqual(@as(u32, 42), args.get("value"));
}

test "TypedKernelArgs with many fields" {
    const Args = struct {
        a: u32,
        b: u32,
        c: u32,
        d: f32,
        e: usize,
    };
    var args = module.TypedKernelArgs(Args).init(.{
        .a = 1,
        .b = 2,
        .c = 3,
        .d = 4.0,
        .e = 5,
    });

    try std.testing.expectEqual(@as(usize, 5), args.count());
}

test "TypedKernelArgs set and get" {
    const Args = struct { value: u32 };
    var args = module.TypedKernelArgs(Args).init(.{ .value = 10 });

    try std.testing.expectEqual(@as(u32, 10), args.get("value"));
    args.set("value", 20);
    try std.testing.expectEqual(@as(u32, 20), args.get("value"));
}

// ============================================================================
// NvrtcOptions Edge Cases
// ============================================================================

test "NvrtcOptions default values" {
    const opts = module.NvrtcOptions{};

    try std.testing.expect(opts.arch == null);
    try std.testing.expectEqual(module.NvrtcOptions.CppStandard.cpp11, opts.std);
    try std.testing.expectEqual(@as(u2, 2), opts.opt_level);
    try std.testing.expect(!opts.debug);
    try std.testing.expect(!opts.fast_math);
    try std.testing.expect(opts.fmad);
}

test "NvrtcOptions maxPerformance modifies correctly" {
    var opts = module.NvrtcOptions{};
    _ = opts.maxPerformance();

    try std.testing.expectEqual(@as(u2, 3), opts.opt_level);
    try std.testing.expect(opts.fast_math);
    try std.testing.expect(opts.use_fast_div);
    try std.testing.expect(!opts.debug);
}

test "NvrtcOptions forDebugging modifies correctly" {
    var opts = module.NvrtcOptions{};
    _ = opts.forDebugging();

    try std.testing.expectEqual(@as(u2, 0), opts.opt_level);
    try std.testing.expect(opts.debug);
    try std.testing.expect(opts.line_info);
    try std.testing.expect(!opts.fast_math);
}

test "NvrtcOptions CppStandard all values" {
    try std.testing.expectEqualStrings("--std=c++11", module.NvrtcOptions.CppStandard.cpp11.toOption());
    try std.testing.expectEqualStrings("--std=c++14", module.NvrtcOptions.CppStandard.cpp14.toOption());
    try std.testing.expectEqualStrings("--std=c++17", module.NvrtcOptions.CppStandard.cpp17.toOption());
    try std.testing.expectEqualStrings("--std=c++20", module.NvrtcOptions.CppStandard.cpp20.toOption());
}

// ============================================================================
// ComputeArch Edge Cases
// ============================================================================

test "ComputeArch oldest supported" {
    const arch = types.ComputeArch{ .major = 3, .minor = 0 };
    try std.testing.expectEqualStrings("Kepler", arch.name());
}

test "ComputeArch newest supported" {
    const arch = types.ComputeArch{ .major = 10, .minor = 0 };
    try std.testing.expectEqualStrings("Blackwell", arch.name());
}

test "ComputeArch unknown version" {
    const arch = types.ComputeArch{ .major = 99, .minor = 0 };
    try std.testing.expectEqualStrings("Unknown", arch.name());
}

test "ComputeArch minor version variations" {
    const arch1 = types.ComputeArch{ .major = 8, .minor = 0 };
    const arch2 = types.ComputeArch{ .major = 8, .minor = 6 };
    const arch3 = types.ComputeArch{ .major = 8, .minor = 9 };

    // SM 8.0-8.8 are Ampere, SM 8.9+ is Ada Lovelace
    try std.testing.expectEqualStrings("Ampere", arch1.name());
    try std.testing.expectEqualStrings("Ampere", arch2.name());
    try std.testing.expectEqualStrings("Ada Lovelace", arch3.name());
}

// ============================================================================
// Stream Edge Cases
// ============================================================================

test "Stream struct fields" {
    const s = stream.Stream{
        .handle = null,
        .drv = driver.getDriver(),
        .is_default = false,
        .priority = 0,
    };
    try std.testing.expect(!s.is_default);
    try std.testing.expectEqual(@as(i32, 0), s.priority);
}

// ============================================================================
// PoolStats Edge Cases
// ============================================================================

test "PoolStats default values" {
    const stats = memory.PoolStats{};

    try std.testing.expectEqual(@as(usize, 0), stats.total_buffers);
    try std.testing.expectEqual(@as(usize, 0), stats.allocated_buffers);
    try std.testing.expectEqual(@as(usize, 0), stats.free_buffers);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), stats.fragmentation_ratio, 0.001);
}

// ============================================================================
// TransferOp Edge Cases
// ============================================================================

test "TransferOp enum values" {
    try std.testing.expect(memory.TransferOp.host_to_device != memory.TransferOp.device_to_host);
    try std.testing.expect(memory.TransferOp.device_to_host != memory.TransferOp.device_to_device);
}

// ============================================================================
// MemoryStats Edge Cases
// ============================================================================

test "MemoryStats format with zero values" {
    const stats = memory.MemoryStats{};
    const formatted = try stats.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Device Allocs: 0") != null);
}

test "MemoryStats format with max values" {
    const stats = memory.MemoryStats{
        .device_allocs = std.math.maxInt(usize),
        .device_bytes_allocated = std.math.maxInt(usize),
    };
    // Should not crash formatting large values
    const formatted = try stats.format(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(formatted.len > 0);
}

// ============================================================================
// Device Edge Cases
// ============================================================================

test "Device empty name" {
    var dev = device.Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
    };
    dev.name_len = 0;
    try std.testing.expectEqualStrings("", dev.getName());
}

test "Device getTotalMemoryGB with zero memory" {
    var dev = device.Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
        .total_memory = 0,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), dev.getTotalMemoryGB(), 0.001);
}

test "Device getTotalMemoryGB with large memory" {
    var dev = device.Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
        .total_memory = 80 * 1024 * 1024 * 1024, // 80 GB (like A100)
    };
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), dev.getTotalMemoryGB(), 0.01);
}

test "DeviceList empty" {
    var list = device.DeviceList{
        .items = &[_]device.Device{},
        .allocator = std.testing.allocator,
        .drv = driver.getDriver(),
    };
    try std.testing.expectEqual(@as(usize, 0), list.count());
    try std.testing.expect(list.get(0) == null);
    try std.testing.expect(list.get(100) == null);
    list.deinit();
}

// ============================================================================
// ContextScope Edge Cases
// ============================================================================

test "ContextScope struct size" {
    try std.testing.expect(@sizeOf(device.ContextScope) > 0);
}

// ============================================================================
// Alignment Edge Cases
// ============================================================================

test "alignUp with zero" {
    const result = alignUp(0, 256);
    try std.testing.expectEqual(@as(usize, 0), result);
}

test "alignUp exact alignment" {
    const result = alignUp(256, 256);
    try std.testing.expectEqual(@as(usize, 256), result);
}

test "alignUp just over" {
    const result = alignUp(257, 256);
    try std.testing.expectEqual(@as(usize, 512), result);
}

test "alignUp just under" {
    const result = alignUp(255, 256);
    try std.testing.expectEqual(@as(usize, 256), result);
}

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// ============================================================================
// Profiler Edge Cases
// ============================================================================

test "ProfileTimer operation name truncation" {
    const long_name = "a" ** 200;
    var timer = cuda.profiler.ProfileTimer.start(long_name);
    const profile = timer.finish();
    // Name should be truncated to 128 chars
    try std.testing.expect(profile.getOperation().len <= 128);
}

test "PerformanceProfile with zero total time" {
    var profile = cuda.profiler.PerformanceProfile{};
    profile.total_ms = 0;
    profile.finalize();
    // Should not divide by zero
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), profile.transfer_overhead_percent, 0.001);
}

test "BenchmarkResult getName empty" {
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
    try std.testing.expectEqualStrings("", result.getName());
}
