const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=CudaDynamicLoader; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_CudaLoaderInit; OWNER=engine; UPDATED=2025-10-26

const RTLD_LAZY = 0x00001;
const RTLD_NOW = 0x00002;

// Dynamic loader for CUDA driver API (libcuda.so)
pub extern fn dlopen(path: [*:0]const u8, flag: i32) ?*anyopaque;
pub extern fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
pub extern fn dlclose(handle: *anyopaque) i32;
pub extern fn dlerror() ?[*:0]const u8;

// Type aliases for CUDA API
const CUresult = i32;
const CUdevice = i32;
const CUdeviceptr = u64;
const CUcontext = *anyopaque;

// Function pointer types
const cuInit_t = *const fn (u32) callconv(.c) CUresult;
const cuDeviceGetCount_t = *const fn (*i32) callconv(.c) CUresult;
const cuDeviceGet_t = *const fn (*CUdevice, i32) callconv(.c) CUresult;
const cuDeviceGetName_t = *const fn ([*]u8, i32, CUdevice) callconv(.c) CUresult;
const cuDeviceTotalMem_t = *const fn (*usize, CUdevice) callconv(.c) CUresult;
const cuCtxCreate_t = *const fn (*CUcontext, u32, CUdevice) callconv(.c) CUresult;
const cuCtxDestroy_t = *const fn (CUcontext) callconv(.c) CUresult;
const cuMemAlloc_t = *const fn (*CUdeviceptr, usize) callconv(.c) CUresult;
const cuMemFree_t = *const fn (CUdeviceptr) callconv(.c) CUresult;
const cuMemcpyHtoD_t = *const fn (CUdeviceptr, *const anyopaque, usize) callconv(.c) CUresult;
const cuMemcpyDtoH_t = *const fn (*anyopaque, CUdeviceptr, usize) callconv(.c) CUresult;

