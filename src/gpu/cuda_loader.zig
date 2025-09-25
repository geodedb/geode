const std = @import("std");
const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("cuda.h");
});

pub const Cuda = struct {
    lib_handle: ?*anyopaque,
    // function pointers
    cuInit: ?*c.void,
};
