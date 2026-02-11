// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Driver Dynamic Loader
//!
//! This module provides dynamic loading of the NVIDIA CUDA driver library.
//! It loads the driver at runtime using platform-specific mechanisms, allowing
//! the application to gracefully handle systems without CUDA installed.
//!
//! ## Supported Platforms
//! - Linux (x86_64, aarch64) - Full support via libcuda.so
//! - macOS (x86_64, aarch64) - Support via libcuda.dylib (requires CUDA toolkit)
//! - Windows (x86_64) - Support via nvcuda.dll
//! - Other platforms return an unavailable driver
//!
//! ## Usage
//! ```zig
//! var driver = CudaDriver.init();
//! defer driver.deinit();
//!
//! if (driver.available()) {
//!     _ = driver.cuInit(0);
//!     var count: i32 = 0;
//!     _ = driver.cuDeviceGetCount(&count);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

// Re-export types for convenience
pub const CUresult = types.CUresult;
pub const CUdevice = types.CUdevice;
pub const CUdeviceptr = types.CUdeviceptr;
pub const CUcontext = types.CUcontext;
pub const CUmodule = types.CUmodule;
pub const CUfunction = types.CUfunction;
pub const CUstream = types.CUstream;
pub const CUevent = types.CUevent;
pub const CUdevice_attribute = types.CUdevice_attribute;
pub const ComputeArch = types.ComputeArch;
pub const CudaError = types.CudaError;
pub const CUDA_SUCCESS = types.CUDA_SUCCESS;
pub const RTLD_LAZY = types.RTLD_LAZY;
pub const RTLD_NOW = types.RTLD_NOW;

// ============================================================================
// Platform Detection
// ============================================================================

/// Supported operating systems for CUDA
pub const Platform = enum {
    linux,
    macos,
    windows,
    unsupported,
};

/// Get current platform
pub fn getPlatform() Platform {
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
        else => .unsupported,
    };
}

/// Check if current platform is supported
pub fn isPlatformSupported() bool {
    return getPlatform() != .unsupported;
}

// ============================================================================
// Dynamic Loader (Cross-Platform using std.DynLib)
// ============================================================================

// Wrapper around std.DynLib for cross-platform dynamic loading
const DynLib = struct {
    inner: ?std.DynLib,

    const Self = @This();

    fn open(path: [*:0]const u8) Self {
        const lib = std.DynLib.open(std.mem.span(path)) catch return .{ .inner = null };
        return .{ .inner = lib };
    }

    fn openMultiple(paths: []const [*:0]const u8) Self {
        for (paths) |path| {
            const lib = open(path);
            if (lib.inner != null) return lib;
        }
        return .{ .inner = null };
    }

    fn close(self: *Self) void {
        if (self.inner) |*lib| {
            lib.close();
            self.inner = null;
        }
    }

    fn getSymbol(self: Self, name: [*:0]const u8) ?*anyopaque {
        if (self.inner) |lib| {
            // Use lookup which returns optional - need mutable copy
            var mutable_lib = lib;
            return mutable_lib.lookup(*anyopaque, std.mem.span(name));
        }
        return null;
    }
};

// Library names per platform
const cuda_lib_names = switch (builtin.os.tag) {
    .linux => &[_][*:0]const u8{ "libcuda.so.1", "libcuda.so" },
    .macos => &[_][*:0]const u8{ "libcuda.dylib", "/usr/local/cuda/lib/libcuda.dylib" },
    .windows => &[_][*:0]const u8{"nvcuda.dll"},
    else => &[_][*:0]const u8{},
};

// ============================================================================
// CUDA Function Pointer Types
// ============================================================================

// Initialization and version
const cuInit_t = *const fn (u32) callconv(.c) CUresult;
const cuDriverGetVersion_t = *const fn (*i32) callconv(.c) CUresult;

// Error handling (#25 - CUDA error string support)
const cuGetErrorString_t = *const fn (CUresult, *[*:0]const u8) callconv(.c) CUresult;
const cuGetErrorName_t = *const fn (CUresult, *[*:0]const u8) callconv(.c) CUresult;

// Device management
const cuDeviceGetCount_t = *const fn (*i32) callconv(.c) CUresult;
const cuDeviceGet_t = *const fn (*CUdevice, i32) callconv(.c) CUresult;
const cuDeviceGetName_t = *const fn ([*]u8, i32, CUdevice) callconv(.c) CUresult;
const cuDeviceTotalMem_t = *const fn (*usize, CUdevice) callconv(.c) CUresult;
const cuDeviceGetAttribute_t = *const fn (*i32, CUdevice_attribute, CUdevice) callconv(.c) CUresult;

// Context management
const cuCtxCreate_t = *const fn (*CUcontext, u32, CUdevice) callconv(.c) CUresult;
const cuCtxDestroy_t = *const fn (CUcontext) callconv(.c) CUresult;
const cuCtxSynchronize_t = *const fn () callconv(.c) CUresult;
const cuCtxGetCurrent_t = *const fn (*?CUcontext) callconv(.c) CUresult;
const cuCtxSetCurrent_t = *const fn (?CUcontext) callconv(.c) CUresult;
const cuCtxPushCurrent_t = *const fn (CUcontext) callconv(.c) CUresult;
const cuCtxPopCurrent_t = *const fn (*?CUcontext) callconv(.c) CUresult;

// Memory management
const cuMemAlloc_t = *const fn (*CUdeviceptr, usize) callconv(.c) CUresult;
const cuMemFree_t = *const fn (CUdeviceptr) callconv(.c) CUresult;
const cuMemAllocHost_t = *const fn (*?*anyopaque, usize) callconv(.c) CUresult;
const cuMemFreeHost_t = *const fn (*anyopaque) callconv(.c) CUresult;
const cuMemcpyHtoD_t = *const fn (CUdeviceptr, *const anyopaque, usize) callconv(.c) CUresult;
const cuMemcpyDtoH_t = *const fn (*anyopaque, CUdeviceptr, usize) callconv(.c) CUresult;
const cuMemcpyDtoD_t = *const fn (CUdeviceptr, CUdeviceptr, usize) callconv(.c) CUresult;
const cuMemsetD8_t = *const fn (CUdeviceptr, u8, usize) callconv(.c) CUresult;
const cuMemsetD32_t = *const fn (CUdeviceptr, u32, usize) callconv(.c) CUresult;
const cuMemGetInfo_t = *const fn (*usize, *usize) callconv(.c) CUresult;

