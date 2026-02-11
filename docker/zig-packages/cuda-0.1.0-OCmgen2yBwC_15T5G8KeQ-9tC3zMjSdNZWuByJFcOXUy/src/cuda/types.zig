// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Types and Constants
//!
//! This module defines all CUDA type aliases, constants, and error codes
//! used throughout the library. These types mirror the NVIDIA CUDA Driver API.

const std = @import("std");

// ============================================================================
// CUDA Result Codes
// ============================================================================

/// CUDA driver API result type
pub const CUresult = i32;

/// CUDA success code
pub const CUDA_SUCCESS: CUresult = 0;

/// Common CUDA error codes
pub const CUerror = enum(CUresult) {
    success = 0,
    invalid_value = 1,
    out_of_memory = 2,
    not_initialized = 3,
    deinitialized = 4,
    profiler_disabled = 5,
    profiler_not_initialized = 6,
    profiler_already_started = 7,
    profiler_already_stopped = 8,
    no_device = 100,
    invalid_device = 101,
    invalid_image = 200,
    invalid_context = 201,
    context_already_current = 202,
    map_failed = 205,
    unmap_failed = 206,
    array_is_mapped = 207,
    already_mapped = 208,
    no_binary_for_gpu = 209,
    already_acquired = 210,
    not_mapped = 211,
    not_mapped_as_array = 212,
    not_mapped_as_pointer = 213,
    ecc_uncorrectable = 214,
    unsupported_limit = 215,
    context_already_in_use = 216,
    invalid_source = 300,
    file_not_found = 301,
    shared_object_symbol_not_found = 302,
    shared_object_init_failed = 303,
    operating_system = 304,
    invalid_handle = 400,
    not_found = 500,
    not_ready = 600,
    launch_failed = 700,
    launch_out_of_resources = 701,
    launch_timeout = 702,
    launch_incompatible_texturing = 703,
    unknown = 999,
    _,
};

// ============================================================================
// CUDA Device Types
// ============================================================================

/// CUDA device ordinal (0-based index)
pub const CUdevice = i32;

/// CUDA device pointer (64-bit GPU address)
pub const CUdeviceptr = u64;

/// Null device pointer constant
pub const CU_NULL_DEVICE_PTR: CUdeviceptr = 0;

// ============================================================================
// CUDA Context Types
// ============================================================================

/// CUDA context handle (opaque pointer)
pub const CUcontext = *anyopaque;

/// Context creation flags
pub const CUctx_flags = enum(u32) {
    sched_auto = 0x00,
    sched_spin = 0x01,
    sched_yield = 0x02,
    sched_blocking_sync = 0x04,
    map_host = 0x08,
    lmem_resize_to_max = 0x10,
};

// ============================================================================
// CUDA Module Types
// ============================================================================

/// CUDA module handle (opaque pointer)
pub const CUmodule = *anyopaque;

/// CUDA kernel function handle (opaque pointer)
pub const CUfunction = *anyopaque;

// ============================================================================
// CUDA Stream Types
// ============================================================================

/// CUDA stream handle (opaque pointer, null = default stream)
pub const CUstream = ?*anyopaque;

/// Default CUDA stream
pub const CU_STREAM_DEFAULT: CUstream = null;

/// Stream creation flags
pub const CUstream_flags = enum(u32) {
    default = 0x0,
    non_blocking = 0x1,
};

// ============================================================================
// CUDA Event Types
// ============================================================================

/// CUDA event handle (opaque pointer)
pub const CUevent = *anyopaque;

/// Event creation flags
pub const CUevent_flags = enum(u32) {
    default = 0x0,
    blocking_sync = 0x1,
    disable_timing = 0x2,
    interprocess = 0x4,
};

// ============================================================================
// CUDA Memory Types
// ============================================================================

/// Memory allocation types
pub const CUmemorytype = enum(u32) {
    host = 0x01,
    device = 0x02,
    array = 0x03,
    unified = 0x04,
};

/// Unified memory attachment flags
pub const CUmem_attach_flags = enum(u32) {
    /// Memory can be accessed by any stream on any device
    global = 0x1,
    /// Memory is initially attached to host (faster CPU access)
    host = 0x2,
    /// Memory is accessible only by a single stream
    single = 0x4,
};

