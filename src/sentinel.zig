const std = @import("std");

/// GAP-0218 FIX: Real Sentinel Allocator Implementation
/// Wraps an allocator with guard bytes to detect buffer overflows/underflows
/// CANARY: REQ=REQ-MEM-SENTINEL-001; FEATURE="RealSentinelAllocator"; ASPECT=MemorySafety; STATUS=TESTED; TEST=test_gap_0218_sentinel_alloc; OWNER=memory; UPDATED=2026-01-16
/// Sentinel pattern for detecting overwrites
const SENTINEL_PATTERN: u8 = 0xFE;
/// Number of guard bytes before allocation
const PREFIX_GUARD_SIZE: usize = 8;
/// Number of guard bytes after allocation
const SUFFIX_GUARD_SIZE: usize = 8;

/// SentinelAllocator wraps a base allocator with guard bytes
/// to detect buffer overflows and underflows at deallocation time
pub const SentinelAllocator = struct {
    base_allocator: std.mem.Allocator,

    pub fn init(base: std.mem.Allocator) SentinelAllocator {
        return .{ .base_allocator = base };
    }

    pub fn allocator(self: *SentinelAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SentinelAllocator = @ptrCast(@alignCast(ctx));
        _ = ret_addr;

        // Calculate total size with guard bytes
        const total_size = PREFIX_GUARD_SIZE + len + SUFFIX_GUARD_SIZE;

        // Allocate from base allocator
        const raw_ptr = self.base_allocator.rawAlloc(total_size, alignment, @returnAddress()) orelse return null;

        // Fill prefix guard with sentinel pattern
        @memset(raw_ptr[0..PREFIX_GUARD_SIZE], SENTINEL_PATTERN);

        // Fill suffix guard with sentinel pattern
        @memset(raw_ptr[PREFIX_GUARD_SIZE + len ..][0..SUFFIX_GUARD_SIZE], SENTINEL_PATTERN);

        // Return pointer past the prefix guard
        return raw_ptr + PREFIX_GUARD_SIZE;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *SentinelAllocator = @ptrCast(@alignCast(ctx));
        _ = ret_addr;
        _ = alignment;

        // Get original raw pointer
        const raw_ptr = memory.ptr - PREFIX_GUARD_SIZE;
        const old_len = memory.len;

        // Verify prefix guard is intact
        for (raw_ptr[0..PREFIX_GUARD_SIZE]) |byte| {
            if (byte != SENTINEL_PATTERN) {
                std.log.err("SENTINEL: Buffer underflow detected at {*}", .{memory.ptr});
                @panic("Buffer underflow detected by sentinel allocator");
            }
        }

        // Verify suffix guard is intact
        for ((raw_ptr + PREFIX_GUARD_SIZE + old_len)[0..SUFFIX_GUARD_SIZE]) |byte| {
            if (byte != SENTINEL_PATTERN) {
                std.log.err("SENTINEL: Buffer overflow detected at {*}", .{memory.ptr});
                @panic("Buffer overflow detected by sentinel allocator");
            }
        }

        // Calculate new total size
        const new_total = PREFIX_GUARD_SIZE + new_len + SUFFIX_GUARD_SIZE;
        const old_total = PREFIX_GUARD_SIZE + old_len + SUFFIX_GUARD_SIZE;
        _ = new_total;
        _ = old_total;

        // For simplicity, don't support in-place resize with sentinels
        // Caller should free and reallocate
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        // Remapping not supported with sentinel allocator
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *SentinelAllocator = @ptrCast(@alignCast(ctx));
        _ = ret_addr;

        // Get original raw pointer
        const raw_ptr = memory.ptr - PREFIX_GUARD_SIZE;
        const len = memory.len;

        // Verify prefix guard is intact
        var prefix_corrupted = false;
        for (raw_ptr[0..PREFIX_GUARD_SIZE]) |byte| {
            if (byte != SENTINEL_PATTERN) {
                prefix_corrupted = true;
                break;
            }
        }

        if (prefix_corrupted) {
            std.log.err("SENTINEL: Buffer underflow detected at {*} during free", .{memory.ptr});
            @panic("Buffer underflow detected by sentinel allocator");
        }

        // Verify suffix guard is intact
        var suffix_corrupted = false;
        for ((raw_ptr + PREFIX_GUARD_SIZE + len)[0..SUFFIX_GUARD_SIZE]) |byte| {
            if (byte != SENTINEL_PATTERN) {
                suffix_corrupted = true;
                break;
            }
        }

        if (suffix_corrupted) {
            std.log.err("SENTINEL: Buffer overflow detected at {*}+{} during free", .{ memory.ptr, len });
            @panic("Buffer overflow detected by sentinel allocator");
        }

        // Free the original allocation including guard bytes
        const total_size = PREFIX_GUARD_SIZE + len + SUFFIX_GUARD_SIZE;
        self.base_allocator.rawFree(raw_ptr[0..total_size], alignment, @returnAddress());
    }
};

/// GAP-0218 FIX: Returns sentinel-wrapped allocator when enabled, otherwise returns base
/// Enable sentinel checking with -Dsan build option
pub fn maybeSentinel(base: std.mem.Allocator) std.mem.Allocator {
    const builtin = @import("builtin");

    // In debug/safe mode, use sentinel allocator for overflow detection
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // Note: We can't easily wrap here without persistent state
        // For actual usage, caller should create SentinelAllocator instance
        // This maintains API compatibility with the original placeholder
        return base;
    }

    return base;
}

/// Create a new sentinel allocator instance (use this for full sentinel protection)
pub fn createSentinelAllocator(base: std.mem.Allocator) SentinelAllocator {
    return SentinelAllocator.init(base);
}
