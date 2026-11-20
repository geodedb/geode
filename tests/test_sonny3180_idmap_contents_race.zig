// SONNY-3180 (round 15, F2): the CONTENTS of each graph's IdMap, and the
// resident node and edge maps every graph shares, are read under their own
// locks, so reads race writers and DROP GRAPH of other graphs safely.
//
// Round 14 locked `GraphStore.id_maps` (the map from a graph's name to its
// IdMap) but not what each IdMap holds. The review's probes:
//   - every snapshot read (`QueryReadSession.initIfAvailable`, reached from
//     the gRPC and QUIC read paths through `snapshotUnderReadLock`) cloned
//     every graph's IdMap (`IdMap.clone`, no lock) and every graph's resident
//     nodes and edges (no lock), holding only its own graph's read lock: two
//     snapshot readers and a writer of another graph crashed within a second,
//     in Debug and ReleaseSafe; with DROP/CREATE churn, ReleaseSafe showed
//     heap corruption;
//   - `allEdgeIds` (CALL db.propertyKeys(), the graph algorithms),
//     `getAllEdgesForTenant` and the backup serializer walked every IdMap
//     with its unlocked iterator;
//   - over gRPC, a read and a COMMIT on a graph racing DROP and CREATE GRAPH
//     of the same name tripped a hash-map assertion in `IdMap.clone`.
//
// Now `IdMap.clone`, `nodeCount` and `edgeCount` take the map's mutex, and
// the walks copy the uuids under it (`snapshotNodeUuids`,
// `snapshotEdgeUuids`) or hold it (`forEachNodeUuid`); DROP GRAPH frees the
// contents under the same mutex (`releaseContents`), so no walk holds
// contents a drop frees (the IdMap itself is kept). A resident map is walked
// a shard at a time under the shard's lock (`forEachResident`,
// `snapshotKeys`), and a snapshot read clones only its own graph.
//
// Each race runs for a bounded time with the caches unbounded (the
// harness's default) and BOUNDED (as `initGlobalStore` sets them in
// production). Loop the step (the brief: 20 times) to shake out the rare
// interleavings.
//
// CANARY: REQ=REQ-SONNY-3180-IDMAP-CONTENTS; FEATURE="IdMap"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3180_idmap_contents_race.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

