# CUDA Zig Library API Reference

This document provides comprehensive API documentation for the CUDA Zig library.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Core Types](#core-types)
- [Device Management](#device-management)
- [Memory Management](#memory-management)
- [Streams and Events](#streams-and-events)
- [Modules and Kernels](#modules-and-kernels)
- [Profiling](#profiling)
- [Error Handling](#error-handling)

---

## Overview

The CUDA Zig library provides a safe, idiomatic Zig interface to NVIDIA CUDA. Key features:

- **Dynamic Loading**: No compile-time CUDA SDK dependency
- **Graceful Degradation**: Works when CUDA is unavailable
- **Memory Safety**: Pooled allocations, RAII patterns
- **Multi-GPU**: Full support for multi-device systems
- **Type Safety**: Compile-time validated kernel arguments

### Import

```zig
const cuda = @import("cuda");
```

---

## Quick Start

```zig
const std = @import("std");
const cuda = @import("cuda");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check CUDA availability
    if (!cuda.isAvailable()) {
        std.debug.print("CUDA not available\n", .{});
        return;
    }

    // Create context
    var ctx = try cuda.Context.init(allocator, .{});
    defer ctx.deinit();

    // Allocate device memory
    const buffer = try ctx.memory.allocDevice(1024);
    defer ctx.memory.freeDevice(buffer);

    std.debug.print("CUDA initialized with {} bytes allocated\n", .{buffer.size});
}
```

---

## Core Types

### `cuda.Context`

The main entry point for CUDA operations. Manages device, memory, streams, and modules.

```zig
pub const Context = struct {
    // Initialize with options
    pub fn init(allocator: Allocator, options: ContextOptions) !Context;

    // Clean up all resources
    pub fn deinit(self: *Context) void;

    // Access sub-systems
    memory: *Memory,
    stream: *StreamManager,
    // ...
};
```

#### `ContextOptions`

```zig
pub const ContextOptions = struct {
    /// Device ordinal (0 = first GPU)
    device: u32 = 0,
    /// Context creation flags
    flags: u32 = 0,
    /// Enable memory pooling
    enable_pooling: bool = true,
};
```

### `cuda.CudaError`

Error type for all CUDA operations.

```zig
pub const CudaError = error{
    DriverNotFound,      // CUDA driver not installed
    InitFailed,          // Driver initialization failed
    NoDevice,            // No CUDA-capable device
    InvalidDevice,       // Invalid device ordinal
    OutOfMemory,         // GPU memory allocation failed
    InvalidArgument,     // Invalid parameter
    NotSupported,        // Feature not supported
    ContextError,        // Context operation failed
    ContextCreateFailed, // Failed to create context
    ModuleLoadFailed,    // Failed to load PTX/CUBIN
    FunctionNotFound,    // Kernel function not found
    LaunchFailed,        // Kernel launch failed
    SyncFailed,          // Synchronization failed
    CopyFailed,          // Memory copy failed
    CompilationFailed,   // NVRTC compilation failed
    NvrtcNotFound,       // NVRTC library not found
    GpuError,            // Generic GPU error
};
```

### `cuda.LaunchConfig`

Kernel launch configuration.

```zig
pub const LaunchConfig = struct {
    /// Grid dimensions (blocks)
    grid: [3]u32 = .{ 1, 1, 1 },
    /// Block dimensions (threads per block)
    block: [3]u32 = .{ 1, 1, 1 },
    /// Dynamic shared memory size
    shared_mem: u32 = 0,
    /// Stream to launch on (null = default stream)
    stream: ?CUstream = null,

    /// Create config for 1D kernel
    pub fn for1D(num_elements: u32, block_size: u32) LaunchConfig;

    /// Create config for 2D kernel
    pub fn for2D(width: u32, height: u32, block_x: u32, block_y: u32) LaunchConfig;

    /// Calculate total threads
    pub fn totalThreads(self: LaunchConfig) u64;

    /// Validate configuration
    pub fn validate(self: LaunchConfig) !void;

    /// Validate with device limits
    pub fn validateWithLimits(self: LaunchConfig, limits: DeviceLimits) !void;
};
```

### `cuda.ComputeArch`

GPU compute capability.

```zig
pub const ComputeArch = struct {
    major: u32,
    minor: u32,

    /// Get architecture name (e.g., "Ampere", "Hopper")
    pub fn name(self: ComputeArch) []const u8;

    /// Get compute string (e.g., "sm_86")
    pub fn computeString(self: ComputeArch) []const u8;

    /// Check if architecture supports feature
    pub fn supports(self: ComputeArch, feature: Feature) bool;
};
```

---

## Device Management

### `cuda.Device`

Represents a CUDA-capable GPU.

```zig
pub const Device = struct {
    ordinal: i32,           // Device index
    handle: CUdevice,       // CUDA handle
    total_memory: usize,    // Total memory in bytes
    compute_major: u32,     // Compute capability major
    compute_minor: u32,     // Compute capability minor
    context: ?CUcontext,    // Associated context

    /// Get device name
    pub fn getName(self: *const Device) []const u8;

    /// Get compute architecture
    pub fn getArch(self: *const Device) ComputeArch;

    /// Get total memory in GB
    pub fn getTotalMemoryGB(self: *const Device) f64;

    /// Create a context for this device
    pub fn createContext(self: *Device, flags: u32) !void;

    /// Destroy this device's context
    pub fn destroyContext(self: *Device) void;

    /// Make this device's context current
    pub fn makeCurrent(self: *const Device) !void;

    /// Check if peer access to another device is possible
    pub fn canAccessPeer(self: *const Device, peer: *const Device) !bool;

    /// Enable peer access to another device
    pub fn enablePeerAccess(self: *Device, peer: *Device) !void;

    /// Get device attribute
    pub fn getAttribute(self: *const Device, attr: CUdevice_attribute) !i32;

    /// Get multiprocessor count
    pub fn getMultiprocessorCount(self: *const Device) !i32;

    /// Get warp size
    pub fn getWarpSize(self: *const Device) !i32;

    /// Get max threads per block
    pub fn getMaxThreadsPerBlock(self: *const Device) !i32;

    /// Check unified memory support
    pub fn supportsUnifiedMemory(self: *const Device) bool;

    // Context switching (#17)
    pub fn pushContext(self: *const Device) !void;
    pub fn popContext(self: *const Device) !?CUcontext;
    pub fn supportsContextStack(self: *const Device) bool;
};
```

### `cuda.DeviceList`

Collection of available devices.

```zig
pub const DeviceList = struct {
    items: []Device,

    /// Get device count
    pub fn count(self: *const DeviceList) usize;

    /// Get device by index
    pub fn get(self: *DeviceList, index: usize) ?*Device;

    /// Create contexts for all devices
    pub fn createAllContexts(self: *DeviceList, flags: u32) !void;

    /// Enable peer access between all capable devices
    pub fn enableAllPeerAccess(self: *DeviceList) !void;

    /// Clean up
    pub fn deinit(self: *DeviceList) void;
};
```

### Device Functions

```zig
/// Enumerate all CUDA devices
pub fn enumerate(drv: *const CudaDriver, allocator: Allocator) !DeviceList;

/// Get current device ordinal
pub fn getCurrentDevice(drv: *const CudaDriver) !i32;

/// Get total device count
pub fn getDeviceCount(drv: *const CudaDriver) !i32;

/// Check peer access support
pub fn supportsPeerAccess(drv: *const CudaDriver) bool;
```

### `cuda.ContextScope`

RAII-style context management.

```zig
pub const ContextScope = struct {
    /// Create scope, pushing device's context
    pub fn init(device: *const Device) !ContextScope;

    /// Create from raw context
    pub fn initFromContext(drv: *const CudaDriver, ctx: CUcontext) !ContextScope;

    /// Restore previous context (call in defer)
    pub fn deinit(self: *ContextScope) void;

    /// Manually end scope early
    pub fn end(self: *ContextScope) !void;
};
```

**Usage:**
```zig
var scope = try cuda.ContextScope.init(&gpu1);
defer scope.deinit();
// All operations here use gpu1's context
```

---

## Memory Management

### `cuda.Buffer`

GPU memory buffer.

```zig
pub const Buffer = struct {
    ptr: CUdeviceptr,       // Device pointer
    size: usize,            // Size in bytes
    kind: MemoryKind,       // Memory type
    allocated: bool,        // Allocation status
    alignment: usize,       // Alignment (default 256)

    /// Check if buffer is valid
    pub fn isValid(self: Buffer) bool;

    /// Get as typed pointer (for kernel params)
    pub fn asPtr(self: Buffer, comptime T: type) [*]T;
};
```

### `cuda.UnifiedBuffer`

Unified memory accessible from CPU and GPU.

```zig
pub const UnifiedBuffer = struct {
    ptr: CUdeviceptr,
    size: usize,

    /// Get as host pointer for CPU access
    pub fn asHostPtr(self: UnifiedBuffer, comptime T: type) [*]T;

    /// Get as slice for CPU access
    pub fn asHostSlice(self: UnifiedBuffer, comptime T: type) []T;

    /// Prefetch to device (async)
    pub fn prefetchToDevice(self: *const UnifiedBuffer, device: CUdevice, stream: CUstream) !void;

    /// Prefetch to host (async)
    pub fn prefetchToHost(self: *const UnifiedBuffer, stream: CUstream) !void;

    /// Set memory access hint
    pub fn advise(self: *const UnifiedBuffer, advice: CUmem_advise, device: CUdevice) !void;

    /// Check validity
    pub fn isValid(self: UnifiedBuffer) bool;
};
```

### `cuda.Memory`

Memory manager with pooling.

```zig
pub const Memory = struct {
    /// Initialize memory manager
    pub fn init(drv: *const CudaDriver, allocator: Allocator) !Memory;

    /// Clean up all allocations
    pub fn deinit(self: *Memory) void;

    // === Device Memory ===

    /// Allocate device memory
    pub fn allocDevice(self: *Memory, size: usize) !Buffer;

    /// Free device memory (returns to pool)
    pub fn freeDevice(self: *Memory, buf: Buffer) void;

    /// Actually free (remove from pool)
    pub fn freeDeviceImmediate(self: *Memory, buf: Buffer) void;

    // === Pinned Memory ===

    /// Allocate pinned host memory
    pub fn allocPinned(self: *Memory, size: usize) ![]u8;

    /// Free pinned memory
    pub fn freePinned(self: *Memory, ptr: []u8) void;

    /// Check true pinned memory support
    pub fn hasTruePinnedMemory(self: *const Memory) bool;

    // === Unified Memory ===

    /// Allocate unified memory
    pub fn allocUnified(self: *Memory, size: usize) !UnifiedBuffer;

    /// Free unified memory
    pub fn freeUnified(self: *Memory, buf: *UnifiedBuffer) void;

    /// Check unified memory support
    pub fn hasUnifiedMemory(self: *const Memory) bool;

    // === Transfers (synchronous) ===

    /// Copy host to device
    pub fn copyHostToDevice(self: *Memory, dst: Buffer, src: []const u8) !void;

    /// Copy device to host
    pub fn copyDeviceToHost(self: *Memory, dst: []u8, src: Buffer) !void;

    /// Copy device to device
    pub fn copyDeviceToDevice(self: *Memory, dst: Buffer, src: Buffer, size: usize) !void;

    /// Set memory to value
    pub fn memset(self: *Memory, dst: Buffer, value: u8, count: usize) !void;

    /// Zero memory
    pub fn zero(self: *Memory, dst: Buffer) !void;

    // === Transfers (asynchronous) ===

    /// Async host to device
    pub fn copyHostToDeviceAsync(self: *Memory, dst: Buffer, src: []const u8, stream: CUstream) !void;

    /// Async device to host
    pub fn copyDeviceToHostAsync(self: *Memory, dst: []u8, src: Buffer, stream: CUstream) !void;

    // === Pool Management (#13) ===

    /// Get pool statistics
    pub fn getPoolStats(self: *const Memory) PoolStats;

    /// Defragment: free small unused buffers
    pub fn defragment(self: *Memory, threshold_bytes: usize) usize;

    /// Compact: keep only largest N free buffers
    pub fn compact(self: *Memory, keep_count: usize) usize;

    /// Clear entire pool
    pub fn clearPool(self: *Memory) void;

    // === Transfer Batching (#11) ===

    /// Create transfer batch
    pub fn createTransferBatch(self: *Memory, stream: CUstream) TransferBatch;

    // === Info ===

    /// Get free/total memory
    pub fn getMemoryInfo(self: *Memory) !struct { free: usize, total: usize };

    /// Get statistics
    pub fn getStats(self: *const Memory) MemoryStats;

    /// Synchronize all operations
    pub fn synchronize(self: *Memory) !void;
};
```

### `cuda.TransferBatch`

Batch multiple async transfers.

```zig
pub const TransferBatch = struct {
    /// Create batch
    pub fn init(drv: *const CudaDriver, allocator: Allocator, stream: CUstream) TransferBatch;

    /// Clean up
    pub fn deinit(self: *TransferBatch) void;

    /// Add host-to-device transfer
    pub fn addH2D(self: *TransferBatch, dst: Buffer, src: []const u8) !void;

    /// Add device-to-host transfer
    pub fn addD2H(self: *TransferBatch, dst: []u8, src: Buffer) !void;

    /// Add device-to-device transfer
    pub fn addD2D(self: *TransferBatch, dst: Buffer, src: Buffer, size: usize) !void;

    /// Submit all transfers (async)
    pub fn submit(self: *TransferBatch) !void;

    /// Wait for completion
    pub fn synchronize(self: *TransferBatch) !void;

    /// Submit and wait
    pub fn execute(self: *TransferBatch) !void;

    /// Get transfer count
    pub fn count(self: *const TransferBatch) usize;

    /// Get total bytes
    pub fn getTotalBytes(self: *const TransferBatch) usize;

    /// Reset for reuse
    pub fn reset(self: *TransferBatch) void;
};
```

### `cuda.PoolStats`

Memory pool statistics.

```zig
pub const PoolStats = struct {
    total_buffers: usize,
    allocated_buffers: usize,
    free_buffers: usize,
    total_bytes: usize,
    allocated_bytes: usize,
    free_bytes: usize,
    unique_sizes: usize,
    fragmentation_ratio: f32,  // 0.0 = none, 1.0 = fully fragmented
    largest_free_block: usize,
};
```

### `cuda.MemoryStats`

Memory usage statistics.

```zig
pub const MemoryStats = struct {
    device_allocs: usize,
    device_bytes_allocated: usize,
    pool_hits: usize,
    pinned_bytes_allocated: usize,
    unified_bytes_allocated: usize,
    h2d_transfers: usize,
    h2d_bytes: usize,
    d2h_transfers: usize,
    d2h_bytes: usize,
    d2d_transfers: usize,
    d2d_bytes: usize,

    /// Format as string
    pub fn format(self: MemoryStats, allocator: Allocator) ![]u8;
};
```

---

## Streams and Events

### `cuda.Stream`

CUDA stream for async operations.

```zig
pub const Stream = struct {
    handle: CUstream,
    priority: i32,

    /// Create stream
    pub fn create(drv: *const CudaDriver) !Stream;

    /// Create with priority
    pub fn createWithPriority(drv: *const CudaDriver, priority: StreamPriority) !Stream;

    /// Destroy stream
    pub fn destroy(self: *Stream) void;

    /// Synchronize stream
    pub fn synchronize(self: *Stream) !void;

    /// Query if complete (non-blocking)
    pub fn query(self: *Stream) !bool;

    /// Wait for event
    pub fn waitEvent(self: *Stream, event: Event) !void;

    /// Check validity
    pub fn isValid(self: Stream) bool;
};
```

### `cuda.StreamPriority`

```zig
pub const StreamPriority = struct {
    value: i32,

    pub const high = StreamPriority{ .value = -1 };
    pub const normal = StreamPriority{ .value = 0 };
    pub const low = StreamPriority{ .value = 1 };

    /// Get priority range for device
    pub fn getRange(drv: *const CudaDriver) !struct { least: i32, greatest: i32 };
};
```

### `cuda.Event`

CUDA event for synchronization and timing.

```zig
pub const Event = struct {
    handle: CUevent,

    /// Create event
    pub fn create(drv: *const CudaDriver) !Event;

    /// Destroy event
    pub fn destroy(self: *Event) void;

    /// Record on stream
    pub fn record(self: *Event, stream: ?CUstream) !void;

    /// Synchronize (wait for completion)
    pub fn synchronize(self: *Event) !void;

    /// Query if complete
    pub fn query(self: *Event) !bool;

    /// Get elapsed time between events (ms)
    pub fn elapsedTime(start: Event, end: Event) !f32;
};
```

### `cuda.EventTimer`

Convenience timer using events.

```zig
pub const EventTimer = struct {
    /// Start timing
    pub fn start(drv: *const CudaDriver, stream: ?CUstream) !EventTimer;

    /// Stop timing
    pub fn stop(self: *EventTimer, stream: ?CUstream) !void;

    /// Get elapsed time (ms)
    pub fn getElapsedMs(self: *EventTimer) !f32;

    /// Clean up
    pub fn deinit(self: *EventTimer) void;
};
```

---

## Modules and Kernels

### `cuda.Module`

Container for CUDA kernels.

```zig
pub const Module = struct {
    /// Load from PTX source
    pub fn loadPtx(drv: *const CudaDriver, allocator: Allocator, ptx: []const u8) !Module;

    /// Load from null-terminated PTX
    pub fn loadPtxZ(drv: *const CudaDriver, allocator: Allocator, ptx: [*:0]const u8) !Module;

    /// Load from CUBIN binary
    pub fn loadCubin(drv: *const CudaDriver, allocator: Allocator, cubin: []const u8) !Module;

    /// Load from file (PTX, CUBIN, or fatbin)
    pub fn loadFile(drv: *const CudaDriver, allocator: Allocator, path: [:0]const u8) !Module;

    /// Get kernel by name
    pub fn getKernel(self: *Module, name: []const u8) !Kernel;

    /// Check if loaded
    pub fn isLoaded(self: *const Module) bool;

    /// Unload module
    pub fn unload(self: *Module) void;
};
```

### `cuda.Kernel`

CUDA kernel function.

```zig
pub const Kernel = struct {
    handle: CUfunction,

    /// Get kernel name
    pub fn getName(self: *const Kernel) []const u8;

    /// Launch kernel
    pub fn launch(self: *const Kernel, config: LaunchConfig, params: ?[*]?*anyopaque) !void;

    /// Launch with explicit dimensions
    pub fn launchEx(self: *const Kernel,
        grid_x: u32, grid_y: u32, grid_z: u32,
        block_x: u32, block_y: u32, block_z: u32,
        shared_mem: u32, stream: CUstream,
        params: ?[*]?*anyopaque) !void;

    /// Launch 1D kernel
    pub fn launch1D(self: *const Kernel, num_elements: u32, block_size: u32, params: ?[*]?*anyopaque) !void;

    /// Launch and synchronize
    pub fn launchSync(self: *const Kernel, config: LaunchConfig, params: ?[*]?*anyopaque) !void;

    // === Occupancy ===

    /// Get max active blocks per SM
    pub fn getMaxActiveBlocksPerSM(self: *const Kernel, block_size: i32, dynamic_smem: usize) !i32;

    /// Get optimal block size
    pub fn getOptimalBlockSize(self: *const Kernel, dynamic_smem: usize, limit: i32) !OccupancyResult;

    /// Calculate occupancy percentage
    pub fn calculateOccupancy(self: *const Kernel, block_size: i32, dynamic_smem: usize, max_threads_per_sm: i32) !f32;

    // === Attributes ===

    /// Get function attribute
    pub fn getAttribute(self: *const Kernel, attr: CUfunction_attribute) !i32;

    /// Get max threads per block
    pub fn getMaxThreadsPerBlock(self: *const Kernel) !i32;

    /// Get registers per thread
    pub fn getNumRegs(self: *const Kernel) !i32;

    /// Get shared memory size
    pub fn getSharedMemorySize(self: *const Kernel) !i32;

    /// Get local memory per thread
    pub fn getLocalMemorySize(self: *const Kernel) !i32;
};
```

### `cuda.OccupancyResult`

```zig
pub const OccupancyResult = struct {
    block_size: i32,
    min_grid_size: i32,

    /// Convert to LaunchConfig
    pub fn toLaunchConfig(self: OccupancyResult, num_elements: u32) LaunchConfig;
};
```

### `cuda.NvrtcCompiler`

Runtime CUDA compiler.

```zig
pub const NvrtcCompiler = struct {
    /// Initialize compiler
    pub fn init(allocator: Allocator) NvrtcCompiler;

    /// Clean up
    pub fn deinit(self: *NvrtcCompiler) void;

    /// Check availability
    pub fn available(self: *const NvrtcCompiler) bool;

    /// Compile to PTX
    pub fn compileToPtx(self: *NvrtcCompiler, source: [:0]const u8, name: [:0]const u8, arch: ?ComputeArch) ![]u8;

    /// Compile with options (#15)
    pub fn compileToPtxWithOptions(self: *NvrtcCompiler, source: [:0]const u8, name: [:0]const u8, options: NvrtcOptions) ![]u8;

    /// Get compilation log
    pub fn getCompilationLog(self: *NvrtcCompiler, source: [:0]const u8, name: [:0]const u8, options: NvrtcOptions) ![]u8;
};
```

### `cuda.NvrtcOptions`

NVRTC compilation options.

```zig
pub const NvrtcOptions = struct {
    arch: ?ComputeArch = null,
    std: CppStandard = .cpp11,
    opt_level: u2 = 2,           // 0-3
    debug: bool = false,
    line_info: bool = false,
    fast_math: bool = false,
    fmad: bool = true,
    use_fast_div: bool = false,
    include_paths: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
    extra_options: []const []const u8 = &.{},
    relocatable: bool = false,
    extensible: bool = false,

    pub const CppStandard = enum { cpp11, cpp14, cpp17, cpp20 };

    /// Create for architecture
    pub fn forArch(arch: ComputeArch) NvrtcOptions;

    /// Enable max performance
    pub fn maxPerformance(self: *NvrtcOptions) *NvrtcOptions;

    /// Enable debugging
    pub fn forDebugging(self: *NvrtcOptions) *NvrtcOptions;
};
```

### Kernel Argument Helpers

#### `cuda.KernelArgs`

Dynamic argument builder.

```zig
pub fn KernelArgs(comptime max_args: usize) type {
    return struct {
        /// Add pointer argument
        pub fn addPtr(self: *Self, ptr: anytype) void;

        /// Get argument array
        pub fn getArgs(self: *Self) [*]?*anyopaque;

        /// Reset arguments
        pub fn reset(self: *Self) void;
    };
}
```

#### `cuda.TypedKernelArgs`

Type-safe argument builder (#16).

```zig
pub fn TypedKernelArgs(comptime T: type) type {
    return struct {
        values: T,

        /// Create with values
        pub fn init(values: T) Self;

        /// Get argument array
        pub fn asParams(self: *Self) [*]?*anyopaque;

        /// Get argument count
        pub fn count(self: *const Self) usize;

        /// Get field value
        pub fn get(self: *const Self, comptime field: []const u8) FieldType;

        /// Set field value
        pub fn set(self: *Self, comptime field: []const u8, value: FieldType) void;
    };
}
```

**Usage:**
```zig
const Args = struct {
    d_input: cuda.CUdeviceptr,
    d_output: cuda.CUdeviceptr,
    n: u32,
};

var args = cuda.TypedKernelArgs(Args).init(.{
    .d_input = input_buf.ptr,
    .d_output = output_buf.ptr,
    .n = 1024,
});

try kernel.launch(config, args.asParams());
```

#### `cuda.kernelParams`

Quick argument building from tuple.

```zig
pub fn kernelParams(args: anytype) [*]?*anyopaque;
```

**Usage:**
```zig
var n: u32 = 1024;
try kernel.launch(config, cuda.kernelParams(.{ &input.ptr, &output.ptr, &n }));
```

---

## Profiling

### `cuda.ProfileTimer`

CPU-based profiler.

```zig
pub const ProfileTimer = struct {
    /// Start timer
    pub fn start(operation: []const u8) ProfileTimer;

    /// Mark H2D transfer start
    pub fn markH2DStart(self: *ProfileTimer) void;

    /// Mark H2D transfer end
    pub fn markH2DEnd(self: *ProfileTimer, bytes: usize) void;

    /// Mark kernel start
    pub fn markKernelStart(self: *ProfileTimer) void;

    /// Mark kernel end
    pub fn markKernelEnd(self: *ProfileTimer) void;

    /// Mark D2H transfer start
    pub fn markD2HStart(self: *ProfileTimer) void;

    /// Mark D2H transfer end
    pub fn markD2HEnd(self: *ProfileTimer, bytes: usize) void;

    /// Finish and get profile
    pub fn finish(self: *ProfileTimer) PerformanceProfile;
};
```

### `cuda.PerformanceProfile`

```zig
pub const PerformanceProfile = struct {
    host_to_device_ms: f64,
    device_to_host_ms: f64,
    total_transfer_ms: f64,
    kernel_ms: f64,
    total_ms: f64,
    input_bytes: usize,
    output_bytes: usize,
    transfer_overhead_percent: f64,
    kernel_percent: f64,
    effective_bandwidth_gbps: f64,

    /// Get operation name
    pub fn getOperation(self: *const PerformanceProfile) []const u8;

    /// Format as string
    pub fn format(self: *const PerformanceProfile, allocator: Allocator) ![]u8;

    /// Export to JSON
    pub fn toJson(self: *const PerformanceProfile, allocator: Allocator) ![]u8;
};
```

### `cuda.EventProfiler`

GPU event-based profiler (#14).

```zig
pub const EventProfiler = struct {
    /// Create profiler
    pub fn init(drv: *const CudaDriver, allocator: Allocator) !EventProfiler;

    /// Clean up
    pub fn deinit(self: *EventProfiler) void;

    /// Start profiling
    pub fn start(self: *EventProfiler, stream: ?CUstream) !void;

    /// Stop profiling
    pub fn stop(self: *EventProfiler, stream: ?CUstream) !void;

    /// Get elapsed time (ms)
    pub fn getElapsedMs(self: *EventProfiler) !f32;

    /// Begin named region
    pub fn beginRegion(self: *EventProfiler, name: []const u8, stream: ?CUstream) !void;

    /// End named region
    pub fn endRegion(self: *EventProfiler, name: []const u8, stream: ?CUstream) !void;

    /// Get region elapsed time
    pub fn getRegionElapsedMs(self: *EventProfiler, name: []const u8) !f32;

    /// Get all region timings
    pub fn getAllRegionTimings(self: *EventProfiler, allocator: Allocator) !StringHashMap(f32);

    /// Reset for reuse
    pub fn reset(self: *EventProfiler) void;
};
```

### `cuda.ScopedProfiler`

RAII region profiler.

```zig
pub const ScopedProfiler = struct {
    /// Create scoped profiler
    pub fn init(profiler: *EventProfiler, name: []const u8, stream: ?CUstream) !ScopedProfiler;

    /// End region (call in defer or manually)
    pub fn end(self: *ScopedProfiler) void;
};
```

### `cuda.BenchmarkResult`

```zig
pub const BenchmarkResult = struct {
    iterations: usize,
    total_ms: f64,
    mean_ms: f64,
    min_ms: f64,
    max_ms: f64,
    std_dev_ms: f64,
    throughput: f64,
    data_size: usize,
    bandwidth_gbps: f64,

    /// Get name
    pub fn getName(self: *const BenchmarkResult) []const u8;

    /// Format as table row
    pub fn formatRow(self: *const BenchmarkResult, allocator: Allocator) ![]u8;

    /// Export to JSON
    pub fn toJson(self: *const BenchmarkResult, allocator: Allocator) ![]u8;
};
```

### `cuda.benchmark`

```zig
/// Run benchmark
pub fn benchmark(
    name: []const u8,
    iterations: usize,
    data_size: usize,
    func: *const fn () void,
) BenchmarkResult;
```

---

## Error Handling

All fallible functions return `CudaError` or a union with allocation errors.

### Pattern: Check Availability First

```zig
if (!cuda.isAvailable()) {
    // Handle no CUDA gracefully
    return fallbackCpuImplementation();
}

var ctx = try cuda.Context.init(allocator, .{});
defer ctx.deinit();
```

### Pattern: Probe for Details

```zig
var probe_result = try cuda.probe(allocator);
defer probe_result.deinit(allocator);

if (!probe_result.available) {
    std.debug.print("CUDA unavailable: {s}\n", .{probe_result.getErrorMessage()});
    return;
}

for (probe_result.devices) |dev| {
    std.debug.print("GPU {}: {s} ({d:.1} GB)\n", .{
        dev.ordinal,
        dev.getName(),
        dev.getTotalMemoryGB(),
    });
}
```

### Pattern: Error Recovery

```zig
const buffer = ctx.memory.allocDevice(size) catch |err| switch (err) {
    error.OutOfMemory => {
        // Try to free pool and retry
        ctx.memory.clearPool();
        return ctx.memory.allocDevice(size);
    },
    else => return err,
};
```

---

## Thread Safety

- **Module kernel cache**: Protected by mutex
- **Memory pool**: Not thread-safe (use per-thread Memory instances)
- **Streams**: CUDA streams provide synchronization
- **Context**: Use ContextScope for safe multi-device access

See [Thread Safety Guarantees](./THREAD_SAFETY.md) for details.

---

## Version Information

```zig
pub const version = struct {
    pub const major = 0;
    pub const minor = 1;
    pub const patch = 0;
    pub const string = "0.1.0";
};

pub const min_driver_version = 11000; // CUDA 11.0
```
