//! GAP-0878: honest GPU device reporting.
//!
//! Pins the contract that `GPUAccelerator` never fabricates a device:
//! - backend `.none` => listDevices() is empty, status().available == false
//! - backends without an implemented detection path (opencl/vulkan/metal/
//!   webgpu) => zero devices, available == false
//! - backend `.cuda` => either real devices from the dlopen'd driver, or
//!   zero devices when no driver/hardware is present; never a "Mock GPU
//!   Device".
//!
//! Run with: zig build test-gap0878
const std = @import("std");
const accel = @import("gpu_acceleration");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=TruthfulDeviceReporting; STATUS=TESTED; TEST=TestGAP0878_NoneBackendZeroDevices; OWNER=engine; UPDATED=2026-06-11

test "TestGAP0878_NoneBackendZeroDevices" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var gpu = try accel.GPUAccelerator.init(alloc, .none);
    defer gpu.deinit();

    try std.testing.expectEqual(@as(usize, 0), gpu.listDevices().len);

    const st = gpu.status();
    try std.testing.expect(!st.available);
    try std.testing.expectEqual(@as(usize, 0), st.device_count);
    try std.testing.expectEqual(accel.GPUBackend.none, st.backend);
    try std.testing.expectEqual(@as(?u32, null), gpu.active_device);
}

test "TestGAP0878_UnimplementedBackendsZeroDevices" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    inline for (.{ accel.GPUBackend.opencl, accel.GPUBackend.vulkan, accel.GPUBackend.metal, accel.GPUBackend.webgpu }) |backend| {
        var gpu = try accel.GPUAccelerator.init(alloc, backend);
        defer gpu.deinit();
        try std.testing.expectEqual(@as(usize, 0), gpu.listDevices().len);
        try std.testing.expect(!gpu.status().available);
        try std.testing.expectEqual(@as(usize, 0), gpu.status().device_count);
    }
}

test "TestGAP0878_CudaBackendNeverFabricatesDevice" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var gpu = try accel.GPUAccelerator.init(alloc, .cuda);
    defer gpu.deinit();

    const st = gpu.status();
    if (st.available) {
        // Real driver + device present: all entries must be real CUDA devices.
        try std.testing.expect(st.device_count > 0);
        try std.testing.expectEqual(st.device_count, gpu.listDevices().len);
        for (gpu.listDevices()) |dev| {
            try std.testing.expectEqual(accel.GPUBackend.cuda, dev.backend);
            try std.testing.expect(dev.is_available);
            try std.testing.expect(dev.name.len > 0);
            try std.testing.expect(!std.mem.eql(u8, dev.name, "Mock GPU Device"));
        }
    } else {
        // No driver/hardware: zero devices -- never a mock fallback.
        try std.testing.expectEqual(@as(usize, 0), st.device_count);
        try std.testing.expectEqual(@as(usize, 0), gpu.listDevices().len);
        try std.testing.expectEqual(@as(?u32, null), gpu.active_device);
    }
}
