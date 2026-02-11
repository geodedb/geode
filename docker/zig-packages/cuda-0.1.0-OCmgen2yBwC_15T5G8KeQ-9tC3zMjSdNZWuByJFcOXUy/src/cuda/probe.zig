// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Device Probing and Detection
//!
//! This module provides functionality to detect CUDA availability and enumerate
//! GPU devices without panicking. It handles graceful degradation when CUDA
//! is not available.
//!
//! ## Detection Strategy
//! 1. Check if platform is Linux (CUDA only officially supports Linux for compute)
//! 2. Attempt to load libcuda.so dynamically
//! 3. Initialize driver and enumerate devices
//! 4. Query device properties and capabilities
//!
//! ## Usage
//! ```zig
//! const result = try cuda.probe(allocator);
//! defer result.deinit(allocator);
//!
//! if (result.available) {
//!     for (result.devices) |dev| {
//!         std.debug.print("Found: {s}\n", .{dev.name});
//!     }
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const driver = @import("driver.zig");
const types = @import("types.zig");

// Re-exports
pub const ComputeArch = types.ComputeArch;
pub const Architectures = types.Architectures;
pub const CudaError = types.CudaError;

// ============================================================================
// Device Information
// ============================================================================

/// Detailed information about a CUDA device
pub const DeviceInfo = struct {
    /// Device ordinal (0-based index)
    id: u32,
    /// Device name (e.g., "NVIDIA GeForce RTX 4090")
    name: [256]u8 = [_]u8{0} ** 256,
    /// Length of name string
    name_len: usize = 0,
    /// Total device memory in bytes
    total_memory: usize = 0,
    /// Free device memory (snapshot at probe time)
    free_memory: usize = 0,
    /// Compute architecture
    arch: ComputeArch = Architectures.default,
    /// Number of streaming multiprocessors
    sm_count: u32 = 0,
    /// Maximum threads per block
    max_threads_per_block: u32 = 1024,
    /// Maximum shared memory per block
    max_shared_memory: u32 = 49152,
    /// Warp size (always 32 for NVIDIA)
    warp_size: u32 = 32,
    /// Clock rate in KHz
    clock_rate_khz: u32 = 0,
    /// Memory clock rate in KHz
    memory_clock_khz: u32 = 0,
    /// Memory bus width in bits
    memory_bus_width: u32 = 0,
    /// L2 cache size in bytes
    l2_cache_size: u32 = 0,
    /// Whether ECC is enabled
    ecc_enabled: bool = false,
    /// Whether device is integrated (shared memory with host)
    integrated: bool = false,
    /// Whether device supports concurrent kernels
    concurrent_kernels: bool = false,
    /// Whether device supports unified addressing
    unified_addressing: bool = false,
    /// Whether device is available for use
    available: bool = false,

    /// Get device name as a slice
    pub fn getName(self: *const DeviceInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Get architecture name (e.g., "Blackwell", "Ampere")
    pub fn getArchName(self: *const DeviceInfo) []const u8 {
        return self.arch.name();
    }

    /// Check if device meets minimum requirements
    pub fn meetsRequirements(self: *const DeviceInfo, min_arch: ComputeArch, min_memory_mb: usize) bool {
        const mem_mb = self.total_memory / (1024 * 1024);
        return self.available and
            self.arch.major >= min_arch.major and
            mem_mb >= min_memory_mb;
    }

    /// Compute theoretical memory bandwidth in GB/s
    pub fn theoreticalBandwidthGBps(self: *const DeviceInfo) f64 {
        // bandwidth = 2 * memory_clock * bus_width / 8 (bits to bytes)
        // Convert to f64 first to avoid u32 overflow on modern GPUs
        const mem_clock_hz: f64 = @as(f64, @floatFromInt(self.memory_clock_khz)) * 1000.0;
        const bus_bits: f64 = @floatFromInt(self.memory_bus_width);
        return 2.0 * mem_clock_hz * bus_bits / 8.0 / 1e9;
    }
};

// ============================================================================
// Probe Result
// ============================================================================

/// Result of probing the system for CUDA support
pub const ProbeResult = struct {
    /// Whether CUDA is available on this system
    available: bool = false,
    /// CUDA driver version (major * 1000 + minor * 10)
    driver_version: i32 = 0,
    /// Human-readable driver version string
    driver_version_string: [32]u8 = [_]u8{0} ** 32,
    /// Number of CUDA-capable devices found
    device_count: usize = 0,
    /// Device information array (heap allocated)
    devices: []DeviceInfo = &[_]DeviceInfo{},
    /// Reason CUDA is unavailable (if applicable)
    unavailable_reason: UnavailableReason = .none,
    /// Detailed error message
    error_message: [256]u8 = [_]u8{0} ** 256,
    error_message_len: usize = 0,
    /// Probe diagnostics
    diagnostics: ProbeDiagnostics = .{},

    /// Clean up allocated resources
    pub fn deinit(self: *ProbeResult, allocator: std.mem.Allocator) void {
        if (self.devices.len > 0) {
            allocator.free(self.devices);
            self.devices = &[_]DeviceInfo{};
        }
    }

    /// Get error message as a slice
    pub fn getErrorMessage(self: *const ProbeResult) []const u8 {
        return self.error_message[0..self.error_message_len];
    }

    /// Get driver version as string (e.g., "12.3")
    pub fn getDriverVersionString(self: *const ProbeResult) []const u8 {
        const major = @divTrunc(self.driver_version, 1000);
        const minor = @divTrunc(@mod(self.driver_version, 1000), 10);
        var buf = self.driver_version_string;
        const len = std.fmt.bufPrint(&buf, "{}.{}", .{ major, minor }) catch return "?.?";
        return buf[0..len.len];
    }

    /// Get the best available device (highest compute capability)
    pub fn getBestDevice(self: *const ProbeResult) ?*const DeviceInfo {
        if (self.devices.len == 0) return null;

        var best: ?*const DeviceInfo = null;
        var best_score: u32 = 0;

        for (self.devices) |*dev| {
            if (!dev.available) continue;
            const score = dev.arch.major * 100 + dev.arch.minor * 10 + @as(u32, @intCast(dev.sm_count));
            if (score > best_score) {
                best_score = score;
                best = dev;
            }
        }
        return best;
    }

    /// Get device by index
    pub fn getDevice(self: *const ProbeResult, index: usize) ?*const DeviceInfo {
        if (index >= self.devices.len) return null;
        return &self.devices[index];
    }

    /// Find devices matching criteria
    pub fn findDevices(
        self: *const ProbeResult,
        allocator: std.mem.Allocator,
        min_arch: ?ComputeArch,
        min_memory_mb: ?usize,
    ) ![]const *const DeviceInfo {
        var matches: std.ArrayList(*const DeviceInfo) = .{};
        errdefer matches.deinit(allocator);

        for (self.devices) |*dev| {
            if (!dev.available) continue;

            if (min_arch) |arch| {
                if (dev.arch.major < arch.major) continue;
                if (dev.arch.major == arch.major and dev.arch.minor < arch.minor) continue;
            }

            if (min_memory_mb) |mem| {
                const dev_mem_mb = dev.total_memory / (1024 * 1024);
                if (dev_mem_mb < mem) continue;
            }

            try matches.append(allocator, dev);
        }

        return try matches.toOwnedSlice(allocator);
    }
};

/// Reason CUDA is unavailable
pub const UnavailableReason = enum {
    none,
    /// Platform not supported (non-Linux)
    platform_not_supported,
    /// CUDA driver library not found
    driver_not_found,
    /// Driver initialization failed
    driver_init_failed,
    /// No CUDA devices found
    no_devices,
    /// All devices are busy/unavailable
    devices_busy,
    /// Insufficient driver version
    driver_too_old,
    /// NVIDIA kernel module not loaded
    kernel_module_not_loaded,
    /// Unknown error
    unknown,
};

/// Detailed probe diagnostics
pub const ProbeDiagnostics = struct {
    /// Whether we're on a supported platform
    platform_supported: bool = false,
    /// Whether libcuda.so was found
    library_found: bool = false,
    /// Whether driver initialization succeeded
    driver_initialized: bool = false,
    /// Whether devices were enumerated
    devices_enumerated: bool = false,
    /// Whether NVIDIA kernel module appears loaded (Linux only)
    kernel_module_detected: bool = false,
    /// Time taken to probe in microseconds
    probe_time_us: u64 = 0,
};

// ============================================================================
// Probing Functions
// ============================================================================

/// Probe the system for CUDA availability
///
/// This function never panics and always returns a result. If CUDA is not
/// available, the result will indicate why.
pub fn probe(allocator: std.mem.Allocator) !ProbeResult {
    const start_time = std.time.microTimestamp();
    var result = ProbeResult{};

    // Check platform
    if (builtin.os.tag != .linux) {
        result.unavailable_reason = .platform_not_supported;
        setErrorMessage(&result, "CUDA is only supported on Linux");
        result.diagnostics.probe_time_us = @intCast(std.time.microTimestamp() - start_time);
        return result;
    }
    result.diagnostics.platform_supported = true;

    // Check for NVIDIA kernel module (best effort)
    result.diagnostics.kernel_module_detected = checkKernelModule();

    // Get global driver
    const drv = driver.getDriver();
    if (!drv.available()) {
        result.unavailable_reason = .driver_not_found;
        setErrorMessage(&result, "libcuda.so not found or failed to load");
        result.diagnostics.probe_time_us = @intCast(std.time.microTimestamp() - start_time);
        return result;
    }
    result.diagnostics.library_found = true;

    // Initialize driver
    if (drv.cuInit(0) != types.CUDA_SUCCESS) {
        result.unavailable_reason = .driver_init_failed;
        setErrorMessage(&result, "cuInit() failed");
        result.diagnostics.probe_time_us = @intCast(std.time.microTimestamp() - start_time);
        return result;
    }
    result.diagnostics.driver_initialized = true;

    // Get driver version
    _ = drv.cuDriverGetVersion(&result.driver_version);

    // Get device count
    var device_count: i32 = 0;
    if (drv.cuDeviceGetCount(&device_count) != types.CUDA_SUCCESS or device_count <= 0) {
        result.unavailable_reason = .no_devices;
        setErrorMessage(&result, "No CUDA devices found");
        result.diagnostics.probe_time_us = @intCast(std.time.microTimestamp() - start_time);
        return result;
    }
    result.diagnostics.devices_enumerated = true;

    // Enumerate devices
    result.devices = try allocator.alloc(DeviceInfo, @intCast(device_count));
    errdefer allocator.free(result.devices);

    var available_count: usize = 0;
    for (0..@intCast(device_count)) |i| {
        const idx: i32 = @intCast(i);
        var dev_info = DeviceInfo{ .id = @intCast(i) };

        var cuda_dev: driver.CUdevice = 0;
        if (drv.cuDeviceGet(&cuda_dev, idx) != types.CUDA_SUCCESS) {
            result.devices[i] = dev_info;
            continue;
        }

        // Get device name
        if (drv.cuDeviceGetName(&dev_info.name, 256, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.name_len = std.mem.indexOfScalar(u8, &dev_info.name, 0) orelse 256;
        }

        // Get memory
        _ = drv.cuDeviceTotalMem(&dev_info.total_memory, cuda_dev);

        // Get compute capability
        if (drv.getDeviceArch(cuda_dev)) |arch| {
            dev_info.arch = arch;
        }

        // Get device attributes
        var attr_val: i32 = 0;

        if (drv.cuDeviceGetAttribute(&attr_val, .multiprocessor_count, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.sm_count = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .max_threads_per_block, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.max_threads_per_block = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .max_shared_memory_per_block, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.max_shared_memory = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .warp_size, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.warp_size = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .clock_rate, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.clock_rate_khz = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .memory_clock_rate, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.memory_clock_khz = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .global_memory_bus_width, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.memory_bus_width = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .l2_cache_size, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.l2_cache_size = @intCast(attr_val);
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .ecc_enabled, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.ecc_enabled = attr_val != 0;
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .integrated, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.integrated = attr_val != 0;
        }

        if (drv.cuDeviceGetAttribute(&attr_val, .concurrent_kernels, cuda_dev) == types.CUDA_SUCCESS) {
            dev_info.concurrent_kernels = attr_val != 0;
        }

        dev_info.available = true;
        available_count += 1;
        result.devices[i] = dev_info;
    }

    result.device_count = available_count;
    result.available = available_count > 0;

    if (!result.available) {
        result.unavailable_reason = .devices_busy;
        setErrorMessage(&result, "All CUDA devices are busy or unavailable");
    }

    result.diagnostics.probe_time_us = @intCast(std.time.microTimestamp() - start_time);
    return result;
}

/// Quick check if CUDA is available (faster than full probe)
pub fn isAvailable() bool {
    if (builtin.os.tag != .linux) return false;

    const drv = driver.getDriver();
    if (!drv.available()) return false;
    if (drv.cuInit(0) != types.CUDA_SUCCESS) return false;

    var count: i32 = 0;
    if (drv.cuDeviceGetCount(&count) != types.CUDA_SUCCESS) return false;

    return count > 0;
}

/// Get device count without full enumeration
pub fn getDeviceCount() usize {
    if (!isAvailable()) return 0;

    const drv = driver.getDriver();
    var count: i32 = 0;
    if (drv.cuDeviceGetCount(&count) != types.CUDA_SUCCESS) return 0;
    return @intCast(count);
}

// ============================================================================
// Helper Functions
// ============================================================================

fn setErrorMessage(result: *ProbeResult, msg: []const u8) void {
    const len = @min(msg.len, result.error_message.len);
    @memcpy(result.error_message[0..len], msg[0..len]);
    result.error_message_len = len;
}

fn checkKernelModule() bool {
    // Linux: Check /proc/modules for nvidia module
    if (builtin.os.tag == .linux) {
        const file = std.fs.openFileAbsolute("/proc/modules", .{}) catch return false;
        defer file.close();

        var buf: [8192]u8 = undefined;
        const bytes_read = file.read(&buf) catch return false;

        return std.mem.indexOf(u8, buf[0..bytes_read], "nvidia") != null;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "probe returns result without panicking" {
    const result = try probe(std.testing.allocator);
    defer @constCast(&result).deinit(std.testing.allocator);

    // Result should always be valid
    if (result.available) {
        try std.testing.expect(result.device_count > 0);
        try std.testing.expect(result.devices.len > 0);
    } else {
        try std.testing.expect(result.unavailable_reason != .none);
    }
}

test "isAvailable does not panic" {
    _ = isAvailable();
}

test "getDeviceCount does not panic" {
    _ = getDeviceCount();
}

test "DeviceInfo methods" {
    var info = DeviceInfo{
        .id = 0,
        .total_memory = 16 * 1024 * 1024 * 1024, // 16 GB
        .arch = Architectures.blackwell,
        .sm_count = 128,
        .memory_clock_khz = 10000000, // 10 GHz effective
        .memory_bus_width = 384,
        .available = true,
    };
    @memcpy(info.name[0..15], "Test GPU Device");
    info.name_len = 15;

    try std.testing.expectEqualStrings("Test GPU Device", info.getName());
    try std.testing.expectEqualStrings("Blackwell", info.getArchName());
    try std.testing.expect(info.meetsRequirements(Architectures.ampere, 8 * 1024));
    try std.testing.expect(!info.meetsRequirements(Architectures.blackwell, 32 * 1024));
}

test "ProbeResult best device selection" {
    const allocator = std.testing.allocator;

    var devices = try allocator.alloc(DeviceInfo, 3);
    defer allocator.free(devices);

    devices[0] = DeviceInfo{ .id = 0, .arch = Architectures.ampere, .sm_count = 68, .available = true };
    devices[1] = DeviceInfo{ .id = 1, .arch = Architectures.blackwell, .sm_count = 128, .available = true };
    devices[2] = DeviceInfo{ .id = 2, .arch = Architectures.turing, .sm_count = 48, .available = false };

    var result = ProbeResult{
        .available = true,
        .device_count = 2,
        .devices = devices,
    };

    const best = result.getBestDevice();
    try std.testing.expect(best != null);
    try std.testing.expectEqual(@as(u32, 1), best.?.id);

    // Note: We don't call deinit here because we manage devices ourselves in this test
    result.devices = &[_]DeviceInfo{};
}

test "theoreticalBandwidthGBps with high memory clock (overflow check)" {
    // RTX 4060 Ti has memory_clock_khz around 9,001,000
    // This would overflow u32 if multiplied by 1000 before converting to f64
    const info = DeviceInfo{
        .id = 0,
        .memory_clock_khz = 9001000, // ~9 GHz effective
        .memory_bus_width = 128,
        .available = true,
    };

    const bw = info.theoreticalBandwidthGBps();
    // Should be approximately 2 * 9001000 * 1000 * 128 / 8 / 1e9 = 288 GB/s
    try std.testing.expect(bw > 200.0);
    try std.testing.expect(bw < 400.0);
}

test "theoreticalBandwidthGBps with very high memory clock" {
    // Test with even higher clocks that would definitely overflow u32
    const info = DeviceInfo{
        .id = 0,
        .memory_clock_khz = 12000000, // 12 GHz - would be 12 billion in Hz
        .memory_bus_width = 384,
        .available = true,
    };

    const bw = info.theoreticalBandwidthGBps();
    // Should be approximately 2 * 12000000 * 1000 * 384 / 8 / 1e9 = 1152 GB/s
    try std.testing.expect(bw > 1000.0);
    try std.testing.expect(bw < 1500.0);
}

test "theoreticalBandwidthGBps with zero values" {
    const info = DeviceInfo{
        .id = 0,
        .memory_clock_khz = 0,
        .memory_bus_width = 0,
        .available = true,
    };

    const bw = info.theoreticalBandwidthGBps();
    try std.testing.expectEqual(@as(f64, 0.0), bw);
}

test "DeviceInfo meetsRequirements edge cases" {
    const info = DeviceInfo{
        .id = 0,
        .total_memory = 8 * 1024 * 1024 * 1024, // 8 GB
        .arch = Architectures.ampere,
        .available = true,
    };

    // Exact match should pass
    try std.testing.expect(info.meetsRequirements(Architectures.ampere, 8 * 1024));

    // Lower requirements should pass
    try std.testing.expect(info.meetsRequirements(Architectures.volta, 4 * 1024));

    // Higher arch requirement should fail
    try std.testing.expect(!info.meetsRequirements(Architectures.blackwell, 4 * 1024));

    // Higher memory requirement should fail
    try std.testing.expect(!info.meetsRequirements(Architectures.kepler, 16 * 1024));

    // Unavailable device should always fail
    var unavail = info;
    unavail.available = false;
    try std.testing.expect(!unavail.meetsRequirements(Architectures.kepler, 1024));
}

test "DeviceInfo getName with various lengths" {
    var info = DeviceInfo{ .id = 0 };

    // Empty name
    info.name_len = 0;
    try std.testing.expectEqualStrings("", info.getName());

    // Full length name
    @memset(&info.name, 'X');
    info.name_len = 256;
    try std.testing.expectEqual(@as(usize, 256), info.getName().len);

    // Partial name
    info.name_len = 10;
    try std.testing.expectEqual(@as(usize, 10), info.getName().len);
}

test "ProbeResult getDevice bounds checking" {
    const allocator = std.testing.allocator;

    var devices = try allocator.alloc(DeviceInfo, 2);
    defer allocator.free(devices);

    devices[0] = DeviceInfo{ .id = 0, .available = true };
    devices[1] = DeviceInfo{ .id = 1, .available = true };

    var result = ProbeResult{
        .available = true,
        .device_count = 2,
        .devices = devices,
    };

    // Valid indices
    try std.testing.expect(result.getDevice(0) != null);
    try std.testing.expect(result.getDevice(1) != null);

    // Invalid indices
    try std.testing.expect(result.getDevice(2) == null);
    try std.testing.expect(result.getDevice(100) == null);

    result.devices = &[_]DeviceInfo{};
}

test "ProbeResult getBestDevice with no available devices" {
    const allocator = std.testing.allocator;

    var devices = try allocator.alloc(DeviceInfo, 2);
    defer allocator.free(devices);

    devices[0] = DeviceInfo{ .id = 0, .available = false };
    devices[1] = DeviceInfo{ .id = 1, .available = false };

    var result = ProbeResult{
        .available = false,
        .device_count = 0,
        .devices = devices,
    };

    try std.testing.expect(result.getBestDevice() == null);

    result.devices = &[_]DeviceInfo{};
}

test "ProbeResult getBestDevice with empty devices" {
    const result = ProbeResult{
        .available = false,
        .device_count = 0,
        .devices = &[_]DeviceInfo{},
    };

    try std.testing.expect(result.getBestDevice() == null);
}

test "ProbeResult findDevices filtering" {
    const allocator = std.testing.allocator;

    var devices = try allocator.alloc(DeviceInfo, 4);
    defer allocator.free(devices);

    devices[0] = DeviceInfo{ .id = 0, .arch = Architectures.kepler, .total_memory = 2 * 1024 * 1024 * 1024, .available = true };
    devices[1] = DeviceInfo{ .id = 1, .arch = Architectures.ampere, .total_memory = 8 * 1024 * 1024 * 1024, .available = true };
    devices[2] = DeviceInfo{ .id = 2, .arch = Architectures.blackwell, .total_memory = 16 * 1024 * 1024 * 1024, .available = true };
    devices[3] = DeviceInfo{ .id = 3, .arch = Architectures.blackwell, .total_memory = 32 * 1024 * 1024 * 1024, .available = false };

    var result = ProbeResult{
        .available = true,
        .device_count = 3,
        .devices = devices,
    };

    // Filter by arch only
    const ampere_plus = try result.findDevices(allocator, Architectures.ampere, null);
    defer allocator.free(ampere_plus);
    try std.testing.expectEqual(@as(usize, 2), ampere_plus.len);

    // Filter by memory only
    const big_mem = try result.findDevices(allocator, null, 8 * 1024);
    defer allocator.free(big_mem);
    try std.testing.expectEqual(@as(usize, 2), big_mem.len);

    // Filter by both
    const filtered = try result.findDevices(allocator, Architectures.blackwell, 10 * 1024);
    defer allocator.free(filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);

    // No matches
    const none = try result.findDevices(allocator, Architectures.blackwell, 64 * 1024);
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    result.devices = &[_]DeviceInfo{};
}

test "ProbeResult error message handling" {
    var result = ProbeResult{};

    // Test with empty message
    try std.testing.expectEqualStrings("", result.getErrorMessage());

    // Set a message via the helper
    setErrorMessage(&result, "Test error");
    try std.testing.expectEqualStrings("Test error", result.getErrorMessage());

    // Test truncation
    var long_msg: [512]u8 = undefined;
    @memset(&long_msg, 'X');
    setErrorMessage(&result, &long_msg);
    try std.testing.expectEqual(@as(usize, 256), result.getErrorMessage().len);
}
