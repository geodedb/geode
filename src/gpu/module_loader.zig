const std = @import("std");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=ModuleLoader; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_ModuleLoader; OWNER=engine; UPDATED=2025-10-26

const CUresult = i32;
const CUmodule = *anyopaque;
const CUfunction = *anyopaque;
const CUstream = *anyopaque;
const CUdeviceptr = u64;
const CUcontext = *anyopaque;
const CUdevice = i32;

pub const ModuleLoader = struct {
    loader: *const CudaLoader,
    module: ?CUmodule,
    context: ?CUcontext,
    device: CUdevice,

    cuModuleLoadData_fn: ?*const fn (*CUmodule, *const anyopaque) callconv(.c) CUresult,
    cuModuleGetFunction_fn: ?*const fn (*CUfunction, CUmodule, [*:0]const u8) callconv(.c) CUresult,
    cuLaunchKernel_fn: ?*const fn (
        CUfunction,
        u32,
        u32,
        u32, // grid dim
        u32,
        u32,
        u32, // block dim
        u32, // shared mem
        ?*anyopaque, // stream (nullable)
        *anyopaque, // kernel params
        ?*anyopaque, // extra (nullable)
    ) callconv(.c) CUresult,

    pub fn init(loader: *const CudaLoader) !ModuleLoader {
        if (!loader.available()) {
            return error.GPUUnavailable;
        }

        // Initialize CUDA and get device
        if (loader.cuInit(0) != 0) return error.GPUInitFailed;

        var device: CUdevice = 0;
        if (loader.cuDeviceGet(&device, 0) != 0) return error.GPUDeviceNotFound;

        // Create CUDA context
        var context: CUcontext = undefined;
        if (loader.cuCtxCreate(&context, 0, device) != 0) return error.GPUContextCreateFailed;

        // Load additional symbols for module management
        const handle = loader.handle orelse return error.GPUUnavailable;

        const cuModuleLoadData_sym = @import("cuda_loader.zig").dlsym(handle, "cuModuleLoadData");
        const cuModuleGetFunction_sym = @import("cuda_loader.zig").dlsym(handle, "cuModuleGetFunction");
        const cuLaunchKernel_sym = @import("cuda_loader.zig").dlsym(handle, "cuLaunchKernel");

        return ModuleLoader{
            .loader = loader,
            .module = null,
            .context = context,
            .device = device,
            .cuModuleLoadData_fn = if (cuModuleLoadData_sym) |sym| @ptrCast(@alignCast(sym)) else null,
            .cuModuleGetFunction_fn = if (cuModuleGetFunction_sym) |sym| @ptrCast(@alignCast(sym)) else null,
            .cuLaunchKernel_fn = if (cuLaunchKernel_sym) |sym| @ptrCast(@alignCast(sym)) else null,
        };
    }

    pub fn deinit(self: *ModuleLoader) void {
        if (self.context) |ctx| {
            _ = self.loader.cuCtxDestroy(ctx);
        }
    }

    pub fn loadPTX(self: *ModuleLoader, ptx_source: []const u8) !void {
        if (self.cuModuleLoadData_fn == null) return error.GPUUnavailable;

        var module: CUmodule = undefined;
        const result = self.cuModuleLoadData_fn.?(&module, ptx_source.ptr);
        if (result != 0) return error.ModuleLoadFailed;

        self.module = module;
    }

    pub fn getFunction(self: *const ModuleLoader, name: []const u8) !CUfunction {
        if (self.cuModuleGetFunction_fn == null or self.module == null) {
            return error.GPUUnavailable;
        }

        var func: CUfunction = undefined;
        const name_z = try std.heap.page_allocator.dupeZ(u8, name);
        defer std.heap.page_allocator.free(name_z);

        const result = self.cuModuleGetFunction_fn.?(&func, self.module.?, name_z.ptr);
        if (result != 0) return error.FunctionNotFound;

        return func;
    }

    pub fn launchKernel(
        self: *const ModuleLoader,
        func: CUfunction,
        grid_dim: [3]u32,
        block_dim: [3]u32,
        shared_mem: u32,
        params: *anyopaque,
    ) !void {
        if (self.cuLaunchKernel_fn == null) return error.GPUUnavailable;

        const result = self.cuLaunchKernel_fn.?(
            func,
            grid_dim[0],
            grid_dim[1],
            grid_dim[2],
            block_dim[0],
            block_dim[1],
            block_dim[2],
            shared_mem,
            null, // stream
            params,
            null, // extra
        );

        if (result != 0) return error.KernelLaunchFailed;

        // Synchronize to wait for kernel completion
        if (self.loader.cuCtxSynchronize() != 0) return error.SynchronizeFailed;
    }
};

test "TestCANARY_REQ_GQL_051_ModuleLoader" {
    const loader = CudaLoader.init();
    if (!loader.available()) {
        // Skip if CUDA unavailable
        return;
    }

    var mod_loader = ModuleLoader.init(&loader) catch |err| {
        if (err == error.GPUUnavailable or err == error.GPUInitFailed or err == error.GPUDeviceNotFound or err == error.GPUContextCreateFailed) return;
        return err;
    };
    defer mod_loader.deinit();

    // Test structure created successfully
    try std.testing.expect(mod_loader.loader.available());
    try std.testing.expect(mod_loader.context != null);
}
