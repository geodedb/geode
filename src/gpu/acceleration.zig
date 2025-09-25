const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("cuda.h");
});

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

pub const KernelCompiled = struct { module: c.CUmodule, func: c.CUfunction };

pub const GPUKernel = struct {
    name: []const u8,
    source: []const u8,
    compiled: ?*KernelCompiled = null,
    work_group_size: [3]u32,
};

pub const GPUBuffer = struct {
    host_ptr: ?*u8,
    device_ptr: c.CUdeviceptr,
    size: usize,
    device_id: u32,
    is_host_visible: bool,
};

pub const GraphAlgorithmKernel = enum { bfs, dfs, pagerank, betweenness_centrality, shortest_path };

pub const GPUAccelerator = struct {
    allocator: Allocator,
    backend: GPUBackend,
    devices: std.ArrayList(GPUDevice),
    active_device: ?u32,
    kernels: std.StringHashMap(*GPUKernel),
    buffers: std.ArrayList(*GPUBuffer),
    is_initialized: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, backend: GPUBackend) !Self {
        var accel = Self{
            .allocator = allocator,
            .backend = backend,
            .devices = try std.ArrayList(GPUDevice).initCapacity(allocator, 0),
            .active_device = null,
            .kernels = std.StringHashMap(*GPUKernel).init(allocator),
            .buffers = try std.ArrayList(*GPUBuffer).initCapacity(allocator, 0),
            .is_initialized = false,
        };

        _ = accel.detectDevices() catch {};
        if (backend == .cuda) {
            // initialize driver (best-effort)
            _ = c.cuInit(0) catch {};
        }

        try accel.compileKernels();
        accel.is_initialized = true;
        return accel;
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |b| {
            if (b) |bp| {
                if (bp.host_ptr) self.allocator.free(bp.host_ptr);
                if (bp.device_ptr != 0) c.cuMemFree(bp.device_ptr);
                self.allocator.destroy(bp);
            }
        }
        self.buffers.deinit(self.allocator);

        var it = self.kernels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.compiled) |kc| c.cuModuleUnload(kc.module);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.kernels.deinit();
        self.devices.deinit(self.allocator);
    }

    fn detectDevices(self: *Self) !void {
        if (self.backend == .none) {
            try self.devices.append(self.allocator, GPUDevice{ .id = 0, .name = "Mock GPU Device", .memory_size = 8 * 1024 * 1024 * 1024, .compute_units = 1, .max_threads_per_block = 1024, .backend = .none, .is_available = true });
            self.active_device = 0;
            return;
        }
        if (self.backend == .cuda) {
            var count: c.int = 0;
            if (c.cuDeviceGetCount(&count) == c.CUresult.CUDA_SUCCESS and count > 0) {
                var i: c.int = 0;
                while (i < count) : (i += 1) {
                    var dev: c.CUdevice = 0;
                    if (c.cuDeviceGet(&dev, i) != c.CUresult.CUDA_SUCCESS) continue;
                    var buf: [256]u8 = undefined;
                    _ = c.cuDeviceGetName(&buf[0], 256, dev);
                    var len: usize = 0;
                    while (len < 256 and buf[len] != 0) : (len += 1) {}
                    const name_slice = buf[0..len];
                    try self.devices.append(self.allocator, GPUDevice{ .id = @as(u32, self.devices.items.len), .name = name_slice, .memory_size = 0, .compute_units = 0, .max_threads_per_block = 1024, .backend = .cuda, .is_available = true });
                }
                if (self.devices.items.len > 0) self.active_device = 0;
                return;
            }
        }
        try self.devices.append(self.allocator, GPUDevice{ .id = 0, .name = "Mock GPU Device", .memory_size = 8 * 1024 * 1024 * 1024, .compute_units = 80, .max_threads_per_block = 1024, .backend = self.backend, .is_available = true });
        if (self.devices.items.len > 0) self.active_device = 0;
    }

    fn compileKernels(self: *Self) !void {
        // register placeholder kernels defined in kernel_sources.zig
        const ks = @import("kernel_sources.zig");
        try self.compileKernel("bfs", ks.bfs_kernel_source);
        try self.compileKernel("pagerank", ks.pagerank_kernel_source);
        try self.compileKernel("shortest_path", ks.shortest_path_kernel_source);
    }

    fn compileKernel(self: *Self, name: []const u8, source: []const u8) !void {
        const kernel = try self.allocator.create(GPUKernel);
        kernel.* = GPUKernel{ .name = name, .source = source, .compiled = null, .work_group_size = .{ 256, 1, 1 } };
        if (self.backend == .cuda) {
            var module: c.CUmodule = null;
            if (c.cuModuleLoadDataEx(&module, source.ptr, 0, null, null) == c.CUresult.CUDA_SUCCESS) {
                var name_cstr = try self.allocator.alloc(u8, name.len + 1);
                std.mem.copy(u8, name_cstr[0..name.len], name);
                name_cstr[name.len] = 0;
                var func: c.CUfunction = null;
                if (c.cuModuleGetFunction(&func, module, name_cstr.ptr) == c.CUresult.CUDA_SUCCESS) {
                    const kc = try self.allocator.create(KernelCompiled);
                    kc.* = KernelCompiled{ .module = module, .func = func };
                    kernel.compiled = kc;
                } else {
                    _ = c.cuModuleUnload(module) catch {};
                }
                self.allocator.free(name_cstr);
            }
        }
        try self.kernels.put(name, kernel);
    }

    pub fn allocateBuffer(self: *Self, size: usize, host_visible: bool) !*GPUBuffer {
        const b = try self.allocator.create(GPUBuffer);
        b.* = GPUBuffer{ .host_ptr = null, .device_ptr = 0, .size = size, .device_id = self.active_device orelse 0, .is_host_visible = host_visible };
        if (host_visible) b.host_ptr = try self.allocator.alloc(u8, size);
        try self.buffers.append(self.allocator, b);
        return b;
    }

    pub fn freeBuffer(self: *Self, buffer: *GPUBuffer) void {
        for (self.buffers.items, 0..) |buf, i| {
            if (buf == buffer) {
                _ = self.buffers.swapRemove(i);
                break;
            }
        }
        if (buffer.host_ptr) self.allocator.free(buffer.host_ptr);
        if (buffer.device_ptr != 0) _ = c.cuMemFree(buffer.device_ptr);
        self.allocator.destroy(buffer);
    }

    pub fn copyToDevice(self: *Self, host_data: []const u8, device_buffer: *GPUBuffer) !void {
        if (device_buffer.size < host_data.len) return error.BufferTooSmall;
        if (self.backend == .cuda) {
            if (device_buffer.device_ptr == 0) {
                var dptr: c.CUdeviceptr = 0;
                if (c.cuMemAlloc(&dptr, host_data.len) != c.CUresult.CUDA_SUCCESS) return error.BufferAllocFailed;
                device_buffer.device_ptr = dptr;
            }
            if (c.cuMemcpyHtoD(device_buffer.device_ptr, host_data.ptr, host_data.len) != c.CUresult.CUDA_SUCCESS) return error.CopyFailed;
            return;
        }
        if (!device_buffer.is_host_visible) return error.NoHostVisible;
        if (device_buffer.host_ptr) std.mem.copy(u8, device_buffer.host_ptr[0..host_data.len], host_data) else return error.NoHostVisible;
    }

    pub fn copyFromDevice(self: *Self, device_buffer: *GPUBuffer, host_data: []u8) !void {
        if (host_data.len < device_buffer.size) return error.BufferTooSmall;
        if (self.backend == .cuda) {
            if (device_buffer.device_ptr == 0) return error.NoDevicePointer;
            if (c.cuMemcpyDtoH(host_data.ptr, device_buffer.device_ptr, host_data.len) != c.CUresult.CUDA_SUCCESS) return error.CopyFailed;
            return;
        }
        if (!device_buffer.is_host_visible) return error.NoHostVisible;
        if (device_buffer.host_ptr) std.mem.copy(u8, host_data, device_buffer.host_ptr[0..host_data.len]) else return error.NoHostVisible;
    }

    pub fn launchKernel(self: *Self, name: []const u8, grid: [3]u32, block: [3]u32, args: []const *GPUBuffer) !void {
        _ = args; // placeholder until arg packing is implemented
        const k = self.kernels.get(name) orelse return error.KernelNotFound;
        if (k.compiled == null) return error.KernelNotCompiled;
        if (self.backend != .cuda) return error.KernelNotSupported;
        const kc = k.compiled.*;
        if (c.cuLaunchKernel(kc.func, grid[0], grid[1], grid[2], block[0], block[1], block[2], 0, null, null, null) != c.CUresult.CUDA_SUCCESS) return error.LaunchFailed;
    }

    pub fn synchronize(self: *Self) !void {
        _ = self;
    }
};
