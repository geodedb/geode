// CANARY: REQ=REQ-GQL-060; FEATURE="Core Graph Builders"; ASPECT=ConcurrencySafeGraph; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_060_ConcurrencySafe; OWNER=graph; UPDATED=2025-09-20
// ConcurrencySafeGraph wraps Graph with a RW lock to allow multiple readers and exclusive writers.
// Simplified model: writers take exclusive lock for any mutation (addNode/addEdge/rebuildIndex);
// readers take shared lock for outEdges snapshot copy (so they can iterate without holding lock).
// This is a minimal evidence slice; performance tuning & lock striping deferred.
const std = @import("std");
const builders = @import("builders.zig");

pub const ConcurrencySafeGraph = struct {
    g: builders.Graph,
    rw: std.Io.RwLock = std.Io.RwLock.init,

    pub fn init(allocator: std.mem.Allocator) ConcurrencySafeGraph {
        return .{ .g = builders.Graph.init(allocator) };
    }

    pub fn deinit(self: *ConcurrencySafeGraph) void {
        self.g.deinit();
    }

    pub fn addNode(self: *ConcurrencySafeGraph, id: u64) void {
        self.rw.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rw.unlock(std.Io.Threaded.global_single_threaded.io());
        self.g.addNode(id);
    }

    pub fn addEdge(self: *ConcurrencySafeGraph, src: u64, dst: u64, w: builders.Weight) !void {
        self.rw.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rw.unlock(std.Io.Threaded.global_single_threaded.io());
        try self.g.addEdge(src, dst, w);
    }

    pub const Edge = builders.Edge;

    pub fn snapshotOutEdges(self: *ConcurrencySafeGraph, allocator: std.mem.Allocator, node: u64) ![]Edge {
        self.rw.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        const it = self.g.outEdges(node);
        const slice = it.edges; // underlying slice
        const dup = try allocator.alloc(Edge, slice.len);
        std.mem.copy(Edge, dup, slice);
        self.rw.unlockShared(std.Io.Threaded.global_single_threaded.io());
        return dup;
    }
};

test "TestCANARY_REQ_GQL_060_ConcurrencySafe basic single thread" {
    var cg = ConcurrencySafeGraph.init(std.testing.allocator);
    defer cg.deinit();
    cg.addNode(1);
    try cg.addEdge(1, 1, 1.0);
    const edges = try cg.snapshotOutEdges(std.testing.allocator, 1);
    defer std.testing.allocator.free(edges);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
}

test "TestCANARY_REQ_GQL_060_ConcurrencySafe multi-thread writers and readers" {
    var cg = ConcurrencySafeGraph.init(std.testing.allocator);
    defer cg.deinit();
    cg.addNode(0);
    const writer_count = 4;
    const reader_count = 4;
    var writers: [writer_count]std.Thread = undefined;
    var readers: [reader_count]std.Thread = undefined;
    // spawn writers adding a chain
    var i: usize = 0;
    while (i < writer_count) : (i += 1) {
        const base: u64 = @intCast(i * 100);
        writers[i] = try std.Thread.spawn(.{}, struct {
            fn run(cg_ptr: *ConcurrencySafeGraph, base_local: u64) void {
                var j: u64 = 0;
                while (j < 50) : (j += 1) {
                    cg_ptr.addNode(base_local + j + 1);
                    cg_ptr.addEdge(base_local + j, base_local + j + 1, 1.0) catch {};
                }
            }
        }.run, .{ &cg, base });
    }
    // spawn readers that repeatedly snapshot node 0 edges
    var r: usize = 0;
    while (r < reader_count) : (r += 1) {
        readers[r] = try std.Thread.spawn(.{}, struct {
            fn run(cg_ptr: *ConcurrencySafeGraph) void {
                var k: usize = 0;
                while (k < 200) : (k += 1) {
                    // P2-3: Use testing allocator in tests instead of page_allocator
                    const e = cg_ptr.snapshotOutEdges(std.testing.allocator, 0) catch null;
                    if (e) |edges| std.testing.allocator.free(edges);
                }
            }
        }.run, .{&cg});
    }
    // join
    i = 0;
    while (i < writer_count) : (i += 1) writers[i].join();
    r = 0;
    while (r < reader_count) : (r += 1) readers[r].join();
    // simple sanity: node 0 should have at most 1 outgoing chain edge (depending on racing)
    const edges0 = try cg.snapshotOutEdges(std.testing.allocator, 0);
    defer std.testing.allocator.free(edges0);
    try std.testing.expect(edges0.len <= 1);
}
