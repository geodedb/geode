// SONNY-3233 (round 15, F3, F5, F12): the node, edge and adjacency caches,
// the edge-type index and the graph registry are shared by every graph, and
// every change to them now holds their lock, so writers of different graphs
// no longer race each other.
//
// The round 14 review found:
//   - F3: `BoundedNodeCache.ensureUnusedCapacity` grew every shard's map with
//     no shard lock. A batch CREATE (and graph hydration) reserves room that
//     way, so batch creates on g1 racing single creates on g2 panicked in
//     `insertEvicting` within seconds in ReleaseSafe, with BOUNDED caches (as
//     `initGlobalStore` sets them in production);
//   - F5: with the caches unbounded (in-memory, or GEODE_*_CACHE_ENTRIES=0),
//     `appendAdj` inserted into the adjacency cache, and edited an entry and
//     retired its old buffer, with no shard lock; `edge_type_index` had no
//     lock at all. Two edge writers on different graphs crashed a Debug
//     build;
//   - F12: `ensureGraphNoDirty` (every first write to a graph) checked and
//     inserted into `graphs` without `graphs_mutex`, and `graphExists` and
//     the snapshot clone read it unlocked, while CREATE and DROP GRAPH change
//     it under the mutex.
//
// Each race runs for a bounded time with BOUNDED caches (the fixture's
// production option) and unbounded ones, and checks what each writer made.
// Loop the step (the brief: 20 times).
//
// CANARY: REQ=REQ-SONNY-3233-CACHE-LOCKING; FEATURE="GraphStore"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3233_cache_graph_locking.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

const race_ms: u64 = 3000;

fn monoMs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

