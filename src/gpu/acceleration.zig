//! GPU device detection and status reporting.
//!
//! GAP-0878: this module reports the TRUTH about GPU availability. Backend
//! `.none` (and any backend whose driver is absent) yields ZERO devices and
//! `available = false`. No mock/fake device is ever fabricated. Real device
//! enumeration is implemented for the CUDA backend only, via the dlopen-based
//! `cuda_loader.zig` (no CUDA headers required at build time); all other
//! backends currently report no devices (detection not implemented).
const std = @import("std");
const Allocator = std.mem.Allocator;
const CudaLoader = @import("cuda_loader.zig").CudaLoader;

pub const GPUBackend = enum { none, cuda, opencl, vulkan, metal, webgpu };

pub const GPUDevice = struct {
    id: u32,
    name: []const u8,
    memory_size: usize,
    compute_units: u32,
    max_threads_per_block: u32,
    backend: GPUBackend,
    is_available: bool,
};

pub const GPUStatus = struct {
    backend: GPUBackend,
    available: bool,
    device_count: usize,
};

pub const GPUAccelerator = struct {
    allocator: Allocator,
    backend: GPUBackend,
    devices: std.ArrayList(GPUDevice),
    active_device: ?u32,

    const Self = @This();

    pub fn init(allocator: Allocator, backend: GPUBackend) !Self {
        var accel = Self{
            .allocator = allocator,
            .backend = backend,
            .devices = std.ArrayList(GPUDevice).empty,
            .active_device = null,
        };
        errdefer accel.deinit();
        try accel.detectDevices();
        return accel;
    }

    pub fn deinit(self: *Self) void {
        for (self.devices.items) |dev| self.allocator.free(dev.name);
        self.devices.deinit(self.allocator);
    }

    /// Enumerate real devices for the configured backend. Backends without a
    /// working driver (or without an implemented detection path) leave the
    /// device list empty -- callers must check `status().available`.
    fn detectDevices(self: *Self) !void {
        switch (self.backend) {
            .none => return, // explicitly no GPU: zero devices, never a mock
            .cuda => try self.detectCudaDevices(),
            // Detection not implemented for these backends yet: report none.
            .opencl, .vulkan, .metal, .webgpu => return,
        }
    }

    fn detectCudaDevices(self: *Self) !void {
        const loader = CudaLoader.init();
        if (!loader.available()) return;
        if (loader.cuInit(0) != 0) return;
        var count: i32 = 0;
        if (loader.cuDeviceGetCount(&count) != 0 or count <= 0) return;
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            var dev: i32 = 0;
            if (loader.cuDeviceGet(&dev, i) != 0) continue;
            var buf: [256]u8 = undefined;
            _ = loader.cuDeviceGetName(&buf, buf.len, dev);
            var name_len: usize = 0;
            while (name_len < buf.len and buf[name_len] != 0) : (name_len += 1) {}
            const name = try self.allocator.dupe(u8, buf[0..name_len]);
            errdefer self.allocator.free(name);
            var total_mem: usize = 0;
            _ = loader.cuDeviceTotalMem(&total_mem, dev);
            try self.devices.append(self.allocator, GPUDevice{
                .id = @intCast(self.devices.items.len),
                .name = name,
                .memory_size = total_mem,
                .compute_units = 0,
                .max_threads_per_block = 1024,
                .backend = .cuda,
                .is_available = true,
            });
        }
        if (self.devices.items.len > 0) self.active_device = 0;
    }

    /// Devices actually detected. Empty when no GPU is present or the backend
    /// is `.none` -- never contains a fabricated device.
    pub fn listDevices(self: *const Self) []const GPUDevice {
        return self.devices.items;
    }

    pub fn status(self: *const Self) GPUStatus {
        return GPUStatus{
            .backend = self.backend,
            .available = self.active_device != null and self.devices.items.len > 0,
            .device_count = self.devices.items.len,
        };
    }
};

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=DeviceDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_051_GPUNoneBackendReportsNoDevice; OWNER=engine; UPDATED=2026-06-11

test "TestCANARY_REQ_GQL_051_GPUNoneBackendReportsNoDevice" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var accel = try GPUAccelerator.init(alloc, .none);
    defer accel.deinit();

    try std.testing.expectEqual(@as(usize, 0), accel.listDevices().len);
    const st = accel.status();
    try std.testing.expect(!st.available);
    try std.testing.expectEqual(@as(usize, 0), st.device_count);
    try std.testing.expectEqual(GPUBackend.none, st.backend);
    try std.testing.expectEqual(@as(?u32, null), accel.active_device);
}

test "TestCANARY_REQ_GQL_051_GPUUnimplementedBackendsReportNoDevice" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    inline for (.{ GPUBackend.opencl, GPUBackend.vulkan, GPUBackend.metal, GPUBackend.webgpu }) |backend| {
        var accel = try GPUAccelerator.init(alloc, backend);
        defer accel.deinit();
        try std.testing.expectEqual(@as(usize, 0), accel.listDevices().len);
        try std.testing.expect(!accel.status().available);
    }
}

test "TestCANARY_REQ_GQL_051_GPUCudaBackendIsTruthful" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var accel = try GPUAccelerator.init(alloc, .cuda);
    defer accel.deinit();

    const st = accel.status();
    if (st.available) {
        // Real driver + device: every listed device must be a real CUDA device.
        try std.testing.expect(st.device_count > 0);
        for (accel.listDevices()) |dev| {
            try std.testing.expectEqual(GPUBackend.cuda, dev.backend);
            try std.testing.expect(dev.is_available);
            try std.testing.expect(!std.mem.eql(u8, dev.name, "Mock GPU Device"));
        }
    } else {
        // No driver/device: must report zero devices, not a mock.
        try std.testing.expectEqual(@as(usize, 0), st.device_count);
    }
}
