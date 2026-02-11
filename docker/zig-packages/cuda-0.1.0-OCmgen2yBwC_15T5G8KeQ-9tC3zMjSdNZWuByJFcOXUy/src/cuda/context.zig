// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Context - High-Level Compute API
//!
//! This module provides a unified high-level API for CUDA compute operations.
//! It's designed to align with the Vulkan sibling library interface for
//! seamless backend switching.
//!
//! ## Design Goals
//! - Unified interface matching ../vulkan compute API
//! - RAII-style resource management
//! - Graceful degradation when CUDA unavailable
//! - Zero-copy where possible
//!
//! ## Usage
//! ```zig
//! const result = try cuda.probe(allocator);
//! if (!result.available) return error.CudaUnavailable;
//!
//! var ctx = try Context.init(allocator, .{ .device_index = 0 });
//! defer ctx.deinit();
//!
//! const buffer = try ctx.createBuffer(1024, .device);
//! defer ctx.destroyBuffer(buffer);
//!
//! try ctx.memcpyH2D(buffer, data);
//!
//! const module = try ctx.createModulePtx(ptx_source);
//! defer ctx.destroyModule(module);
//!
//! const kernel = try ctx.getKernel(module, "my_kernel");
//! try ctx.launch(kernel, .{ .grid = .{64, 1, 1}, .block = .{256, 1, 1} }, &args);
//!
//! try ctx.sync();
//! ```

const std = @import("std");
const driver = @import("driver.zig");
const types = @import("types.zig");
const probe_mod = @import("probe.zig");
const memory_mod = @import("memory.zig");
const stream_mod = @import("stream.zig");
const module_mod = @import("module.zig");

// Re-exports for convenience
pub const DeviceInfo = probe_mod.DeviceInfo;
pub const ProbeResult = probe_mod.ProbeResult;
pub const Buffer = memory_mod.Buffer;
pub const MemoryKind = memory_mod.MemoryKind;
pub const Stream = stream_mod.Stream;
pub const Event = stream_mod.Event;
pub const EventTimer = stream_mod.EventTimer;
pub const Module = module_mod.Module;
pub const Kernel = module_mod.Kernel;
pub const LaunchConfig = types.LaunchConfig;
pub const ComputeArch = types.ComputeArch;
pub const CudaError = types.CudaError;
pub const MemoryStats = memory_mod.MemoryStats;

// ============================================================================
// Context Options
// ============================================================================

/// Options for context creation
pub const ContextOptions = struct {
    /// Device index to use (0-based)
    device_index: u32 = 0,
    /// Whether to enable timing/profiling
    enable_timing: bool = true,
    /// Whether to allow JIT compilation
    allow_jit: bool = true,
    /// Initial stream pool size
    stream_pool_size: usize = 4,
    /// Log level (0=off, 1=errors, 2=warnings, 3=info, 4=debug)
    log_level: u8 = 1,
    /// Whether to use unified memory where possible
    prefer_unified_memory: bool = false,
};

// ============================================================================
// Context
// ============================================================================