// Async memory operations
const cuMemcpyHtoDAsync_t = *const fn (CUdeviceptr, *const anyopaque, usize, CUstream) callconv(.c) CUresult;
const cuMemcpyDtoHAsync_t = *const fn (*anyopaque, CUdeviceptr, usize, CUstream) callconv(.c) CUresult;

// Unified memory
const cuMemAllocManaged_t = *const fn (*CUdeviceptr, usize, u32) callconv(.c) CUresult;
const cuMemPrefetchAsync_t = *const fn (CUdeviceptr, usize, CUdevice, CUstream) callconv(.c) CUresult;
const cuMemAdvise_t = *const fn (CUdeviceptr, usize, i32, CUdevice) callconv(.c) CUresult;
const cuPointerGetAttribute_t = *const fn (*anyopaque, i32, CUdeviceptr) callconv(.c) CUresult;

// Module management
const cuModuleLoadData_t = *const fn (*CUmodule, *const anyopaque) callconv(.c) CUresult;
const cuModuleLoadDataEx_t = *const fn (*CUmodule, *const anyopaque, u32, [*]i32, [*]*anyopaque) callconv(.c) CUresult;
const cuModuleLoad_t = *const fn (*CUmodule, [*:0]const u8) callconv(.c) CUresult;
const cuModuleUnload_t = *const fn (CUmodule) callconv(.c) CUresult;
const cuModuleGetFunction_t = *const fn (*CUfunction, CUmodule, [*:0]const u8) callconv(.c) CUresult;

// Kernel launch
const cuLaunchKernel_t = *const fn (
    CUfunction,
    u32,
    u32,
    u32, // grid dim
    u32,
    u32,
    u32, // block dim
    u32, // shared mem
    CUstream, // stream
    ?[*]?*anyopaque, // kernel params
    ?[*]?*anyopaque, // extra
) callconv(.c) CUresult;

// Stream management
const cuStreamCreate_t = *const fn (*CUstream, u32) callconv(.c) CUresult;
const cuStreamCreateWithPriority_t = *const fn (*CUstream, u32, i32) callconv(.c) CUresult;
const cuStreamDestroy_t = *const fn (CUstream) callconv(.c) CUresult;
const cuStreamSynchronize_t = *const fn (CUstream) callconv(.c) CUresult;
const cuStreamQuery_t = *const fn (CUstream) callconv(.c) CUresult;
const cuStreamGetPriority_t = *const fn (CUstream, *i32) callconv(.c) CUresult;
const cuCtxGetStreamPriorityRange_t = *const fn (*i32, *i32) callconv(.c) CUresult;

// Event management
const cuEventCreate_t = *const fn (*CUevent, u32) callconv(.c) CUresult;
const cuEventDestroy_t = *const fn (CUevent) callconv(.c) CUresult;
const cuEventRecord_t = *const fn (CUevent, CUstream) callconv(.c) CUresult;
const cuEventSynchronize_t = *const fn (CUevent) callconv(.c) CUresult;
const cuEventElapsedTime_t = *const fn (*f32, CUevent, CUevent) callconv(.c) CUresult;
const cuEventQuery_t = *const fn (CUevent) callconv(.c) CUresult;

// Multi-GPU / Peer access
const cuDeviceCanAccessPeer_t = *const fn (*i32, CUdevice, CUdevice) callconv(.c) CUresult;
const cuCtxEnablePeerAccess_t = *const fn (CUcontext, u32) callconv(.c) CUresult;
const cuCtxDisablePeerAccess_t = *const fn (CUcontext) callconv(.c) CUresult;
const cuDeviceGetP2PAttribute_t = *const fn (*i32, i32, CUdevice, CUdevice) callconv(.c) CUresult;

// Occupancy calculator
const cuOccupancyMaxActiveBlocksPerMultiprocessor_t = *const fn (*i32, CUfunction, i32, usize) callconv(.c) CUresult;
const cuOccupancyMaxPotentialBlockSize_t = *const fn (*i32, *i32, CUfunction, ?*const fn (i32) callconv(.c) usize, usize, i32) callconv(.c) CUresult;
const cuFuncGetAttribute_t = *const fn (*i32, i32, CUfunction) callconv(.c) CUresult;

// ============================================================================
// CUDA Driver
// ============================================================================