/// How long each race runs.
const race_ms: u64 = 2500;

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
    snaps: std.atomic.Value(usize) = .init(0),
    walks: std.atomic.Value(usize) = .init(0),
    writes: std.atomic.Value(usize) = .init(0),
    drops: std.atomic.Value(usize) = .init(0),
    calls: std.atomic.Value(usize) = .init(0),
    /// Failures that are not a race's expected refusals.
    errors: std.atomic.Value(usize) = .init(0),
    /// A snapshot of `default` or `g1` that saw another graph's node.
    leaks: std.atomic.Value(usize) = .init(0),

    fn noteErr(self: *Race, what: []const u8, e: anyerror) void {
        const n = self.errors.fetchAdd(1, .monotonic);
        if (n < 8) std.debug.print("    {s}: {s}\n", .{ what, @errorName(e) });
    }

    /// Snapshot reads of `graph` (every gRPC and QUIC read not served
    /// engine-direct takes one).
    fn snapshotReader(self: *Race, graph: []const u8) void {
        const a = std.heap.smp_allocator;
        while (!self.stop.load(.acquire)) {
            var sess = graph_store.snapshotUnderReadLock(a, graph) catch |e| {
                self.noteErr("snapshotUnderReadLock", e);
                continue;
            };
            defer sess.deinit();
            // A snapshot holds its own graph only.
            if (sess.store().getNodesByLabel("g2", "W")) |ids| {
                if (ids.len > 0) _ = self.leaks.fetchAdd(1, .monotonic);
            }
            _ = self.snaps.fetchAdd(1, .monotonic);
        }
    }

    /// Store walks over every graph: the IdMaps (bounded caches) or the
    /// resident maps (unbounded).
    fn walker(self: *Race) void {
        const a = std.heap.smp_allocator;
        while (!self.stop.load(.acquire)) {
            const lock = graph_store.acquireGraphReadLock("default");
            defer graph_store.releaseGraphLock(lock);
            if (self.st.allEdgeIds(a)) |ids| a.free(ids) else |e| self.noteErr("allEdgeIds", e);
            if (self.st.getAllNodes(a)) |ids| a.free(ids) else |e| self.noteErr("getAllNodes", e);
            if (self.st.getAllEdgesForTenant(a, null)) |ids| a.free(ids) else |e| self.noteErr("getAllEdgesForTenant", e);
            _ = self.st.getNodeCount();
            _ = self.st.getEdgeCount();
            if (self.st.countNodesForGraph("default", "t-none")) |_| {} else |e| self.noteErr("countNodesForGraph", e);
            _ = self.walks.fetchAdd(1, .monotonic);
        }
    }

    /// Nodes and edges written to g2.
    fn writer(self: *Race) void {
        const labels = [_][]const u8{"W"};
        var prev: ?u64 = null;
        while (!self.stop.load(.acquire)) {
            const lock = graph_store.acquireGraphWriteLock("g2");
            defer graph_store.releaseGraphLock(lock);
            const id = self.st.createNodeWithGraph(&labels, "g2") catch |e| {
                self.noteErr("createNode g2", e);
                continue;
            };
            if (prev) |p| {
                _ = self.st.createEdgeWithGraph(p, id, "E", "g2") catch |e| self.noteErr("createEdge g2", e);
            }
            prev = id;
            _ = self.writes.fetchAdd(1, .monotonic);
        }
    }

    /// CREATE GRAPH, nodes and edges, DROP GRAPH, over and over.
    fn dropper(self: *Race, which: usize) void {
        var buf: [32]u8 = undefined;
        const labels = [_][]const u8{"Z"};
        var i: usize = 0;
        while (!self.stop.load(.acquire)) : (i += 1) {
            const name = std.fmt.bufPrint(&buf, "dz{d}x{d}", .{ which, i % 3 }) catch unreachable;
            const lock = graph_store.acquireGraphWriteLock(name);
            defer graph_store.releaseGraphLock(lock);
            self.st.createGraph(name) catch |e| {
                self.noteErr("createGraph", e);
                continue;
            };
            var prev: ?u64 = null;
            var k: usize = 0;
            while (k < 300) : (k += 1) {
                const id = self.st.createNodeWithGraph(&labels, name) catch |e| {
                    self.noteErr("createNode dz", e);
                    break;
                };
                if (prev) |p| {
                    _ = self.st.createEdgeWithGraph(p, id, "E", name) catch |e| {
                        self.noteErr("createEdge dz", e);
                        break;
                    };
                }
                prev = id;
            }
            self.st.dropGraph(name) catch |e| self.noteErr("dropGraph", e);
            _ = self.drops.fetchAdd(1, .monotonic);
        }
    }

    /// `CALL db.propertyKeys()` over gRPC (it walks every edge id).
    fn propertyKeys(self: *Race, store: *grpc.SessionStore) void {
        const sid_tmp = store.createSession("pk", "", null, null, null, false, 0) catch |e| {
            self.noteErr("createSession", e);
            return;
        };
        const sid = std.heap.smp_allocator.dupe(u8, sid_tmp) catch |e| {
            self.noteErr("dupe", e);
            return;
        };
        defer std.heap.smp_allocator.free(sid);
        while (!self.stop.load(.acquire)) {
            // The session keeps a request's result, allocated with the
            // request's allocator, and frees it with its own at the next
            // request: one allocator for both, as the server passes.
            const code = fx.outcome(std.heap.smp_allocator, sid, "CALL db.propertyKeys()") catch |e| {
                self.noteErr("CALL db.propertyKeys()", e);
                continue;
            };
            if (code) |c| {
                const k = self.errors.fetchAdd(1, .monotonic);
                if (k < 8) std.debug.print("    CALL db.propertyKeys() -> {s}\n", .{c});
            }
            _ = self.calls.fetchAdd(1, .monotonic);
        }
    }
};

const Parts = struct {
    snapshots: bool = false,
    walker: bool = false,
    writer: bool = false,
    droppers: bool = false,
    property_keys: bool = false,
};