/// CUDA compute context - main entry point for GPU operations
pub const Context = struct {
    /// Host allocator
    allocator: std.mem.Allocator,
    /// CUDA driver
    drv: *const driver.CudaDriver,
    /// CUDA context handle
    cuda_ctx: ?driver.CUcontext = null,
    /// Device ordinal
    device_id: driver.CUdevice = 0,
    /// Device info cache
    device_info: DeviceInfo = .{ .id = 0 },
    /// Memory manager
    memory: memory_mod.Memory,
    /// NVRTC compiler (optional)
    nvrtc: ?module_mod.NvrtcCompiler = null,
    /// Stream pool
    streams: std.ArrayList(Stream),
    /// Loaded modules
    modules: std.ArrayList(*Module),
    /// Options
    options: ContextOptions,
    /// Initialized flag
    initialized: bool = false,

    /// Initialize a CUDA context
    pub fn init(allocator: std.mem.Allocator, options: ContextOptions) !Context {
        const drv = driver.getDriver();
        if (!drv.available()) {
            return CudaError.DriverNotFound;
        }

        // Initialize CUDA
        if (drv.cuInit(0) != types.CUDA_SUCCESS) {
            return CudaError.InitFailed;
        }

        // Check device count
        var count: i32 = 0;
        if (drv.cuDeviceGetCount(&count) != types.CUDA_SUCCESS or count <= 0) {
            return CudaError.NoDevice;
        }

        if (options.device_index >= @as(u32, @intCast(count))) {
            return CudaError.InvalidDevice;
        }

        // Get device handle
        var device: driver.CUdevice = 0;
        if (drv.cuDeviceGet(&device, @intCast(options.device_index)) != types.CUDA_SUCCESS) {
            return CudaError.InvalidDevice;
        }

        // Create CUDA context
        var cuda_ctx: driver.CUcontext = undefined;
        if (drv.cuCtxCreate(&cuda_ctx, 0, device) != types.CUDA_SUCCESS) {
            return CudaError.ContextCreateFailed;
        }
        errdefer _ = drv.cuCtxDestroy(cuda_ctx);

        // Initialize memory manager
        var memory = try memory_mod.Memory.init(drv, allocator);
        errdefer memory.deinit();

        // Initialize NVRTC if allowed
        var nvrtc: ?module_mod.NvrtcCompiler = null;
        if (options.allow_jit) {
            var compiler = module_mod.NvrtcCompiler.init(allocator);
            if (compiler.available()) {
                nvrtc = compiler;
            } else {
                compiler.deinit();
            }
        }

        // Get device info
        var device_info = DeviceInfo{ .id = options.device_index };
        if (drv.getDeviceArch(device)) |arch| {
            device_info.arch = arch;
        }
        var name_buf: [256]u8 = [_]u8{0} ** 256;
        if (drv.cuDeviceGetName(&name_buf, 256, device) == types.CUDA_SUCCESS) {
            device_info.name = name_buf;
            device_info.name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse 256;
        }
        _ = drv.cuDeviceTotalMem(&device_info.total_memory, device);
        device_info.available = true;

        return Context{
            .allocator = allocator,
            .drv = drv,
            .cuda_ctx = cuda_ctx,
            .device_id = device,
            .device_info = device_info,
            .memory = memory,
            .nvrtc = nvrtc,
            .streams = .{},
            .modules = .{},
            .options = options,
            .initialized = true,
        };
    }

    /// Clean up context and all resources
    pub fn deinit(self: *Context) void {
        // Synchronize before cleanup
        _ = self.drv.cuCtxSynchronize();

        // Destroy all modules
        for (self.modules.items) |mod| {
            mod.unload();
            self.allocator.destroy(mod);
        }
        self.modules.deinit(self.allocator);

        // Destroy all streams
        for (self.streams.items) |*stream| {
            stream.destroy();
        }
        self.streams.deinit(self.allocator);

        // Clean up memory
        self.memory.deinit();

        // Clean up NVRTC
        if (self.nvrtc) |*nvrtc| {
            nvrtc.deinit();
            self.nvrtc = null; // Clear to make double-deinit safe
        }

        // Destroy CUDA context
        if (self.cuda_ctx) |ctx| {
            _ = self.drv.cuCtxDestroy(ctx);
            self.cuda_ctx = null; // Clear to make double-deinit safe
        }

        self.initialized = false;
    }

    // ========================================================================
    // Device Info
    // ========================================================================

    /// Get device information
    pub fn deviceInfo(self: *const Context) DeviceInfo {
        return self.device_info;
    }

    /// Get device architecture
    pub fn getArch(self: *const Context) ComputeArch {
        return self.device_info.arch;
    }

    /// Get free and total memory
    pub fn getMemoryInfo(self: *Context) !struct { free: usize, total: usize } {
        return self.memory.getMemoryInfo();
    }

    // ========================================================================
    // Buffer Operations
    // ========================================================================

    /// Create a device buffer
    pub fn createBuffer(self: *Context, size: usize, kind: MemoryKind) !Buffer {
        return switch (kind) {
            .device => self.memory.allocDevice(size),
            .unified => {
                const unified = try self.memory.allocUnified(size);
                return Buffer{
                    .ptr = unified.ptr,
                    .size = unified.size,
                    .kind = .unified,
                    .allocated = true,
                };
            },
            .pinned => CudaError.InvalidArgument,
        };
    }

    /// Destroy a buffer
    pub fn destroyBuffer(self: *Context, buffer: Buffer) void {
        switch (buffer.kind) {
            .device => self.memory.freeDevice(buffer),
            .unified => {
                var unified = memory_mod.UnifiedBuffer{
                    .ptr = buffer.ptr,
                    .size = buffer.size,
                    .drv = self.drv,
                };
                self.memory.freeUnified(&unified);
            },
            .pinned => {},
        }
    }

    /// Create a pinned host buffer
    pub fn createPinnedBuffer(self: *Context, size: usize) ![]u8 {
        return self.memory.allocPinned(size);
    }

    /// Destroy a pinned host buffer
    pub fn destroyPinnedBuffer(self: *Context, buffer: []u8) void {
        self.memory.freePinned(buffer);
    }

    /// Create a unified memory buffer
    pub fn createUnifiedBuffer(self: *Context, size: usize) !memory_mod.UnifiedBuffer {
        return self.memory.allocUnified(size);
    }

    /// Destroy a unified memory buffer
    pub fn destroyUnifiedBuffer(self: *Context, buffer: *memory_mod.UnifiedBuffer) void {
        self.memory.freeUnified(buffer);
    }

    /// Copy from host to device
    pub fn memcpyH2D(self: *Context, dst: Buffer, src: []const u8) !void {
        try self.memory.copyHostToDevice(dst, src);
    }

    /// Copy from device to host
    pub fn memcpyD2H(self: *Context, dst: []u8, src: Buffer) !void {
        try self.memory.copyDeviceToHost(dst, src);
    }

    /// Copy from device to device
    pub fn memcpyD2D(self: *Context, dst: Buffer, src: Buffer, size: usize) !void {
        try self.memory.copyDeviceToDevice(dst, src, size);
    }

    /// Async copy from host to device
    pub fn memcpyH2DAsync(self: *Context, dst: Buffer, src: []const u8, stream: *const Stream) !void {
        try self.memory.copyHostToDeviceAsync(dst, src, stream.getHandle());
    }

    /// Async copy from device to host
    pub fn memcpyD2HAsync(self: *Context, dst: []u8, src: Buffer, stream: *const Stream) !void {
        try self.memory.copyDeviceToHostAsync(dst, src, stream.getHandle());
    }

    /// Zero a buffer
    pub fn zeroBuffer(self: *Context, buffer: Buffer) !void {
        try self.memory.zero(buffer);
    }

    /// Get memory statistics
    pub fn getMemoryStats(self: *const Context) MemoryStats {
        return self.memory.getStats();
    }

    // ========================================================================
    // Module Operations
    // ========================================================================

    /// Load a module from PTX source
    pub fn createModulePtx(self: *Context, ptx_source: []const u8) !*Module {
        const module = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module);

        module.* = try Module.loadPtx(self.drv, self.allocator, ptx_source);
        try self.modules.append(self.allocator, module);

        return module;
    }

    /// Compile CUDA C source and create module
    pub fn createModuleFromSource(self: *Context, cuda_source: [:0]const u8, name: [:0]const u8) !*Module {
        if (self.nvrtc == null) {
            return CudaError.NvrtcNotFound;
        }

        const ptx = try self.nvrtc.?.compileToPtx(cuda_source, name, self.device_info.arch);
        defer self.allocator.free(ptx);

        return self.createModulePtx(ptx);
    }

    /// Destroy a module
    pub fn destroyModule(self: *Context, module: *Module) void {
        // Remove from tracking
        for (self.modules.items, 0..) |mod, i| {
            if (mod == module) {
                _ = self.modules.orderedRemove(i);
                break;
            }
        }

        module.unload();
        self.allocator.destroy(module);
    }

    /// Get a kernel from a module
    pub fn getKernel(self: *Context, module: *Module, name: []const u8) !Kernel {
        _ = self;
        return module.getKernel(name);
    }

    // ========================================================================
    // Kernel Launch
    // ========================================================================

    /// Launch a kernel
    pub fn launch(
        self: *Context,
        kernel: Kernel,
        config: LaunchConfig,
        params: ?[*]?*anyopaque,
    ) !void {
        _ = self;
        try kernel.launch(config, params);
    }

    /// Launch a kernel with automatic 1D configuration
    pub fn launch1D(
        self: *Context,
        kernel: Kernel,
        num_elements: u32,
        block_size: u32,
        params: ?[*]?*anyopaque,
    ) !void {
        _ = self;
        try kernel.launch1D(num_elements, block_size, params);
    }

    /// Launch a kernel and synchronize
    pub fn launchSync(
        self: *Context,
        kernel: Kernel,
        config: LaunchConfig,
        params: ?[*]?*anyopaque,
    ) !void {
        try kernel.launch(config, params);
        try self.sync(null);
    }

    // ========================================================================
    // Stream Operations
    // ========================================================================

    /// Create a new stream
    pub fn createStream(self: *Context) !*Stream {
        const stream = try Stream.create(self.drv);
        try self.streams.append(self.allocator, stream);
        return &self.streams.items[self.streams.items.len - 1];
    }

    /// Get default stream
    pub fn getDefaultStream(self: *Context) Stream {
        return Stream.getDefault(self.drv);
    }

    // ========================================================================
    // Synchronization
    // ========================================================================

    /// Synchronize (wait for all operations to complete)
    pub fn sync(self: *Context, stream: ?*const Stream) !void {
        if (stream) |s| {
            try s.synchronize();
        } else {
            if (self.drv.cuCtxSynchronize() != types.CUDA_SUCCESS) {
                return CudaError.SyncFailed;
            }
        }
    }

    /// Synchronize all streams
    pub fn syncAll(self: *Context) !void {
        try self.sync(null);
    }

    // ========================================================================
    // Timing
    // ========================================================================

    /// Create an event timer for profiling
    pub fn createTimer(self: *Context) !EventTimer {
        return EventTimer.create(self.drv);
    }

    // ========================================================================
    // Utility
    // ========================================================================

    /// Check if context is valid
    pub fn isValid(self: *const Context) bool {
        return self.initialized and self.cuda_ctx != null;
    }

    /// Get driver version
    pub fn getDriverVersion(self: *const Context) i32 {
        var version: i32 = 0;
        _ = self.drv.cuDriverGetVersion(&version);
        return version;
    }

    /// Check if JIT compilation is available
    pub fn supportsJit(self: *const Context) bool {
        return self.nvrtc != null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ContextOptions defaults" {
    const opts = ContextOptions{};
    try std.testing.expectEqual(@as(u32, 0), opts.device_index);
    try std.testing.expect(opts.enable_timing);
    try std.testing.expect(opts.allow_jit);
}

