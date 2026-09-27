// SONNY-3028 regression: DROP GRAPH frees a graph only when no thread holds
// it.
//
// `programDataGraph` counted DROP GRAPH as a statement on the session's
// graph, so `DROP GRAPH g` from a session on `default` took `default`'s write
// lock, and `StorageAdapter.dropGraph` freed g's `ManagedGraph` while other
// threads held or waited for g's lock (review probe R9R11-P5: the holder's
// release was a use-after-free) and while engine transactions pointed into
// it (`START TRANSACTION; CREATE (:X); DROP GRAPH g; CREATE (:Y)` left the
// session's engine transaction on the freed graph).
//
// Now CREATE and DROP GRAPH run on the graph they name (the handler takes its
// write lock, so DROP GRAPH waits for the graph's other requests), every
// holder and waiter of a graph's lock pins the graph and the last one frees a
// dropped graph, a waiter that gets the lock of a dropped graph lets it go
// (`GraphNotFound`), and DROP GRAPH of the graph the session's transaction
// changed is refused (55006).
//
// CANARY: REQ=REQ-SONNY-3028-DROP-GRAPH-PINS; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3028_drop_graph_in_use.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const query_traits = geode.query_traits;

// ---------------------------------------------------------------------------
// The plan both handlers make.
// ---------------------------------------------------------------------------

fn planOf(query: []const u8, session_graph: []const u8) !query_traits.StatementPlan {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    const analysis = query_traits.analyzeRequest(&parsed.program);
    const plan = query_traits.statementPlan(&parsed.program, &analysis, session_graph, "default", .grpc);
    // `lock_graph` points into the parsed program: compare before it goes.
    return .{
        .is_mutation = plan.is_mutation,
        .needs_store_lock = plan.needs_store_lock,
        .self_locking = plan.self_locking,
        .point_read = plan.point_read,
        .lock_graph = if (std.mem.eql(u8, plan.lock_graph, session_graph)) session_graph else if (std.mem.eql(u8, plan.lock_graph, "g2")) "g2" else if (std.mem.eql(u8, plan.lock_graph, "g5")) "g5" else "other",
        .spans_graphs = plan.spans_graphs,
        .lock_graph_may_be_missing = plan.lock_graph_may_be_missing,
    };
}

test "SONNY-3028: CREATE and DROP GRAPH run on the graph they name; a program that only creates or drops it needs no lock when it is missing" {
    const drop = try planOf("DROP GRAPH g2", "default");
    try testing.expectEqualStrings("g2", drop.lock_graph);
    try testing.expect(drop.is_mutation and !drop.spans_graphs and drop.lock_graph_may_be_missing);

    const create = try planOf("CREATE GRAPH g5", "default");
    try testing.expectEqualStrings("g5", create.lock_graph);
    try testing.expect(create.lock_graph_may_be_missing);

    const idiom = try planOf("DROP GRAPH IF EXISTS g5; CREATE GRAPH g5", "default");
    try testing.expectEqualStrings("g5", idiom.lock_graph);
    try testing.expect(!idiom.spans_graphs and idiom.lock_graph_may_be_missing);

    const then_write = try planOf("DROP GRAPH IF EXISTS g2; USE GRAPH g2; CREATE (:X)", "default");
    try testing.expectEqualStrings("g2", then_write.lock_graph);
    try testing.expect(!then_write.lock_graph_may_be_missing);

    const two = try planOf("CREATE (:X); DROP GRAPH g2", "default");
    try testing.expect(two.spans_graphs);
}

// ---------------------------------------------------------------------------
// The gRPC handler, in process.
// ---------------------------------------------------------------------------

/// Holds `graph`'s read lock for `hold_ms`. If `freed` is set when it lets
/// go, the graph was dropped under it: it releases only the store lock, since
/// touching the freed graph's lock would be the use-after-free itself.
const Holder = struct {
    graph: []const u8,
    hold_ms: u64 = 500,
    held: std.atomic.Value(bool) = .init(false),
    letting_go: std.atomic.Value(bool) = .init(false),
    freed: *std.atomic.Value(bool),

    fn go(self: *Holder) void {
        const lock = graph_store.acquireGraphReadLock(self.graph);
        self.held.store(true, .release);
        fx.sleepMs(self.hold_ms);
        self.letting_go.store(true, .release);
        if (self.freed.load(.acquire)) {
            var h2 = lock;
            h2.managed_graph = null;
            graph_store.releaseGraphLock(h2);
            return;
        }
        graph_store.releaseGraphLock(lock);
    }

    fn start(self: *Holder) !std.Thread {
        const t = try std.Thread.spawn(.{}, go, .{self});
        while (!self.held.load(.acquire)) fx.sleepMs(1);
        return t;
    }
};