/// CUDA Driver - dynamically loaded CUDA driver API
pub const CudaDriver = struct {
    /// Dynamic library wrapper for cross-platform loading
    lib: DynLib,

    // Initialization
    cuInit_fn: ?cuInit_t = null,
    cuDriverGetVersion_fn: ?cuDriverGetVersion_t = null,

    // Error handling (#25)
    cuGetErrorString_fn: ?cuGetErrorString_t = null,
    cuGetErrorName_fn: ?cuGetErrorName_t = null,

    // Device management
    cuDeviceGetCount_fn: ?cuDeviceGetCount_t = null,
    cuDeviceGet_fn: ?cuDeviceGet_t = null,
    cuDeviceGetName_fn: ?cuDeviceGetName_t = null,
    cuDeviceTotalMem_fn: ?cuDeviceTotalMem_t = null,
    cuDeviceGetAttribute_fn: ?cuDeviceGetAttribute_t = null,

    // Context management
    cuCtxCreate_fn: ?cuCtxCreate_t = null,
    cuCtxDestroy_fn: ?cuCtxDestroy_t = null,
    cuCtxSynchronize_fn: ?cuCtxSynchronize_t = null,
    cuCtxGetCurrent_fn: ?cuCtxGetCurrent_t = null,
    cuCtxSetCurrent_fn: ?cuCtxSetCurrent_t = null,
    cuCtxPushCurrent_fn: ?cuCtxPushCurrent_t = null,
    cuCtxPopCurrent_fn: ?cuCtxPopCurrent_t = null,

    // Memory management
    cuMemAlloc_fn: ?cuMemAlloc_t = null,
    cuMemFree_fn: ?cuMemFree_t = null,
    cuMemAllocHost_fn: ?cuMemAllocHost_t = null,
    cuMemFreeHost_fn: ?cuMemFreeHost_t = null,
    cuMemcpyHtoD_fn: ?cuMemcpyHtoD_t = null,
    cuMemcpyDtoH_fn: ?cuMemcpyDtoH_t = null,
    cuMemcpyDtoD_fn: ?cuMemcpyDtoD_t = null,
    cuMemsetD8_fn: ?cuMemsetD8_t = null,
    cuMemsetD32_fn: ?cuMemsetD32_t = null,
    cuMemGetInfo_fn: ?cuMemGetInfo_t = null,

    // Async memory
    cuMemcpyHtoDAsync_fn: ?cuMemcpyHtoDAsync_t = null,
    cuMemcpyDtoHAsync_fn: ?cuMemcpyDtoHAsync_t = null,

    // Unified memory
    cuMemAllocManaged_fn: ?cuMemAllocManaged_t = null,
    cuMemPrefetchAsync_fn: ?cuMemPrefetchAsync_t = null,
    cuMemAdvise_fn: ?cuMemAdvise_t = null,

    // Module management
    cuModuleLoadData_fn: ?cuModuleLoadData_t = null,
    cuModuleLoadDataEx_fn: ?cuModuleLoadDataEx_t = null,
    cuModuleLoad_fn: ?cuModuleLoad_t = null,
    cuModuleUnload_fn: ?cuModuleUnload_t = null,
    cuModuleGetFunction_fn: ?cuModuleGetFunction_t = null,

    // Kernel launch
    cuLaunchKernel_fn: ?cuLaunchKernel_t = null,

    // Stream management
    cuStreamCreate_fn: ?cuStreamCreate_t = null,
    cuStreamCreateWithPriority_fn: ?cuStreamCreateWithPriority_t = null,
    cuStreamDestroy_fn: ?cuStreamDestroy_t = null,
    cuStreamSynchronize_fn: ?cuStreamSynchronize_t = null,
    cuStreamQuery_fn: ?cuStreamQuery_t = null,
    cuStreamGetPriority_fn: ?cuStreamGetPriority_t = null,
    cuCtxGetStreamPriorityRange_fn: ?cuCtxGetStreamPriorityRange_t = null,

    // Event management
    cuEventCreate_fn: ?cuEventCreate_t = null,
    cuEventDestroy_fn: ?cuEventDestroy_t = null,
    cuEventRecord_fn: ?cuEventRecord_t = null,
    cuEventSynchronize_fn: ?cuEventSynchronize_t = null,
    cuEventElapsedTime_fn: ?cuEventElapsedTime_t = null,
    cuEventQuery_fn: ?cuEventQuery_t = null,

    // Multi-GPU / Peer access
    cuDeviceCanAccessPeer_fn: ?cuDeviceCanAccessPeer_t = null,
    cuCtxEnablePeerAccess_fn: ?cuCtxEnablePeerAccess_t = null,
    cuCtxDisablePeerAccess_fn: ?cuCtxDisablePeerAccess_t = null,
    cuDeviceGetP2PAttribute_fn: ?cuDeviceGetP2PAttribute_t = null,

    // Occupancy calculator
    cuOccupancyMaxActiveBlocksPerMultiprocessor_fn: ?cuOccupancyMaxActiveBlocksPerMultiprocessor_t = null,
    cuOccupancyMaxPotentialBlockSize_fn: ?cuOccupancyMaxPotentialBlockSize_t = null,
    cuFuncGetAttribute_fn: ?cuFuncGetAttribute_t = null,

    /// Initialize the CUDA driver by loading the platform-specific library
    pub fn init() CudaDriver {
        // Check platform support
        if (!isPlatformSupported()) {
            return .{ .lib = .{ .inner = null } };
        }

        // Try to load CUDA library using platform-specific mechanism
        const lib = DynLib.openMultiple(cuda_lib_names);
        if (lib.inner == null) {
            return .{ .lib = .{ .inner = null } };
        }

        var driver = CudaDriver{ .lib = lib };

        // Load essential symbols
        driver.cuInit_fn = loadSymbolFrom(cuInit_t, lib, "cuInit");
        driver.cuDriverGetVersion_fn = loadSymbolFrom(cuDriverGetVersion_t, lib, "cuDriverGetVersion");

        // Error handling (#25 - CUDA error string support)
        driver.cuGetErrorString_fn = loadSymbolFrom(cuGetErrorString_t, lib, "cuGetErrorString");
        driver.cuGetErrorName_fn = loadSymbolFrom(cuGetErrorName_t, lib, "cuGetErrorName");
        driver.cuDeviceGetCount_fn = loadSymbolFrom(cuDeviceGetCount_t, lib, "cuDeviceGetCount");
        driver.cuDeviceGet_fn = loadSymbolFrom(cuDeviceGet_t, lib, "cuDeviceGet");
        driver.cuDeviceGetName_fn = loadSymbolFrom(cuDeviceGetName_t, lib, "cuDeviceGetName");
        driver.cuDeviceTotalMem_fn = loadSymbolFrom(cuDeviceTotalMem_t, lib, "cuDeviceTotalMem_v2");
        driver.cuDeviceGetAttribute_fn = loadSymbolFrom(cuDeviceGetAttribute_t, lib, "cuDeviceGetAttribute");

        // Context management
        driver.cuCtxCreate_fn = loadSymbolFrom(cuCtxCreate_t, lib, "cuCtxCreate_v2");
        driver.cuCtxDestroy_fn = loadSymbolFrom(cuCtxDestroy_t, lib, "cuCtxDestroy_v2");
        driver.cuCtxSynchronize_fn = loadSymbolFrom(cuCtxSynchronize_t, lib, "cuCtxSynchronize");
        driver.cuCtxGetCurrent_fn = loadSymbolFrom(cuCtxGetCurrent_t, lib, "cuCtxGetCurrent");
        driver.cuCtxSetCurrent_fn = loadSymbolFrom(cuCtxSetCurrent_t, lib, "cuCtxSetCurrent");
        driver.cuCtxPushCurrent_fn = loadSymbolFrom(cuCtxPushCurrent_t, lib, "cuCtxPushCurrent_v2");
        driver.cuCtxPopCurrent_fn = loadSymbolFrom(cuCtxPopCurrent_t, lib, "cuCtxPopCurrent_v2");

        // Memory management
        driver.cuMemAlloc_fn = loadSymbolFrom(cuMemAlloc_t, lib, "cuMemAlloc_v2");
        driver.cuMemFree_fn = loadSymbolFrom(cuMemFree_t, lib, "cuMemFree_v2");
        driver.cuMemAllocHost_fn = loadSymbolFrom(cuMemAllocHost_t, lib, "cuMemAllocHost_v2");
        driver.cuMemFreeHost_fn = loadSymbolFrom(cuMemFreeHost_t, lib, "cuMemFreeHost");
        driver.cuMemcpyHtoD_fn = loadSymbolFrom(cuMemcpyHtoD_t, lib, "cuMemcpyHtoD_v2");
        driver.cuMemcpyDtoH_fn = loadSymbolFrom(cuMemcpyDtoH_t, lib, "cuMemcpyDtoH_v2");
        driver.cuMemcpyDtoD_fn = loadSymbolFrom(cuMemcpyDtoD_t, lib, "cuMemcpyDtoD_v2");
        driver.cuMemsetD8_fn = loadSymbolFrom(cuMemsetD8_t, lib, "cuMemsetD8_v2");
        driver.cuMemsetD32_fn = loadSymbolFrom(cuMemsetD32_t, lib, "cuMemsetD32_v2");
        driver.cuMemGetInfo_fn = loadSymbolFrom(cuMemGetInfo_t, lib, "cuMemGetInfo_v2");

        // Async memory
        driver.cuMemcpyHtoDAsync_fn = loadSymbolFrom(cuMemcpyHtoDAsync_t, lib, "cuMemcpyHtoDAsync_v2");
        driver.cuMemcpyDtoHAsync_fn = loadSymbolFrom(cuMemcpyDtoHAsync_t, lib, "cuMemcpyDtoHAsync_v2");

        // Unified memory
        driver.cuMemAllocManaged_fn = loadSymbolFrom(cuMemAllocManaged_t, lib, "cuMemAllocManaged");
        driver.cuMemPrefetchAsync_fn = loadSymbolFrom(cuMemPrefetchAsync_t, lib, "cuMemPrefetchAsync");
        driver.cuMemAdvise_fn = loadSymbolFrom(cuMemAdvise_t, lib, "cuMemAdvise");

        // Module management
        driver.cuModuleLoadData_fn = loadSymbolFrom(cuModuleLoadData_t, lib, "cuModuleLoadData");
        driver.cuModuleLoadDataEx_fn = loadSymbolFrom(cuModuleLoadDataEx_t, lib, "cuModuleLoadDataEx");
        driver.cuModuleLoad_fn = loadSymbolFrom(cuModuleLoad_t, lib, "cuModuleLoad");
        driver.cuModuleUnload_fn = loadSymbolFrom(cuModuleUnload_t, lib, "cuModuleUnload");
        driver.cuModuleGetFunction_fn = loadSymbolFrom(cuModuleGetFunction_t, lib, "cuModuleGetFunction");

        // Kernel launch
        driver.cuLaunchKernel_fn = loadSymbolFrom(cuLaunchKernel_t, lib, "cuLaunchKernel");

        // Stream management
        driver.cuStreamCreate_fn = loadSymbolFrom(cuStreamCreate_t, lib, "cuStreamCreate");
        driver.cuStreamCreateWithPriority_fn = loadSymbolFrom(cuStreamCreateWithPriority_t, lib, "cuStreamCreateWithPriority");
        driver.cuStreamDestroy_fn = loadSymbolFrom(cuStreamDestroy_t, lib, "cuStreamDestroy_v2");
        driver.cuStreamSynchronize_fn = loadSymbolFrom(cuStreamSynchronize_t, lib, "cuStreamSynchronize");
        driver.cuStreamQuery_fn = loadSymbolFrom(cuStreamQuery_t, lib, "cuStreamQuery");
        driver.cuStreamGetPriority_fn = loadSymbolFrom(cuStreamGetPriority_t, lib, "cuStreamGetPriority");
        driver.cuCtxGetStreamPriorityRange_fn = loadSymbolFrom(cuCtxGetStreamPriorityRange_t, lib, "cuCtxGetStreamPriorityRange");

        // Event management
        driver.cuEventCreate_fn = loadSymbolFrom(cuEventCreate_t, lib, "cuEventCreate");
        driver.cuEventDestroy_fn = loadSymbolFrom(cuEventDestroy_t, lib, "cuEventDestroy_v2");
        driver.cuEventRecord_fn = loadSymbolFrom(cuEventRecord_t, lib, "cuEventRecord");
        driver.cuEventSynchronize_fn = loadSymbolFrom(cuEventSynchronize_t, lib, "cuEventSynchronize");
        driver.cuEventElapsedTime_fn = loadSymbolFrom(cuEventElapsedTime_t, lib, "cuEventElapsedTime");
        driver.cuEventQuery_fn = loadSymbolFrom(cuEventQuery_t, lib, "cuEventQuery");

        // Multi-GPU / Peer access
        driver.cuDeviceCanAccessPeer_fn = loadSymbolFrom(cuDeviceCanAccessPeer_t, lib, "cuDeviceCanAccessPeer");
        driver.cuCtxEnablePeerAccess_fn = loadSymbolFrom(cuCtxEnablePeerAccess_t, lib, "cuCtxEnablePeerAccess");
        driver.cuCtxDisablePeerAccess_fn = loadSymbolFrom(cuCtxDisablePeerAccess_t, lib, "cuCtxDisablePeerAccess");
        driver.cuDeviceGetP2PAttribute_fn = loadSymbolFrom(cuDeviceGetP2PAttribute_t, lib, "cuDeviceGetP2PAttribute");

        // Occupancy calculator
        driver.cuOccupancyMaxActiveBlocksPerMultiprocessor_fn = loadSymbolFrom(cuOccupancyMaxActiveBlocksPerMultiprocessor_t, lib, "cuOccupancyMaxActiveBlocksPerMultiprocessor");
        driver.cuOccupancyMaxPotentialBlockSize_fn = loadSymbolFrom(cuOccupancyMaxPotentialBlockSize_t, lib, "cuOccupancyMaxPotentialBlockSize");
        driver.cuFuncGetAttribute_fn = loadSymbolFrom(cuFuncGetAttribute_t, lib, "cuFuncGetAttribute");

        // Verify essential symbols loaded
        if (driver.cuInit_fn == null or driver.cuDeviceGetCount_fn == null) {
            var lib_to_close = driver.lib;
            lib_to_close.close();
            return .{ .lib = .{ .inner = null } };
        }

        return driver;
    }

    /// Clean up and unload the CUDA driver
    pub fn deinit(self: *CudaDriver) void {
        self.lib.close();
    }

    /// Check if CUDA driver is available
    pub fn available(self: *const CudaDriver) bool {
        return self.lib.inner != null and self.cuInit_fn != null;
    }

    /// Check if events are supported
    pub fn supportsEvents(self: *const CudaDriver) bool {
        return self.cuEventCreate_fn != null and
            self.cuEventDestroy_fn != null and
            self.cuEventRecord_fn != null and
            self.cuEventSynchronize_fn != null and
            self.cuEventElapsedTime_fn != null;
    }

    /// Check if streams are supported
    pub fn supportsStreams(self: *const CudaDriver) bool {
        return self.cuStreamCreate_fn != null and
            self.cuStreamDestroy_fn != null and
            self.cuStreamSynchronize_fn != null;
    }

    /// Check if async memory operations are supported
    pub fn supportsAsyncMemory(self: *const CudaDriver) bool {
        return self.cuMemcpyHtoDAsync_fn != null and self.cuMemcpyDtoHAsync_fn != null;
    }

    // ========================================================================
    // CUDA API Wrappers
    // ========================================================================

    // Initialization
    pub fn cuInit(self: *const CudaDriver, flags: u32) CUresult {
        if (self.cuInit_fn) |fn_ptr| return fn_ptr(flags);
        return -1;
    }

    pub fn cuDriverGetVersion(self: *const CudaDriver, version: *i32) CUresult {
        if (self.cuDriverGetVersion_fn) |fn_ptr| return fn_ptr(version);
        return -1;
    }

    // Device management
    pub fn cuDeviceGetCount(self: *const CudaDriver, count: *i32) CUresult {
        if (self.cuDeviceGetCount_fn) |fn_ptr| return fn_ptr(count);
        return -1;
    }

    pub fn cuDeviceGet(self: *const CudaDriver, device: *CUdevice, ordinal: i32) CUresult {
        if (self.cuDeviceGet_fn) |fn_ptr| return fn_ptr(device, ordinal);
        return -1;
    }

    pub fn cuDeviceGetName(self: *const CudaDriver, name: [*]u8, len: i32, dev: CUdevice) CUresult {
        if (self.cuDeviceGetName_fn) |fn_ptr| return fn_ptr(name, len, dev);
        return -1;
    }

    pub fn cuDeviceTotalMem(self: *const CudaDriver, bytes: *usize, dev: CUdevice) CUresult {
        if (self.cuDeviceTotalMem_fn) |fn_ptr| return fn_ptr(bytes, dev);
        return -1;
    }

    pub fn cuDeviceGetAttribute(self: *const CudaDriver, value: *i32, attrib: CUdevice_attribute, dev: CUdevice) CUresult {
        if (self.cuDeviceGetAttribute_fn) |fn_ptr| return fn_ptr(value, attrib, dev);
        return -1;
    }

    /// Get device compute architecture
    pub fn getDeviceArch(self: *const CudaDriver, dev: CUdevice) ?ComputeArch {
        var major: i32 = 0;
        var minor: i32 = 0;

        if (self.cuDeviceGetAttribute(&major, .compute_capability_major, dev) != CUDA_SUCCESS) {
            return null;
        }
        if (self.cuDeviceGetAttribute(&minor, .compute_capability_minor, dev) != CUDA_SUCCESS) {
            return null;
        }

        return ComputeArch{
            .major = @intCast(major),
            .minor = @intCast(minor),
        };
    }

    // Context management
    pub fn cuCtxCreate(self: *const CudaDriver, ctx: *CUcontext, flags: u32, dev: CUdevice) CUresult {
        if (self.cuCtxCreate_fn) |fn_ptr| return fn_ptr(ctx, flags, dev);
        return -1;
    }

    pub fn cuCtxDestroy(self: *const CudaDriver, ctx: CUcontext) CUresult {
        if (self.cuCtxDestroy_fn) |fn_ptr| return fn_ptr(ctx);
        return -1;
    }

    pub fn cuCtxSynchronize(self: *const CudaDriver) CUresult {
        if (self.cuCtxSynchronize_fn) |fn_ptr| return fn_ptr();
        return -1;
    }

    pub fn cuCtxGetCurrent(self: *const CudaDriver, ctx: *?CUcontext) CUresult {
        if (self.cuCtxGetCurrent_fn) |fn_ptr| return fn_ptr(ctx);
        return -1;
    }

    pub fn cuCtxSetCurrent(self: *const CudaDriver, ctx: ?CUcontext) CUresult {
        if (self.cuCtxSetCurrent_fn) |fn_ptr| return fn_ptr(ctx);
        return -1;
    }

    /// Push context onto the context stack (#17)
    pub fn cuCtxPushCurrent(self: *const CudaDriver, ctx: CUcontext) CUresult {
        if (self.cuCtxPushCurrent_fn) |fn_ptr| return fn_ptr(ctx);
        return -1;
    }

    /// Pop context from the context stack (#17)
    pub fn cuCtxPopCurrent(self: *const CudaDriver, ctx: *?CUcontext) CUresult {
        if (self.cuCtxPopCurrent_fn) |fn_ptr| return fn_ptr(ctx);
        return -1;
    }

    /// Check if context stack operations are supported
    pub fn hasContextStack(self: *const CudaDriver) bool {
        return self.cuCtxPushCurrent_fn != null and self.cuCtxPopCurrent_fn != null;
    }

    // Memory management
    pub fn memAlloc(self: *const CudaDriver, dptr: *CUdeviceptr, bytesize: usize) CUresult {
        if (self.cuMemAlloc_fn) |fn_ptr| return fn_ptr(dptr, bytesize);
        return -1;
    }

    pub fn memFree(self: *const CudaDriver, dptr: CUdeviceptr) CUresult {
        if (self.cuMemFree_fn) |fn_ptr| return fn_ptr(dptr);
        return -1;
    }

    /// Allocate page-locked (pinned) host memory
    pub fn memAllocHost(self: *const CudaDriver, ptr: *?*anyopaque, bytesize: usize) CUresult {
        if (self.cuMemAllocHost_fn) |fn_ptr| return fn_ptr(ptr, bytesize);
        return -1;
    }

    /// Free page-locked host memory
    pub fn memFreeHost(self: *const CudaDriver, ptr: *anyopaque) CUresult {
        if (self.cuMemFreeHost_fn) |fn_ptr| return fn_ptr(ptr);
        return -1;
    }

    /// Check if pinned memory allocation is available
    pub fn hasPinnedMemory(self: *const CudaDriver) bool {
        return self.cuMemAllocHost_fn != null and self.cuMemFreeHost_fn != null;
    }

    pub fn memcpyHtoD(self: *const CudaDriver, dst: CUdeviceptr, src: *const anyopaque, size: usize) CUresult {
        if (self.cuMemcpyHtoD_fn) |fn_ptr| return fn_ptr(dst, src, size);
        return -1;
    }

    pub fn memcpyDtoH(self: *const CudaDriver, dst: *anyopaque, src: CUdeviceptr, size: usize) CUresult {
        if (self.cuMemcpyDtoH_fn) |fn_ptr| return fn_ptr(dst, src, size);
        return -1;
    }

    pub fn memcpyDtoD(self: *const CudaDriver, dst: CUdeviceptr, src: CUdeviceptr, size: usize) CUresult {
        if (self.cuMemcpyDtoD_fn) |fn_ptr| return fn_ptr(dst, src, size);
        return -1;
    }

    pub fn memsetD8(self: *const CudaDriver, dptr: CUdeviceptr, value: u8, count: usize) CUresult {
        if (self.cuMemsetD8_fn) |fn_ptr| return fn_ptr(dptr, value, count);
        return -1;
    }

    pub fn memsetD32(self: *const CudaDriver, dptr: CUdeviceptr, value: u32, count: usize) CUresult {
        if (self.cuMemsetD32_fn) |fn_ptr| return fn_ptr(dptr, value, count);
        return -1;
    }

    pub fn memGetInfo(self: *const CudaDriver, free: *usize, total: *usize) CUresult {
        if (self.cuMemGetInfo_fn) |fn_ptr| return fn_ptr(free, total);
        return -1;
    }

    // Async memory operations
    pub fn memcpyHtoDAsync(self: *const CudaDriver, dst: CUdeviceptr, src: *const anyopaque, size: usize, stream: CUstream) CUresult {
        if (self.cuMemcpyHtoDAsync_fn) |fn_ptr| return fn_ptr(dst, src, size, stream);
        return -1;
    }

    pub fn memcpyDtoHAsync(self: *const CudaDriver, dst: *anyopaque, src: CUdeviceptr, size: usize, stream: CUstream) CUresult {
        if (self.cuMemcpyDtoHAsync_fn) |fn_ptr| return fn_ptr(dst, src, size, stream);
        return -1;
    }

    // ========================================================================
    // Unified Memory
    // ========================================================================

    /// Allocate unified memory accessible from both host and device
    /// Flags: 1 = CU_MEM_ATTACH_GLOBAL (accessible from any stream on any device)
    ///        2 = CU_MEM_ATTACH_HOST (initially attached to host, faster for CPU access)
    pub fn memAllocManaged(self: *const CudaDriver, dptr: *CUdeviceptr, bytesize: usize, flags: u32) CUresult {
        if (self.cuMemAllocManaged_fn) |fn_ptr| return fn_ptr(dptr, bytesize, flags);
        return -1;
    }

    /// Prefetch unified memory to the specified device
    /// Use CU_DEVICE_CPU (-1) to prefetch to host memory
    pub fn memPrefetchAsync(self: *const CudaDriver, dptr: CUdeviceptr, count: usize, dst_device: CUdevice, stream: CUstream) CUresult {
        if (self.cuMemPrefetchAsync_fn) |fn_ptr| return fn_ptr(dptr, count, dst_device, stream);
        return -1;
    }

    /// Advise about expected memory access patterns
    pub fn memAdvise(self: *const CudaDriver, dptr: CUdeviceptr, count: usize, advice: i32, device: CUdevice) CUresult {
        if (self.cuMemAdvise_fn) |fn_ptr| return fn_ptr(dptr, count, advice, device);
        return -1;
    }

    /// Check if unified memory is supported
    pub fn hasUnifiedMemory(self: *const CudaDriver) bool {
        return self.cuMemAllocManaged_fn != null;
    }

    // Module management
    pub fn moduleLoadData(self: *const CudaDriver, module: *CUmodule, data: *const anyopaque) CUresult {
        if (self.cuModuleLoadData_fn) |fn_ptr| return fn_ptr(module, data);
        return -1;
    }

    /// Load module from file (CUBIN, PTX, or fatbin)
    pub fn moduleLoad(self: *const CudaDriver, module: *CUmodule, filename: [*:0]const u8) CUresult {
        if (self.cuModuleLoad_fn) |fn_ptr| return fn_ptr(module, filename);
        return -1;
    }

    /// Check if file-based module loading is supported
    pub fn hasModuleLoad(self: *const CudaDriver) bool {
        return self.cuModuleLoad_fn != null;
    }

    pub fn moduleUnload(self: *const CudaDriver, module: CUmodule) CUresult {
        if (self.cuModuleUnload_fn) |fn_ptr| return fn_ptr(module);
        return -1;
    }

    pub fn moduleGetFunction(self: *const CudaDriver, func: *CUfunction, module: CUmodule, name: [*:0]const u8) CUresult {
        if (self.cuModuleGetFunction_fn) |fn_ptr| return fn_ptr(func, module, name);
        return -1;
    }

    // Kernel launch
    pub fn launchKernel(
        self: *const CudaDriver,
        func: CUfunction,
        grid_dim: [3]u32,
        block_dim: [3]u32,
        shared_mem: u32,
        stream: CUstream,
        params: ?[*]?*anyopaque,
    ) CUresult {
        if (self.cuLaunchKernel_fn) |fn_ptr| {
            return fn_ptr(
                func,
                grid_dim[0],
                grid_dim[1],
                grid_dim[2],
                block_dim[0],
                block_dim[1],
                block_dim[2],
                shared_mem,
                stream,
                params,
                null,
            );
        }
        return -1;
    }

    // Stream management
    pub fn streamCreate(self: *const CudaDriver, stream: *CUstream, flags: u32) CUresult {
        if (self.cuStreamCreate_fn) |fn_ptr| {
            var s: ?*anyopaque = null;
            const result = fn_ptr(&s, flags);
            stream.* = s;
            return result;
        }
        return -1;
    }

    /// Create stream with priority (lower numbers = higher priority)
    pub fn streamCreateWithPriority(self: *const CudaDriver, stream: *CUstream, flags: u32, priority: i32) CUresult {
        if (self.cuStreamCreateWithPriority_fn) |fn_ptr| {
            var s: ?*anyopaque = null;
            const result = fn_ptr(&s, flags, priority);
            stream.* = s;
            return result;
        }
        return -1;
    }

    pub fn streamDestroy(self: *const CudaDriver, stream: CUstream) CUresult {
        if (self.cuStreamDestroy_fn) |fn_ptr| return fn_ptr(stream);
        return -1;
    }

    pub fn streamSynchronize(self: *const CudaDriver, stream: CUstream) CUresult {
        if (self.cuStreamSynchronize_fn) |fn_ptr| return fn_ptr(stream);
        return -1;
    }

    pub fn streamQuery(self: *const CudaDriver, stream: CUstream) CUresult {
        if (self.cuStreamQuery_fn) |fn_ptr| return fn_ptr(stream);
        return -1;
    }

    /// Get priority of a stream
    pub fn streamGetPriority(self: *const CudaDriver, stream: CUstream, priority: *i32) CUresult {
        if (self.cuStreamGetPriority_fn) |fn_ptr| return fn_ptr(stream, priority);
        return -1;
    }

    /// Get the range of stream priorities for the current context
    /// Returns least priority (highest number) and greatest priority (lowest number)
    pub fn getStreamPriorityRange(self: *const CudaDriver, least_priority: *i32, greatest_priority: *i32) CUresult {
        if (self.cuCtxGetStreamPriorityRange_fn) |fn_ptr| return fn_ptr(least_priority, greatest_priority);
        return -1;
    }

    /// Check if stream priority is supported
    pub fn supportsStreamPriority(self: *const CudaDriver) bool {
        return self.cuStreamCreateWithPriority_fn != null and self.cuCtxGetStreamPriorityRange_fn != null;
    }

    // Event management
    pub fn eventCreate(self: *const CudaDriver, event: *CUevent, flags: u32) CUresult {
        if (self.cuEventCreate_fn) |fn_ptr| return fn_ptr(event, flags);
        return -1;
    }

    pub fn eventDestroy(self: *const CudaDriver, event: CUevent) CUresult {
        if (self.cuEventDestroy_fn) |fn_ptr| return fn_ptr(event);
        return -1;
    }

    pub fn eventRecord(self: *const CudaDriver, event: CUevent, stream: CUstream) CUresult {
        if (self.cuEventRecord_fn) |fn_ptr| return fn_ptr(event, stream);
        return -1;
    }

    pub fn eventSynchronize(self: *const CudaDriver, event: CUevent) CUresult {
        if (self.cuEventSynchronize_fn) |fn_ptr| return fn_ptr(event);
        return -1;
    }

    pub fn eventElapsedTime(self: *const CudaDriver, ms: *f32, start: CUevent, end: CUevent) CUresult {
        if (self.cuEventElapsedTime_fn) |fn_ptr| return fn_ptr(ms, start, end);
        return -1;
    }

    pub fn eventQuery(self: *const CudaDriver, event: CUevent) CUresult {
        if (self.cuEventQuery_fn) |fn_ptr| return fn_ptr(event);
        return -1;
    }

    // ========================================================================
    // Multi-GPU / Peer Access
    // ========================================================================

    /// Check if device can access peer device memory directly
    pub fn deviceCanAccessPeer(self: *const CudaDriver, can_access: *i32, device: CUdevice, peer_device: CUdevice) CUresult {
        if (self.cuDeviceCanAccessPeer_fn) |fn_ptr| return fn_ptr(can_access, device, peer_device);
        return -1;
    }

    /// Enable peer access from current context to peer context
    pub fn ctxEnablePeerAccess(self: *const CudaDriver, peer_context: CUcontext, flags: u32) CUresult {
        if (self.cuCtxEnablePeerAccess_fn) |fn_ptr| return fn_ptr(peer_context, flags);
        return -1;
    }

    /// Disable peer access to peer context
    pub fn ctxDisablePeerAccess(self: *const CudaDriver, peer_context: CUcontext) CUresult {
        if (self.cuCtxDisablePeerAccess_fn) |fn_ptr| return fn_ptr(peer_context);
        return -1;
    }

    /// Get P2P attribute between two devices
    pub fn deviceGetP2PAttribute(self: *const CudaDriver, value: *i32, attribute: i32, src_device: CUdevice, dst_device: CUdevice) CUresult {
        if (self.cuDeviceGetP2PAttribute_fn) |fn_ptr| return fn_ptr(value, attribute, src_device, dst_device);
        return -1;
    }

    /// Check if peer access is supported
    pub fn supportsPeerAccess(self: *const CudaDriver) bool {
        return self.cuDeviceCanAccessPeer_fn != null and self.cuCtxEnablePeerAccess_fn != null;
    }

    // ========================================================================
    // Occupancy Calculator
    // ========================================================================

    /// Calculate maximum active blocks per multiprocessor for a kernel
    pub fn occupancyMaxActiveBlocksPerMultiprocessor(
        self: *const CudaDriver,
        num_blocks: *i32,
        func: CUfunction,
        block_size: i32,
        dynamic_smem_size: usize,
    ) CUresult {
        if (self.cuOccupancyMaxActiveBlocksPerMultiprocessor_fn) |fn_ptr| {
            return fn_ptr(num_blocks, func, block_size, dynamic_smem_size);
        }
        return -1;
    }

    /// Calculate optimal block size for maximum occupancy
    pub fn occupancyMaxPotentialBlockSize(
        self: *const CudaDriver,
        min_grid_size: *i32,
        block_size: *i32,
        func: CUfunction,
        block_size_to_smem: ?*const fn (i32) callconv(.c) usize,
        dynamic_smem_size: usize,
        block_size_limit: i32,
    ) CUresult {
        if (self.cuOccupancyMaxPotentialBlockSize_fn) |fn_ptr| {
            return fn_ptr(min_grid_size, block_size, func, block_size_to_smem, dynamic_smem_size, block_size_limit);
        }
        return -1;
    }

    /// Get function attribute
    pub fn funcGetAttribute(self: *const CudaDriver, value: *i32, attribute: i32, func: CUfunction) CUresult {
        if (self.cuFuncGetAttribute_fn) |fn_ptr| return fn_ptr(value, attribute, func);
        return -1;
    }

    /// Check if occupancy calculator is supported
    pub fn supportsOccupancy(self: *const CudaDriver) bool {
        return self.cuOccupancyMaxActiveBlocksPerMultiprocessor_fn != null;
    }

    // ========================================================================
    // Error Handling (#25 - CUDA error string support)
    // ========================================================================

    /// Get the description string for a CUDA error code
    pub fn getErrorString(self: *const CudaDriver, error_code: CUresult) ?[]const u8 {
        if (self.cuGetErrorString_fn) |fn_ptr| {
            var str_ptr: [*:0]const u8 = undefined;
            if (fn_ptr(error_code, &str_ptr) == CUDA_SUCCESS) {
                return std.mem.sliceTo(str_ptr, 0);
            }
        }
        return null;
    }

    /// Get the name string for a CUDA error code
    pub fn getErrorName(self: *const CudaDriver, error_code: CUresult) ?[]const u8 {
        if (self.cuGetErrorName_fn) |fn_ptr| {
            var str_ptr: [*:0]const u8 = undefined;
            if (fn_ptr(error_code, &str_ptr) == CUDA_SUCCESS) {
                return std.mem.sliceTo(str_ptr, 0);
            }
        }
        return null;
    }

    /// Check if error string functions are available
    pub fn supportsErrorStrings(self: *const CudaDriver) bool {
        return self.cuGetErrorString_fn != null and self.cuGetErrorName_fn != null;
    }

    /// Get formatted error message (name: description)
    pub fn formatError(self: *const CudaDriver, error_code: CUresult, buf: []u8) []const u8 {
        const name = self.getErrorName(error_code) orelse "UNKNOWN";
        const desc = self.getErrorString(error_code) orelse "Unknown error";

        const result = std.fmt.bufPrint(buf, "{s}: {s}", .{ name, desc }) catch {
            return "Error formatting failed";
        };
        return result;
    }

    // ========================================================================
    // Driver Version Checking (#26)
    // ========================================================================

    /// CUDA driver version information
    pub const DriverVersion = struct {
        major: u32,
        minor: u32,
        raw: i32,

        /// Format version as string (e.g., "12.3")
        pub fn format(self: DriverVersion, buf: []u8) []const u8 {
            return std.fmt.bufPrint(buf, "{d}.{d}", .{ self.major, self.minor }) catch "?.?";
        }

        /// Check if version meets minimum requirement
        pub fn atLeast(self: DriverVersion, min_major: u32, min_minor: u32) bool {
            if (self.major > min_major) return true;
            if (self.major == min_major and self.minor >= min_minor) return true;
            return false;
        }
    };

    /// Get the CUDA driver version
    pub fn getDriverVersion(self: *const CudaDriver) ?DriverVersion {
        if (self.cuDriverGetVersion_fn) |fn_ptr| {
            var version: i32 = 0;
            if (fn_ptr(&version) == CUDA_SUCCESS) {
                // CUDA version is encoded as (major * 1000 + minor * 10)
                const major: u32 = @intCast(@divTrunc(version, 1000));
                const minor: u32 = @intCast(@mod(@divTrunc(version, 10), 100));
                return DriverVersion{
                    .major = major,
                    .minor = minor,
                    .raw = version,
                };
            }
        }
        return null;
    }

    /// Check if driver version meets minimum requirement
    pub fn checkDriverVersion(self: *const CudaDriver, min_major: u32, min_minor: u32) bool {
        if (self.getDriverVersion()) |version| {
            return version.atLeast(min_major, min_minor);
        }
        return false;
    }

    /// Minimum recommended CUDA versions for features
    pub const MinVersions = struct {
        /// Unified memory (CUDA 6.0)
        pub const unified_memory: struct { major: u32, minor: u32 } = .{ .major = 6, .minor = 0 };
        /// Cooperative groups (CUDA 9.0)
        pub const cooperative_groups: struct { major: u32, minor: u32 } = .{ .major = 9, .minor = 0 };
        /// Graphs (CUDA 10.0)
        pub const graphs: struct { major: u32, minor: u32 } = .{ .major = 10, .minor = 0 };
        /// Async memory operations (CUDA 11.2)
        pub const async_memory: struct { major: u32, minor: u32 } = .{ .major = 11, .minor = 2 };
    };

    /// Get current platform
    pub fn platform(_: *const CudaDriver) Platform {
        return getPlatform();
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn loadSymbolFrom(comptime T: type, lib: DynLib, name: [*:0]const u8) ?T {
    const sym = lib.getSymbol(name) orelse return null;
    return @ptrCast(@alignCast(sym));
}

// ============================================================================
// Global Driver Instance (Thread-Safe Singleton)
// ============================================================================

var global_driver: ?CudaDriver = null;
var driver_init_once = std.once(initGlobalDriver);

fn initGlobalDriver() void {
    global_driver = CudaDriver.init();
}

/// Get the global CUDA driver instance (lazily initialized)
pub fn getDriver() *const CudaDriver {
    driver_init_once.call();
    if (global_driver) |*driver| return driver;
    unreachable;
}

/// Check if CUDA is available on this system
pub fn cudaAvailable() bool {
    return getDriver().available();
}

// ============================================================================
// Tests
// ============================================================================

test "CudaDriver init and availability check" {
    var driver = CudaDriver.init();
    defer driver.deinit();

    // Test passes whether CUDA is available or not
    if (driver.available()) {
        try std.testing.expect(driver.cuInit(0) == 0);
        var count: i32 = 0;
        const result = driver.cuDeviceGetCount(&count);
        try std.testing.expect(result == 0);
    } else {
        // CUDA not available - that's fine
        try std.testing.expect(driver.lib.inner == null);
    }
}

test "CudaDriver global instance" {
    const driver = getDriver();
    // Global driver should be initialized
    _ = driver.available();
}

test "CudaDriver device architecture detection" {
    var driver = CudaDriver.init();
    defer driver.deinit();

    if (!driver.available()) return;

    if (driver.cuInit(0) != CUDA_SUCCESS) return;

    var count: i32 = 0;
    if (driver.cuDeviceGetCount(&count) != CUDA_SUCCESS) return;
    if (count <= 0) return;

    var dev: CUdevice = 0;
    if (driver.cuDeviceGet(&dev, 0) != CUDA_SUCCESS) return;

    if (driver.getDeviceArch(dev)) |arch| {
        try std.testing.expect(arch.major >= 3); // At least Kepler
        try std.testing.expect(arch.minor <= 10); // Reasonable minor version
        _ = arch.name();
        _ = arch.computeString();
        _ = arch.smString();
    }
}
