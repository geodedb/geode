const std = @import("std");

// Lightweight counting allocator wrapper capturing total allocated / freed bytes and peak usage.
// NOTE: This is a best‑effort tracker; it does not attribute bytes to callers beyond stage
// boundary snapshots taken by the caller. Expansion (resize growth) is not supported in place.
// Shrinks are accounted as frees of the delta.
pub const TrackingAllocator = struct {
    inner: std.mem.Allocator,
    allocator: std.mem.Allocator = undefined,
    total_alloc: usize = 0,
    total_freed: usize = 0,
    peak: usize = 0,

    pub fn init(self: *TrackingAllocator, inner: std.mem.Allocator) void {
        self.inner = inner;
        self.total_alloc = 0;
        self.total_freed = 0;
        self.peak = 0;
        self.allocator = .{ .ptr = self, .vtable = &vtable };
    }

    pub fn net(self: *const TrackingAllocator) usize {
        return self.total_alloc - self.total_freed;
    }

    pub fn peakBytes(self: *const TrackingAllocator) usize {
        return self.peak;
    }

    fn vAlloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        if (len == 0) return null;
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        // Use inner allocator to allocate raw bytes; alignment best effort.
        const slice = self.inner.alloc(u8, len) catch return null;
        _ = ptr_align; // not enforcing alignment in tracking wrapper
        self.total_alloc += slice.len;
        const current = self.total_alloc - self.total_freed;
        if (current > self.peak) self.peak = current;
        return slice.ptr;
    }

    fn vResize(ctx: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        _ = ptr_align;
        if (buf.len == new_len) return true;
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len < buf.len) {
            // Shrink in place; account freed delta.
            const delta = buf.len - new_len;
            self.total_freed += delta;
            return true;
        }
        // Cannot grow in place.
        return false;
    }

    fn vFree(ctx: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ret_addr;
        _ = ptr_align;
        if (buf.len == 0) return;
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.free(buf);
        self.total_freed += buf.len;
    }

    fn vRemap(ctx: *anyopaque, buf: []u8, old_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = old_align;
        _ = new_len;
        _ = ret_addr;
        return null; // not supported
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = vAlloc,
        .resize = vResize,
        .free = vFree,
        .remap = vRemap,
    };
};
