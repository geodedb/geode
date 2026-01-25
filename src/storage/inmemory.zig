const std = @import("std");
const iface = @import("interface");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=IMPL; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;

// PERF: PHASE5_NEIGHBORS_LAZY_SORT - Lazy sorting for neighbors() to avoid O(n²) repeated sorts
// CANARY: REQ=REQ-PERF-PHASE5-002; FEATURE="GraphOptimization"; ASPECT=LAZY_SORT; STATUS=EXEMPT; OWNER=performance; UPDATED=2025-11-16

pub const InMemory = struct {
    allocator: std.mem.Allocator,
    // adjacency: src -> sorted unique neighbors
    adj: std.AutoHashMap(u64, std.ArrayList(u64)),
    // labels: node id -> set of labels
    labels: std.AutoHashMap(u64, std.StringHashMap(void)),
    // Phase 5.1.2: Track which adjacency lists are sorted (avoids O(n²) repeated sorting)
    adj_sorted: std.AutoHashMap(u64, bool),

    pub fn init(allocator: std.mem.Allocator) InMemory {
        return .{
            .allocator = allocator,
            .adj = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .labels = std.AutoHashMap(u64, std.StringHashMap(void)).init(allocator),
            .adj_sorted = std.AutoHashMap(u64, bool).init(allocator),
        };
    }

    pub fn deinit(self: *InMemory) void {
        var it = self.adj.valueIterator();
        while (it.next()) |lst| lst.*.deinit(self.allocator);
        self.adj.deinit();
        var itl = self.labels.valueIterator();
        while (itl.next()) |m| m.*.deinit();
        self.labels.deinit();
        // Phase 5.1.2: Clean up sorted tracking map
        self.adj_sorted.deinit();
    }

    pub fn addEdge(self: *InMemory, src: u64, dst: u64) !void {
        var gop = try self.adj.getOrPut(src);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        }
        // ensure uniqueness and sorted order on finalize; for now just append
        try gop.value_ptr.append(self.allocator, dst);
        // Phase 5.1.2: Mark adjacency list as unsorted after adding edge
        try self.adj_sorted.put(src, false);
    }

    pub fn neighbors(self: *InMemory, src: u64) iface.NeighborIter {
        // Phase 5.1.2: Use getPtr to get mutable pointer for in-place sorting
        if (self.adj.getPtr(src)) |lst_ptr| {
            const is_sorted = self.adj_sorted.get(src) orelse false;

            if (!is_sorted) {
                // Sort ONCE and deduplicate, then cache the sorted state
                var slice = lst_ptr.items;
                std.mem.sort(u64, slice, {}, std.sort.asc(u64));

                // In-place deduplication
                var w: usize = 0;
                var i: usize = 0;
                while (i < slice.len) : (i += 1) {
                    if (w == 0 or slice[i] != slice[w - 1]) {
                        slice[w] = slice[i];
                        w += 1;
                    }
                }

                // Truncate to deduplicated length
                lst_ptr.items.len = w;

                // Mark as sorted (ignore errors - worst case is re-sorting)
                self.adj_sorted.put(src, true) catch |err| {
                    log.debug("Failed to mark adjacency list as sorted (performance impact only)", &.{
                        Attr.uint("src", src),
                        Attr.err("error", err),
                    });
                };
            }

            return .{ .items = lst_ptr.items };
        }
        return .{ .items = &.{} };
    }

    pub fn addNodeLabel(self: *InMemory, node: u64, label: []const u8) !void {
        var gop = try self.labels.getOrPut(node);
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
        try gop.value_ptr.put(label, {});
    }

    pub fn hasLabel(self: *InMemory, node: u64, label: []const u8) bool {
        if (self.labels.get(node)) |m| return m.contains(label) else return false;
    }

    pub fn expandLabeled(self: *InMemory, src: u64, label: []const u8) iface.NeighborIter {
        if (self.adj.get(src)) |lst| {
            var tmp = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return .{ .items = &.{} };
            for (lst.items) |nid| {
                if (self.hasLabel(nid, label)) tmp.append(self.allocator, nid) catch |err| {
                    log.warn("Failed to append labeled neighbor (query results truncated)", &.{
                        Attr.uint("src", src),
                        Attr.string("label", label),
                        Attr.err("error", err),
                    });
                };
            }
            std.mem.sort(u64, tmp.items, {}, std.sort.asc(u64));
            return .{ .items = tmp.toOwnedSlice(self.allocator) catch &.{} };
        }
        return .{ .items = &.{} };
    }

    pub fn expandNHop(self: *InMemory, seed: u64, hops: u32) iface.NeighborIter {
        if (hops == 0) return .{ .items = &.{} };
        var frontier = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return .{ .items = &.{} };
        var next = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return .{ .items = &.{} };
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer frontier.deinit(self.allocator);
        defer next.deinit(self.allocator);
        defer visited.deinit();
        frontier.append(self.allocator, seed) catch |err| {
            log.err("CRITICAL: Failed to initialize n-hop traversal (query will fail)", &.{
                Attr.uint("seed", seed),
                Attr.err("error", err),
            });
        };
        var h: u32 = 0;
        while (h < hops) : (h += 1) {
            next.clearRetainingCapacity();
            var i: usize = 0;
            while (i < frontier.items.len) : (i += 1) {
                const s = frontier.items[i];
                const it = self.neighbors(s);
                var j: usize = 0;
                while (j < it.items.len) : (j += 1) {
                    const nid = it.items[j];
                    if (visited.get(nid) == null) {
                        visited.put(nid, {}) catch |err| {
                            log.warn("Failed to track visited node (infinite loop possible if OOM)", &.{
                                Attr.uint("nid", nid),
                                Attr.err("error", err),
                            });
                        };
                        next.append(self.allocator, nid) catch |err| {
                            log.warn("Failed to append to n-hop frontier (traversal truncated)", &.{
                                Attr.uint("nid", nid),
                                Attr.err("error", err),
                            });
                        };
                    }
                }
            }
            frontier.items = next.items;
        }
        std.mem.sort(u64, frontier.items, {}, std.sort.asc(u64));
        return .{ .items = frontier.toOwnedSlice(self.allocator) catch &.{} };
    }
};
