const std = @import("std");

const c = @cImport({
    @cInclude("cuda.h");
});

pub const CudaLoader = struct {
    pub fn init() i32 {
        return c.cuInit(0);
    }

    pub fn device_get_count(count_ptr: *i32) i32 {
        return c.cuDeviceGetCount(count_ptr);
    }

    pub fn device_get(device_ptr: *i32, ordinal: i32) i32 {
        return c.cuDeviceGet(device_ptr, ordinal);
    }

    pub fn device_get_name(buf: [*]u8, len: i32, device: i32) i32 {
        return c.cuDeviceGetName(buf, len, device);
    }

    // Additional wrappers can be added as needed (ctx create, module load, memalloc, memcpy, launch)
};