/// Memory advice for cuMemAdvise
pub const CUmem_advise = enum(i32) {
    /// Data will be mostly read, and only occasionally written to
    set_read_mostly = 1,
    /// Undo the effect of set_read_mostly
    unset_read_mostly = 2,
    /// Set preferred location for the data
    set_preferred_location = 3,
    /// Undo effect of set_preferred_location
    unset_preferred_location = 4,
    /// Data will be accessed by the specified device
    set_accessed_by = 5,
    /// Undo effect of set_accessed_by
    unset_accessed_by = 6,
};

/// CPU device ID for prefetch/advise operations
pub const CU_DEVICE_CPU: CUdevice = -1;

/// Memory copy direction
pub const CUmemcpy_kind = enum(u32) {
    host_to_host = 0,
    host_to_device = 1,
    device_to_host = 2,
    device_to_device = 3,
    default = 4,
};

// ============================================================================
// CUDA Device Attributes
// ============================================================================

/// Device attribute enumeration
pub const CUdevice_attribute = enum(i32) {
    max_threads_per_block = 1,
    max_block_dim_x = 2,
    max_block_dim_y = 3,
    max_block_dim_z = 4,
    max_grid_dim_x = 5,
    max_grid_dim_y = 6,
    max_grid_dim_z = 7,
    max_shared_memory_per_block = 8,
    total_constant_memory = 9,
    warp_size = 10,
    max_pitch = 11,
    max_registers_per_block = 12,
    clock_rate = 13,
    texture_alignment = 14,
    multiprocessor_count = 16,
    kernel_exec_timeout = 17,
    integrated = 18,
    can_map_host_memory = 19,
    compute_mode = 20,
    concurrent_kernels = 31,
    ecc_enabled = 32,
    pci_bus_id = 33,
    pci_device_id = 34,
    tcc_driver = 35,
    memory_clock_rate = 36,
    global_memory_bus_width = 37,
    l2_cache_size = 38,
    max_threads_per_multiprocessor = 39,
    compute_capability_major = 75,
    compute_capability_minor = 76,
    managed_memory = 83,
    multi_gpu_board = 84,
    multi_gpu_board_group_id = 85,
    _,
};

/// Function attribute enumeration for cuFuncGetAttribute
pub const CUfunction_attribute = enum(i32) {
    /// Maximum number of threads per block
    max_threads_per_block = 0,
    /// Size of statically-allocated shared memory per block
    shared_size_bytes = 1,
    /// Size of constant memory
    const_size_bytes = 2,
    /// Size of local memory per thread
    local_size_bytes = 3,
    /// Number of registers used by each thread
    num_regs = 4,
    /// PTX virtual architecture version
    ptx_version = 5,
    /// Binary architecture version
    binary_version = 6,
    /// Attribute for caching config
    cache_mode_ca = 7,
    /// Maximum dynamically-allocated shared memory size
    max_dynamic_shared_size_bytes = 8,
    /// Preferred shared memory carveout
    preferred_shared_memory_carveout = 9,
    _,
};

/// P2P attributes for cuDeviceGetP2PAttribute
pub const CUdevice_P2PAttribute = enum(i32) {
    /// Link performance rank
    performance_rank = 0x01,
    /// Access supported
    access_supported = 0x02,
    /// Native atomic operations supported
    native_atomic_supported = 0x03,
    /// Access via array (CUDA Arrays supported)
    cuda_array_access_supported = 0x04,
    _,
};

// ============================================================================
// CUDA Compute Architecture
// ============================================================================

