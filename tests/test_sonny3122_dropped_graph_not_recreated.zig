// SONNY-3122 regression: a write to a graph that no longer exists fails with
// GraphNotFound; only CREATE GRAPH (and a HELLO that may create it) creates
// a graph.
//
// A session left on a graph another session dropped took the graph's write
// lock for its next write (`acquireGraphWriteLockCancelable`, and the
// QUIC default fast paths through it). The adapter no longer had the graph
// (GraphNotFound), and `materializeGraphForWriteLock` created it again
// (`getOrCreateGraph`) so the write could go ahead: the dropped graph came
// back, for a principal without the schema permission (the SONNY-3033
// class). A thread that waited for the lock while the drop ran was told the
// graph was gone (SONNY-3028) and then created it again the same way (review
// probe V12). The materialization was for a graph the engine does not know
// yet (ENG-3914 RC-3: the default graph on a fresh server, a graph whose load
// was deferred); a graph that exists nowhere is now not created.
//
// CANARY: REQ=REQ-SONNY-3122-NO-RECREATE-ON-WRITE; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3122_dropped_graph_not_recreated.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;

fn adapterKnows(graph: []const u8) bool {
    const ad = graph_store.getGlobalAdapter() orelse return false;
    return ad.graphExists(graph);
}

fn expectGone(f: *fx.Fixture, graph: []const u8) !void {
    if (f.st.graphExists(graph) or adapterKnows(graph)) {
        std.debug.print("the dropped graph '{s}' exists again (store {}, adapter {})\n", .{ graph, f.st.graphExists(graph), adapterKnows(graph) });
        return error.DroppedGraphRecreated;
    }
}

test "SONNY-3122: over gRPC a session on a graph another session dropped cannot write to it, and the graph stays dropped" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const a = try f.session("writer");
    const b = try f.session("dropper");
    try f.st.createGraph("g3122");
    try fx.expectRuns(ga, a, "USE GRAPH g3122");
    try fx.expectRuns(ga, a, "CREATE (:X {v: 1})");
    try fx.expectRuns(ga, b, "DROP GRAPH g3122");
    try expectGone(&f, "g3122");

    const code = try fx.outcome(ga, a, "CREATE (:X {v: 2})");
    if (code == null) {
        std.debug.print("a write to the dropped graph succeeded\n", .{});
        return error.WriteToDroppedGraphSucceeded;
    }
    try expectGone(&f, "g3122");
    // MERGE takes the same lock.
    try testing.expect((try fx.outcome(ga, a, "MERGE (:X {v: 3})")) != null);
    try expectGone(&f, "g3122");
}

const Waiter = struct {
    graph: []const u8,
    started: std.atomic.Value(bool) = .init(false),
    /// 1 got a lock, 2 GraphNotFound, 3 other error.
    outcome: std.atomic.Value(u8) = .init(0),

    fn go(self: *Waiter) void {
        self.started.store(true, .release);
        const deadline = graph_store.monoNanosNowPub() + 30 * std.time.ns_per_s;
        if (graph_store.acquireGraphWriteLockCancelable(self.graph, deadline)) |h| {
            graph_store.releaseGraphLock(h);
            self.outcome.store(1, .release);
        } else |err| {
            self.outcome.store(if (err == error.GraphNotFound) 2 else 3, .release);
        }
    }
};

test "SONNY-3122 (V12): a write waiting for the lock of a graph that is dropped meanwhile is told it is gone and does not create it again" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.st.createGraph("g3122w");
    var holder: fx.Holder = .{ .graph = "g3122w", .write = true, .hold_ms = 400 };
    const ht = try holder.start();
    var waiter: Waiter = .{ .graph = "g3122w" };
    const wt = try std.Thread.spawn(.{}, Waiter.go, .{&waiter});
    while (!waiter.started.load(.acquire)) fx.sleepMs(1);
    fx.sleepMs(20);
    // Waits for the holder (SONNY-3135 N7c), then drops.
    try f.st.dropGraph("g3122w");
    ht.join();
    wt.join();
    const got = waiter.outcome.load(.acquire);
    if (got == 1) {
        // It may have won the lock before the drop: then the graph was
        // dropped after it let go, and must still be gone.
        try expectGone(&f, "g3122w");
    } else {
        try testing.expectEqual(@as(u8, 2), got);
        try expectGone(&f, "g3122w");
    }
}

