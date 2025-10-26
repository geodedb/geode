const std = @import("std");
const builtin = @import("builtin");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=NVRTCCompiler; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_NVRTCCompile; OWNER=engine; UPDATED=2025-10-26

// NVRTC (NVIDIA Runtime Compilation) API
const nvrtcResult = i32;
const nvrtcProgram = *anyopaque;

// External dynamic loader functions
pub extern fn dlopen(path: [*:0]const u8, flag: i32) ?*anyopaque;
pub extern fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
pub extern fn dlclose(handle: *anyopaque) i32;

const RTLD_LAZY = 0x00001;

// Function pointer types
const nvrtcCreateProgram_t = *const fn (*nvrtcProgram, [*:0]const u8, [*:0]const u8, i32, [*]const [*:0]const u8, [*]const [*:0]const u8) callconv(.c) nvrtcResult;
const nvrtcDestroyProgram_t = *const fn (*nvrtcProgram) callconv(.c) nvrtcResult;
const nvrtcCompileProgram_t = *const fn (nvrtcProgram, i32, [*]const [*:0]const u8) callconv(.c) nvrtcResult;
const nvrtcGetPTXSize_t = *const fn (nvrtcProgram, *usize) callconv(.c) nvrtcResult;
const nvrtcGetPTX_t = *const fn (nvrtcProgram, [*]u8) callconv(.c) nvrtcResult;
const nvrtcGetProgramLogSize_t = *const fn (nvrtcProgram, *usize) callconv(.c) nvrtcResult;
const nvrtcGetProgramLog_t = *const fn (nvrtcProgram, [*]u8) callconv(.c) nvrtcResult;