/// GPU compute architecture specification
pub const ComputeArch = struct {
    /// SM major version (e.g., 5 for Maxwell, 7 for Volta, 8 for Ampere, 9 for Hopper, 10 for Blackwell)
    major: u32,
    /// SM minor version
    minor: u32,

    /// Get the compute capability string (e.g., "compute_52")
    pub fn computeString(self: ComputeArch) []const u8 {
        return switch (self.major) {
            3 => switch (self.minor) {
                0 => "compute_30",
                5 => "compute_35",
                7 => "compute_37",
                else => "compute_30",
            },
            5 => switch (self.minor) {
                0 => "compute_50",
                2 => "compute_52",
                3 => "compute_53",
                else => "compute_50",
            },
            6 => switch (self.minor) {
                0 => "compute_60",
                1 => "compute_61",
                2 => "compute_62",
                else => "compute_60",
            },
            7 => switch (self.minor) {
                0 => "compute_70",
                2 => "compute_72",
                5 => "compute_75",
                else => "compute_70",
            },
            8 => switch (self.minor) {
                0 => "compute_80",
                6 => "compute_86",
                7 => "compute_87",
                9 => "compute_89",
                else => "compute_80",
            },
            9 => switch (self.minor) {
                0 => "compute_90",
                else => "compute_90",
            },
            10 => switch (self.minor) {
                0 => "compute_100",
                else => "compute_100",
            },
            else => "compute_52", // Default fallback
        };
    }

    /// Get the SM architecture string (e.g., "sm_52")
    pub fn smString(self: ComputeArch) []const u8 {
        return switch (self.major) {
            3 => switch (self.minor) {
                0 => "sm_30",
                5 => "sm_35",
                7 => "sm_37",
                else => "sm_30",
            },
            5 => switch (self.minor) {
                0 => "sm_50",
                2 => "sm_52",
                3 => "sm_53",
                else => "sm_50",
            },
            6 => switch (self.minor) {
                0 => "sm_60",
                1 => "sm_61",
                2 => "sm_62",
                else => "sm_60",
            },
            7 => switch (self.minor) {
                0 => "sm_70",
                2 => "sm_72",
                5 => "sm_75",
                else => "sm_70",
            },
            8 => switch (self.minor) {
                0 => "sm_80",
                6 => "sm_86",
                7 => "sm_87",
                9 => "sm_89",
                else => "sm_80",
            },
            9 => switch (self.minor) {
                0 => "sm_90",
                else => "sm_90",
            },
            10 => switch (self.minor) {
                0 => "sm_100",
                else => "sm_100",
            },
            else => "sm_52",
        };
    }

    /// Get architecture name
    pub fn name(self: ComputeArch) []const u8 {
        return switch (self.major) {
            3 => "Kepler",
            5 => "Maxwell",
            6 => "Pascal",
            7 => if (self.minor >= 5) "Turing" else "Volta",
            8 => if (self.minor >= 9) "Ada Lovelace" else "Ampere",
            9 => "Hopper",
            10 => "Blackwell",
            else => "Unknown",
        };
    }

    /// Check if architecture supports specific features
    pub fn supportsUnifiedMemory(self: ComputeArch) bool {
        return self.major >= 3;
    }

    pub fn supportsDynamicParallelism(self: ComputeArch) bool {
        // Dynamic parallelism requires sm_35+ (compute capability 3.5 or higher)
        return self.major > 3 or (self.major == 3 and self.minor >= 5);
    }

    pub fn supportsTensorCores(self: ComputeArch) bool {
        return self.major >= 7;
    }

    pub fn supportsAsyncCopy(self: ComputeArch) bool {
        return self.major >= 8;
    }

    /// Blackwell-specific: Supports new FP4/FP6 formats and enhanced tensor cores
    pub fn supportsBlackwellFeatures(self: ComputeArch) bool {
        return self.major >= 10;
    }
};

/// Known GPU architectures
pub const Architectures = struct {
    pub const kepler = ComputeArch{ .major = 3, .minor = 5 };
    pub const maxwell = ComputeArch{ .major = 5, .minor = 2 };
    pub const pascal = ComputeArch{ .major = 6, .minor = 1 };
    pub const volta = ComputeArch{ .major = 7, .minor = 0 };
    pub const turing = ComputeArch{ .major = 7, .minor = 5 };
    pub const ampere = ComputeArch{ .major = 8, .minor = 0 };
    pub const ada_lovelace = ComputeArch{ .major = 8, .minor = 9 };
    pub const hopper = ComputeArch{ .major = 9, .minor = 0 };
    pub const blackwell = ComputeArch{ .major = 10, .minor = 0 };

    /// Default architecture for compatibility (Maxwell)
    pub const default = maxwell;

    /// Minimum supported architecture
    pub const minimum = ComputeArch{ .major = 3, .minor = 0 };
};

// ============================================================================
// Memory Alignment Constants (#28)
// ============================================================================