test "SONNY-3028: over gRPC DROP GRAPH from a session on another graph waits for a holder of the graph's lock (R9R11-P5)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("dropper");
    try f.st.createGraph("g3");

    var freed: std.atomic.Value(bool) = .init(false);
    var holder: Holder = .{ .graph = "g3", .freed = &freed };
    const t = try holder.start();
    const code = fx.outcome(ga, s, "DROP GRAPH g3");
    const waited = holder.letting_go.load(.acquire);
    if (!waited) freed.store(true, .release);
    t.join();
    try testing.expect((try code) == null);
    try testing.expect(waited);
    try testing.expect(!f.st.graphExists("g3"));
}

const Waiter = struct {
    graph: []const u8,
    started: std.atomic.Value(bool) = .init(false),
    outcome: std.atomic.Value(u8) = .init(0), // 1 got the lock, 2 GraphNotFound, 3 other error

    fn go(self: *Waiter) void {
        const ad = graph_store.getGlobalAdapter() orelse return;
        self.started.store(true, .release);
        const deadline = monoNow() + 30 * std.time.ns_per_s;
        if (ad.acquireGraphWriteLockCancelable(self.graph, deadline)) |mg| {
            ad.releaseGraphWriteLock(mg);
            self.outcome.store(1, .release);
        } else |err| {
            self.outcome.store(if (err == error.GraphNotFound) 2 else 3, .release);
        }
    }
};

fn monoNow() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "SONNY-3028: over gRPC a thread waiting for a graph's write lock while DROP GRAPH runs either gets it first or is told the graph is gone; the graph is freed once, by the last" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("dropper");
    try f.st.createGraph("g4");

    var freed: std.atomic.Value(bool) = .init(false);
    var holder: Holder = .{ .graph = "g4", .freed = &freed };
    const ht = try holder.start();
    var waiter: Waiter = .{ .graph = "g4" };
    const wt = try std.Thread.spawn(.{}, Waiter.go, .{&waiter});
    while (!waiter.started.load(.acquire)) fx.sleepMs(1);
    fx.sleepMs(20);
    const code = try fx.outcome(ga, s, "DROP GRAPH g4");
    ht.join();
    wt.join();
    try testing.expect(code == null);
    const got = waiter.outcome.load(.acquire);
    try testing.expect(got == 1 or got == 2);
    try testing.expect(!f.st.graphExists("g4"));
    // The testing allocator reports a dropped graph nobody freed as a leak.
}

test "SONNY-3028: over gRPC CREATE GRAPH of a new graph and DROP GRAPH IF EXISTS of a missing one need no lock" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("ddl");
    try fx.expectRuns(ga, s, "DROP GRAPH IF EXISTS g5");
    try fx.expectRuns(ga, s, "CREATE GRAPH g5");
    try testing.expect(f.st.graphExists("g5"));
    try fx.expectRuns(ga, s, "DROP GRAPH IF EXISTS g5; CREATE GRAPH g5");
    try testing.expect(f.st.graphExists("g5"));
    _ = try fx.expectRefused(ga, s, "CREATE GRAPH g5", "42P07");
    try fx.expectRuns(ga, s, "DROP GRAPH g5");
    try testing.expect(!f.st.graphExists("g5"));
    _ = try fx.expectRefused(ga, s, "DROP GRAPH g5", "3F000");
}

test "SONNY-3028: over gRPC DROP GRAPH of the graph the session's transaction changed is refused (55006); the failed statement rolls the transaction back (GAP-0917), and the graph stays" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("txn");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.begin(ga, s);
    try fx.expectRuns(ga, s, "CREATE (:X {v: 1})");
    _ = try fx.expectRefused(ga, s, "DROP GRAPH g1", "55006");
    try testing.expect(f.st.graphExists("g1"));
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "X"));
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    // Outside a transaction the graph drops.
    try fx.expectRuns(ga, s, "DROP GRAPH g1");
    try testing.expect(!f.st.graphExists("g1"));
}

test "SONNY-3028: over gRPC `START TRANSACTION; CREATE; DROP GRAPH g; CREATE` in one program is refused (55006): the graph stays, the change is rolled back, no engine transaction is left on it" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("inprog");
    const entry = f.sessions.getEntry(s) orelse return error.SessionMissing;
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    _ = try fx.expectRefused(ga, s, "START TRANSACTION; CREATE (:X {v: 1}); DROP GRAPH g1; CREATE (:Y {v: 2})", "55006");
    try testing.expect(f.st.graphExists("g1"));
    try testing.expect(!entry.state.in_txn);
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "X"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "Y"));
    try testing.expectEqual(@as(usize, 0), fx.engineActive("g1"));
    // The graph still works.
    try fx.expectRuns(ga, s, "CREATE (:Z {v: 3})");
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "Z"));
}