const Race = struct {
    st: *graph_store.GraphStore,
    stop: std.atomic.Value(bool) = .init(false),
    batches: std.atomic.Value(usize) = .init(0),
    singles: std.atomic.Value(usize) = .init(0),
    edges: [2]std.atomic.Value(usize) = .{ .init(0), .init(0) },
    removed: [2]std.atomic.Value(usize) = .{ .init(0), .init(0) },
    ddl: std.atomic.Value(usize) = .init(0),
    reads: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),

    fn noteErr(self: *Race, what: []const u8, e: anyerror) void {
        const n = self.errors.fetchAdd(1, .monotonic);
        if (n < 8) std.debug.print("    {s}: {s}\n", .{ what, @errorName(e) });
    }

    /// Batch CREATE on g1: reserves cache room (`ensureUnusedCapacity`).
    fn batcher(self: *Race) void {
        const labels = [_][]const u8{"B"};
        const a = std.heap.smp_allocator;
        while (!self.stop.load(.acquire)) {
            const lock = graph_store.acquireGraphWriteLock("g1");
            defer graph_store.releaseGraphLock(lock);
            const ids = self.st.createNodesBatchWithAllocator(&labels, "g1", 1024, a) catch |e| {
                self.noteErr("batch g1", e);
                continue;
            };
            a.free(ids);
            _ = self.batches.fetchAdd(1, .monotonic);
        }
    }

    /// Single CREATE on g2, and a read of what it made.
    fn single(self: *Race) void {
        const labels = [_][]const u8{"S"};
        while (!self.stop.load(.acquire)) {
            const lock = graph_store.acquireGraphWriteLock("g2");
            defer graph_store.releaseGraphLock(lock);
            const id = self.st.createNodeWithGraph(&labels, "g2") catch |e| {
                self.noteErr("single g2", e);
                continue;
            };
            _ = self.st.getNodeProperty(id, "v");
            _ = self.singles.fetchAdd(1, .monotonic);
        }
    }

    /// A chain of nodes and edges in `graph`; every fourth edge deleted
    /// again (the adjacency removal path).
    fn edgeWriter(self: *Race, which: usize, graph: []const u8) void {
        const labels = [_][]const u8{"N"};
        var prev: ?u64 = null;
        var k: usize = 0;
        while (!self.stop.load(.acquire)) : (k += 1) {
            const lock = graph_store.acquireGraphWriteLock(graph);
            defer graph_store.releaseGraphLock(lock);
            const id = self.st.createNodeWithGraph(&labels, graph) catch |e| {
                self.noteErr("edge writer node", e);
                continue;
            };
            if (prev) |p| {
                const eid = self.st.createEdgeWithGraph(p, id, "E", graph) catch |e| {
                    self.noteErr("edge writer edge", e);
                    continue;
                };
                _ = self.edges[which].fetchAdd(1, .monotonic);
                if (k % 4 == 0) {
                    self.st.deleteEdge(eid);
                    _ = self.removed[which].fetchAdd(1, .monotonic);
                }
            }
            prev = id;
        }
    }

    /// Edge-type and adjacency reads of `default`.
    fn edgeReader(self: *Race) void {
        const a = std.heap.smp_allocator;
        while (!self.stop.load(.acquire)) {
            const lock = graph_store.acquireGraphReadLock("default");
            defer graph_store.releaseGraphLock(lock);
            _ = self.st.getEdgeIdsByType("default", "R");
            const ids = self.st.getEdgesByType(a, "R", null, "default");
            a.free(ids);
            _ = self.reads.fetchAdd(1, .monotonic);
        }
    }

    /// CREATE and DROP GRAPH churn: grows and shrinks `graphs`.
    fn graphsDdl(self: *Race) void {
        var buf: [32]u8 = undefined;
        var round: usize = 0;
        while (!self.stop.load(.acquire)) : (round += 1) {
            var i: usize = 0;
            while (i < 40 and !self.stop.load(.acquire)) : (i += 1) {
                const name = std.fmt.bufPrint(&buf, "ch{d}-{d}", .{ round, i }) catch unreachable;
                self.st.createGraph(name) catch |e| self.noteErr("ddl create", e);
            }
            i = 0;
            while (i < 40) : (i += 1) {
                const name = std.fmt.bufPrint(&buf, "ch{d}-{d}", .{ round, i }) catch unreachable;
                self.st.dropGraph(name) catch |e| switch (e) {
                    // Stopped before this one was created.
                    error.GraphNotFound => {},
                    else => self.noteErr("ddl drop", e),
                };
            }
            _ = self.ddl.fetchAdd(1, .monotonic);
        }
    }

    /// Readers of the registry.
    fn registryReader(self: *Race) void {
        const a = std.heap.smp_allocator;
        while (!self.stop.load(.acquire)) {
            if (!self.st.graphExists("g1")) self.noteErr("graphExists(g1)", error.Missing);
            if (self.st.listGraphNames(a)) |names| {
                for (names) |n| a.free(n);
                a.free(names);
            } else |e| self.noteErr("listGraphNames", e);
            _ = self.reads.fetchAdd(1, .monotonic);
        }
    }
};

fn runFor(race: *Race, threads: []?std.Thread) void {
    const t0 = monoMs();
    while (monoMs() - t0 < race_ms) fx.sleepMs(50);
    race.stop.store(true, .release);
    for (threads) |t| if (t) |th| th.join();
}

test "SONNY-3233: batch CREATE on g1 races single CREATE on g2, with bounded (production) and unbounded caches" {
    for ([_]bool{ true, false }) |bounded| {
        var f: fx.Fixture = undefined;
        try f.initWith(.{ .bounded_caches = bounded });
        defer f.deinit();
        var race: Race = .{ .st = f.st };
        var threads = [_]?std.Thread{ null, null };
        threads[0] = try std.Thread.spawn(.{}, Race.batcher, .{&race});
        threads[1] = try std.Thread.spawn(.{}, Race.single, .{&race});
        runFor(&race, &threads);
        const batches = race.batches.load(.monotonic);
        const singles = race.singles.load(.monotonic);
        std.debug.print("batch vs single ({s}, {s} caches, node cap {d}): batches={d} singles={d} errors={d}\n", .{ @tagName(builtin.mode), if (bounded) "bounded" else "unbounded", f.st.nodes.effectiveCap(), batches, singles, race.errors.load(.monotonic) });
        try testing.expectEqual(@as(usize, 0), race.errors.load(.monotonic));
        try testing.expect(batches > 0 and singles > 0);
        try testing.expectEqual(batches * 1024, fx.countLabel(f.st, "g1", "B"));
        try testing.expectEqual(singles, fx.countLabel(f.st, "g2", "S"));
    }
}