/// CUDA memory alignment requirements
pub const MemoryAlignment = struct {
    /// Default CUDA memory alignment (256 bytes for coalesced access)
    pub const default: usize = 256;

    /// Texture memory alignment requirement
    pub const texture: usize = 512;

    /// Surface memory alignment requirement
    pub const surface: usize = 512;

    /// Constant memory alignment
    pub const constant: usize = 256;

    /// Shared memory alignment (typically cache line)
    pub const shared: usize = 128;

    /// Page-locked (pinned) memory alignment
    pub const pinned: usize = 4096;

    /// Unified memory alignment
    pub const unified: usize = 4096;

    /// Minimum alignment for device memory allocations
    pub const device_min: usize = 256;

    /// Alignment for warp-level operations
    pub const warp: usize = 128;

    /// Align a size up to the specified alignment
    pub fn alignUp(size: usize, alignment: usize) usize {
        return (size + alignment - 1) & ~(alignment - 1);
    }

    /// Align a size up to default CUDA alignment
    pub fn alignDefault(size: usize) usize {
        return alignUp(size, default);
    }

    /// Check if a size is properly aligned
    pub fn isAligned(size: usize, alignment: usize) bool {
        return (size & (alignment - 1)) == 0;
    }

    /// Check if an address/size is aligned for device memory
    pub fn isDeviceAligned(size: usize) bool {
        return isAligned(size, device_min);
    }

    /// Get alignment requirement for a given memory type
    pub fn forMemoryType(kind: MemoryKind) usize {
        return switch (kind) {
            .device => device_min,
            .pinned => pinned,
            .unified => unified,
            .mapped => pinned,
        };
    }
};

/// Memory type for alignment validation
pub const MemoryKind = enum {
    device,
    pinned,
    unified,
    mapped,
};

/// Validate buffer size and alignment
pub fn validateBufferSize(size: usize, alignment: usize) !usize {
    if (size == 0) return error.InvalidSize;
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidAlignment;
    return MemoryAlignment.alignUp(size, alignment);
}

// ============================================================================
// Dynamic Loader Constants
// ============================================================================

/// dlopen flags
pub const RTLD_LAZY: i32 = 0x00001;
pub const RTLD_NOW: i32 = 0x00002;
pub const RTLD_GLOBAL: i32 = 0x00100;
pub const RTLD_LOCAL: i32 = 0x00000;

// ============================================================================
// NVRTC Types
// ============================================================================

/// NVRTC result type
pub const nvrtcResult = i32;

/// NVRTC program handle (opaque pointer)
pub const nvrtcProgram = *anyopaque;

/// NVRTC success code
pub const NVRTC_SUCCESS: nvrtcResult = 0;

/// NVRTC error codes
pub const NvrtcError = enum(nvrtcResult) {
    success = 0,
    out_of_memory = 1,
    program_creation_failure = 2,
    invalid_input = 3,
    invalid_program = 4,
    invalid_option = 5,
    compilation = 6,
    builtin_operation_failure = 7,
    no_name_expressions_after_compilation = 8,
    no_lowered_names_before_compilation = 9,
    name_expression_not_valid = 10,
    internal_error = 11,
    _,
};

// ============================================================================
// Library Error Types
// ============================================================================

/// CUDA library errors
pub const CudaError = error{
    /// CUDA driver not available (libcuda.so not found)
    DriverNotFound,
    /// CUDA driver initialization failed
    InitFailed,
    /// No CUDA-capable GPU found
    NoDevice,
    /// Invalid device ordinal
    InvalidDevice,
    /// Failed to create CUDA context
    ContextCreateFailed,
    /// CUDA context operation failed
    ContextError,
    /// Memory allocation failed
    OutOfMemory,
    /// Memory copy operation failed
    CopyFailed,
    /// Failed to synchronize
    SyncFailed,
    /// Module load failed
    ModuleLoadFailed,
    /// Kernel function not found
    FunctionNotFound,
    /// Kernel launch failed
    LaunchFailed,
    /// NVRTC compiler not available
    NvrtcNotFound,
    /// Kernel compilation failed
    CompilationFailed,
    /// Feature not supported on this GPU
    NotSupported,
    /// Invalid argument passed to function
    InvalidArgument,
    /// Operation timed out
    Timeout,
    /// Platform not supported (non-Linux)
    PlatformNotSupported,
    /// Generic GPU error
    GpuError,
};

/// Combine with standard allocation errors
pub const Error = CudaError || std.mem.Allocator.Error;