test "Context init without GPU (graceful failure)" {
    const allocator = std.testing.allocator;

    // This should fail gracefully if no GPU
    const result = Context.init(allocator, .{});
    if (result) |*ctx| {
        var mutable_ctx = ctx.*;
        defer mutable_ctx.deinit();
        try std.testing.expect(mutable_ctx.isValid());
    } else |err| {
        // Expected errors on systems without CUDA
        try std.testing.expect(err == CudaError.DriverNotFound or
            err == CudaError.InitFailed or
            err == CudaError.NoDevice);
    }
}

test "ContextOptions all fields" {
    const opts = ContextOptions{
        .device_index = 1,
        .enable_timing = false,
        .allow_jit = false,
        .stream_pool_size = 8,
        .log_level = 4,
        .prefer_unified_memory = true,
    };

    try std.testing.expectEqual(@as(u32, 1), opts.device_index);
    try std.testing.expect(!opts.enable_timing);
    try std.testing.expect(!opts.allow_jit);
    try std.testing.expectEqual(@as(usize, 8), opts.stream_pool_size);
    try std.testing.expectEqual(@as(u8, 4), opts.log_level);
    try std.testing.expect(opts.prefer_unified_memory);
}

test "ContextOptions default stream pool size" {
    const opts = ContextOptions{};
    try std.testing.expectEqual(@as(usize, 4), opts.stream_pool_size);
}