fn runRace(bounded: bool, parts: Parts, name: []const u8) !void {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = bounded });
    defer f.deinit();
    // Something to snapshot and walk in `default` and `g1`.
    {
        const ga = f.ga();
        const s = try f.session("seed");
        try fx.expectRuns(ga, s, "CREATE (:C {v: 0})-[:R {w: 1}]->(:C {v: 1})");
        try fx.expectRuns(ga, s, "USE GRAPH g1");
        try fx.expectRuns(ga, s, "CREATE (:D {v: 0})-[:R {w: 1}]->(:D {v: 1})");
    }
    var store = grpc.SessionStore.init(std.heap.smp_allocator, .{
        .idle_in_transaction_timeout_ms = 0,
        .session_idle_timeout_ms = 0,
        .max_sessions_per_principal = 0,
    });
    grpc.setSessionStore(&store);
    defer {
        grpc.setSessionStore(&f.sessions);
        store.deinit();
    }
    var race: Race = .{ .st = f.st };
    var threads = [_]?std.Thread{null} ** 8;
    if (parts.snapshots) {
        threads[0] = try std.Thread.spawn(.{}, Race.snapshotReader, .{ &race, @as([]const u8, "default") });
        threads[1] = try std.Thread.spawn(.{}, Race.snapshotReader, .{ &race, @as([]const u8, "g1") });
    }
    if (parts.walker) threads[2] = try std.Thread.spawn(.{}, Race.walker, .{&race});
    if (parts.writer) threads[3] = try std.Thread.spawn(.{}, Race.writer, .{&race});
    if (parts.droppers) {
        threads[4] = try std.Thread.spawn(.{}, Race.dropper, .{ &race, 0 });
        threads[5] = try std.Thread.spawn(.{}, Race.dropper, .{ &race, 1 });
    }
    if (parts.property_keys) threads[6] = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Race.propertyKeys, .{ &race, &store });
    const t0 = monoMs();
    while (monoMs() - t0 < race_ms) fx.sleepMs(50);
    race.stop.store(true, .release);
    for (threads) |t| if (t) |th| th.join();
    std.debug.print("{s} ({s}, {s} caches): snapshots={d} walks={d} writes={d} drops={d} calls={d} errors={d} leaks={d}\n", .{
        name,                        @tagName(builtin.mode),      if (bounded) "bounded" else "unbounded",
        race.snaps.load(.monotonic), race.walks.load(.monotonic), race.writes.load(.monotonic),
        race.drops.load(.monotonic), race.calls.load(.monotonic), race.errors.load(.monotonic),
        race.leaks.load(.monotonic),
    });
    try testing.expectEqual(@as(usize, 0), race.errors.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), race.leaks.load(.monotonic));
    if (parts.snapshots) try testing.expect(race.snaps.load(.monotonic) > 0);
    if (parts.walker) try testing.expect(race.walks.load(.monotonic) > 0);
    if (parts.writer) try testing.expect(race.writes.load(.monotonic) > 0);
    if (parts.droppers) try testing.expect(race.drops.load(.monotonic) > 0);
    if (parts.property_keys) try testing.expect(race.calls.load(.monotonic) > 0);
    // The store serves after the race: g2 holds what the writer made.
    try testing.expectEqual(race.writes.load(.monotonic), fx.countLabel(f.st, "g2", "W"));
}

test "SONNY-3180: snapshot reads of default and g1 race a writer of g2 without a fault, and hold their own graph only" {
    for ([_]bool{ false, true }) |bounded| try runRace(bounded, .{ .snapshots = true, .writer = true }, "snapshots + writer");
}

test "SONNY-3180: snapshot reads race a writer of another graph and CREATE/DROP GRAPH churn" {
    for ([_]bool{ false, true }) |bounded| try runRace(bounded, .{ .snapshots = true, .writer = true, .droppers = true }, "snapshots + writer + drop churn");
}

test "SONNY-3180: allEdgeIds, getAllNodes, the counts and CALL db.propertyKeys() race writers and CREATE/DROP GRAPH churn" {
    for ([_]bool{ false, true }) |bounded| try runRace(bounded, .{ .walker = true, .writer = true, .droppers = true, .property_keys = true }, "walks + db.propertyKeys + writer + drop churn");
}

// ---------------------------------------------------------------------------
// gRPC: a read and a COMMIT on gm racing DROP and CREATE GRAPH gm.
// ---------------------------------------------------------------------------

