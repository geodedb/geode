// SONNY-3350 regression (round 17): the round 16 review's minors.
//
// - A Raft `drop_graph` entry dropped the graph with no lock: the apply
//   thread freed the graph under a request holding its read or write lock.
//   It takes the graph's write lock now, as DROP GRAPH's handlers do.
// - The IdMap readers the round 16 pins did not cover (`planned_read_runtime`
//   and `node_scan_stream`'s slot-to-id resolves, the point-write fast path)
//   looked the map up by name and used it with no pin. A reader that holds
//   the global lock only (`acquireGraphReadLock` falls back to it when the
//   graph is missing, as a page re-locks after a DROP) does not hold off a
//   DROP GRAPH, which frees an unpinned map. They pin it now
//   (`GraphStore.idMapNodeId`, `idMapEdgeId`, `idMapBackfillNode`).
// - A read of several graphs (`snapshotUnderReadLocks`, SONNY-3312) took
//   every graph's read lock and copied it before the executor refused a USE
//   GRAPH the principal may not bind: a principal refused a graph waited on
//   its writers, and had it copied. Each graph's access is checked first now.
//
// CANARY: REQ=REQ-SONNY-3350-ROUND16-MINORS; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3350_round16_minors.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;
const planned_read_runtime = geode.planned_read_runtime;
const raft_apply = geode.distributed.raft_apply;
const principal_mod = geode.security.principal;

const Apply = struct {
    st: *graph_store.GraphStore,
    graph: []const u8,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn go(self: *Apply) void {
        defer self.done.store(true, .release);
        const out = raft_apply.applyCommand(testing.allocator, self.st, .{ .schema_change = .{
            .operation = .drop_graph,
            .graph = self.graph,
            .schema = "",
        } }, 1) catch |e| {
            self.err = e;
            return;
        };
        testing.allocator.free(out);
    }
};

test "SONNY-3350: a Raft drop_graph waits for the graph's lock holders, and drops the graph after" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_]bool{ false, true }) |write| {
        const name = if (write) "g1" else "g2";
        var holder = fx.Holder{ .graph = name, .hold_ms = 400, .write = write };
        const ht = try holder.start();
        var apply = Apply{ .st = f.st, .graph = name };
        const at = try std.Thread.spawn(.{}, Apply.go, .{&apply});
        fx.sleepMs(150);
        const early = apply.done.load(.acquire);
        const exists_under_lock = f.st.graphExists(name);
        at.join();
        const let_go = holder.letting_go.load(.acquire);
        ht.join();
        std.debug.print("SONNY-3350 raft drop under a {s} lock: done while held={}, graph there while held={}, lock let go before the drop returned={}\n", .{ if (write) "write" else "read", early, exists_under_lock, let_go });
        try testing.expect(apply.err == null);
        try testing.expect(!early);
        try testing.expect(exists_under_lock);
        try testing.expect(let_go);
        try testing.expect(!f.st.graphExists(name));
    }
    // A graph that is not there: idempotent, and nothing is created.
    var apply = Apply{ .st = f.st, .graph = "never_made" };
    apply.go();
    try testing.expect(apply.err == null);
    try testing.expect(!f.st.graphExists("never_made"));
}

/// The graph the IdMap lookup hook drops, on a thread of its own, between
/// a reader's lookup and its read.
var drop_target: []const u8 = "";
var drops_done: usize = 0;

fn dropOnOtherThread(st: *graph_store.GraphStore) void {
    st.dropGraph(drop_target) catch {};
}

fn dropHook(graph_name: []const u8) void {
    if (!std.mem.eql(u8, graph_name, drop_target)) return;
    const st = graph_store.getGlobalStore(testing.allocator);
    if (!st.graphExists(drop_target)) return;
    const t = std.Thread.spawn(.{}, dropOnOtherThread, .{st}) catch return;
    t.join();
    drops_done += 1;
}