pub const CudaLoader = struct {
    handle: ?*anyopaque,
    cuInit_fn: ?cuInit_t,
    cuDeviceGetCount_fn: ?cuDeviceGetCount_t,
    cuDeviceGet_fn: ?cuDeviceGet_t,
    cuDeviceGetName_fn: ?cuDeviceGetName_t,
    cuDeviceTotalMem_fn: ?cuDeviceTotalMem_t,
    cuCtxCreate_fn: ?cuCtxCreate_t,
    cuCtxDestroy_fn: ?cuCtxDestroy_t,
    cuMemAlloc_fn: ?cuMemAlloc_t,
    cuMemFree_fn: ?cuMemFree_t,
    cuMemcpyHtoD_fn: ?cuMemcpyHtoD_t,
    cuMemcpyDtoH_fn: ?cuMemcpyDtoH_t,

    pub fn init() CudaLoader {
        if (builtin.os.tag != .linux) {
            return CudaLoader{ .handle = null, .cuInit_fn = null, .cuDeviceGetCount_fn = null, .cuDeviceGet_fn = null, .cuDeviceGetName_fn = null, .cuDeviceTotalMem_fn = null, .cuCtxCreate_fn = null, .cuCtxDestroy_fn = null, .cuMemAlloc_fn = null, .cuMemFree_fn = null, .cuMemcpyHtoD_fn = null, .cuMemcpyDtoH_fn = null };
        }

        // Try to load libcuda.so
        const handle = dlopen("libcuda.so.1", RTLD_LAZY) orelse dlopen("libcuda.so", RTLD_LAZY) orelse {
            return CudaLoader{ .handle = null, .cuInit_fn = null, .cuDeviceGetCount_fn = null, .cuDeviceGet_fn = null, .cuDeviceGetName_fn = null, .cuDeviceTotalMem_fn = null, .cuCtxCreate_fn = null, .cuCtxDestroy_fn = null, .cuMemAlloc_fn = null, .cuMemFree_fn = null, .cuMemcpyHtoD_fn = null, .cuMemcpyDtoH_fn = null };
        };

        // Load symbols
        const cuInit_sym = dlsym(handle, "cuInit");
        const cuDeviceGetCount_sym = dlsym(handle, "cuDeviceGetCount");
        const cuDeviceGet_sym = dlsym(handle, "cuDeviceGet");
        const cuDeviceGetName_sym = dlsym(handle, "cuDeviceGetName");
        const cuDeviceTotalMem_sym = dlsym(handle, "cuDeviceTotalMem_v2");
        const cuCtxCreate_sym = dlsym(handle, "cuCtxCreate_v2");
        const cuCtxDestroy_sym = dlsym(handle, "cuCtxDestroy_v2");
        const cuMemAlloc_sym = dlsym(handle, "cuMemAlloc_v2");
        const cuMemFree_sym = dlsym(handle, "cuMemFree_v2");
        const cuMemcpyHtoD_sym = dlsym(handle, "cuMemcpyHtoD_v2");
        const cuMemcpyDtoH_sym = dlsym(handle, "cuMemcpyDtoH_v2");

        if (cuInit_sym == null or cuDeviceGetCount_sym == null) {
            _ = dlclose(handle);
            return CudaLoader{ .handle = null, .cuInit_fn = null, .cuDeviceGetCount_fn = null, .cuDeviceGet_fn = null, .cuDeviceGetName_fn = null, .cuDeviceTotalMem_fn = null, .cuCtxCreate_fn = null, .cuCtxDestroy_fn = null, .cuMemAlloc_fn = null, .cuMemFree_fn = null, .cuMemcpyHtoD_fn = null, .cuMemcpyDtoH_fn = null };
        }

        return CudaLoader{
            .handle = handle,
            .cuInit_fn = @ptrCast(@alignCast(cuInit_sym)),
            .cuDeviceGetCount_fn = @ptrCast(@alignCast(cuDeviceGetCount_sym)),
            .cuDeviceGet_fn = @ptrCast(@alignCast(cuDeviceGet_sym)),
            .cuDeviceGetName_fn = @ptrCast(@alignCast(cuDeviceGetName_sym)),
            .cuDeviceTotalMem_fn = @ptrCast(@alignCast(cuDeviceTotalMem_sym)),
            .cuCtxCreate_fn = @ptrCast(@alignCast(cuCtxCreate_sym)),
            .cuCtxDestroy_fn = @ptrCast(@alignCast(cuCtxDestroy_sym)),
            .cuMemAlloc_fn = @ptrCast(@alignCast(cuMemAlloc_sym)),
            .cuMemFree_fn = @ptrCast(@alignCast(cuMemFree_sym)),
            .cuMemcpyHtoD_fn = @ptrCast(@alignCast(cuMemcpyHtoD_sym)),
            .cuMemcpyDtoH_fn = @ptrCast(@alignCast(cuMemcpyDtoH_sym)),
        };
    }

    pub fn deinit(self: *CudaLoader) void {
        if (self.handle) |h| _ = dlclose(h);
        self.handle = null;
    }

    pub fn available(self: *const CudaLoader) bool {
        return self.handle != null and self.cuInit_fn != null;
    }

    pub fn cuInit(self: *const CudaLoader, flags: u32) CUresult {
        if (self.cuInit_fn) |fn_ptr| return fn_ptr(flags);
        return -1;
    }

    pub fn cuDeviceGetCount(self: *const CudaLoader, count: *i32) CUresult {
        if (self.cuDeviceGetCount_fn) |fn_ptr| return fn_ptr(count);
        return -1;
    }

    pub fn cuDeviceGet(self: *const CudaLoader, device: *CUdevice, ordinal: i32) CUresult {
        if (self.cuDeviceGet_fn) |fn_ptr| return fn_ptr(device, ordinal);
        return -1;
    }

    pub fn cuDeviceGetName(self: *const CudaLoader, name: [*]u8, len: i32, dev: CUdevice) CUresult {
        if (self.cuDeviceGetName_fn) |fn_ptr| return fn_ptr(name, len, dev);
        return -1;
    }

    pub fn cuDeviceTotalMem(self: *const CudaLoader, bytes: *usize, dev: CUdevice) CUresult {
        if (self.cuDeviceTotalMem_fn) |fn_ptr| return fn_ptr(bytes, dev);
        return -1;
    }

    pub fn memAlloc(self: *const CudaLoader, dptr: *CUdeviceptr, bytesize: usize) CUresult {
        if (self.cuMemAlloc_fn) |fn_ptr| return fn_ptr(dptr, bytesize);
        return -1;
    }

    pub fn memFree(self: *const CudaLoader, dptr: CUdeviceptr) CUresult {
        if (self.cuMemFree_fn) |fn_ptr| return fn_ptr(dptr);
        return -1;
    }

    pub fn memcpyHtoD(self: *const CudaLoader, dst_device: CUdeviceptr, src_host: *const anyopaque, byte_count: usize) CUresult {
        if (self.cuMemcpyHtoD_fn) |fn_ptr| return fn_ptr(dst_device, src_host, byte_count);
        return -1;
    }

    pub fn memcpyDtoH(self: *const CudaLoader, dst_host: *anyopaque, src_device: CUdeviceptr, byte_count: usize) CUresult {
        if (self.cuMemcpyDtoH_fn) |fn_ptr| return fn_ptr(dst_host, src_device, byte_count);
        return -1;
    }
};

test "TestCANARY_REQ_GQL_051_CudaLoaderInit" {
    var loader = CudaLoader.init();
    defer loader.deinit();
    // Test passes whether CUDA available or not
    if (loader.available()) {
        try std.testing.expect(loader.cuInit(0) == 0);
        var count: i32 = 0;
        _ = loader.cuDeviceGetCount(&count);
        // count may be 0 if no devices, but call should succeed
    }
}
