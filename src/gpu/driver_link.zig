// Provide weak wrappers that map to system libdl symbols when available.
// When building without driver_link injection, these will be no-ops.

pub extern fn __libc_dlopen(path: [*]const u8, flag: i32) ?*anyopaque {
    // implemented by system libdl at link time when available
    return null;
}

pub extern fn __libc_dlsym(handle: ?*anyopaque, symbol: [*]const u8) ?*anyopaque {
    return null;
}

pub extern fn __libc_dlclose(handle: *anyopaque) i32 {
    return 0;
}

// Expose cuInit symbol weakly as well to allow linking libcuda when present.
pub extern fn cuInit(flags: u32) i32 {
    return -1;
}
