// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! CUDA Module and Kernel Management
//!
//! This module handles loading PTX/CUBIN modules and extracting kernel functions.
//! It supports runtime compilation via NVRTC and provides kernel launch primitives.
//!
//! ## Usage
//! ```zig
//! var module = try Module.loadPtx(&driver, ptx_source);
//! defer module.unload();
//!
//! const kernel = try module.getKernel("my_kernel");
//! try kernel.launch(grid, block, &args, 0, stream);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const driver = @import("driver.zig");
const types = @import("types.zig");
const stream_mod = @import("stream.zig");

// Re-exports
pub const CUmodule = types.CUmodule;
pub const CUfunction = types.CUfunction;
pub const CUstream = types.CUstream;
pub const LaunchConfig = types.LaunchConfig;
pub const CudaError = types.CudaError;
pub const CUDA_SUCCESS = types.CUDA_SUCCESS;

// ============================================================================
// Kernel
// ============================================================================

/// CUDA kernel function handle
/// Maximum kernel name length (255 chars + null terminator)
pub const MAX_KERNEL_NAME_LEN = 255;

pub const Kernel = struct {
    /// Underlying CUDA function handle
    handle: CUfunction,
    /// Driver reference
    drv: *const driver.CudaDriver,
    /// Kernel name (max 255 chars + null terminator)
    name: [MAX_KERNEL_NAME_LEN + 1]u8 = [_]u8{0} ** (MAX_KERNEL_NAME_LEN + 1),
    name_len: usize = 0,

    /// Get kernel name as slice
    pub fn getName(self: *const Kernel) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Launch kernel with configuration
    pub fn launch(
        self: *const Kernel,
        config: LaunchConfig,
        params: ?[*]?*anyopaque,
    ) !void {
        const result = self.drv.launchKernel(
            self.handle,
            config.grid,
            config.block,
            config.shared_mem,
            config.stream,
            params,
        );
        if (result != CUDA_SUCCESS) {
            return CudaError.LaunchFailed;
        }
    }

    /// Launch kernel with explicit dimensions
    pub fn launchEx(
        self: *const Kernel,
        grid_x: u32,
        grid_y: u32,
        grid_z: u32,
        block_x: u32,
        block_y: u32,
        block_z: u32,
        shared_mem: u32,
        stream: CUstream,
        params: ?[*]?*anyopaque,
    ) !void {
        const result = self.drv.launchKernel(
            self.handle,
            .{ grid_x, grid_y, grid_z },
            .{ block_x, block_y, block_z },
            shared_mem,
            stream,
            params,
        );
        if (result != CUDA_SUCCESS) {
            return CudaError.LaunchFailed;
        }
    }

    /// Launch 1D kernel
    pub fn launch1D(
        self: *const Kernel,
        num_elements: u32,
        block_size: u32,
        params: ?[*]?*anyopaque,
    ) !void {
        const config = LaunchConfig.for1D(num_elements, block_size);
        try self.launch(config, params);
    }

    /// Launch kernel and synchronize immediately
    pub fn launchSync(
        self: *const Kernel,
        config: LaunchConfig,
        params: ?[*]?*anyopaque,
    ) !void {
        try self.launch(config, params);
        if (self.drv.cuCtxSynchronize() != CUDA_SUCCESS) {
            return CudaError.SyncFailed;
        }
    }

    // ========================================================================
    // Occupancy Calculator
    // ========================================================================

    /// Calculate maximum active blocks per multiprocessor for this kernel
    pub fn getMaxActiveBlocksPerSM(
        self: *const Kernel,
        block_size: i32,
        dynamic_smem_size: usize,
    ) !i32 {
        if (!self.drv.supportsOccupancy()) return CudaError.NotSupported;

        var num_blocks: i32 = 0;
        const result = self.drv.occupancyMaxActiveBlocksPerMultiprocessor(
            &num_blocks,
            self.handle,
            block_size,
            dynamic_smem_size,
        );
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
        return num_blocks;
    }

    /// Calculate optimal block size for maximum occupancy
    /// Returns the suggested block size and minimum grid size
    pub fn getOptimalBlockSize(
        self: *const Kernel,
        dynamic_smem_size: usize,
        block_size_limit: i32,
    ) !OccupancyResult {
        if (!self.drv.supportsOccupancy()) return CudaError.NotSupported;

        var min_grid_size: i32 = 0;
        var block_size: i32 = 0;
        const result = self.drv.occupancyMaxPotentialBlockSize(
            &min_grid_size,
            &block_size,
            self.handle,
            null,
            dynamic_smem_size,
            block_size_limit,
        );
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }

        return OccupancyResult{
            .block_size = block_size,
            .min_grid_size = min_grid_size,
        };
    }

    /// Get a function attribute
    pub fn getAttribute(self: *const Kernel, attribute: types.CUfunction_attribute) !i32 {
        var value: i32 = 0;
        const result = self.drv.funcGetAttribute(&value, @intFromEnum(attribute), self.handle);
        if (result != CUDA_SUCCESS) {
            return CudaError.GpuError;
        }
        return value;
    }

    /// Get maximum threads per block for this kernel
    pub fn getMaxThreadsPerBlock(self: *const Kernel) !i32 {
        return self.getAttribute(.max_threads_per_block);
    }

    /// Get number of registers per thread
    pub fn getNumRegs(self: *const Kernel) !i32 {
        return self.getAttribute(.num_regs);
    }

    /// Get shared memory size in bytes
    pub fn getSharedMemorySize(self: *const Kernel) !i32 {
        return self.getAttribute(.shared_size_bytes);
    }

    /// Get local memory size per thread in bytes
    pub fn getLocalMemorySize(self: *const Kernel) !i32 {
        return self.getAttribute(.local_size_bytes);
    }

    /// Calculate occupancy as a percentage (0.0 - 1.0)
    /// Requires device multiprocessor count to calculate theoretical max
    pub fn calculateOccupancy(
        self: *const Kernel,
        block_size: i32,
        dynamic_smem_size: usize,
        max_threads_per_sm: i32,
    ) !f32 {
        const active_blocks = try self.getMaxActiveBlocksPerSM(block_size, dynamic_smem_size);
        const active_threads = active_blocks * block_size;
        return @as(f32, @floatFromInt(active_threads)) / @as(f32, @floatFromInt(max_threads_per_sm));
    }
};

