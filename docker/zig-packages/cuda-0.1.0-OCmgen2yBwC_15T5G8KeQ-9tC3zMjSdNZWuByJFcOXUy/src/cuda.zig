// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Compute Library for Zig
//!
//! A comprehensive, production-ready CUDA library for Zig applications.
//! Provides GPU compute capabilities with graceful degradation when
//! CUDA is unavailable.
//!
//! ## Features
//! - Dynamic CUDA driver loading (no compile-time NVIDIA SDK required)
//! - Graceful degradation when CUDA is unavailable
//! - Support for all NVIDIA architectures including Blackwell
//! - High-level Context API aligned with Vulkan sibling library
//! - Memory management with pooling
//! - Stream and event management
//! - PTX module loading and JIT compilation via NVRTC
//! - Performance profiling and benchmarking
//!
//! ## Quick Start
//! ```zig
//! const cuda = @import("cuda");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Probe for CUDA availability
//!     var result = try cuda.probe(allocator);
//!     defer result.deinit(allocator);
//!
//!     if (!result.available) {
//!         std.debug.print("CUDA unavailable: {s}\n", .{result.getErrorMessage()});
//!         return;
//!     }
//!
//!     // Create context
//!     var ctx = try cuda.Context.init(allocator, .{});
//!     defer ctx.deinit();
//!
//!     // Create buffer and transfer data
//!     const buffer = try ctx.createBuffer(1024, .device);
//!     defer ctx.destroyBuffer(buffer);
//!
//!     var data: [256]u32 = undefined;
//!     for (&data, 0..) |*v, i| v.* = @intCast(i);
//!
//!     try ctx.memcpyH2D(buffer, std.mem.sliceAsBytes(&data));
//!
//!     // Load and run kernel
//!     const module = try ctx.createModulePtx(my_ptx);
//!     defer ctx.destroyModule(module);
//!
//!     const kernel = try ctx.getKernel(module, "my_kernel");
//!     try ctx.launchSync(kernel, .{ .grid = .{1, 1, 1}, .block = .{256, 1, 1} }, null);
//! }
//! ```
//!
//! ## Architecture
//! The library is organized into these modules:
//! - **context**: High-level compute API (aligned with Vulkan library)
//! - **driver**: Low-level CUDA driver API wrappers
//! - **probe**: Device detection and availability checking
//! - **memory**: GPU memory management with pooling
//! - **stream**: CUDA streams and events
//! - **module**: PTX/CUBIN loading and kernel management
//! - **profiler**: Performance profiling and benchmarking
//! - **types**: Common types, constants, and errors

const std = @import("std");

// ============================================================================
// Core Modules
// ============================================================================

/// High-level CUDA compute context
pub const context = @import("cuda/context.zig");

/// Low-level CUDA driver API
pub const driver = @import("cuda/driver.zig");

/// Device probing and detection
pub const probe_mod = @import("cuda/probe.zig");

/// Memory management
pub const memory = @import("cuda/memory.zig");

/// Stream and event management
pub const stream = @import("cuda/stream.zig");

/// Module and kernel management
pub const module = @import("cuda/module.zig");

/// Multi-GPU and device management
pub const device = @import("cuda/device.zig");

/// Profiling and benchmarking
pub const profiler = @import("cuda/profiler.zig");

/// Types and constants
pub const types = @import("cuda/types.zig");

// ============================================================================
// Primary API Types (re-exported for convenience)
// ============================================================================

/// CUDA compute context - main entry point
pub const Context = context.Context;

/// Context creation options
pub const ContextOptions = context.ContextOptions;

/// GPU device information
pub const DeviceInfo = probe_mod.DeviceInfo;

/// Result of probing for CUDA availability
pub const ProbeResult = probe_mod.ProbeResult;

/// GPU memory buffer
pub const Buffer = memory.Buffer;

/// Unified memory buffer
pub const UnifiedBuffer = memory.UnifiedBuffer;

/// Memory allocation type
pub const MemoryKind = memory.MemoryKind;

/// Memory usage statistics
pub const MemoryStats = memory.MemoryStats;

/// Memory pool statistics
pub const PoolStats = memory.PoolStats;

/// Async transfer batch (#11)
pub const TransferBatch = memory.TransferBatch;

/// Transfer operation type
pub const TransferOp = memory.TransferOp;

/// CUDA stream
pub const Stream = stream.Stream;

/// CUDA event
pub const Event = stream.Event;

/// Event-based timer
pub const EventTimer = stream.EventTimer;

/// Stream priority levels
pub const StreamPriority = stream.StreamPriority;

/// Stream pool
pub const StreamPool = stream.StreamPool;

/// CUDA module (contains kernels)
pub const Module = module.Module;

/// CUDA kernel function
pub const Kernel = module.Kernel;

/// Occupancy calculation result
pub const OccupancyResult = module.OccupancyResult;

/// NVRTC compiler options (#15)
pub const NvrtcOptions = module.NvrtcOptions;

/// NVRTC compiler
pub const NvrtcCompiler = module.NvrtcCompiler;

/// Device representation for multi-GPU
pub const Device = device.Device;

/// List of available devices
pub const DeviceList = device.DeviceList;

/// Context scope for RAII-style context switching (#17)
pub const ContextScope = device.ContextScope;

/// Kernel launch configuration
pub const LaunchConfig = types.LaunchConfig;