// ============================================================================
// Utility Types
// ============================================================================

/// Device memory buffer descriptor
pub const DeviceBuffer = struct {
    /// GPU device pointer
    ptr: CUdeviceptr,
    /// Buffer size in bytes
    size: usize,
    /// Whether buffer is currently allocated/in-use
    allocated: bool,

    /// Check if buffer is valid
    pub fn isValid(self: DeviceBuffer) bool {
        return self.ptr != CU_NULL_DEVICE_PTR and self.size > 0;
    }
};

/// Launch configuration validation errors
pub const LaunchConfigError = error{
    /// Block dimensions exceed maximum threads per block (typically 1024)
    BlockSizeExceedsLimit,
    /// Grid dimension exceeds maximum (typically 2^31-1 for x, 65535 for y/z)
    GridSizeExceedsLimit,
    /// Block dimension is zero (must be at least 1)
    ZeroBlockDimension,
    /// Grid dimension is zero (must be at least 1)
    ZeroGridDimension,
    /// Shared memory exceeds device limit
    SharedMemoryExceedsLimit,
};

/// Default CUDA limits (conservative values that work on all devices)
pub const LaunchLimits = struct {
    /// Maximum threads per block (most devices support 1024)
    pub const max_threads_per_block: u32 = 1024;
    /// Maximum block dimension X
    pub const max_block_dim_x: u32 = 1024;
    /// Maximum block dimension Y
    pub const max_block_dim_y: u32 = 1024;
    /// Maximum block dimension Z
    pub const max_block_dim_z: u32 = 64;
    /// Maximum grid dimension X (2^31 - 1)
    pub const max_grid_dim_x: u32 = 2147483647;
    /// Maximum grid dimension Y
    pub const max_grid_dim_y: u32 = 65535;
    /// Maximum grid dimension Z
    pub const max_grid_dim_z: u32 = 65535;
    /// Default maximum shared memory per block (48KB, varies by device)
    pub const max_shared_memory_per_block: u32 = 49152;
};

