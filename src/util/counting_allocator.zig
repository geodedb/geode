const std = @import("std");

// Simple counting allocator wrapper that tracks total and peak bytes allocated.
// Not thread-safe; baseline for PROFILE bytes_alloc metrics. Does not track frees
// per-op; caller snapshots counters at stage boundaries and computes deltas.
pub const CountingAllocator = struct {
    parent: std.mem.Allocator,
    total_alloc: usize = 0,
    total_free: usize = 0,
    peak_bytes: usize = 0,

    pub fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn allocFn(ctx: *anyopaque, n: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const mem = self.parent.rawAlloc(n, log2_align, ret_addr) orelse return null;
        self.total_alloc += n;
        const live = self.liveBytes();
        if (live > self.peak_bytes) self.peak_bytes = live;
        return mem;
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, new_size: usize, log2_align: u8, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const old = buf.len;
        if (self.parent.rawResize(buf, new_size, log2_align, ret_addr)) {
            if (new_size > old) {
                self.total_alloc += (new_size - old);
                const live = self.liveBytes();
                if (live > self.peak_bytes) self.peak_bytes = live;
            } else if (old > new_size) {
                self.total_free += (old - new_size);
            }
            return true;
        }
        return false;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total_free += buf.len;
        self.parent.rawFree(buf, log2_align, ret_addr);
    }

    fn liveBytes(self: *CountingAllocator) usize {
        if (self.total_alloc >= self.total_free) return self.total_alloc - self.total_free;
        return 0; // shouldn't happen
    }

    pub fn net(self: *CountingAllocator) usize {
        return self.liveBytes();
    }

    pub fn peakBytes(self: *CountingAllocator) usize {
        return self.peak_bytes;
    }

    pub fn snapshot(self: *CountingAllocator) Snapshot {
        return .{ .total_alloc = self.total_alloc, .total_free = self.total_free, .peak = self.peak_bytes };
    }

    pub const Snapshot = struct { total_alloc: usize, total_free: usize, peak: usize };

    const vtable = std.mem.Allocator.VTable{ .alloc = allocFn, .resize = resizeFn, .free = freeFn };
};