pub const NVRTCCompiler = struct {
    handle: ?*anyopaque,
    nvrtcCreateProgram_fn: ?nvrtcCreateProgram_t,
    nvrtcDestroyProgram_fn: ?nvrtcDestroyProgram_t,
    nvrtcCompileProgram_fn: ?nvrtcCompileProgram_t,
    nvrtcGetPTXSize_fn: ?nvrtcGetPTXSize_t,
    nvrtcGetPTX_fn: ?nvrtcGetPTX_t,
    nvrtcGetProgramLogSize_fn: ?nvrtcGetProgramLogSize_t,
    nvrtcGetProgramLog_fn: ?nvrtcGetProgramLog_t,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NVRTCCompiler {
        if (builtin.os.tag != .linux) {
            return NVRTCCompiler{
                .handle = null,
                .nvrtcCreateProgram_fn = null,
                .nvrtcDestroyProgram_fn = null,
                .nvrtcCompileProgram_fn = null,
                .nvrtcGetPTXSize_fn = null,
                .nvrtcGetPTX_fn = null,
                .nvrtcGetProgramLogSize_fn = null,
                .nvrtcGetProgramLog_fn = null,
                .allocator = allocator,
            };
        }

        // Try to load libnvrtc.so
        const handle = dlopen("libnvrtc.so", RTLD_LAZY) orelse {
            return NVRTCCompiler{
                .handle = null,
                .nvrtcCreateProgram_fn = null,
                .nvrtcDestroyProgram_fn = null,
                .nvrtcCompileProgram_fn = null,
                .nvrtcGetPTXSize_fn = null,
                .nvrtcGetPTX_fn = null,
                .nvrtcGetProgramLogSize_fn = null,
                .nvrtcGetProgramLog_fn = null,
                .allocator = allocator,
            };
        };

        // Load symbols
        const createProg = dlsym(handle, "nvrtcCreateProgram");
        const destroyProg = dlsym(handle, "nvrtcDestroyProgram");
        const compileProg = dlsym(handle, "nvrtcCompileProgram");
        const getPTXSize = dlsym(handle, "nvrtcGetPTXSize");
        const getPTX = dlsym(handle, "nvrtcGetPTX");
        const getLogSize = dlsym(handle, "nvrtcGetProgramLogSize");
        const getLog = dlsym(handle, "nvrtcGetProgramLog");

        if (createProg == null or compileProg == null or getPTXSize == null or getPTX == null) {
            _ = dlclose(handle);
            return NVRTCCompiler{
                .handle = null,
                .nvrtcCreateProgram_fn = null,
                .nvrtcDestroyProgram_fn = null,
                .nvrtcCompileProgram_fn = null,
                .nvrtcGetPTXSize_fn = null,
                .nvrtcGetPTX_fn = null,
                .nvrtcGetProgramLogSize_fn = null,
                .nvrtcGetProgramLog_fn = null,
                .allocator = allocator,
            };
        }

        return NVRTCCompiler{
            .handle = handle,
            .nvrtcCreateProgram_fn = @ptrCast(@alignCast(createProg)),
            .nvrtcDestroyProgram_fn = @ptrCast(@alignCast(destroyProg)),
            .nvrtcCompileProgram_fn = @ptrCast(@alignCast(compileProg)),
            .nvrtcGetPTXSize_fn = @ptrCast(@alignCast(getPTXSize)),
            .nvrtcGetPTX_fn = @ptrCast(@alignCast(getPTX)),
            .nvrtcGetProgramLogSize_fn = @ptrCast(@alignCast(getLogSize)),
            .nvrtcGetProgramLog_fn = @ptrCast(@alignCast(getLog)),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NVRTCCompiler) void {
        if (self.handle) |h| {
            _ = dlclose(h);
        }
    }

    pub fn available(self: *const NVRTCCompiler) bool {
        return self.nvrtcCreateProgram_fn != null and self.nvrtcCompileProgram_fn != null;
    }

    pub fn compileCudaToPTX(self: *NVRTCCompiler, cuda_source: [:0]const u8, kernel_name: [:0]const u8) ![]u8 {
        if (!self.available()) return error.NVRTCUnavailable;

        const createProg = self.nvrtcCreateProgram_fn.?;
        const destroyProg = self.nvrtcDestroyProgram_fn.?;
        const compileProg = self.nvrtcCompileProgram_fn.?;
        const getPTXSize = self.nvrtcGetPTXSize_fn.?;
        const getPTX = self.nvrtcGetPTX_fn.?;
        const getLogSize = self.nvrtcGetProgramLogSize_fn.?;
        const getLog = self.nvrtcGetProgramLog_fn.?;

        // Create program
        var prog: nvrtcProgram = undefined;
        const empty_headers: [*]const [*:0]const u8 = @ptrCast(&[_][*:0]const u8{});
        const empty_include_names: [*]const [*:0]const u8 = @ptrCast(&[_][*:0]const u8{});
        var result = createProg(&prog, cuda_source.ptr, kernel_name.ptr, 0, empty_headers, empty_include_names);
        if (result != 0) {
            std.debug.print("nvrtcCreateProgram failed: {}\n", .{result});
            return error.CompilationFailed;
        }
        defer _ = destroyProg(&prog);

        // Compile with options
        const options = [_][*:0]const u8{
            "--gpu-architecture=compute_52", // SM 5.2 for broad compatibility
            "--std=c++11",
        };
        result = compileProg(prog, options.len, &options);

        // Get compilation log if available
        var log_size: usize = 0;
        _ = getLogSize(prog, &log_size);
        if (log_size > 1) {
            const log_buf = try self.allocator.alloc(u8, log_size);
            defer self.allocator.free(log_buf);
            _ = getLog(prog, log_buf.ptr);
            if (result != 0) {
                std.debug.print("NVRTC compilation log:\n{s}\n", .{log_buf});
            }
        }

        if (result != 0) {
            std.debug.print("nvrtcCompileProgram failed: {}\n", .{result});
            return error.CompilationFailed;
        }

        // Get PTX size
        var ptx_size: usize = 0;
        result = getPTXSize(prog, &ptx_size);
        if (result != 0) {
            std.debug.print("nvrtcGetPTXSize failed: {}\n", .{result});
            return error.CompilationFailed;
        }

        // Get PTX
        const ptx_buffer = try self.allocator.alloc(u8, ptx_size);
        result = getPTX(prog, ptx_buffer.ptr);
        if (result != 0) {
            self.allocator.free(ptx_buffer);
            std.debug.print("nvrtcGetPTX failed: {}\n", .{result});
            return error.CompilationFailed;
        }

        return ptx_buffer;
    }
};

test "TestCANARY_REQ_GQL_051_NVRTCInit" {
    const allocator = std.testing.allocator;
    var compiler = NVRTCCompiler.init(allocator);
    defer compiler.deinit();

    // Test availability (may be false if nvrtc not installed)
    _ = compiler.available();
}

test "TestCANARY_REQ_GQL_051_NVRTCCompile" {
    const allocator = std.testing.allocator;
    var compiler = NVRTCCompiler.init(allocator);
    defer compiler.deinit();

    if (!compiler.available()) {
        // Skip test if NVRTC not available
        return error.SkipZigTest;
    }

    // Simple kernel for testing
    const cuda_src =
        \\ extern "C" __global__ void test_kernel(int* output) {
        \\     int tid = threadIdx.x + blockIdx.x * blockDim.x;
        \\     output[tid] = tid * 2;
        \\ }
    ;

    const ptx = try compiler.compileCudaToPTX(cuda_src, "test_kernel");
    defer allocator.free(ptx);

    try std.testing.expect(ptx.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ptx, "test_kernel") != null);
}
