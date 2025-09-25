const std = @import("std");

const c = @cImport({
    @cInclude("cuda.h");
});

pub const CudaLoader = struct {
    pub fn init() c.CUresult {
        return c.cuInit(0);
    }

    pub fn device_get_count(count_ptr: *i32) c.CUresult {
        return c.cuDeviceGetCount(count_ptr);
    }

    pub fn device_get(device_ptr: *c.CUdevice, ordinal: i32) c.CUresult {
        return c.cuDeviceGet(device_ptr, ordinal);
    }

    pub fn device_get_name(buf: [*]u8, len: i32, device: c.CUdevice) c.CUresult {
        return c.cuDeviceGetName(buf, len, device);
    }

    pub fn ctx_create(ctx_ptr: *c.CUcontext, flags: u32, dev: c.CUdevice) c.CUresult {
        return c.cuCtxCreate(ctx_ptr, flags, dev);
    }

    pub fn module_load_data_ex(module_ptr: *c.CUmodule, data: ?*anyopaque) c.CUresult {
        return c.cuModuleLoadDataEx(module_ptr, data, 0, null, null);
    }

    pub fn module_get_function(func_ptr: *c.CUfunction, module: c.CUmodule, name: [*]const u8) c.CUresult {
        return c.cuModuleGetFunction(func_ptr, module, name);
    }

    pub fn launch_kernel(f: c.CUfunction, gridDimX: u32, gridDimY: u32, gridDimZ: u32, blockDimX: u32, blockDimY: u32, blockDimZ: u32, sharedMemBytes: u32, hStream: c.CUstream, kernelParams: ?*anyopaque, extra: ?*anyopaque) c.CUresult {
        return c.cuLaunchKernel(f, gridDimX, gridDimY, gridDimZ, blockDimX, blockDimY, blockDimZ, sharedMemBytes, hStream, kernelParams, extra);
    }

    pub fn mem_alloc(dptr: *c.CUdeviceptr, bytesize: usize) c.CUresult {
        return c.cuMemAlloc(dptr, bytesize);
    }

    pub fn mem_free(dptr: c.CUdeviceptr) c.CUresult {
        return c.cuMemFree(dptr);
    }

    pub fn memcpy_htod(dstDevice: c.CUdeviceptr, srcHost: ?*anyopaque, bytesize: usize) c.CUresult {
        return c.cuMemcpyHtoD(dstDevice, srcHost, bytesize);
    }

    pub fn memcpy_dtoh(dstHost: ?*anyopaque, srcDevice: c.CUdeviceptr, bytesize: usize) c.CUresult {
        return c.cuMemcpyDtoH(dstHost, srcDevice, bytesize);
    }
};