test "SONNY-3233: two edge writers on different graphs, with edge deletes and edge-type readers of a third" {
    for ([_]bool{ false, true }) |bounded| {
        var f: fx.Fixture = undefined;
        try f.initWith(.{ .bounded_caches = bounded });
        defer f.deinit();
        {
            const s = try f.session("seed");
            try fx.expectRuns(f.ga(), s, "CREATE (:C {v: 0})-[:R]->(:C {v: 1})");
        }
        var race: Race = .{ .st = f.st };
        var threads = [_]?std.Thread{ null, null, null };
        threads[0] = try std.Thread.spawn(.{}, Race.edgeWriter, .{ &race, 0, @as([]const u8, "g1") });
        threads[1] = try std.Thread.spawn(.{}, Race.edgeWriter, .{ &race, 1, @as([]const u8, "g2") });
        threads[2] = try std.Thread.spawn(.{}, Race.edgeReader, .{&race});
        runFor(&race, &threads);
        std.debug.print("edge writers ({s}, {s} caches): g1 edges={d} (-{d}) g2 edges={d} (-{d}) reads={d} errors={d}\n", .{
            @tagName(builtin.mode),         if (bounded) "bounded" else "unbounded",
            race.edges[0].load(.monotonic), race.removed[0].load(.monotonic),
            race.edges[1].load(.monotonic), race.removed[1].load(.monotonic),
            race.reads.load(.monotonic),    race.errors.load(.monotonic),
        });
        try testing.expectEqual(@as(usize, 0), race.errors.load(.monotonic));
        // Each graph holds the edges its writer made and did not delete.
        const a = testing.allocator;
        for ([_][]const u8{ "g1", "g2" }, 0..) |g, i| {
            const ids = f.st.getEdgesByType(a, "E", null, g);
            defer a.free(ids);
            const want = race.edges[i].load(.monotonic) - race.removed[i].load(.monotonic);
            if (ids.len != want) std.debug.print("  {s}: {d} edges, want {d}\n", .{ g, ids.len, want });
            try testing.expectEqual(want, ids.len);
        }
    }
}

test "SONNY-3233: CREATE/DROP GRAPH churn races first writes to other graphs and registry readers" {
    for ([_]bool{ false, true }) |bounded| {
        var f: fx.Fixture = undefined;
        try f.initWith(.{ .bounded_caches = bounded });
        defer f.deinit();
        var race: Race = .{ .st = f.st };
        var threads = [_]?std.Thread{ null, null, null, null };
        threads[0] = try std.Thread.spawn(.{}, Race.graphsDdl, .{&race});
        threads[1] = try std.Thread.spawn(.{}, Race.registryReader, .{&race});
        threads[2] = try std.Thread.spawn(.{}, Race.single, .{&race});
        threads[3] = try std.Thread.spawn(.{}, Race.batcher, .{&race});
        runFor(&race, &threads);
        std.debug.print("graphs churn ({s}, {s} caches): ddl rounds={d} reads={d} singles={d} batches={d} errors={d}\n", .{
            @tagName(builtin.mode),        if (bounded) "bounded" else "unbounded",
            race.ddl.load(.monotonic),     race.reads.load(.monotonic),
            race.singles.load(.monotonic), race.batches.load(.monotonic),
            race.errors.load(.monotonic),
        });
        try testing.expectEqual(@as(usize, 0), race.errors.load(.monotonic));
        try testing.expect(race.ddl.load(.monotonic) > 0);
        try testing.expect(f.st.graphExists("g1") and f.st.graphExists("g2"));
        try testing.expectEqual(race.singles.load(.monotonic), fx.countLabel(f.st, "g2", "S"));
        try testing.expectEqual(race.batches.load(.monotonic) * 1024, fx.countLabel(f.st, "g1", "B"));
    }
}