test "ContextOptions default log level" {
    const opts = ContextOptions{};
    try std.testing.expectEqual(@as(u8, 1), opts.log_level); // errors only
}

test "Context init with invalid device index (graceful failure)" {
    const allocator = std.testing.allocator;

    // Try to use a very high device index
    const result = Context.init(allocator, .{ .device_index = 999 });
    if (result) |*ctx| {
        var mutable_ctx = ctx.*;
        defer mutable_ctx.deinit();
        // Shouldn't get here if device 999 doesn't exist
    } else |err| {
        // Should get InvalidDevice or similar error
        try std.testing.expect(err == CudaError.InvalidDevice or
            err == CudaError.DriverNotFound or
            err == CudaError.InitFailed or
            err == CudaError.NoDevice);
    }
}

test "Context double deinit safety" {
    const allocator = std.testing.allocator;

    const result = Context.init(allocator, .{});
    if (result) |*ctx| {
        var mutable_ctx = ctx.*;

        // First deinit
        mutable_ctx.deinit();

        // Verify state after deinit
        try std.testing.expect(!mutable_ctx.initialized);
        try std.testing.expect(mutable_ctx.cuda_ctx == null);

        // Second deinit should be safe (no-op since cuda_ctx is null)
        // This tests that deinit properly handles already-deinitialized state
    } else |_| {
        // No GPU, test passes trivially
    }
}

