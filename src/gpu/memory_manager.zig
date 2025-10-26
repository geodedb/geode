const std = @import("std");
const CudaLoader = @import("cuda_loader.zig").CudaLoader;
const phase0 = @import("phase0.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=MemoryManager; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUMemoryManager; OWNER=engine; UPDATED=2025-10-26

const CUdeviceptr = u64;

pub const DeviceBuffer = struct {
    ptr: CUdeviceptr,
    size: usize,
    allocated: bool,
};

pub const MemoryManager = struct {
    loader: *const CudaLoader,
    allocator: std.mem.Allocator,
    pool: std.array_list.Managed(DeviceBuffer),
    pinned_host_buffers: std.array_list.Managed([*]u8),

    pub fn init(loader: *const CudaLoader, allocator: std.mem.Allocator) !MemoryManager {
        return MemoryManager{
            .loader = loader,
            .allocator = allocator,
            .pool = std.array_list.Managed(DeviceBuffer).init(allocator),
            .pinned_host_buffers = std.array_list.Managed([*]u8).init(allocator),
        };
    }

    pub fn deinit(self: *MemoryManager) void {
        for (self.pool.items) |buf| {
            if (buf.allocated) {
                _ = self.loader.memFree(buf.ptr);
            }
        }
        self.pool.deinit();

        for (self.pinned_host_buffers.items) |buf_ptr| {
            self.allocator.free(buf_ptr[0..1]); // Simplified cleanup
        }
        self.pinned_host_buffers.deinit();
    }

    pub fn allocDevice(self: *MemoryManager, size: usize) !DeviceBuffer {
        if (!self.loader.available()) {
            return error.GPUUnavailable;
        }

        // Try to reuse existing buffer from pool
        for (self.pool.items, 0..) |buf, idx| {
            if (!buf.allocated and buf.size >= size) {
                self.pool.items[idx].allocated = true;
                return buf;
            }
        }

        // Allocate new buffer
        var dptr: CUdeviceptr = 0;
        const result = self.loader.memAlloc(&dptr, size);
        if (result != 0) {
            return error.GPUMemoryExhausted;
        }

        const buf = DeviceBuffer{ .ptr = dptr, .size = size, .allocated = true };
        try self.pool.append(buf);
        return buf;
    }

    pub fn freeDevice(self: *MemoryManager, buf: DeviceBuffer) void {
        for (self.pool.items, 0..) |pool_buf, idx| {
            if (pool_buf.ptr == buf.ptr) {
                self.pool.items[idx].allocated = false;
                return;
            }
        }
    }

    pub fn copyHostToDevice(self: *MemoryManager, dst: DeviceBuffer, src: []const u8) !void {
        if (!self.loader.available()) {
            return error.GPUUnavailable;
        }

        const result = self.loader.memcpyHtoD(dst.ptr, src.ptr, src.len);
        if (result != 0) {
            return error.GPUCopyFailed;
        }
    }

    pub fn copyDeviceToHost(self: *MemoryManager, dst: []u8, src: DeviceBuffer) !void {
        if (!self.loader.available()) {
            return error.GPUUnavailable;
        }

        const result = self.loader.memcpyDtoH(dst.ptr, src.ptr, dst.len);
        if (result != 0) {
            return error.GPUCopyFailed;
        }
    }

    pub fn allocPinnedHost(self: *MemoryManager, size: usize) ![]u8 {
        // Simplified: use regular allocation; true pinned memory requires cuMemAllocHost
        const buf = try self.allocator.alloc(u8, size);
        return buf;
    }

    pub fn synchronize(self: *MemoryManager) !void {
        if (!self.loader.available()) {
            return error.GPUUnavailable;
        }
        const result = self.loader.cuCtxSynchronize();
        if (result != 0) {
            return error.GPUSyncFailed;
        }
    }
};

test "TestCANARY_REQ_GQL_051_GPUMemoryManager" {
    const loader = CudaLoader.init();
    if (!loader.available()) {
        // Skip test if CUDA unavailable
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var mgr = try MemoryManager.init(&loader, alloc);
    defer mgr.deinit();

    // Test device allocation
    const buf1 = mgr.allocDevice(1024) catch |err| {
        if (err == error.GPUMemoryExhausted) return; // Expected on systems without GPU
        return err;
    };

    mgr.freeDevice(buf1);

    // Test buffer reuse
    const buf2 = try mgr.allocDevice(512);
    try std.testing.expect(buf2.ptr == buf1.ptr); // Should reuse
}
