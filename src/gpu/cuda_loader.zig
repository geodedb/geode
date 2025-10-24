extern fn dlopen(path: [*]const u8, flag: i32) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*]const u8) ?*anyopaque;
extern fn dlclose(handle: *anyopaque) i32;

const std = @import("std");

pub const CudaLoader = struct {
    handle: ?*anyopaque,
    cuInit_sym: ?*anyopaque,
    cuDeviceGetCount_sym: ?*anyopaque,
    cuDeviceGet_sym: ?*anyopaque,
    cuDeviceGetName_sym: ?*anyopaque,
    cuMemAlloc_sym: ?*anyopaque,
    cuMemFree_sym: ?*anyopaque,
    cuMemcpyHtoD_sym: ?*anyopaque,
    cuMemcpyDtoH_sym: ?*anyopaque,

    pub fn init() CudaLoader {
        const candidates = [_][*]const u8{ "libcuda.so", "libcuda.so.1", "libcuda.so.440" };
        var found: ?*anyopaque = null;
        var i: usize = 0;
        while (i < candidates.len) : (i += 1) {
            const h = dlopen(candidates[i], 1);
            if (h != null) {
                found = h;
                break;
            }
        }
        if (found == null) return CudaLoader{ .handle = null, .cuInit_sym = null, .cuDeviceGetCount_sym = null, .cuDeviceGet_sym = null, .cuDeviceGetName_sym = null, .cuMemAlloc_sym = null, .cuMemFree_sym = null, .cuMemcpyHtoD_sym = null, .cuMemcpyDtoH_sym = null };
        const loader = CudaLoader{
            .handle = found,
            .cuInit_sym = dlsym(found, "cuInit"),
            .cuDeviceGetCount_sym = dlsym(found, "cuDeviceGetCount"),
            .cuDeviceGet_sym = dlsym(found, "cuDeviceGet"),
            .cuDeviceGetName_sym = dlsym(found, "cuDeviceGetName"),
            .cuMemAlloc_sym = dlsym(found, "cuMemAlloc"),
            .cuMemFree_sym = dlsym(found, "cuMemFree"),
            .cuMemcpyHtoD_sym = dlsym(found, "cuMemcpyHtoD"),
            .cuMemcpyDtoH_sym = dlsym(found, "cuMemcpyDtoH"),
        };
        return loader;
    }

    pub fn deinit(self: *CudaLoader) void {
        if (self.handle) |h| _ = dlclose(h);
        self.handle = null;
    }

    pub fn available(self: *CudaLoader) bool {
        return self.handle != null and self.cuInit_sym != null;
    }

    pub fn cuInit(self: *CudaLoader) i32 {
        if (self.cuInit_sym == null) return -1;
        const f = @ptrCast(fn (u32) i32, self.cuInit_sym.?);
        return f(0);
    }

    pub fn cuDeviceGetCount(self: *CudaLoader, out: *i32) i32 {
        if (self.cuDeviceGetCount_sym == null) return -1;
        const f = @ptrCast(fn (*i32) i32, self.cuDeviceGetCount_sym.?);
        return f(out);
    }

    pub fn cuDeviceGet(self: *CudaLoader, out: *i32, ordinal: i32) i32 {
        if (self.cuDeviceGet_sym == null) return -1;
        const f = @ptrCast(fn (*i32, i32) i32, self.cuDeviceGet_sym.?);
        return f(out, ordinal);
    }

    pub fn cuDeviceGetName(self: *CudaLoader, name: [*]u8, len: i32, dev: i32) i32 {
        if (self.cuDeviceGetName_sym == null) return -1;
        const f = @ptrCast(fn ([*]u8, i32, i32) i32, self.cuDeviceGetName_sym.?);
        return f(name, len, dev);
    }

    pub fn memAlloc(self: *CudaLoader, dptr: *usize, bytesize: usize) i32 {
        if (self.cuMemAlloc_sym == null) return -1;
        const f = @ptrCast(fn (*usize, usize) i32, self.cuMemAlloc_sym.?);
        return f(dptr, bytesize);
    }

    pub fn memFree(self: *CudaLoader, dptr: usize) i32 {
        if (self.cuMemFree_sym == null) return -1;
        const f = @ptrCast(fn (usize) i32, self.cuMemFree_sym.?);
        return f(dptr);
    }

    pub fn memcpyHtoD(self: *CudaLoader, dst: usize, src: ?*anyopaque, len: usize) i32 {
        if (self.cuMemcpyHtoD_sym == null) return -1;
        const f = @ptrCast(fn (usize, ?*anyopaque, usize) i32, self.cuMemcpyHtoD_sym.?);
        return f(dst, src, len);
    }

    pub fn memcpyDtoH(self: *CudaLoader, dst: ?*anyopaque, src: usize, len: usize) i32 {
        if (self.cuMemcpyDtoH_sym == null) return -1;
        const f = @ptrCast(fn (?*anyopaque, usize, usize) i32, self.cuMemcpyDtoH_sym.?);
        return f(dst, src, len);
    }
};
