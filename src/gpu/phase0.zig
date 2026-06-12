const std = @import("std");
const builtin = @import("builtin");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase0Infra; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUPhase0DeviceEnum; OWNER=engine; UPDATED=2025-10-26

pub const DeviceInfo = struct {
    id: u32,
    name: []const u8,
    sm_count: u32,
    total_mem: usize,
    warp_size: u32,
    available: bool,
};

var global_loader: ?CudaLoader = null;
var loader_init_mutex: std.Io.Mutex = std.Io.Mutex.init;

fn getLoader() *const CudaLoader {
    const io = std.Io.Threaded.global_single_threaded.io();
    loader_init_mutex.lockUncancelable(io);
    defer loader_init_mutex.unlock(io);
    if (global_loader == null) global_loader = CudaLoader.init();
    return &global_loader.?;
}

pub fn enumerate(allocator: std.mem.Allocator) ![]DeviceInfo {
    if (builtin.os.tag != .linux) {
        var tmp = [_]DeviceInfo{DeviceInfo{ .id = 0, .name = "non-linux", .sm_count = 0, .total_mem = 0, .warp_size = 32, .available = false }};
        const dup = try allocator.dupe(DeviceInfo, tmp[0..]);
        return dup;
    }

    const loader = getLoader();
    if (!loader.available()) {
        var tmp = [_]DeviceInfo{DeviceInfo{ .id = 0, .name = "cuda-unavailable", .sm_count = 0, .total_mem = 0, .warp_size = 32, .available = false }};
        const dup = try allocator.dupe(DeviceInfo, tmp[0..]);
        return dup;
    }

    var count: i32 = 0;
    if (loader.cuInit(0) != 0 or loader.cuDeviceGetCount(&count) != 0 or count <= 0) {
        var tmp = [_]DeviceInfo{DeviceInfo{ .id = 0, .name = "cuda-unavailable", .sm_count = 0, .total_mem = 0, .warp_size = 32, .available = false }};
        const dup = try allocator.dupe(DeviceInfo, tmp[0..]);
        return dup;
    }

    var list = try std.ArrayList(DeviceInfo).initCapacity(allocator, @intCast(count));
    defer list.deinit(allocator);

    var i: i32 = 0;
    while (i < count) : (i += 1) {
        var dev: i32 = 0;
        if (loader.cuDeviceGet(&dev, i) != 0) continue;
        var buf: [128]u8 = undefined;
        _ = loader.cuDeviceGetName(&buf, 128, dev);
        var name_len: usize = 0;
        while (name_len < buf.len and buf[name_len] != 0) : (name_len += 1) {}
        var total_mem: usize = 0;
        _ = loader.cuDeviceTotalMem(&total_mem, dev);
        try list.append(allocator, .{ .id = @intCast(i), .name = buf[0..name_len], .sm_count = 0, .total_mem = total_mem, .warp_size = 32, .available = true });
    }
    return try list.toOwnedSlice(allocator);
}

pub fn gpuEnabled() bool {
    if (builtin.os.tag != .linux) return false;
    const loader = getLoader();
    if (!loader.available()) return false;
    var count: i32 = 0;
    if (loader.cuInit(0) != 0 or loader.cuDeviceGetCount(&count) != 0) return false;
    return count > 0;
}

// Simple heuristic threshold placeholder
pub fn shouldUseGpu(edge_count: usize, selectivity: f64) bool {
    if (!gpuEnabled()) return false;
    return edge_count > 50_000 and selectivity > 0.05;
}

test "TestCANARY_REQ_GQL_051_GPUPhase0DeviceEnum" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const infos = try enumerate(alloc);
    defer alloc.free(infos);
    // Pass even if unavailable, but record behavior
    if (gpuEnabled()) {
        try std.testing.expect(infos.len > 0);
        try std.testing.expect(infos[0].available);
    } else {
        try std.testing.expect(infos.len == 1);
        try std.testing.expect(!infos[0].available);
    }
}
