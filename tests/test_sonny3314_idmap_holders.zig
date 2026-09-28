// SONNY-3314 regression (round 16, I2 and M1): a dropped graph's IdMap and
// name are freed only when nothing holds them, and freed then.
//
// Round 15 (c47a3628, SONNY-3253) freed a dropped graph's IdMap and name at
// once when no walk over every graph (`idMapsSnapshot`) was running, and kept
// them otherwise until no walk at all ran. Two holders were not counted:
//   - a point resolve (`resolveNodeGraphSlot`, `resolveEdgeGraphSlot`) handed
//     back the `id_maps` key after letting the lock go, and hydrate-on-miss
//     (`materializeNodeFromEngine`) used that name after a DROP GRAPH had
//     freed it;
//   - a first-touch hydration (`loadOneGraphFromAdapterFull`) held the IdMap
//     for its whole build with no graph lock, and DROP GRAPH freed it.
// And (M1) overlapping walks kept the walker count above 0, so no dropped map
// was freed at all.
//
// Now each holder pins the map it holds (`IdMap.holders`), and a dropped
// graph's map and name are freed by its last holder, or at the drop when
// nothing pins it. Each test below loops, with bounded retained memory:
//   - DROP GRAPH racing hydrate-on-miss (the cache's real hydrate path) and a
//     pinned resolve that checks the name it holds is whole;
//   - DROP GRAPH during a first-touch hydration of the same graph;
//   - overlapping snapshot walks during DROP churn: the retired maps stay
//     bounded by the maps the walks pinned, and are freed when they end.
// Run the step 20 times.
//
// CANARY: REQ=REQ-SONNY-3314-IDMAP-PINS; FEATURE="IdMap"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3314_idmap_holders.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

const labels = [_][]const u8{"H"};

fn monoMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// Creates graph `name` with `n` nodes, then drops it, `rounds` times,
/// publishing each round's node ids for the other threads.
const Churn = struct {
    st: *graph_store.GraphStore,
    name: []const u8,
    n: usize,
    rounds: usize,
    ids: [64]std.atomic.Value(u64) = [_]std.atomic.Value(u64){.init(0)} ** 64,
    done: std.atomic.Value(bool) = .init(false),
    failures: usize = 0,

    fn run(self: *Churn) void {
        defer self.done.store(true, .release);
        for (0..self.rounds) |_| {
            self.st.createGraph(self.name) catch {
                self.failures += 1;
                continue;
            };
            for (0..self.n) |i| {
                const id = self.st.createNodeWithGraph(&labels, self.name) catch {
                    self.failures += 1;
                    continue;
                };
                self.ids[i % self.ids.len].store(id, .release);
            }
            self.st.dropGraph(self.name) catch {
                self.failures += 1;
            };
        }
    }
};

/// Resolves the published ids as hydrate-on-miss does, holding each pin while
/// it spins, and checks the name it holds; and takes the cache's real
/// hydrate-on-miss path for ids it evicts first.
const Resolver = struct {
    st: *graph_store.GraphStore,
    churn: *Churn,
    resolved: usize = 0,
    torn: usize = 0,
    hydrated: usize = 0,

    fn run(self: *Resolver) void {
        var buf: [64]u8 = undefined;
        var i: usize = 0;
        while (!self.churn.done.load(.acquire)) : (i += 1) {
            const id = self.churn.ids[i % self.churn.ids.len].load(.acquire);
            if (id == 0) continue;
            if (self.st.resolveNodeGraphNameForTest(id, &buf, 2000)) |name| {
                self.resolved += 1;
                if (!std.mem.eql(u8, name, self.churn.name)) {
                    self.torn += 1;
                    if (self.torn < 4) std.debug.print("SONNY-3314: a pinned name read {any}\n", .{name});
                }
            }
            // The cache's hydrate-on-miss: evict (retired, not freed), then
            // read through the hydrate hook, racing the DROP.
            if (i % 4 == 0) {
                self.st.nodes.remove(id);
                if (self.st.getNodePtrHydrated(id)) |node| {
                    _ = node;
                    self.hydrated += 1;
                }
            }
        }
    }
};

