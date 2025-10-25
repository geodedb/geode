const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase0Infra; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUPhase0DeviceEnum; OWNER=engine; UPDATED=2025-10-25

pub const DeviceInfo = struct {
    id: u32,
    name: []const u8,
    sm_count: u32,
    total_mem: usize,
    warp_size: u32,
    available: bool,
};

extern fn cuInit(flags: cu_uint) cu_int;
extern fn cuDeviceGetCount(count: *cu_int) cu_int;
extern fn cuDeviceGet(device: *cu_int, ordinal: cu_int) cu_int;
extern fn cuDeviceGetName(name: [*]u8, len: cu_int, dev: cu_int) cu_int;
extern fn cuDeviceTotalMem(bytes: *usize, dev: cu_int) cu_int;

const cu_uint = u32;
const cu_int = i32;

pub fn enumerate(allocator: std.mem.Allocator) ![]DeviceInfo {
    if (builtin.os.tag != .linux) {
        return &[_]DeviceInfo{DeviceInfo{ .id = 0, .name = "non-linux", .sm_count = 0, .total_mem = 0, .warp_size = 32, .available = false }};
    }
    var count: cu_int = 0;
    if (cuInit(0) != 0 or cuDeviceGetCount(&count) != 0 or count <= 0) {
        return &[_]DeviceInfo{DeviceInfo{ .id = 0, .name = "cuda-unavailable", .sm_count = 0, .total_mem = 0, .warp_size = 32, .available = false }};
    }
    var list = try std.ArrayList(DeviceInfo).initCapacity(allocator, @intCast(count));
    defer list.deinit(); // borrowed allocator
    var i: cu_int = 0;
    while (i < count) : (i += 1) {
        var dev: cu_int = 0;
        if (cuDeviceGet(&dev, i) != 0) continue;
        var buf: [128]u8 = undefined;
        _ = cuDeviceGetName(&buf, 128, dev);
        var name_len: usize = 0;
        while (name_len < buf.len and buf[name_len] != 0) : (name_len += 1) {}
        var total_mem: usize = 0;
        _ = cuDeviceTotalMem(&total_mem, dev);
        try list.append(allocator, .{ .id = @intCast(i), .name = buf[0..name_len], .sm_count = 0, .total_mem = total_mem, .warp_size = 32, .available = true });
    }
    return try list.toOwnedSlice(allocator);
}

pub fn gpuEnabled() bool {
    if (builtin.os.tag != .linux) return false;
    var count: cu_int = 0;
    if (cuInit(0) != 0 or cuDeviceGetCount(&count) != 0) return false;
    return count > 0;
}

// Simple heuristic threshold placeholder
pub fn shouldUseGpu(edge_count: usize, selectivity: f64) bool {
    if (!gpuEnabled()) return false;
    return edge_count > 50_000 and selectivity > 0.05;
}

test "TestCANARY_REQ_GQL_051_GPUPhase0DeviceEnum" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
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