const SameName = struct {
    store: *grpc.SessionStore,
    stop: std.atomic.Value(bool) = .init(false),
    a_iters: usize = 0,
    a_ok: usize = 0,
    a_refused: usize = 0,
    a_unexpected: usize = 0,
    a_last: [8]u8 = .{0} ** 8,
    b_drops: usize = 0,
    b_held: usize = 0,
    b_recreated: usize = 0,
    b_unexpected: usize = 0,

    fn a(self: *SameName, iters: usize) void {
        defer self.stop.store(true, .release);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            // One allocator for the requests and the session (see
            // `Race.propertyKeys`).
            const ga = std.heap.smp_allocator;
            const sid = ga.dupe(u8, self.store.createSession("sa", "", null, null, null, false, 0) catch continue) catch continue;
            // A transaction a refusal left open lets its hold go.
            defer _ = fx.rollback(ga, sid) catch false;
            self.a_iters += 1;
            // gm may be gone between B's DROP and CREATE: 42002/2B000-style
            // refusals are clean answers.
            const use = fx.outcome(ga, sid, "USE GRAPH gm") catch {
                self.a_unexpected += 1;
                continue;
            };
            if (use != null) {
                self.a_refused += 1;
                continue;
            }
            fx.begin(ga, sid) catch {
                self.a_refused += 1;
                continue;
            };
            _ = fx.outcome(ga, sid, "CREATE (:X {v: 1})") catch {
                self.a_unexpected += 1;
                continue;
            };
            const c = fx.outcome(ga, sid, "COMMIT; MATCH (n:X) RETURN count(n) AS c") catch {
                self.a_unexpected += 1;
                continue;
            };
            if (c) |code| {
                self.a_refused += 1;
                const n = @min(code.len, self.a_last.len);
                @memcpy(self.a_last[0..n], code[0..n]);
            } else self.a_ok += 1;
            _ = fx.outcome(ga, sid, "MATCH (n) RETURN count(n) AS c") catch {
                self.a_unexpected += 1;
            };
        }
    }

    fn noteB(self: *SameName, what: []const u8, code: []const u8) void {
        if (self.b_unexpected < 6) std.debug.print("    B {s} -> {s}\n", .{ what, code });
        self.b_unexpected += 1;
    }

    fn b(self: *SameName) void {
        const created = self.store.createSession("sb", "", null, null, null, false, 0) catch return;
        const sid = std.heap.smp_allocator.dupe(u8, created) catch return;
        defer std.heap.smp_allocator.free(sid);
        while (!self.stop.load(.acquire)) {
            const ga = std.heap.smp_allocator;
            const d = fx.outcome(ga, sid, "DROP GRAPH gm") catch {
                self.b_unexpected += 1;
                continue;
            };
            if (d) |code| {
                // Held by A's open transaction.
                if (std.mem.eql(u8, code, "55006")) self.b_held += 1 else self.noteB("DROP GRAPH gm", code);
                continue;
            }
            self.b_drops += 1;
            if (fx.outcome(ga, sid, "CREATE GRAPH gm")) |cc| {
                // 42P07: A's statement, waiting for gm's lock across the
                // DROP, created gm again (SONNY-3122's general case, known).
                if (cc) |code| {
                    if (std.mem.eql(u8, code, "42P07")) self.b_recreated += 1 else self.noteB("CREATE GRAPH gm", code);
                }
            } else |e| self.noteB("CREATE GRAPH gm", @errorName(e));
        }
    }
};

test "SONNY-3180: over gRPC, a read and a COMMIT on gm race DROP and CREATE GRAPH gm without a fault" {
    for ([_]bool{ false, true }) |bounded| {
        var f: fx.Fixture = undefined;
        try f.initWith(.{ .bounded_caches = bounded });
        defer f.deinit();
        var store = grpc.SessionStore.init(std.heap.smp_allocator, .{
            .idle_in_transaction_timeout_ms = 0,
            .session_idle_timeout_ms = 0,
            .max_sessions_per_principal = 0,
        });
        grpc.setSessionStore(&store);
        defer {
            grpc.setSessionStore(&f.sessions);
            store.deinit();
        }
        try f.st.createGraph("gm");
        var race: SameName = .{ .store = &store };
        const t0 = monoMs();
        const ta = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, SameName.a, .{ &race, 150 });
        const tb = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, SameName.b, .{&race});
        ta.join();
        tb.join();
        std.debug.print("same-name race ({s}, {s} caches, {d} ms): A iters={d} ok={d} refused={d} (last {s}) unexpected={d}; B drops={d} held(55006)={d} re-created by A (42P07)={d} unexpected={d}; held after={}\n", .{
            @tagName(builtin.mode),           if (bounded) "bounded" else "unbounded", monoMs() - t0,
            race.a_iters,                     race.a_ok,                               race.a_refused,
            std.mem.sliceTo(&race.a_last, 0), race.a_unexpected,                       race.b_drops,
            race.b_held,                      race.b_recreated,                        race.b_unexpected,
            graph_store.graphHeldByTxn("gm"),
        });
        try testing.expectEqual(@as(usize, 0), race.a_unexpected);
        try testing.expectEqual(@as(usize, 0), race.b_unexpected);
        try testing.expect(race.a_iters > 0);
        try testing.expect(!graph_store.graphHeldByTxn("gm"));
    }
}