/// Kernel launch configuration
pub const LaunchConfig = struct {
    /// Grid dimensions (blocks)
    grid: [3]u32 = .{ 1, 1, 1 },
    /// Block dimensions (threads)
    block: [3]u32 = .{ 256, 1, 1 },
    /// Shared memory size in bytes
    shared_mem: u32 = 0,
    /// Stream to use (null = default)
    stream: CUstream = CU_STREAM_DEFAULT,

    /// Create config for 1D launch with automatic block sizing
    pub fn for1D(num_elements: u32, block_size: u32) LaunchConfig {
        const blocks = (num_elements + block_size - 1) / block_size;
        return .{
            .grid = .{ blocks, 1, 1 },
            .block = .{ block_size, 1, 1 },
        };
    }

    /// Create config for 2D launch
    pub fn for2D(width: u32, height: u32, block_x: u32, block_y: u32) LaunchConfig {
        return .{
            .grid = .{ (width + block_x - 1) / block_x, (height + block_y - 1) / block_y, 1 },
            .block = .{ block_x, block_y, 1 },
        };
    }

    /// Total number of threads
    pub fn totalThreads(self: LaunchConfig) u64 {
        const grid_total: u64 = @as(u64, self.grid[0]) * @as(u64, self.grid[1]) * @as(u64, self.grid[2]);
        const block_total: u64 = @as(u64, self.block[0]) * @as(u64, self.block[1]) * @as(u64, self.block[2]);
        return grid_total * block_total;
    }

    /// Total threads per block
    pub fn threadsPerBlock(self: LaunchConfig) u32 {
        return self.block[0] * self.block[1] * self.block[2];
    }

    /// Validate configuration against default CUDA limits
    /// Returns error if any dimension exceeds limits
    pub fn validate(self: LaunchConfig) LaunchConfigError!void {
        return self.validateWithLimits(
            LaunchLimits.max_threads_per_block,
            LaunchLimits.max_shared_memory_per_block,
        );
    }

    /// Validate configuration against specific device limits
    pub fn validateWithLimits(
        self: LaunchConfig,
        max_threads_per_block: u32,
        max_shared_mem: u32,
    ) LaunchConfigError!void {
        // Check for zero dimensions
        if (self.block[0] == 0 or self.block[1] == 0 or self.block[2] == 0) {
            return LaunchConfigError.ZeroBlockDimension;
        }
        if (self.grid[0] == 0 or self.grid[1] == 0 or self.grid[2] == 0) {
            return LaunchConfigError.ZeroGridDimension;
        }

        // Check block dimensions against individual limits
        if (self.block[0] > LaunchLimits.max_block_dim_x or
            self.block[1] > LaunchLimits.max_block_dim_y or
            self.block[2] > LaunchLimits.max_block_dim_z)
        {
            return LaunchConfigError.BlockSizeExceedsLimit;
        }

        // Check total threads per block
        const threads = self.threadsPerBlock();
        if (threads > max_threads_per_block) {
            return LaunchConfigError.BlockSizeExceedsLimit;
        }

        // Check grid dimensions
        if (self.grid[0] > LaunchLimits.max_grid_dim_x or
            self.grid[1] > LaunchLimits.max_grid_dim_y or
            self.grid[2] > LaunchLimits.max_grid_dim_z)
        {
            return LaunchConfigError.GridSizeExceedsLimit;
        }

        // Check shared memory
        if (self.shared_mem > max_shared_mem) {
            return LaunchConfigError.SharedMemoryExceedsLimit;
        }
    }

    /// Check if configuration is valid (returns bool instead of error)
    pub fn isValid(self: LaunchConfig) bool {
        self.validate() catch return false;
        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ComputeArch strings" {
    const arch = Architectures.blackwell;
    try std.testing.expectEqualStrings("compute_100", arch.computeString());
    try std.testing.expectEqualStrings("sm_100", arch.smString());
    try std.testing.expectEqualStrings("Blackwell", arch.name());
    try std.testing.expect(arch.supportsBlackwellFeatures());
    try std.testing.expect(arch.supportsTensorCores());
}

test "LaunchConfig for1D" {
    const config = LaunchConfig.for1D(1000, 256);
    try std.testing.expectEqual(@as(u32, 4), config.grid[0]); // ceil(1000/256) = 4
    try std.testing.expectEqual(@as(u32, 256), config.block[0]);
}

test "DeviceBuffer validation" {
    const valid_buf = DeviceBuffer{ .ptr = 0x1000, .size = 1024, .allocated = true };
    const invalid_buf = DeviceBuffer{ .ptr = 0, .size = 0, .allocated = false };

    try std.testing.expect(valid_buf.isValid());
    try std.testing.expect(!invalid_buf.isValid());
}

test "ComputeArch all architectures have valid strings" {
    const archs = [_]ComputeArch{
        Architectures.kepler,
        Architectures.maxwell,
        Architectures.pascal,
        Architectures.volta,
        Architectures.turing,
        Architectures.ampere,
        Architectures.ada_lovelace,
        Architectures.hopper,
        Architectures.blackwell,
    };

    for (archs) |arch| {
        // Name should not be empty
        try std.testing.expect(arch.name().len > 0);
        // Compute string should start with "compute_"
        try std.testing.expect(std.mem.startsWith(u8, arch.computeString(), "compute_"));
        // SM string should start with "sm_"
        try std.testing.expect(std.mem.startsWith(u8, arch.smString(), "sm_"));
    }
}

test "ComputeArch feature detection by generation" {
    // Kepler (sm_35) - has unified memory (major >= 3) and dynamic parallelism (major >= 3, minor >= 5)
    try std.testing.expect(Architectures.kepler.supportsUnifiedMemory()); // major 3 >= 3
    try std.testing.expect(Architectures.kepler.supportsDynamicParallelism()); // major 3 >= 3, minor 5 >= 5
    try std.testing.expect(!Architectures.kepler.supportsTensorCores()); // major 3 < 7
    try std.testing.expect(!Architectures.kepler.supportsAsyncCopy()); // major 3 < 8
    try std.testing.expect(!Architectures.kepler.supportsBlackwellFeatures()); // major 3 < 10

    // Maxwell (sm_52) - same unified memory and dynamic parallelism
    try std.testing.expect(Architectures.maxwell.supportsUnifiedMemory());
    try std.testing.expect(Architectures.maxwell.supportsDynamicParallelism());
    try std.testing.expect(!Architectures.maxwell.supportsTensorCores()); // major 5 < 7

    // Volta (sm_70) - first with tensor cores
    try std.testing.expect(Architectures.volta.supportsTensorCores()); // major 7 >= 7
    try std.testing.expect(!Architectures.volta.supportsAsyncCopy()); // major 7 < 8

    // Ampere (sm_80) - added async copy
    try std.testing.expect(Architectures.ampere.supportsTensorCores());
    try std.testing.expect(Architectures.ampere.supportsAsyncCopy()); // major 8 >= 8
    try std.testing.expect(!Architectures.ampere.supportsBlackwellFeatures()); // major 8 < 10

    // Blackwell (sm_100) - all features
    try std.testing.expect(Architectures.blackwell.supportsUnifiedMemory());
    try std.testing.expect(Architectures.blackwell.supportsDynamicParallelism());
    try std.testing.expect(Architectures.blackwell.supportsTensorCores());
    try std.testing.expect(Architectures.blackwell.supportsAsyncCopy());
    try std.testing.expect(Architectures.blackwell.supportsBlackwellFeatures()); // major 10 >= 10
}

test "ComputeArch custom architecture" {
    const custom = ComputeArch{ .major = 9, .minor = 5 };
    try std.testing.expectEqual(@as(u8, 9), custom.major);
    try std.testing.expectEqual(@as(u8, 5), custom.minor);

    // Custom 9.5 should have tensor cores (major >= 7)
    try std.testing.expect(custom.supportsTensorCores());
    // Should have async copy (major >= 8)
    try std.testing.expect(custom.supportsAsyncCopy());
    // Should not have blackwell features (major < 10)
    try std.testing.expect(!custom.supportsBlackwellFeatures());
}

test "ComputeArch comparison" {
    // Same architecture
    try std.testing.expect(Architectures.ampere.major == Architectures.ampere.major);

    // Different major versions
    try std.testing.expect(Architectures.volta.major < Architectures.ampere.major);
    try std.testing.expect(Architectures.blackwell.major > Architectures.ampere.major);
}

test "LaunchConfig for1D edge cases" {
    // Single thread
    const config1 = LaunchConfig.for1D(1, 256);
    try std.testing.expectEqual(@as(u32, 1), config1.grid[0]);
    try std.testing.expectEqual(@as(u32, 256), config1.block[0]);

    // Exact multiple
    const config2 = LaunchConfig.for1D(256, 256);
    try std.testing.expectEqual(@as(u32, 1), config2.grid[0]);

    // One over
    const config3 = LaunchConfig.for1D(257, 256);
    try std.testing.expectEqual(@as(u32, 2), config3.grid[0]);

    // Large workload
    const config4 = LaunchConfig.for1D(10_000_000, 1024);
    try std.testing.expectEqual(@as(u32, 9766), config4.grid[0]);
}

test "LaunchConfig for2D edge cases" {
    // Square
    const config1 = LaunchConfig.for2D(1024, 1024, 32, 32);
    try std.testing.expectEqual(@as(u32, 32), config1.grid[0]);
    try std.testing.expectEqual(@as(u32, 32), config1.grid[1]);

    // Non-square
    const config2 = LaunchConfig.for2D(1920, 1080, 16, 16);
    try std.testing.expectEqual(@as(u32, 120), config2.grid[0]);
    try std.testing.expectEqual(@as(u32, 68), config2.grid[1]);

    // Small workload
    const config3 = LaunchConfig.for2D(10, 10, 8, 8);
    try std.testing.expectEqual(@as(u32, 2), config3.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), config3.grid[1]);
}

