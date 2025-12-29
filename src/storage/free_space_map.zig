const std = @import("std");

/// Manages free space tracking for pages to allow efficient reuse (FSM).
/// Keeps an in-memory index of pages bucketted by available contiguous bytes.
pub const FreeSpaceMap = struct {
    const Bin = std.ArrayList(u32);
    allocator: std.mem.Allocator,
    // Buckets for free space:
    // We'll use simple power-of-2 buckets or fixed ranges.
    // Given page size is typically 4K, precise tracking is overkill.
    // We verify exact fit on retrieval anyway.
    // Map: PageId -> FreeBytes (to support updates/removals)
    page_free: std.AutoHashMap(u32, u16),
    bins: [6]Bin,

    // Min contiguous bytes to consider tracking
    min_bytes: u16 = 64,

    pub fn init(allocator: std.mem.Allocator, min_bytes: u16) FreeSpaceMap {
        var bins: [6]Bin = undefined;
        for (0..6) |i| bins[i] = .{};
        return .{
            .allocator = allocator,
            .page_free = std.AutoHashMap(u32, u16).init(allocator),
            .bins = bins,
            .min_bytes = min_bytes,
        };
    }

    pub fn deinit(self: *FreeSpaceMap) void {
        self.page_free.deinit();
        for (0..6) |i| self.bins[i].deinit(self.allocator);
    }

    fn getBinIndex(size: u16) usize {
        if (size < 64) return 0;
        if (size < 256) return 1;
        if (size < 1024) return 2;
        if (size < 2048) return 3;
        if (size < 4096) return 4;
        return 5;
    }

    /// Update or insert free space info for a page.
    pub fn upsertPageFree(self: *FreeSpaceMap, page_id: u32, free_contig: u16) !void {
        if (free_contig < self.min_bytes) {
            try self.removePage(page_id);
            return;
        }

        // Check if already tracked to see if we need to move bins
        const entry = try self.page_free.getOrPut(page_id);
        if (entry.found_existing) {
            const old_free = entry.value_ptr.*;
            const old_bin = getBinIndex(old_free);
            const new_bin = getBinIndex(free_contig);

            if (old_bin != new_bin) {
                // Remove from old bin
                const bin_list = &self.bins[old_bin];
                for (bin_list.items, 0..) |pid, i| {
                    if (pid == page_id) {
                        _ = bin_list.swapRemove(i);
                        break;
                    }
                }
                // Add to new bin
                try self.bins[new_bin].append(self.allocator, page_id);
            }
            // Update stored exact value
            entry.value_ptr.* = free_contig;
        } else {
            // New tracking
            entry.value_ptr.* = free_contig;
            try self.bins[getBinIndex(free_contig)].append(self.allocator, page_id);
        }
    }

    /// Stop tracking a page (e.g. if it becomes full or is dropped)
    pub fn removePage(self: *FreeSpaceMap, page_id: u32) !void {
        if (self.page_free.fetchRemove(page_id)) |kv| {
            const bin_idx = getBinIndex(kv.value);
            const bin_list = &self.bins[bin_idx];
            for (bin_list.items, 0..) |pid, i| {
                if (pid == page_id) {
                    _ = bin_list.swapRemove(i);
                    return;
                }
            }
        }
    }

    /// Find a candidate page that has at least `size_needed` contiguous bytes.
    /// Returns the PageId or null if no suitable page found.
    pub fn findPageFor(self: *const FreeSpaceMap, size_needed: u16) ?u32 {
        const start_bin = getBinIndex(size_needed);

        // Search bins starting from best fit up
        var b: usize = start_bin;
        while (b < 6) : (b += 1) {
            const bin_list = &self.bins[b];

            // Greedily pick the last one (swapRemove optimization friendly)
            // Ideally we'd scan for best fit within the bin, but this is FSM v1.
            var i: usize = bin_list.items.len;
            while (i > 0) : (i -= 1) {
                const pid = bin_list.items[i - 1];
                if (self.page_free.get(pid)) |free| {
                    if (free >= size_needed) return pid;
                }
            }
        }
        return null;
    }

    /// Get the exact free space for a page if tracked
    pub fn getFreeSpace(self: *const FreeSpaceMap, page_id: u32) ?u16 {
        return self.page_free.get(page_id);
    }
};