/// Result from occupancy calculation
pub const OccupancyResult = struct {
    /// Optimal block size for maximum occupancy
    block_size: i32,
    /// Minimum grid size for maximum occupancy
    min_grid_size: i32,

    /// Create a LaunchConfig from this result
    pub fn toLaunchConfig(self: OccupancyResult, num_elements: u32) LaunchConfig {
        const grid_size = @divTrunc(num_elements + @as(u32, @intCast(self.block_size)) - 1, @as(u32, @intCast(self.block_size)));
        return LaunchConfig{
            .grid = .{ grid_size, 1, 1 },
            .block = .{ @intCast(self.block_size), 1, 1 },
        };
    }
};

// ============================================================================
// Module
// ============================================================================

/// CUDA module containing kernels
/// Thread-safety: All public methods are protected by an internal mutex
pub const Module = struct {
    /// Underlying CUDA module handle
    handle: ?CUmodule,
    /// Driver reference
    drv: *const driver.CudaDriver,
    /// Cached kernels (protected by mutex)
    kernels: std.StringHashMap(Kernel),
    /// Allocator
    allocator: std.mem.Allocator,
    /// Mutex for thread-safe kernel cache access
    mutex: std.Thread.Mutex = .{},

    /// Load module from PTX source
    pub fn loadPtx(drv: *const driver.CudaDriver, allocator: std.mem.Allocator, ptx_source: []const u8) !Module {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (ptx_source.len == 0) return CudaError.InvalidArgument;

        var handle: CUmodule = undefined;
        const result = drv.moduleLoadData(&handle, ptx_source.ptr);
        if (result != CUDA_SUCCESS) {
            return CudaError.ModuleLoadFailed;
        }

        return Module{
            .handle = handle,
            .drv = drv,
            .kernels = std.StringHashMap(Kernel).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    /// Load module from null-terminated PTX string
    pub fn loadPtxZ(drv: *const driver.CudaDriver, allocator: std.mem.Allocator, ptx_source: [*:0]const u8) !Module {
        const len = std.mem.len(ptx_source);
        return loadPtx(drv, allocator, ptx_source[0..len]);
    }

    /// Load module from CUBIN data (pre-compiled binary)
    pub fn loadCubin(drv: *const driver.CudaDriver, allocator: std.mem.Allocator, cubin_data: []const u8) !Module {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (cubin_data.len == 0) return CudaError.InvalidArgument;

        var handle: CUmodule = undefined;
        const result = drv.moduleLoadData(&handle, cubin_data.ptr);
        if (result != CUDA_SUCCESS) {
            return CudaError.ModuleLoadFailed;
        }

        return Module{
            .handle = handle,
            .drv = drv,
            .kernels = std.StringHashMap(Kernel).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    /// Load module from file path (CUBIN, PTX, or fatbin)
    pub fn loadFile(drv: *const driver.CudaDriver, allocator: std.mem.Allocator, filename: [:0]const u8) !Module {
        if (!drv.available()) return CudaError.DriverNotFound;
        if (!drv.hasModuleLoad()) return CudaError.NotSupported;

        var handle: CUmodule = undefined;
        const result = drv.moduleLoad(&handle, filename.ptr);
        if (result != CUDA_SUCCESS) {
            return CudaError.ModuleLoadFailed;
        }

        return Module{
            .handle = handle,
            .drv = drv,
            .kernels = std.StringHashMap(Kernel).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    /// Unload the module
    /// Thread-safe: Acquires mutex before cleanup
    pub fn unload(self: *Module) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all cached kernel name keys before clearing the map
        var iter = self.kernels.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.kernels.deinit();

        // Unload CUDA module
        if (self.handle) |h| {
            _ = self.drv.moduleUnload(h);
            self.handle = null;
        }
    }

    /// Get kernel function by name
    /// Thread-safe: Uses mutex to protect cache access
    pub fn getKernel(self: *Module, name: []const u8) !Kernel {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check cache first
        if (self.kernels.get(name)) |kernel| {
            return kernel;
        }

        if (self.handle == null) return CudaError.InvalidArgument;

        // Validate name length (must leave room for null terminator)
        if (name.len > MAX_KERNEL_NAME_LEN) return CudaError.InvalidArgument;

        // Create null-terminated name buffer
        var name_buf: [MAX_KERNEL_NAME_LEN + 1]u8 = [_]u8{0} ** (MAX_KERNEL_NAME_LEN + 1);
        @memcpy(name_buf[0..name.len], name);
        // Null terminator guaranteed at name_buf[name.len] since buffer is zero-initialized

        // Get function from module
        var func: CUfunction = undefined;
        const result = self.drv.moduleGetFunction(&func, self.handle.?, @ptrCast(&name_buf));
        if (result != CUDA_SUCCESS) {
            return CudaError.FunctionNotFound;
        }

        // Create kernel and cache it
        var kernel = Kernel{
            .handle = func,
            .drv = self.drv,
        };
        @memcpy(kernel.name[0..name.len], name);
        kernel.name_len = name.len;

        // Store in cache (need to dupe key for ownership)
        const key = try self.allocator.dupe(u8, name);
        try self.kernels.put(key, kernel);

        return kernel;
    }

    /// Check if module is loaded
    pub fn isLoaded(self: *const Module) bool {
        return self.handle != null;
    }
};

// ============================================================================
// NVRTC Compiler
// ============================================================================

/// NVRTC compilation options (#15)
pub const NvrtcOptions = struct {
    /// Target GPU architecture (e.g., "sm_70", "sm_86")
    arch: ?types.ComputeArch = null,
    /// C++ standard to use
    std: CppStandard = .cpp11,
    /// Optimization level (0-3)
    opt_level: u2 = 2,
    /// Enable debug info
    debug: bool = false,
    /// Enable line info for profiling
    line_info: bool = false,
    /// Enable fast math optimizations
    fast_math: bool = false,
    /// Enable fused multiply-add
    fmad: bool = true,
    /// Use fast floating-point division
    use_fast_div: bool = false,
    /// Additional include paths
    include_paths: []const []const u8 = &.{},
    /// Preprocessor definitions
    defines: []const []const u8 = &.{},
    /// Additional raw options
    extra_options: []const []const u8 = &.{},
    /// Generate relocatable device code (for linking)
    relocatable: bool = false,
    /// Extensible identifier (for device functions)
    extensible: bool = false,

    pub const CppStandard = enum {
        cpp11,
        cpp14,
        cpp17,
        cpp20,

        pub fn toOption(self: CppStandard) []const u8 {
            return switch (self) {
                .cpp11 => "--std=c++11",
                .cpp14 => "--std=c++14",
                .cpp17 => "--std=c++17",
                .cpp20 => "--std=c++20",
            };
        }
    };

    /// Get default options for a given architecture
    pub fn forArch(arch: types.ComputeArch) NvrtcOptions {
        return NvrtcOptions{
            .arch = arch,
        };
    }

    /// Enable maximum performance optimizations
    pub fn maxPerformance(self: *NvrtcOptions) *NvrtcOptions {
        self.opt_level = 3;
        self.fast_math = true;
        self.use_fast_div = true;
        self.fmad = true;
        self.debug = false;
        self.line_info = false;
        return self;
    }

    /// Enable debug configuration
    pub fn forDebugging(self: *NvrtcOptions) *NvrtcOptions {
        self.opt_level = 0;
        self.debug = true;
        self.line_info = true;
        self.fast_math = false;
        return self;
    }

    /// Build options array for NVRTC
    pub fn buildOptions(self: NvrtcOptions, allocator: std.mem.Allocator, arch_buf: *[64]u8) !std.ArrayList([*:0]const u8) {
        var options = std.ArrayList([*:0]const u8).init(allocator);
        errdefer options.deinit();

        // Architecture
        if (self.arch) |arch| {
            const arch_str = std.fmt.bufPrintZ(arch_buf, "--gpu-architecture={s}", .{arch.computeString()}) catch return error.OutOfMemory;
            try options.append(arch_str.ptr);
        }

        // C++ standard
        try options.append(@ptrCast(self.std.toOption().ptr));

        // Debug/optimization
        if (self.debug) {
            try options.append("-G");
        }
        if (self.line_info) {
            try options.append("-lineinfo");
        }

        // Fast math options
        if (self.fast_math) {
            try options.append("--use_fast_math");
        }
        if (!self.fmad) {
            try options.append("--fmad=false");
        }
        if (self.use_fast_div) {
            try options.append("--prec-div=false");
        }

        // Relocatable code
        if (self.relocatable) {
            try options.append("-dc");
        }
        if (self.extensible) {
            try options.append("-ewp");
        }

        return options;
    }
};

// NVRTC function pointer types
const nvrtcResult = i32;
const nvrtcProgram = *anyopaque;
const nvrtcCreateProgram_t = *const fn (*nvrtcProgram, [*:0]const u8, [*:0]const u8, i32, [*]const [*:0]const u8, [*]const [*:0]const u8) callconv(.c) nvrtcResult;
const nvrtcDestroyProgram_t = *const fn (*nvrtcProgram) callconv(.c) nvrtcResult;
const nvrtcCompileProgram_t = *const fn (nvrtcProgram, i32, [*]const [*:0]const u8) callconv(.c) nvrtcResult;
const nvrtcGetPTXSize_t = *const fn (nvrtcProgram, *usize) callconv(.c) nvrtcResult;
const nvrtcGetPTX_t = *const fn (nvrtcProgram, [*]u8) callconv(.c) nvrtcResult;
const nvrtcGetProgramLogSize_t = *const fn (nvrtcProgram, *usize) callconv(.c) nvrtcResult;
const nvrtcGetProgramLog_t = *const fn (nvrtcProgram, [*]u8) callconv(.c) nvrtcResult;

/// NVRTC Runtime Compiler
pub const NvrtcCompiler = struct {
    /// Dynamic library handle
    lib: ?std.DynLib,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Function pointers
    nvrtcCreateProgram_fn: ?nvrtcCreateProgram_t = null,
    nvrtcDestroyProgram_fn: ?nvrtcDestroyProgram_t = null,
    nvrtcCompileProgram_fn: ?nvrtcCompileProgram_t = null,
    nvrtcGetPTXSize_fn: ?nvrtcGetPTXSize_t = null,
    nvrtcGetPTX_fn: ?nvrtcGetPTX_t = null,
    nvrtcGetProgramLogSize_fn: ?nvrtcGetProgramLogSize_t = null,
    nvrtcGetProgramLog_fn: ?nvrtcGetProgramLog_t = null,

    // NVRTC library names per platform
    const nvrtc_lib_names = switch (builtin.os.tag) {
        .linux => &[_][]const u8{ "libnvrtc.so", "libnvrtc.so.12", "libnvrtc.so.11" },
        .macos => &[_][]const u8{"libnvrtc.dylib"},
        .windows => &[_][]const u8{ "nvrtc64_120_0.dll", "nvrtc64_110_0.dll", "nvrtc.dll" },
        else => &[_][]const u8{},
    };

    /// Initialize NVRTC compiler (load library)
    pub fn init(allocator: std.mem.Allocator) NvrtcCompiler {
        // Try to load NVRTC library
        var lib: ?std.DynLib = null;
        for (nvrtc_lib_names) |name| {
            lib = std.DynLib.open(name) catch continue;
            if (lib != null) break;
        }

        if (lib == null) {
            return NvrtcCompiler{ .lib = null, .allocator = allocator };
        }

        var compiler = NvrtcCompiler{ .lib = lib, .allocator = allocator };

        // Load symbols
        compiler.nvrtcCreateProgram_fn = loadSymFromLib(nvrtcCreateProgram_t, &lib.?, "nvrtcCreateProgram");
        compiler.nvrtcDestroyProgram_fn = loadSymFromLib(nvrtcDestroyProgram_t, &lib.?, "nvrtcDestroyProgram");
        compiler.nvrtcCompileProgram_fn = loadSymFromLib(nvrtcCompileProgram_t, &lib.?, "nvrtcCompileProgram");
        compiler.nvrtcGetPTXSize_fn = loadSymFromLib(nvrtcGetPTXSize_t, &lib.?, "nvrtcGetPTXSize");
        compiler.nvrtcGetPTX_fn = loadSymFromLib(nvrtcGetPTX_t, &lib.?, "nvrtcGetPTX");
        compiler.nvrtcGetProgramLogSize_fn = loadSymFromLib(nvrtcGetProgramLogSize_t, &lib.?, "nvrtcGetProgramLogSize");
        compiler.nvrtcGetProgramLog_fn = loadSymFromLib(nvrtcGetProgramLog_t, &lib.?, "nvrtcGetProgramLog");

        // Verify essential symbols
        if (compiler.nvrtcCreateProgram_fn == null or compiler.nvrtcCompileProgram_fn == null) {
            lib.?.close();
            return NvrtcCompiler{ .lib = null, .allocator = allocator };
        }

        return compiler;
    }

    /// Clean up
    pub fn deinit(self: *NvrtcCompiler) void {
        if (self.lib) |*lib| {
            lib.close();
            self.lib = null;
        }
    }

    /// Check if NVRTC is available
    pub fn available(self: *const NvrtcCompiler) bool {
        return self.nvrtcCreateProgram_fn != null and self.nvrtcCompileProgram_fn != null;
    }

    /// Compile CUDA C source to PTX
    pub fn compileToPtx(
        self: *NvrtcCompiler,
        source: [:0]const u8,
        name: [:0]const u8,
        arch: ?types.ComputeArch,
    ) ![]u8 {
        // Use default options with specified arch
        const opts = if (arch) |a| NvrtcOptions.forArch(a) else NvrtcOptions{};
        return self.compileToPtxWithOptions(source, name, opts);
    }

    /// Compile CUDA C source to PTX with full options (#15)
    pub fn compileToPtxWithOptions(
        self: *NvrtcCompiler,
        source: [:0]const u8,
        name: [:0]const u8,
        options: NvrtcOptions,
    ) ![]u8 {
        if (!self.available()) return CudaError.NvrtcNotFound;

        const createProg = self.nvrtcCreateProgram_fn.?;
        const destroyProg = self.nvrtcDestroyProgram_fn.?;
        const compileProg = self.nvrtcCompileProgram_fn.?;
        const getPTXSize = self.nvrtcGetPTXSize_fn.?;
        const getPTX = self.nvrtcGetPTX_fn.?;

        // Create program
        var prog: nvrtcProgram = undefined;
        const empty: [*]const [*:0]const u8 = @ptrCast(&[_][*:0]const u8{});
        var result = createProg(&prog, source.ptr, name.ptr, 0, empty, empty);
        if (result != 0) {
            return CudaError.CompilationFailed;
        }
        defer _ = destroyProg(&prog);

        // Build compile options from NvrtcOptions
        var arch_buf: [64]u8 = undefined;
        var compile_opts = options.buildOptions(self.allocator, &arch_buf) catch return CudaError.InvalidArgument;
        defer compile_opts.deinit();

        // Compile
        result = compileProg(prog, @intCast(compile_opts.items.len), compile_opts.items.ptr);

        // Get log if compilation failed
        if (result != 0) {
            if (self.nvrtcGetProgramLogSize_fn) |getLogSize| {
                if (self.nvrtcGetProgramLog_fn) |getLog| {
                    var log_size: usize = 0;
                    _ = getLogSize(prog, &log_size);
                    if (log_size > 1) {
                        const log = self.allocator.alloc(u8, log_size) catch return CudaError.CompilationFailed;
                        defer self.allocator.free(log);
                        _ = getLog(prog, log.ptr);
                        std.debug.print("NVRTC compilation failed:\n{s}\n", .{log});
                    }
                }
            }
            return CudaError.CompilationFailed;
        }

        // Get PTX size
        var ptx_size: usize = 0;
        result = getPTXSize(prog, &ptx_size);
        if (result != 0) return CudaError.CompilationFailed;

        // Get PTX
        const ptx = try self.allocator.alloc(u8, ptx_size);
        result = getPTX(prog, ptx.ptr);
        if (result != 0) {
            self.allocator.free(ptx);
            return CudaError.CompilationFailed;
        }

        return ptx;
    }

    /// Get compilation log (for debugging compilation issues)
    pub fn getCompilationLog(
        self: *NvrtcCompiler,
        source: [:0]const u8,
        name: [:0]const u8,
        options: NvrtcOptions,
    ) ![]u8 {
        if (!self.available()) return CudaError.NvrtcNotFound;
        if (self.nvrtcGetProgramLogSize_fn == null or self.nvrtcGetProgramLog_fn == null) {
            return CudaError.NotSupported;
        }

        const createProg = self.nvrtcCreateProgram_fn.?;
        const destroyProg = self.nvrtcDestroyProgram_fn.?;
        const compileProg = self.nvrtcCompileProgram_fn.?;
        const getLogSize = self.nvrtcGetProgramLogSize_fn.?;
        const getLog = self.nvrtcGetProgramLog_fn.?;

        // Create and compile program
        var prog: nvrtcProgram = undefined;
        const empty: [*]const [*:0]const u8 = @ptrCast(&[_][*:0]const u8{});
        if (createProg(&prog, source.ptr, name.ptr, 0, empty, empty) != 0) {
            return CudaError.CompilationFailed;
        }
        defer _ = destroyProg(&prog);

        // Build and execute compilation (ignore result, we want the log)
        var arch_buf: [64]u8 = undefined;
        var compile_opts = options.buildOptions(self.allocator, &arch_buf) catch return CudaError.InvalidArgument;
        defer compile_opts.deinit();
        _ = compileProg(prog, @intCast(compile_opts.items.len), compile_opts.items.ptr);

        // Get log
        var log_size: usize = 0;
        _ = getLogSize(prog, &log_size);
        if (log_size <= 1) {
            return try self.allocator.dupe(u8, "");
        }

        const log = try self.allocator.alloc(u8, log_size);
        _ = getLog(prog, log.ptr);
        return log;
    }
};

fn loadSymFromLib(comptime T: type, lib: *std.DynLib, name: []const u8) ?T {
    return lib.lookup(T, @ptrCast(name));
}

// ============================================================================
// Kernel Argument Builder
// ============================================================================

/// Helper for building kernel argument arrays
pub fn KernelArgs(comptime max_args: usize) type {
    return struct {
        const Self = @This();

        args: [max_args]?*anyopaque = [_]?*anyopaque{null} ** max_args,
        count: usize = 0,

        /// Add a pointer argument
        pub fn addPtr(self: *Self, ptr: anytype) void {
            if (self.count < max_args) {
                self.args[self.count] = @ptrCast(@constCast(ptr));
                self.count += 1;
            }
        }

        /// Get argument array for kernel launch
        pub fn getArgs(self: *Self) [*]?*anyopaque {
            return &self.args;
        }

        /// Reset arguments
        pub fn reset(self: *Self) void {
            self.count = 0;
            self.args = [_]?*anyopaque{null} ** max_args;
        }
    };
}

// ============================================================================
// Type-Safe Kernel Arguments (#16)
// ============================================================================

/// Type-safe kernel argument builder with compile-time validation
/// Usage:
/// ```zig
/// var args = TypedKernelArgs(struct { d_input: CUdeviceptr, d_output: CUdeviceptr, n: u32 }){
///     .d_input = buf_in.ptr,
///     .d_output = buf_out.ptr,
///     .n = 1024,
/// };
/// try kernel.launch(config, args.asParams());
/// ```
pub fn TypedKernelArgs(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("TypedKernelArgs requires a struct type");
    }
    const fields = info.@"struct".fields;

    return struct {
        const Self = @This();
        const num_args = fields.len;

        // Store the actual values
        values: T,
        // Pre-computed pointers for kernel launch
        ptrs: [num_args]?*anyopaque = undefined,

        /// Create with values
        pub fn init(values: T) Self {
            var self = Self{ .values = values };
            self.computePtrs();
            return self;
        }

        /// Update pointers after value changes
        fn computePtrs(self: *Self) void {
            inline for (fields, 0..) |field, i| {
                self.ptrs[i] = @ptrCast(&@field(self.values, field.name));
            }
        }

        /// Get argument array for kernel launch
        pub fn asParams(self: *Self) [*]?*anyopaque {
            // Re-compute in case values were modified
            self.computePtrs();
            return &self.ptrs;
        }

        /// Get number of arguments
        pub fn count(_: *const Self) usize {
            return num_args;
        }

        /// Get a specific field value
        pub fn get(self: *const Self, comptime field_name: []const u8) @TypeOf(@field(self.values, field_name)) {
            return @field(self.values, field_name);
        }

        /// Set a specific field value
        pub fn set(self: *Self, comptime field_name: []const u8, value: @TypeOf(@field(self.values, field_name))) void {
            @field(self.values, field_name) = value;
        }
    };
}

/// Build kernel arguments from a tuple of pointers (simpler syntax for common cases)
/// Usage:
/// ```zig
/// var n: u32 = 1024;
/// const params = kernelParams(.{ &buf_in.ptr, &buf_out.ptr, &n });
/// try kernel.launch(config, params);
/// ```
pub fn kernelParams(args: anytype) [*]?*anyopaque {
    const ArgsType = @TypeOf(args);
    const args_info = @typeInfo(ArgsType);

    if (args_info != .@"struct" or !args_info.@"struct".is_tuple) {
        @compileError("kernelParams requires a tuple of pointers");
    }

    const fields = args_info.@"struct".fields;
    const S = struct {
        var ptrs: [fields.len]?*anyopaque = undefined;
    };

    inline for (fields, 0..) |field, i| {
        const ptr = @field(args, field.name);
        S.ptrs[i] = @ptrCast(@constCast(ptr));
    }

    return &S.ptrs;
}

/// Validate kernel argument types at compile time
pub fn validateKernelArgs(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("Kernel arguments must be a struct");
    }

    inline for (info.@"struct".fields) |field| {
        const field_info = @typeInfo(field.type);
        switch (field_info) {
            .int, .float, .pointer, .optional => {
                // Valid types for kernel arguments
            },
            .@"struct" => {
                // Allow CUdeviceptr (which is usize) wrapped in struct
                if (@sizeOf(field.type) > 8) {
                    @compileError("Kernel argument struct field '" ++ field.name ++ "' is too large (max 8 bytes)");
                }
            },
            else => {
                @compileError("Invalid kernel argument type for field '" ++ field.name ++ "'");
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Kernel name storage" {
    var kernel = Kernel{
        .handle = undefined,
        .drv = undefined,
    };
    @memcpy(kernel.name[0..10], "test_kern\x00");
    kernel.name_len = 9;

    try std.testing.expectEqualStrings("test_kern", kernel.getName());
}

test "LaunchConfig for1D" {
    const config = LaunchConfig.for1D(1000, 256);
    try std.testing.expectEqual(@as(u32, 4), config.grid[0]);
    try std.testing.expectEqual(@as(u32, 256), config.block[0]);
    try std.testing.expectEqual(@as(u64, 1024), config.totalThreads());
}

test "KernelArgs builder" {
    var val1: u32 = 42;
    var val2: f32 = 3.14;

    var args = KernelArgs(16){};
    args.addPtr(&val1);
    args.addPtr(&val2);

    try std.testing.expectEqual(@as(usize, 2), args.count);
}

test "NvrtcCompiler init (no panic on missing library)" {
    var compiler = NvrtcCompiler.init(std.testing.allocator);
    defer compiler.deinit();

    // Should not panic, just return unavailable
    _ = compiler.available();
}

test "Kernel getName with empty name" {
    var kernel = Kernel{
        .handle = undefined,
        .drv = undefined,
    };
    kernel.name_len = 0;

    try std.testing.expectEqualStrings("", kernel.getName());
}

test "Kernel getName with full buffer" {
    var kernel = Kernel{
        .handle = undefined,
        .drv = undefined,
    };
    @memset(&kernel.name, 'A');
    kernel.name_len = 128;

    try std.testing.expectEqual(@as(usize, 128), kernel.getName().len);
}

test "LaunchConfig for1D edge cases" {
    // Single element
    const config1 = LaunchConfig.for1D(1, 256);
    try std.testing.expectEqual(@as(u32, 1), config1.grid[0]);

    // Exact multiple
    const config2 = LaunchConfig.for1D(512, 256);
    try std.testing.expectEqual(@as(u32, 2), config2.grid[0]);

    // One more than multiple
    const config3 = LaunchConfig.for1D(257, 256);
    try std.testing.expectEqual(@as(u32, 2), config3.grid[0]);

    // Large number
    const config4 = LaunchConfig.for1D(1000000, 1024);
    try std.testing.expectEqual(@as(u32, 977), config4.grid[0]);
}

test "LaunchConfig for2D" {
    const config = LaunchConfig.for2D(100, 100, 16, 16);
    try std.testing.expectEqual(@as(u32, 7), config.grid[0]);
    try std.testing.expectEqual(@as(u32, 7), config.grid[1]);
    try std.testing.expectEqual(@as(u32, 16), config.block[0]);
    try std.testing.expectEqual(@as(u32, 16), config.block[1]);
}

test "LaunchConfig totalThreads" {
    const config = LaunchConfig{
        .grid = .{ 4, 4, 2 },
        .block = .{ 16, 16, 4 },
    };
    // 4*4*2 * 16*16*4 = 32 * 1024 = 32768
    try std.testing.expectEqual(@as(u64, 32768), config.totalThreads());
}

test "LaunchConfig totalThreads overflow prevention" {
    // Test with large values that could overflow u32
    const config = LaunchConfig{
        .grid = .{ 65535, 65535, 1 },
        .block = .{ 1024, 1, 1 },
    };
    // Should compute as u64 without overflow
    const total = config.totalThreads();
    try std.testing.expect(total > 4294967295); // Greater than u32 max
}

test "KernelArgs multiple adds" {
    var val1: u32 = 1;
    var val2: u32 = 2;
    var val3: u32 = 3;
    var val4: u32 = 4;

    var args = KernelArgs(16){};
    args.addPtr(&val1);
    args.addPtr(&val2);
    args.addPtr(&val3);
    args.addPtr(&val4);

    try std.testing.expectEqual(@as(usize, 4), args.count);

    // Verify we can get the args array (always returns a valid pointer)
    const ptr = args.getArgs();
    try std.testing.expect(@intFromPtr(ptr) != 0);
}

test "KernelArgs capacity limit" {
    var val: u32 = 42;
    var args = KernelArgs(4){};

    // Fill to capacity
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);
    args.addPtr(&val);

    try std.testing.expectEqual(@as(usize, 4), args.count);

    // Additional adds should be ignored (capacity reached)
    args.addPtr(&val);
    try std.testing.expectEqual(@as(usize, 4), args.count);
}

test "KernelArgs reset" {
    var val: u32 = 42;
    var args = KernelArgs(16){};

    args.addPtr(&val);
    args.addPtr(&val);
    try std.testing.expectEqual(@as(usize, 2), args.count);

    args.reset();
    try std.testing.expectEqual(@as(usize, 0), args.count);
}

test "KernelArgs getArgs returns pointer" {
    var args = KernelArgs(16){};
    // getArgs always returns a pointer to the args array
    const ptr = args.getArgs();
    // Should be a valid pointer (not testing for null since it's always valid)
    try std.testing.expect(@intFromPtr(ptr) != 0);
}

test "MAX_KERNEL_NAME_LEN constant" {
    // Verify the constant is set to allow 255 chars + null terminator
    try std.testing.expectEqual(@as(usize, 255), MAX_KERNEL_NAME_LEN);

    // Kernel name buffer should be 256 bytes (255 + 1)
    const kernel = Kernel{
        .handle = undefined,
        .drv = undefined,
    };
    try std.testing.expectEqual(@as(usize, 256), kernel.name.len);
}

test "Kernel name at max length" {
    var kernel = Kernel{
        .handle = undefined,
        .drv = undefined,
    };

    // Fill with max length name (255 chars)
    @memset(kernel.name[0..MAX_KERNEL_NAME_LEN], 'x');
    kernel.name[MAX_KERNEL_NAME_LEN] = 0; // Ensure null terminator
    kernel.name_len = MAX_KERNEL_NAME_LEN;

    try std.testing.expectEqual(@as(usize, 255), kernel.getName().len);
}

test "TypedKernelArgs basic usage" {
    const Args = struct {
        ptr: usize,
        count: u32,
        scale: f32,
    };

    var args = TypedKernelArgs(Args).init(.{
        .ptr = 0x1000,
        .count = 256,
        .scale = 1.5,
    });

    try std.testing.expectEqual(@as(usize, 3), args.count());
    try std.testing.expectEqual(@as(usize, 0x1000), args.get("ptr"));
    try std.testing.expectEqual(@as(u32, 256), args.get("count"));
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), args.get("scale"), 0.001);

    // asParams should return a valid pointer
    const params = args.asParams();
    try std.testing.expect(@intFromPtr(params) != 0);
}

test "TypedKernelArgs set" {
    const Args = struct {
        value: u32,
    };

    var args = TypedKernelArgs(Args).init(.{ .value = 10 });
    try std.testing.expectEqual(@as(u32, 10), args.get("value"));

    args.set("value", 20);
    try std.testing.expectEqual(@as(u32, 20), args.get("value"));
}

test "NvrtcOptions default values" {
    const opts = NvrtcOptions{};
    try std.testing.expectEqual(NvrtcOptions.CppStandard.cpp11, opts.std);
    try std.testing.expectEqual(@as(u2, 2), opts.opt_level);
    try std.testing.expect(!opts.debug);
    try std.testing.expect(!opts.fast_math);
    try std.testing.expect(opts.fmad);
}

test "NvrtcOptions forArch" {
    const arch = types.ComputeArch{ .major = 8, .minor = 6 };
    const opts = NvrtcOptions.forArch(arch);
    try std.testing.expect(opts.arch != null);
    try std.testing.expectEqual(@as(u32, 8), opts.arch.?.major);
}

test "NvrtcOptions maxPerformance" {
    var opts = NvrtcOptions{};
    _ = opts.maxPerformance();

    try std.testing.expectEqual(@as(u2, 3), opts.opt_level);
    try std.testing.expect(opts.fast_math);
    try std.testing.expect(opts.use_fast_div);
    try std.testing.expect(!opts.debug);
}

test "NvrtcOptions forDebugging" {
    var opts = NvrtcOptions{};
    _ = opts.forDebugging();

    try std.testing.expectEqual(@as(u2, 0), opts.opt_level);
    try std.testing.expect(opts.debug);
    try std.testing.expect(opts.line_info);
    try std.testing.expect(!opts.fast_math);
}

test "NvrtcOptions CppStandard toOption" {
    try std.testing.expectEqualStrings("--std=c++11", NvrtcOptions.CppStandard.cpp11.toOption());
    try std.testing.expectEqualStrings("--std=c++14", NvrtcOptions.CppStandard.cpp14.toOption());
    try std.testing.expectEqualStrings("--std=c++17", NvrtcOptions.CppStandard.cpp17.toOption());
    try std.testing.expectEqualStrings("--std=c++20", NvrtcOptions.CppStandard.cpp20.toOption());
}
