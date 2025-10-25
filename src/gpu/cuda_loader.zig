const std = @import("std");
pub extern fn dlopen(path: [*]const u8, flag: i32) ?*anyopaque;
pub extern fn dlsym(handle: ?*anyopaque, symbol: [*]const u8) ?*anyopaque;
pub extern fn dlclose(handle: *anyopaque) i32;
// NOTE: build.zig does not explicitly link -ldl; rely on Zig's implicit libc linkage. If missing, availability() will return false.

// On non-Linux or when libdl unavailable we stub out (tests skip)
comptime {
    if (@import("builtin").os.tag != .linux) @compileError("libdl only supported on linux for CUDA dynamic load");
}

pub const CudaLoader = struct {
    // minimal stub when libdl not linked; availability false

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
        // Stub: dynamic loader disabled (libdl not linked in test builds). All symbols null.
        return CudaLoader{ .handle = null, .cuInit_sym = null, .cuDeviceGetCount_sym = null, .cuDeviceGet_sym = null, .cuDeviceGetName_sym = null, .cuMemAlloc_sym = null, .cuMemFree_sym = null, .cuMemcpyHtoD_sym = null, .cuMemcpyDtoH_sym = null };
    }

    pub fn deinit(self: *CudaLoader) void {
        if (self.handle) |h| _ = dlclose(h);
        self.handle = null;
    }

    pub fn available(self: *CudaLoader) bool {
        return self.handle != null and self.cuInit_sym != null;
    }

    pub fn cuInit(_: *CudaLoader) i32 {
        return -1; // stubbed - dynamic dispatch disabled in minimal GPU feature
    }

    pub fn cuDeviceGetCount(_: *CudaLoader, _: *i32) i32 {
        return -1;
    }

    pub fn cuDeviceGet(_: *CudaLoader, _: *i32, _: i32) i32 {
        return -1;
    }

    pub fn cuDeviceGetName(_: *CudaLoader, _: [*]u8, _: i32, _: i32) i32 {
        return -1;
    }

    pub fn memAlloc(_: *CudaLoader, _: *usize, _: usize) i32 {
        return -1;
    }

    pub fn memFree(_: *CudaLoader, _: usize) i32 {
        return -1;
    }

    pub fn memcpyHtoD(_: *CudaLoader, _: usize, _: ?*anyopaque, _: usize) i32 {
        return -1;
    }

    pub fn memcpyDtoH(_: *CudaLoader, _: ?*anyopaque, _: usize, _: usize) i32 {
        return -1;
    }
};