test "SONNY-3122: the write lock of a graph that exists nowhere is GraphNotFound and creates nothing; the default graph is still materialized" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const deadline = graph_store.monoNanosNowPub() + 10 * std.time.ns_per_s;
    if (graph_store.acquireGraphWriteLockCancelable("never3122", deadline)) |h| {
        graph_store.releaseGraphLock(h);
        std.debug.print("the write lock of a graph that does not exist created it\n", .{});
        return error.LockCreatedGraph;
    } else |err| try testing.expectEqual(error.GraphNotFound, err);
    try expectGone(&f, "never3122");
    // ENG-3914 RC-3: the default graph is materialized by its first write lock.
    const h = try graph_store.acquireGraphWriteLockCancelable(graph_store.DEFAULT_GRAPH_NAME, deadline);
    try testing.expect(h.managed_graph != null);
    graph_store.releaseGraphLock(h);
}

// ---------------------------------------------------------------------------
// QUIC: the default fast paths (a plain CREATE / MERGE of a node) take the
// same lock; against a spawned server.
// ---------------------------------------------------------------------------

const binary_path = @import("geode_test_bin").geode_exe;

fn quicExec(allocator: std.mem.Allocator, c: *util.QuicProtoClient, q: []const u8) !?[]const u8 {
    var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 30);
    defer r.deinit(allocator);
    if (r.error_code) |code| return try std.heap.page_allocator.dupe(u8, code);
    return null;
}

test "SONNY-3122: over QUIC a session on a dropped graph cannot write to it through the fast paths, and the graph stays dropped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
    const allocator = testing.allocator;
    var server = try util.spawnServerRandom(allocator, util.TestEnv.standard());
    defer server.deinit();

    var a = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer a.deinit();
    var ha = try a.hello(allocator, util.DefaultAuth.username, util.DefaultAuth.password);
    defer ha.deinit(allocator);
    try testing.expect(ha.success);
    var b = try util.QuicProtoClient.connect(allocator, server.getAddr());
    defer b.deinit();
    var hb = try b.hello(allocator, util.DefaultAuth.username, util.DefaultAuth.password);
    defer hb.deinit(allocator);
    try testing.expect(hb.success);

    try testing.expectEqual(@as(?[]const u8, null), try quicExec(allocator, &a, "CREATE GRAPH q3122"));
    try testing.expectEqual(@as(?[]const u8, null), try quicExec(allocator, &a, "USE GRAPH q3122"));
    try testing.expectEqual(@as(?[]const u8, null), try quicExec(allocator, &a, "CREATE (:X {v: 1})"));
    try testing.expectEqual(@as(?[]const u8, null), try quicExec(allocator, &b, "DROP GRAPH q3122"));

    var violations: usize = 0;
    for ([_][]const u8{ "CREATE (:X {v: 2})", "MERGE (:X {v: 3})" }) |q| {
        const code = try quicExec(allocator, &a, q);
        if (code) |c| {
            std.heap.page_allocator.free(c);
        } else {
            std.debug.print("`{s}` on the dropped graph succeeded\n", .{q});
            violations += 1;
        }
    }
    // The graph is still gone: B cannot select it, and CREATE GRAPH makes a
    // new, empty one.
    if (try quicExec(allocator, &b, "USE GRAPH q3122")) |c| {
        std.heap.page_allocator.free(c);
    } else {
        std.debug.print("the dropped graph q3122 exists again\n", .{});
        violations += 1;
    }
    if (violations > 0) return error.DroppedGraphRecreated;
}