test "SONNY-3314 (I2): DROP GRAPH racing hydrate-on-miss and pinned resolves: the name a resolve holds stays whole; nothing is retained after" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    var churn: Churn = .{ .st = f.st, .name = "h3314a", .n = 40, .rounds = 60 };
    var resolvers: [3]Resolver = undefined;
    var threads: [3]std.Thread = undefined;
    for (&resolvers, &threads) |*r, *t| {
        r.* = .{ .st = f.st, .churn = &churn };
        t.* = try std.Thread.spawn(.{}, Resolver.run, .{r});
    }
    const ct = try std.Thread.spawn(.{}, Churn.run, .{&churn});
    ct.join();
    for (threads) |t| t.join();
    var resolved: usize = 0;
    var torn: usize = 0;
    var hydrated: usize = 0;
    for (resolvers) |r| {
        resolved += r.resolved;
        torn += r.torn;
        hydrated += r.hydrated;
    }
    std.debug.print("SONNY-3314 hydrate race: {d} drops, {d} pinned resolves, {d} torn names, {d} hydrated; retired after={d}\n", .{ churn.rounds, resolved, torn, hydrated, f.st.retired_id_maps.items.len });
    try testing.expectEqual(@as(usize, 0), churn.failures);
    try testing.expectEqual(@as(usize, 0), torn);
    try testing.expectEqual(@as(usize, 0), f.st.retired_id_maps.items.len);
    try testing.expectEqual(@as(usize, 0), f.st.retired_id_count.load(.acquire));
}

const Hydrate = struct {
    st: *graph_store.GraphStore,
    name: []const u8,
    fn run(self: *Hydrate) void {
        self.st.ensureGraphHydrated(self.name);
    }
};

test "SONNY-3314 (I2): DROP GRAPH during a first-touch hydration of the same graph: no use after free; nothing is retained after" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    var buf: [32]u8 = undefined;
    for (0..8) |round| {
        const name = try std.fmt.bufPrint(&buf, "h3314b{d}", .{round});
        try f.st.createGraph(name);
        for (0..1500) |_| _ = try f.st.createNodeWithGraph(&labels, name);
        try f.st.markPendingHydrationForTest(name);
        var h: Hydrate = .{ .st = f.st, .name = name };
        const t = try std.Thread.spawn(.{}, Hydrate.run, .{&h});
        // Let the build start and take the IdMap, then drop the graph under it.
        fx.sleepMs(@as(u64, round % 4));
        try f.st.dropGraph(name);
        t.join();
    }
    std.debug.print("SONNY-3314 hydration race: retired after={d}\n", .{f.st.retired_id_maps.items.len});
    try testing.expectEqual(@as(usize, 0), f.st.retired_id_maps.items.len);
}

const Walker = struct {
    st: *graph_store.GraphStore,
    stop: *std.atomic.Value(bool),
    walks: usize = 0,
    max_retired_seen: usize = 0,
    fn run(self: *Walker) void {
        while (!self.stop.load(.acquire)) {
            const refs = self.st.idMapsSnapshotForTest(testing.allocator) catch continue;
            for (refs) |r| _ = r.map.nodeCount();
            fx.sleepMs(1);
            self.st.releaseIdMapsForTest(testing.allocator, refs);
            self.walks += 1;
        }
    }
};

test "SONNY-3314 (M1): overlapping snapshot walks during DROP churn: the retired IdMaps stay bounded, and none is left after" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    // Four walkers, each holding a list 1 ms at a time: at round 15's walker
    // count some walk was nearly always running, so no dropped map was freed.
    var walkers: [4]Walker = undefined;
    var threads: [4]std.Thread = undefined;
    for (&walkers, &threads) |*w, *t| {
        w.* = .{ .st = f.st, .stop = &stop };
        t.* = try std.Thread.spawn(.{}, Walker.run, .{w});
    }
    var buf: [32]u8 = undefined;
    const drops: usize = 120;
    var max_retired: usize = 0;
    const t0 = monoMs();
    for (0..drops) |i| {
        const name = try std.fmt.bufPrint(&buf, "h3314c{d}", .{i});
        try f.st.createGraph(name);
        _ = try f.st.createNodeWithGraph(&labels, name);
        try f.st.dropGraph(name);
        max_retired = @max(max_retired, f.st.retired_id_maps.items.len);
    }
    stop.store(true, .release);
    for (threads) |t| t.join();
    var walks: usize = 0;
    for (walkers) |w| walks += w.walks;
    std.debug.print("SONNY-3314 M1: {d} drops in {d} ms under {d} overlapping walks: max retired {d}, after {d}\n", .{ drops, monoMs() - t0, walks, max_retired, f.st.retired_id_maps.items.len });
    // Only a map a walk listed can be retired: each walk lists the maps that
    // exist when it starts (g1, g2, default and at most one churn graph).
    try testing.expect(max_retired <= walkers.len);
    try testing.expectEqual(@as(usize, 0), f.st.retired_id_maps.items.len);
}