/// GPU compute architecture
pub const ComputeArch = types.ComputeArch;

/// Known GPU architectures
pub const Architectures = types.Architectures;

/// CUDA-specific errors
pub const CudaError = types.CudaError;

/// Memory alignment constants and utilities (#28)
pub const MemoryAlignment = types.MemoryAlignment;

/// Validate buffer size with alignment
pub const validateBufferSize = types.validateBufferSize;

/// Platform type for cross-platform support (#24)
pub const Platform = driver.Platform;

/// Get current platform
pub const getPlatform = driver.getPlatform;

/// Check if platform is supported
pub const isPlatformSupported = driver.isPlatformSupported;

/// Driver version information (#26)
pub const DriverVersion = driver.CudaDriver.DriverVersion;

/// Minimum CUDA versions for features
pub const MinVersions = driver.CudaDriver.MinVersions;

/// Performance profile data
pub const PerformanceProfile = profiler.PerformanceProfile;

/// Profile timer
pub const ProfileTimer = profiler.ProfileTimer;

/// Benchmark result
pub const BenchmarkResult = profiler.BenchmarkResult;

/// GPU event-based profiler (#14)
pub const EventProfiler = profiler.EventProfiler;

/// Scoped profiler for automatic region timing
pub const ScopedProfiler = profiler.ScopedProfiler;

// ============================================================================
// Primary API Functions
// ============================================================================

/// Probe the system for CUDA availability
///
/// This is the recommended first step before using any CUDA functionality.
/// It returns detailed information about available devices and any errors.
/// This function never panics.
///
/// Example:
/// ```zig
/// var result = try cuda.probe(allocator);
/// defer result.deinit(allocator);
///
/// if (result.available) {
///     for (result.devices) |dev| {
///         std.debug.print("Found GPU: {s} ({s})\n", .{
///             dev.getName(), dev.getArchName()
///         });
///     }
/// }
/// ```
pub fn probe(allocator: std.mem.Allocator) !ProbeResult {
    return probe_mod.probe(allocator);
}

/// Quick check if CUDA is available (faster than full probe)
///
/// Use this for fast availability checks when you don't need
/// detailed device information.
pub fn isAvailable() bool {
    return probe_mod.isAvailable();
}

/// Get the number of CUDA devices (0 if unavailable)
pub fn getDeviceCount() usize {
    return probe_mod.getDeviceCount();
}

/// Get the global CUDA driver instance
///
/// Most users should use the Context API instead. This is for
/// advanced use cases requiring direct driver access.
pub fn getDriver() *const driver.CudaDriver {
    return driver.getDriver();
}

/// Run a benchmark
pub fn benchmark(
    name: []const u8,
    iterations: usize,
    data_size: usize,
    func: *const fn () void,
) BenchmarkResult {
    return profiler.benchmark(name, iterations, data_size, func);
}

// ============================================================================
// Kernel Argument Helpers
// ============================================================================

/// Create a kernel argument array builder
pub fn KernelArgs(comptime max_args: usize) type {
    return module.KernelArgs(max_args);
}

/// Create type-safe kernel arguments (#16)
pub fn TypedKernelArgs(comptime T: type) type {
    return module.TypedKernelArgs(T);
}

/// Build kernel arguments from a tuple of pointers
pub const kernelParams = module.kernelParams;

// ============================================================================
// Context Switching Helpers (#17)
// ============================================================================

/// Get the current CUDA context
pub const getCurrentContext = device.getCurrentContext;

/// Push a context onto the stack
pub const pushContext = device.pushContext;

/// Pop a context from the stack
pub const popContext = device.popContext;

// ============================================================================
// Version and Build Info
// ============================================================================

/// Library version
pub const version = struct {
    pub const major = 0;
    pub const minor = 1;
    pub const patch = 0;
    pub const string = "0.1.0";
};

/// Minimum supported CUDA driver version
pub const min_driver_version = 11000; // CUDA 11.0

/// Build configuration
pub const build = struct {
    /// Whether runtime API support is enabled (feature flag)
    pub const has_runtime_api = false;
    /// Whether NVRTC support is available
    pub const has_nvrtc = true;
};

// ============================================================================
// Tests
// ============================================================================

test "library version" {
    try std.testing.expectEqualStrings("0.1.0", version.string);
    try std.testing.expectEqual(@as(u32, 0), version.major);
}

test "probe does not panic" {
    var result = probe(std.testing.allocator) catch |err| {
        // Allocation error is acceptable
        try std.testing.expect(err == error.OutOfMemory);
        return;
    };
    defer result.deinit(std.testing.allocator);

    // Result should always be valid
    if (result.available) {
        try std.testing.expect(result.device_count > 0);
    }
}

test "isAvailable does not panic" {
    _ = isAvailable();
}

test "getDeviceCount does not panic" {
    _ = getDeviceCount();
}

test "Context graceful failure without GPU" {
    const result = Context.init(std.testing.allocator, .{});
    if (result) |*ctx| {
        var mutable = ctx.*;
        defer mutable.deinit();
    } else |err| {
        // Expected errors
        try std.testing.expect(
            err == CudaError.DriverNotFound or
                err == CudaError.InitFailed or
                err == CudaError.NoDevice,
        );
    }
}

// Reference all modules to ensure they compile
test {
    std.testing.refAllDecls(@This());
}
