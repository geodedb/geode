// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Multi-GPU and Device Management
//!
//! This module provides support for multi-GPU systems including device
//! enumeration, selection, peer access, and context management.
//!
//! ## Usage
//! ```zig
//! const devices = try Device.enumerate(&driver, allocator);
//! defer devices.deinit();
//!
//! // Enable peer access between GPUs
//! try devices.items[0].enablePeerAccess(&devices.items[1]);
//!
//! // Use specific device
//! try devices.items[0].makeCurrent();
//! ```

const std = @import("std");
const driver = @import("driver.zig");
const types = @import("types.zig");

// Re-exports
pub const CUdevice = types.CUdevice;
pub const CUcontext = types.CUcontext;
pub const CudaError = types.CudaError;
pub const CUDA_SUCCESS = types.CUDA_SUCCESS;

// ============================================================================
// Device
// ============================================================================

/// Represents a CUDA-capable GPU device
pub const Device = struct {
    /// Device ordinal (0-based index)
    ordinal: i32,
    /// Device handle
    handle: CUdevice,
    /// Device name
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,
    /// Total memory in bytes
    total_memory: usize = 0,
    /// Compute capability
    compute_major: u32 = 0,
    compute_minor: u32 = 0,
    /// Driver reference
    drv: *const driver.CudaDriver,
    /// Context for this device (if created)
    context: ?CUcontext = null,

    /// Get device name as slice
    pub fn getName(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Get compute capability as ComputeArch
    pub fn getArch(self: *const Device) types.ComputeArch {
        return types.ComputeArch{
            .major = self.compute_major,
            .minor = self.compute_minor,
        };
    }

    /// Get total memory in GB
    pub fn getTotalMemoryGB(self: *const Device) f64 {
        return @as(f64, @floatFromInt(self.total_memory)) / (1024 * 1024 * 1024);
    }

    /// Create a context for this device
    pub fn createContext(self: *Device, flags: u32) !void {
        if (self.context != null) return; // Already has context

        var ctx: CUcontext = undefined;
        const result = self.drv.cuCtxCreate(&ctx, flags, self.handle);
        if (result != CUDA_SUCCESS) {
            return CudaError.ContextCreateFailed;
        }
        self.context = ctx;
    }

    /// Destroy this device's context
    pub fn destroyContext(self: *Device) void {
        if (self.context) |ctx| {
            _ = self.drv.cuCtxDestroy(ctx);
            self.context = null;
        }
    }

    /// Make this device's context current
    pub fn makeCurrent(self: *const Device) !void {
        if (self.context) |ctx| {
            const result = self.drv.cuCtxSetCurrent(ctx);
            if (result != CUDA_SUCCESS) {
                return CudaError.ContextError;
            }
        } else {
            return CudaError.ContextError;
        }
    }

    /// Check if peer access to another device is possible
    pub fn canAccessPeer(self: *const Device, peer: *const Device) !bool {
        if (!self.drv.supportsPeerAccess()) return false;

        var can_access: i32 = 0;
        const result = self.drv.deviceCanAccessPeer(&can_access, self.handle, peer.handle);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
        return can_access != 0;
    }

    /// Enable peer access to another device's memory
    /// Requires both devices to have contexts created
    pub fn enablePeerAccess(self: *Device, peer: *Device) !void {
        if (self.context == null or peer.context == null) {
            return CudaError.ContextError;
        }
        if (!self.drv.supportsPeerAccess()) {
            return CudaError.NotSupported;
        }

        // First make our context current
        try self.makeCurrent();

        // Enable access to peer's context
        const result = self.drv.ctxEnablePeerAccess(peer.context.?, 0);
        if (result != CUDA_SUCCESS and result != 208) { // 208 = already enabled
            return CudaError.GpuError;
        }
    }

    /// Disable peer access to another device
    pub fn disablePeerAccess(self: *Device, peer: *Device) !void {
        if (self.context == null or peer.context == null) {
            return CudaError.ContextError;
        }

        try self.makeCurrent();
        _ = self.drv.ctxDisablePeerAccess(peer.context.?);
    }

    /// Get a device attribute
    pub fn getAttribute(self: *const Device, attribute: types.CUdevice_attribute) !i32 {
        var value: i32 = 0;
        const result = self.drv.cuDeviceGetAttribute(&value, attribute, self.handle);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
        return value;
    }

    /// Get number of multiprocessors
    pub fn getMultiprocessorCount(self: *const Device) !i32 {
        return self.getAttribute(.multiprocessor_count);
    }

    /// Get warp size
    pub fn getWarpSize(self: *const Device) !i32 {
        return self.getAttribute(.warp_size);
    }

    /// Get max threads per block
    pub fn getMaxThreadsPerBlock(self: *const Device) !i32 {
        return self.getAttribute(.max_threads_per_block);
    }

    /// Get max shared memory per block
    pub fn getMaxSharedMemoryPerBlock(self: *const Device) !i32 {
        return self.getAttribute(.max_shared_memory_per_block);
    }

    /// Check if this device supports unified memory
    pub fn supportsUnifiedMemory(self: *const Device) bool {
        const value = self.getAttribute(.managed_memory) catch return false;
        return value != 0;
    }

    // ========================================================================
    // Explicit Context Switching API (#17)
    // ========================================================================

    /// Push this device's context onto the context stack
    /// Use popContext to restore the previous context
    pub fn pushContext(self: *const Device) !void {
        if (self.context == null) {
            return CudaError.ContextError;
        }
        if (!self.drv.hasContextStack()) {
            return CudaError.NotSupported;
        }
        const result = self.drv.cuCtxPushCurrent(self.context.?);
        if (result != CUDA_SUCCESS) {
            return CudaError.ContextError;
        }
    }

    /// Pop context from the stack (restores previous context)
    /// Returns the popped context
    pub fn popContext(self: *const Device) !?CUcontext {
        if (!self.drv.hasContextStack()) {
            return CudaError.NotSupported;
        }
        var popped: ?CUcontext = null;
        const result = self.drv.cuCtxPopCurrent(&popped);
        if (result != CUDA_SUCCESS) {
            return CudaError.ContextError;
        }
        return popped;
    }

    /// Execute a function with this device's context active
    /// Automatically pushes/pops context around the call
    pub fn withContext(self: *const Device, func: *const fn () anyerror!void) !void {
        try self.pushContext();
        defer _ = self.popContext() catch {};
        try func();
    }

    /// Check if context stack operations are supported
    pub fn supportsContextStack(self: *const Device) bool {
        return self.drv.hasContextStack();
    }
};

// ============================================================================
// Device Enumeration
// ============================================================================

/// List of available CUDA devices
pub const DeviceList = struct {
    /// Devices
    items: []Device,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Driver reference
    drv: *const driver.CudaDriver,

    /// Clean up all device contexts
    pub fn deinit(self: *DeviceList) void {
        for (self.items) |*dev| {
            dev.destroyContext();
        }
        self.allocator.free(self.items);
    }

    /// Get device count
    pub fn count(self: *const DeviceList) usize {
        return self.items.len;
    }

    /// Get device by index
    pub fn get(self: *DeviceList, index: usize) ?*Device {
        if (index >= self.items.len) return null;
        return &self.items[index];
    }

    /// Create contexts for all devices
    pub fn createAllContexts(self: *DeviceList, flags: u32) !void {
        for (self.items) |*dev| {
            try dev.createContext(flags);
        }
    }

    /// Enable peer access between all devices that support it
    pub fn enableAllPeerAccess(self: *DeviceList) !void {
        for (self.items, 0..) |*dev, i| {
            for (self.items[i + 1 ..]) |*peer| {
                if (try dev.canAccessPeer(peer)) {
                    try dev.enablePeerAccess(peer);
                    try peer.enablePeerAccess(dev);
                }
            }
        }
    }
};

/// Enumerate all CUDA devices in the system
pub fn enumerate(drv: *const driver.CudaDriver, allocator: std.mem.Allocator) !DeviceList {
    if (!drv.available()) return CudaError.DriverNotFound;

    var count: i32 = 0;
    var result = drv.cuDeviceGetCount(&count);
    if (result != CUDA_SUCCESS) {
        return CudaError.GpuError;
    }

    if (count <= 0) {
        return DeviceList{
            .items = &[_]Device{},
            .allocator = allocator,
            .drv = drv,
        };
    }

    const devices = try allocator.alloc(Device, @intCast(count));
    errdefer allocator.free(devices);

    for (0..@intCast(count)) |i| {
        const ordinal: i32 = @intCast(i);
        var handle: CUdevice = 0;

        result = drv.cuDeviceGet(&handle, ordinal);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        var dev = Device{
            .ordinal = ordinal,
            .handle = handle,
            .drv = drv,
        };

        // Get device name
        result = drv.cuDeviceGetName(&dev.name, 255, handle);
        if (result == CUDA_SUCCESS) {
            dev.name_len = std.mem.indexOfScalar(u8, &dev.name, 0) orelse 0;
        }

        // Get total memory
        result = drv.cuDeviceTotalMem(&dev.total_memory, handle);

        // Get compute capability
        var major: i32 = 0;
        var minor: i32 = 0;
        _ = drv.cuDeviceGetAttribute(&major, .compute_capability_major, handle);
        _ = drv.cuDeviceGetAttribute(&minor, .compute_capability_minor, handle);
        dev.compute_major = @intCast(major);
        dev.compute_minor = @intCast(minor);

        devices[i] = dev;
    }

    return DeviceList{
        .items = devices,
        .allocator = allocator,
        .drv = drv,
    };
}

/// Get current device ordinal
pub fn getCurrentDevice(drv: *const driver.CudaDriver) !i32 {
    if (!drv.available()) return CudaError.DriverNotFound;

    var ctx: ?CUcontext = null;
    const result = drv.cuCtxGetCurrent(&ctx);
    if (result != CUDA_SUCCESS or ctx == null) {
        return CudaError.ContextError;
    }

    // We don't have a direct way to get device from context in driver API
    // Return 0 as default (primary device)
    return 0;
}

/// Get device count
pub fn getDeviceCount(drv: *const driver.CudaDriver) !i32 {
    if (!drv.available()) return CudaError.DriverNotFound;

    var count: i32 = 0;
    const result = drv.cuDeviceGetCount(&count);
    if (result != CUDA_SUCCESS) {
        return CudaError.GpuError;
    }
    return count;
}

/// Check if peer access is supported on this system
pub fn supportsPeerAccess(drv: *const driver.CudaDriver) bool {
    return drv.supportsPeerAccess();
}

// ============================================================================
// Context Stack Operations (#17)
// ============================================================================

/// Get the current context
pub fn getCurrentContext(drv: *const driver.CudaDriver) !?CUcontext {
    if (!drv.available()) return CudaError.DriverNotFound;

    var ctx: ?CUcontext = null;
    const result = drv.cuCtxGetCurrent(&ctx);
    if (result != CUDA_SUCCESS) {
        return CudaError.ContextError;
    }
    return ctx;
}

/// Push a context onto the stack
pub fn pushContext(drv: *const driver.CudaDriver, ctx: CUcontext) !void {
    if (!drv.hasContextStack()) return CudaError.NotSupported;
    const result = drv.cuCtxPushCurrent(ctx);
    if (result != CUDA_SUCCESS) {
        return CudaError.ContextError;
    }
}

/// Pop a context from the stack
pub fn popContext(drv: *const driver.CudaDriver) !?CUcontext {
    if (!drv.hasContextStack()) return CudaError.NotSupported;
    var ctx: ?CUcontext = null;
    const result = drv.cuCtxPopCurrent(&ctx);
    if (result != CUDA_SUCCESS) {
        return CudaError.ContextError;
    }
    return ctx;
}

/// RAII-style context scope that automatically pushes/pops context
/// Usage:
/// ```zig
/// var scope = try ContextScope.init(device);
/// defer scope.deinit();
/// // ... do work on device ...
/// ```
pub const ContextScope = struct {
    drv: *const driver.CudaDriver,
    prev_ctx: ?CUcontext,
    active: bool,

    /// Create a context scope, pushing the given device's context
    pub fn init(device: *const Device) !ContextScope {
        if (device.context == null) {
            return CudaError.ContextError;
        }

        // Save current context before switching
        const prev = getCurrentContext(device.drv) catch null;

        // Push the new context
        try pushContext(device.drv, device.context.?);

        return ContextScope{
            .drv = device.drv,
            .prev_ctx = prev,
            .active = true,
        };
    }

    /// Create a context scope from a raw context
    pub fn initFromContext(drv: *const driver.CudaDriver, ctx: CUcontext) !ContextScope {
        const prev = getCurrentContext(drv) catch null;
        try pushContext(drv, ctx);

        return ContextScope{
            .drv = drv,
            .prev_ctx = prev,
            .active = true,
        };
    }

    /// Restore previous context
    pub fn deinit(self: *ContextScope) void {
        if (!self.active) return;

        _ = popContext(self.drv) catch {};
        self.active = false;
    }

    /// Manually end the scope early
    pub fn end(self: *ContextScope) !void {
        if (!self.active) return CudaError.InvalidArgument;

        _ = try popContext(self.drv);
        self.active = false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Device struct size" {
    try std.testing.expect(@sizeOf(Device) > 0);
}

test "DeviceList empty" {
    // Can create an empty device list
    var list = DeviceList{
        .items = &[_]Device{},
        .allocator = std.testing.allocator,
        .drv = driver.getDriver(),
    };
    try std.testing.expectEqual(@as(usize, 0), list.count());
    list.deinit();
}

test "Device getName empty" {
    var dev = Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
    };
    try std.testing.expectEqualStrings("", dev.getName());
}

test "Device getArch" {
    var dev = Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
        .compute_major = 8,
        .compute_minor = 6,
    };
    const arch = dev.getArch();
    try std.testing.expectEqual(@as(u32, 8), arch.major);
    try std.testing.expectEqual(@as(u32, 6), arch.minor);
    try std.testing.expectEqualStrings("Ampere", arch.name());
}

test "Device getTotalMemoryGB" {
    var dev = Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
        .total_memory = 8 * 1024 * 1024 * 1024, // 8 GB
    };
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), dev.getTotalMemoryGB(), 0.01);
}

test "ContextScope struct size" {
    try std.testing.expect(@sizeOf(ContextScope) > 0);
}

test "Device context functions exist" {
    // Just verify the functions compile and are callable types
    const drv = driver.getDriver();
    _ = drv.hasContextStack();
}

test "Device supportsContextStack" {
    var dev = Device{
        .ordinal = 0,
        .handle = 0,
        .drv = driver.getDriver(),
    };
    // Should return false on systems without CUDA, true with CUDA
    _ = dev.supportsContextStack();
}