test "SONNY-3350: the IdMap readers pin the map: a DROP GRAPH between the lookup and the read frees nothing under them" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    const Reader = enum { scan_node, planned_node, store_node, store_edge };
    for ([_]Reader{ .scan_node, .planned_node, .store_node, .store_edge }) |reader| {
        drop_target = "gx";
        try st.createGraph("gx");
        const a = try st.createNodeWithGraph(&.{"P"}, "gx");
        const b = try st.createNodeWithGraph(&.{"P"}, "gx");
        const e = try st.createEdgeWithGraph(a, b, "R", "gx");
        const im = st.getIdMap("gx") orelse return error.NoIdMap;
        const node_slot = im.nodeSlot(a) orelse return error.NoSlot;
        const edge_slot = im.edgeSlot(e) orelse return error.NoSlot;

        const before = drops_done;
        graph_store.test_idmap_lookup_hook = &dropHook;
        const got: ?u64 = switch (reader) {
            .scan_node => try node_scan_stream.resolveExternalNodeIdForTest(testing.allocator, "gx", node_slot),
            .planned_node => try planned_read_runtime.resolveExternalNodeIdForTest(testing.allocator, "gx", node_slot),
            .store_node => st.idMapNodeId("gx", node_slot),
            .store_edge => st.idMapEdgeId("gx", edge_slot),
        };
        graph_store.test_idmap_lookup_hook = null;
        std.debug.print("SONNY-3350 IdMap {s}: dropped between lookup and read={}, read={?d} (node {d}, edge {d}); retired after={d}\n", .{ @tagName(reader), drops_done > before, got, a, e, st.retired_id_maps.items.len });
        try testing.expect(drops_done > before);
        try testing.expect(!st.graphExists("gx"));
        // The map a reader pinned is freed when it lets go.
        try testing.expectEqual(@as(usize, 0), st.retired_id_maps.items.len);
        try testing.expectEqual(@as(usize, 0), st.retired_id_count.load(.acquire));
    }
    // Without a DROP, each reader reads the id.
    try st.createGraph("gy");
    const a = try st.createNodeWithGraph(&.{"P"}, "gy");
    const b = try st.createNodeWithGraph(&.{"P"}, "gy");
    const e = try st.createEdgeWithGraph(a, b, "R", "gy");
    const im = st.getIdMap("gy") orelse return error.NoIdMap;
    const node_slot = im.nodeSlot(a) orelse return error.NoSlot;
    try testing.expectEqual(a, try node_scan_stream.resolveExternalNodeIdForTest(testing.allocator, "gy", node_slot));
    try testing.expectEqual(a, try planned_read_runtime.resolveExternalNodeIdForTest(testing.allocator, "gy", node_slot));
    try testing.expectEqual(@as(?u64, a), st.idMapNodeId("gy", node_slot));
    try testing.expectEqual(@as(?u64, e), st.idMapEdgeId("gy", im.edgeSlot(e) orelse return error.NoSlot));
}

fn principal(username: []const u8, roles: []const []const u8) principal_mod.Principal {
    return .{
        .user_id = 1,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

test "SONNY-3350: a read of several graphs checks each graph's access before it locks or copies any" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("ga");
    try st.createGraph("hr");
    _ = try st.createNodeWithGraph(&.{"Secret"}, "hr");

    const reader = principal("reader", &.{"ReadOnly"});
    const admin = principal("root", &.{"Admin"});
    var ctx = h.ctx;

    // A writer holds hr. The reader may not bind it: refused at once,
    // without waiting for the writer.
    {
        var holder = fx.Holder{ .graph = "hr", .hold_ms = 600, .write = true };
        const ht = try holder.start();
        ctx.principal = &reader;
        const r = graph_store.snapshotUnderReadLocks(testing.allocator, &.{ "default", "hr" }, &ctx);
        const let_go = holder.letting_go.load(.acquire);
        ht.join();
        if (r) |session| {
            var s = session;
            s.deinit();
        } else |_| {}
        std.debug.print("SONNY-3350 snapshot as reader: {s}, returned after the writer let go={}\n", .{ if (r) |_| "copied" else |err| @errorName(err), let_go });
        try testing.expectError(error.Unauthorized, r);
        try testing.expect(!let_go);
    }
    // A DSN-bound session reads only its own graph.
    {
        ctx.principal = &admin;
        ctx.graph_bound = true;
        defer ctx.graph_bound = false;
        try testing.expectError(error.GraphBound, graph_store.snapshotUnderReadLocks(testing.allocator, &.{ "default", "hr" }, &ctx));
    }
    // An Admin reads both.
    {
        ctx.principal = &admin;
        var s = try graph_store.snapshotUnderReadLocks(testing.allocator, &.{ "default", "hr" }, &ctx);
        s.deinit();
    }
}