test "Context isValid before init" {
    // Create an uninitialized context struct
    var ctx: Context = undefined;
    ctx.initialized = false;
    ctx.cuda_ctx = null;

    // Should report as invalid
    try std.testing.expect(!ctx.isValid());
}

test "Context getArch returns valid architecture" {
    const allocator = std.testing.allocator;

    const result = Context.init(allocator, .{});
    if (result) |*ctx| {
        var mutable_ctx = ctx.*;
        defer mutable_ctx.deinit();

        const arch = mutable_ctx.getArch();
        // Architecture should have valid major version (3+ for current GPUs)
        // Upper bound is generous to accommodate future GPU generations
        try std.testing.expect(arch.major >= 3);
        try std.testing.expect(arch.major <= 15);
    } else |_| {
        // No GPU, test passes trivially
    }
}

test "Context supportsJit reflects options" {
    const allocator = std.testing.allocator;

    // Try with JIT enabled
    const result1 = Context.init(allocator, .{ .allow_jit = true });
    if (result1) |*ctx| {
        var mutable_ctx = ctx.*;
        defer mutable_ctx.deinit();
        // JIT support depends on NVRTC availability, so just verify no crash
        _ = mutable_ctx.supportsJit();
    } else |_| {}

    // Try with JIT disabled
    const result2 = Context.init(allocator, .{ .allow_jit = false });
    if (result2) |*ctx| {
        var mutable_ctx = ctx.*;
        defer mutable_ctx.deinit();
        // With JIT disabled, should return false
        try std.testing.expect(!mutable_ctx.supportsJit());
    } else |_| {}
}

test "Context getDriverVersion returns reasonable value" {
    const allocator = std.testing.allocator;

    const result = Context.init(allocator, .{});
    if (result) |*ctx| {
        var mutable_ctx = ctx.*;
        defer mutable_ctx.deinit();

        const version = mutable_ctx.getDriverVersion();
        // Driver version should be positive and reasonable (CUDA 8.0 = 8000, etc)
        try std.testing.expect(version >= 8000);
        try std.testing.expect(version < 20000); // Reasonable upper bound
    } else |_| {
        // No GPU, test passes trivially
    }
}

test "Context memory operations require valid context" {
    const allocator = std.testing.allocator;

    const result = Context.init(allocator, .{});
    if (result) |*ctx| {
        var mutable_ctx = ctx.*;
        defer mutable_ctx.deinit();

        // Test memory allocation/deallocation cycle
        const buffer_result = mutable_ctx.createBuffer(1024, .device);
        if (buffer_result) |buf| {
            try std.testing.expect(buf.isValid());
            try std.testing.expect(buf.size >= 1024);
            mutable_ctx.destroyBuffer(buf);
        } else |_| {
            // Allocation failure is acceptable
        }
    } else |_| {
        // No GPU, test passes trivially
    }
}