test "LaunchConfig totalThreads" {
    const config = LaunchConfig{
        .grid = .{ 10, 10, 10 },
        .block = .{ 8, 8, 8 },
    };
    // 10*10*10 * 8*8*8 = 1000 * 512 = 512000
    try std.testing.expectEqual(@as(u64, 512000), config.totalThreads());
}

test "LaunchConfig totalThreads with large values" {
    const config = LaunchConfig{
        .grid = .{ 65535, 65535, 1 },
        .block = .{ 1024, 1, 1 },
    };
    // Should not overflow due to u64 arithmetic
    const total = config.totalThreads();
    try std.testing.expect(total > 4294967295); // > u32 max
}

test "LaunchConfig validation valid configs" {
    // Default config should be valid
    const default_config = LaunchConfig{};
    try default_config.validate();
    try std.testing.expect(default_config.isValid());

    // 1D config should be valid
    const config_1d = LaunchConfig.for1D(1000, 256);
    try config_1d.validate();

    // 2D config should be valid
    const config_2d = LaunchConfig.for2D(100, 100, 16, 16);
    try config_2d.validate();
}

test "LaunchConfig validation block size exceeds limit" {
    // Block with too many threads total
    const config = LaunchConfig{
        .block = .{ 32, 32, 2 }, // 32*32*2 = 2048 > 1024
    };
    try std.testing.expectError(LaunchConfigError.BlockSizeExceedsLimit, config.validate());
    try std.testing.expect(!config.isValid());
}

