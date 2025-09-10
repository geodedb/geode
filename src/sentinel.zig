const std = @import("std");

// Placeholder sentinel wrapper; current Zig toolchain lacks std.heap.sentinelAllocator.
// Future: implement guard-byte allocator when -Dsan enabled.
pub fn maybeSentinel(base: std.mem.Allocator) std.mem.Allocator {
    return base; // no-op placeholder
}