test "LaunchConfig validation zero dimensions" {
    // Zero block dimension
    const zero_block = LaunchConfig{
        .block = .{ 0, 1, 1 },
    };
    try std.testing.expectError(LaunchConfigError.ZeroBlockDimension, zero_block.validate());

    // Zero grid dimension
    const zero_grid = LaunchConfig{
        .grid = .{ 1, 0, 1 },
    };
    try std.testing.expectError(LaunchConfigError.ZeroGridDimension, zero_grid.validate());
}

test "LaunchConfig validation shared memory limit" {
    const config = LaunchConfig{
        .shared_mem = 100000, // 100KB > 48KB default limit
    };
    try std.testing.expectError(LaunchConfigError.SharedMemoryExceedsLimit, config.validate());
}

test "LaunchConfig validation grid size limit" {
    // Grid Y/Z dimension exceeds 65535
    const config = LaunchConfig{
        .grid = .{ 1, 70000, 1 }, // 70000 > 65535
    };
    try std.testing.expectError(LaunchConfigError.GridSizeExceedsLimit, config.validate());
}

test "LaunchConfig threadsPerBlock" {
    const config = LaunchConfig{
        .block = .{ 16, 16, 4 },
    };
    try std.testing.expectEqual(@as(u32, 1024), config.threadsPerBlock());
}

test "LaunchLimits constants" {
    // Verify limits are reasonable values
    try std.testing.expectEqual(@as(u32, 1024), LaunchLimits.max_threads_per_block);
    try std.testing.expectEqual(@as(u32, 65535), LaunchLimits.max_grid_dim_y);
    try std.testing.expectEqual(@as(u32, 49152), LaunchLimits.max_shared_memory_per_block);
}

test "DeviceBuffer edge cases" {
    // Zero pointer always invalid
    const buf1 = DeviceBuffer{ .ptr = 0, .size = 1024, .allocated = true };
    try std.testing.expect(!buf1.isValid());

    // Zero size always invalid
    const buf2 = DeviceBuffer{ .ptr = 0x1000, .size = 0, .allocated = true };
    try std.testing.expect(!buf2.isValid());

    // isValid() only checks ptr and size, not allocated field
    // A buffer with valid ptr/size but allocated=false is still considered valid
    const buf3 = DeviceBuffer{ .ptr = 0x1000, .size = 1024, .allocated = false };
    try std.testing.expect(buf3.isValid()); // ptr != 0 and size > 0 means valid
}

test "CudaError error set completeness" {
    // Verify critical error variants exist in the error set
    // These are compile-time verified - if any error doesn't exist, this won't compile
    const errors = [_]CudaError{
        CudaError.DriverNotFound,
        CudaError.InitFailed,
        CudaError.NoDevice,
        CudaError.InvalidDevice,
        CudaError.ContextCreateFailed,
        CudaError.ContextError,
        CudaError.OutOfMemory,
        CudaError.CopyFailed,
        CudaError.SyncFailed,
        CudaError.LaunchFailed,
        CudaError.ModuleLoadFailed,
        CudaError.FunctionNotFound,
        CudaError.InvalidArgument,
        CudaError.NotSupported,
        CudaError.NvrtcNotFound,
        CudaError.CompilationFailed,
        CudaError.Timeout,
        CudaError.PlatformNotSupported,
        CudaError.GpuError,
    };

    // Verify all errors are unique (they always are in an error set, but good to test)
    for (errors, 0..) |err1, i| {
        for (errors[i + 1 ..]) |err2| {
            try std.testing.expect(err1 != err2);
        }
    }
}

test "CUDA_SUCCESS constant" {
    try std.testing.expectEqual(@as(i32, 0), CUDA_SUCCESS);
}
