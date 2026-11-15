// SONNY-2733 regression: `geode.tenant.backfill_edge_tags` takes each graph's
// write lock in turn, and never holds two.
//
// Before, the procedure ran under the statement lock the transport handler
// took on the SESSION graph, and re-tagged edges in every graph: readers and
// writers of every other graph ran alongside those re-tags. Now it lists the
// graphs, and for each one takes that graph's write lock, scans and re-tags
// that graph's edges, and releases the lock before it takes the next. The QUIC
// and gRPC handlers run a lone CALL of it holding no graph lock
// (`query_traits.isSelfLockingProgram`). In any other request the handler's
// lock is held, and the procedure refuses to run (`GraphLockHeld`) instead of
// deadlocking on that graph or holding two locks.
//
// CANARY: REQ=REQ-SONNY-2733-BACKFILL-LOCKING; FEATURE="PerTenantIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2733_backfill_locking.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const GraphStore = graph_store.GraphStore;
const Action = GraphStore.EdgeTagBackfillAction;

const tenant_a = "tenant_a";
const default_tenant = graph_store.DEFAULT_TENANT_ID;
const labels = [_][]const u8{"N"};

/// A legacy edge in `graph`: tagged `default` between two new tenant_a nodes,
/// with property `w`.
fn legacyEdge(st: *GraphStore, graph: []const u8, w: i64) !u64 {
    const from = try st.createNodeWithGraphAndTenant(&labels, graph, tenant_a);
    const to = try st.createNodeWithGraphAndTenant(&labels, graph, tenant_a);
    const edge = try st.createEdgeWithGraphAndTenant(from, to, "L", graph, default_tenant);
    try st.setEdgeProperty(edge, "w", .{ .Int = w });
    return edge;
}

fn tagOf(st: *GraphStore, edge_id: u64) ![]const u8 {
    const edge = (try st.getEdgeHydratedChecked(edge_id)) orelse return error.EdgeNotFound;
    return edge.tenant_id;
}

fn indexOf(entries: []const GraphStore.EdgeTagBackfillEntry, edge_id: u64) ?usize {
    for (entries, 0..) |entry, i| {
        const id = entry.edge_id orelse continue;
        if (id == edge_id) return i;
    }
    return null;
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// One backfill run on its own thread.
const Run = struct {
    store: *GraphStore,
    result: anyerror![]GraphStore.EdgeTagBackfillEntry = error.NotRun,
    done: std.atomic.Value(bool) = .init(false),

    fn go(self: *Run) void {
        self.result = self.store.backfillEdgeTenantTags(testing.allocator, false);
        self.done.store(true, .release);
    }
};

/// Wait until the backfill has re-tagged `edge_id` of `graph`, reading the edge
/// under that graph's write lock, taken with a deadline. True once it has;
/// false if that does not happen in time. A backfill that kept `graph` locked
/// while it waited for another graph would never let this lock through.
fn awaitRetag(st: *GraphStore, graph: []const u8, edge_id: u64) bool {
    const give_up = graph_store.monoNanosNowPub() + 30 * std.time.ns_per_s;
    while (graph_store.monoNanosNowPub() < give_up) {
        const deadline = graph_store.monoNanosNowPub() + 100 * std.time.ns_per_ms;
        const lock = graph_store.acquireGraphWriteLockCancelable(graph, deadline) catch continue;
        const retagged = if ((st.getEdgeHydratedChecked(edge_id) catch @panic("SONNY-6621: unexpected read failure"))) |edge| std.mem.eql(u8, edge.tenant_id, tenant_a) else false;
        graph_store.releaseGraphLock(lock);
        if (retagged) return true;
        sleepMs(2);
    }
    return false;
}

test "SONNY-2733: the backfill takes each graph's lock in turn and holds none while it waits for the next" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("g1");
    try st.createGraph("g2");
    const e1 = try legacyEdge(st, "g1", 1);
    const e2 = try legacyEdge(st, "g2", 2);

    // Hold g2 while the backfill runs. It goes through the graphs in name
    // order, so it re-tags g1 and then waits for g2.
    const g2_lock = graph_store.acquireGraphReadLock("g2");
    var run: Run = .{ .store = st };
    const thread = std.Thread.spawn(.{}, Run.go, .{&run}) catch |err| {
        graph_store.releaseGraphLock(g2_lock);
        return err;
    };
    // g1 comes free, re-tagged, while the backfill cannot have finished (it
    // still needs g2): it released g1 before it waited for g2.
    const g1_free_and_retagged = awaitRetag(st, "g1", e1);
    const finished_before_g2 = run.done.load(.acquire);
    const e2_untouched = if ((try st.getEdgeHydratedChecked(e2))) |edge| std.mem.eql(u8, edge.tenant_id, default_tenant) else false;
    graph_store.releaseGraphLock(g2_lock);
    thread.join();

    const entries = try run.result;
    defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, entries);
    try testing.expect(g1_free_and_retagged);
    try testing.expect(!finished_before_g2);
    try testing.expect(e2_untouched);

    // Once g2 was free it re-tagged g2's edge too, after g1's.
    const at_1 = indexOf(entries, e1) orelse return error.EdgeNotReported;
    const at_2 = indexOf(entries, e2) orelse return error.EdgeNotReported;
    try testing.expect(at_1 < at_2);
    try testing.expectEqual(Action.retagged, entries[at_1].action);
    try testing.expectEqual(Action.retagged, entries[at_2].action);
    try testing.expectEqualStrings("g1", entries[at_1].graph_name);
    try testing.expectEqualStrings("g2", entries[at_2].graph_name);
    try testing.expectEqualStrings(tenant_a, try tagOf(st, e2));
}

/// Reads a list of edges per graph, each graph under its read lock, until told
/// to stop. Counts a read as bad when the edge is missing, carries a tag other
/// than the two the backfill moves between, or has lost its property.
const Reader = struct {
    store: *GraphStore,
    graphs: []const []const u8,
    edges: []const []const u64,
    stop: *std.atomic.Value(bool),
    rounds: std.atomic.Value(usize) = .init(0),
    bad: std.atomic.Value(usize) = .init(0),

    fn go(self: *Reader) void {
        while (!self.stop.load(.acquire)) {
            for (self.graphs, self.edges) |graph, ids| {
                const lock = graph_store.acquireGraphReadLock(graph);
                for (ids) |id| {
                    const edge = (self.store.getEdgeHydratedChecked(id) catch @panic("SONNY-6621: unexpected read failure")) orelse {
                        _ = self.bad.fetchAdd(1, .monotonic);
                        continue;
                    };
                    const tag_ok = std.mem.eql(u8, edge.tenant_id, default_tenant) or std.mem.eql(u8, edge.tenant_id, tenant_a);
                    const w_ok = if (edge.properties.get("w")) |w| w == .Int else false;
                    if (!tag_ok or !w_ok) _ = self.bad.fetchAdd(1, .monotonic);
                }
                graph_store.releaseGraphLock(lock);
                sleepMs(1);
            }
            _ = self.rounds.fetchAdd(1, .release);
        }
    }
};

/// Adds legacy edges to one graph, each under the graph's write lock, until
/// told to stop or it has made all it can hold.
const Writer = struct {
    store: *GraphStore,
    graph: []const u8,
    stop: *std.atomic.Value(bool),
    created: [16]u64 = undefined,
    count: usize = 0,
    err: ?anyerror = null,

    fn go(self: *Writer) void {
        while (!self.stop.load(.acquire) and self.count < self.created.len) {
            const lock = graph_store.acquireGraphWriteLock(self.graph);
            const made = legacyEdge(self.store, self.graph, 100 + @as(i64, @intCast(self.count)));
            graph_store.releaseGraphLock(lock);
            self.created[self.count] = made catch |err| {
                self.err = err;
                return;
            };
            self.count += 1;
            sleepMs(1);
        }
    }
};

test "SONNY-2733: readers and a writer run alongside the backfill, and the next run finishes the job" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);

    const graphs = [_][]const u8{ "g1", "g2", "g3" };
    const per_graph = 24;
    var seeded: [graphs.len][per_graph]u64 = undefined;
    for (graphs, &seeded) |graph, *ids| {
        try st.createGraph(graph);
        for (ids, 0..) |*id, i| id.* = try legacyEdge(st, graph, @intCast(i));
    }
    const edge_lists = [_][]const u64{ &seeded[0], &seeded[1], &seeded[2] };

    var stop: std.atomic.Value(bool) = .init(false);
    var readers = [_]Reader{
        .{ .store = st, .graphs = &graphs, .edges = &edge_lists, .stop = &stop },
        .{ .store = st, .graphs = &graphs, .edges = &edge_lists, .stop = &stop },
    };
    var writer: Writer = .{ .store = st, .graph = "g2", .stop = &stop };
    var threads: [readers.len + 1]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        stop.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
    }
    for (&readers) |*r| {
        threads[spawned] = try std.Thread.spawn(.{}, Reader.go, .{r});
        spawned += 1;
    }
    threads[spawned] = try std.Thread.spawn(.{}, Writer.go, .{&writer});
    spawned += 1;

    const first = try st.backfillEdgeTenantTags(testing.allocator, false);
    defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, first);

    // Let every reader finish a round over the re-tagged graphs, then stop.
    const give_up = graph_store.monoNanosNowPub() + 30 * std.time.ns_per_s;
    const rounds_at_end = [_]usize{ readers[0].rounds.load(.acquire), readers[1].rounds.load(.acquire) };
    for (&readers, rounds_at_end) |*r, at_end| {
        while (r.rounds.load(.acquire) < at_end + 2 and graph_store.monoNanosNowPub() < give_up) sleepMs(1);
    }
    stop.store(true, .release);
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;

    if (writer.err) |err| return err;
    for (&readers) |*r| {
        try testing.expect(r.rounds.load(.acquire) >= 2);
        try testing.expectEqual(@as(usize, 0), r.bad.load(.acquire));
    }
    for (first) |entry| try testing.expectEqual(Action.retagged, entry.action);
    for (edge_lists) |ids| {
        for (ids) |id| try testing.expectEqualStrings(tenant_a, try tagOf(st, id));
    }

    // The writer's edges that the first run did not reach, and only those, are
    // re-tagged by the next run; each legacy edge is re-tagged exactly once.
    const second = try st.backfillEdgeTenantTags(testing.allocator, false);
    defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, second);
    for (second) |entry| {
        try testing.expectEqual(Action.retagged, entry.action);
        const id = entry.edge_id orelse return error.MissingEdgeId;
        try testing.expect(std.mem.indexOfScalar(u64, writer.created[0..writer.count], id) != null);
    }
    try testing.expectEqual(graphs.len * per_graph + writer.count, first.len + second.len);
    for (writer.created[0..writer.count]) |id| try testing.expectEqualStrings(tenant_a, try tagOf(st, id));

    const third = try st.backfillEdgeTenantTags(testing.allocator, false);
    defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, third);
    try testing.expectEqual(@as(usize, 0), third.len);
}

test "SONNY-2733: the backfill refuses to run while its caller holds a graph lock" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    const legacy = try legacyEdge(st, graph_store.DEFAULT_GRAPH_NAME, 1);

    // Taking that lock again would deadlock, and taking another would hold
    // two. It refuses before it lists or locks anything.
    for ([_]bool{ true, false }) |write| {
        const lock = if (write)
            graph_store.acquireGraphWriteLock(graph_store.DEFAULT_GRAPH_NAME)
        else
            graph_store.acquireGraphReadLock(graph_store.DEFAULT_GRAPH_NAME);
        const refused = st.backfillEdgeTenantTags(testing.allocator, false);
        graph_store.releaseGraphLock(lock);
        try testing.expectError(error.GraphLockHeld, refused);
    }
    try testing.expectEqualStrings(default_tenant, try tagOf(st, legacy));
}

/// Holds one graph's read lock on its own thread until told to let go.
const Holder = struct {
    graph: []const u8,
    held: std.atomic.Value(bool) = .init(false),
    let_go: std.atomic.Value(bool) = .init(false),

    fn go(self: *Holder) void {
        const lock = graph_store.acquireGraphReadLock(self.graph);
        self.held.store(true, .release);
        while (!self.let_go.load(.acquire)) sleepMs(1);
        graph_store.releaseGraphLock(lock);
    }
};

test "SONNY-2733: a graph the backfill cannot lock in time is one failed row, and it goes on to the next graph" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("g1");
    try st.createGraph("g2");
    const e1 = try legacyEdge(st, "g1", 1);
    const e2 = try legacyEdge(st, "g2", 2);

    const budget_was = graph_store.backfill_graph_lock_timeout_ns;
    graph_store.backfill_graph_lock_timeout_ns = 200 * std.time.ns_per_ms;
    defer graph_store.backfill_graph_lock_timeout_ns = budget_was;

    // Another thread keeps g1 read-locked for the whole run.
    var holder: Holder = .{ .graph = "g1" };
    const thread = try std.Thread.spawn(.{}, Holder.go, .{&holder});
    const give_up = graph_store.monoNanosNowPub() + 30 * std.time.ns_per_s;
    while (!holder.held.load(.acquire) and graph_store.monoNanosNowPub() < give_up) sleepMs(1);
    const run = st.backfillEdgeTenantTags(testing.allocator, false);
    holder.let_go.store(true, .release);
    thread.join();

    const entries = try run;
    defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, entries);
    try testing.expect(holder.held.load(.acquire));
    // g1: one row for the graph, unscanned. g2: its edge re-tagged.
    var g1_rows: usize = 0;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.graph_name, "g1")) continue;
        g1_rows += 1;
        try testing.expectEqual(Action.failed, entry.action);
        try testing.expect(entry.edge_id == null);
        try testing.expect(entry.edge_type == null);
        try testing.expectEqualStrings("GraphLockTimeout", entry.reason orelse return error.MissingReason);
    }
    try testing.expectEqual(@as(usize, 1), g1_rows);
    const at_2 = indexOf(entries, e2) orelse return error.EdgeNotReported;
    try testing.expectEqual(Action.retagged, entries[at_2].action);
    try testing.expectEqualStrings(default_tenant, try tagOf(st, e1));

    // With g1 free, the next run re-tags it.
    const again = try st.backfillEdgeTenantTags(testing.allocator, false);
    defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, again);
    const at_1 = indexOf(again, e1) orelse return error.EdgeNotReported;
    try testing.expectEqual(Action.retagged, again[at_1].action);
    try testing.expectEqual(@as(usize, 1), again.len);
    try testing.expectEqualStrings(tenant_a, try tagOf(st, e1));
}

test "SONNY-2733: only a lone CALL of the backfill runs without the handler's statement lock" {
    const Case = struct { query: []const u8, self_locking: bool };
    const cases = [_]Case{
        .{ .query = "CALL geode.tenant.backfill_edge_tags()", .self_locking = true },
        .{ .query = "CALL geode.tenant.backfill_edge_tags(true) YIELD edge_id, action", .self_locking = true },
        .{ .query = "CALL GEODE.Tenant.Backfill_Edge_Tags()", .self_locking = true },
        .{ .query = "CALL geode.tenant.backfill_edge_tags() YIELD edge_id LIMIT 5 OFFSET 1", .self_locking = true },
        // The executor evaluates a RETURN's ORDER BY after the procedure,
        // against the store: that needs the handler's lock (review P20).
        .{ .query = "CALL geode.tenant.backfill_edge_tags() YIELD edge_id RETURN edge_id", .self_locking = false },
        .{ .query = "CALL geode.tenant.backfill_edge_tags() YIELD edge_id RETURN edge_id ORDER BY COUNT { MATCH (m) }", .self_locking = false },
        .{ .query = "CALL geode.tenant.backfill_edge_tags() YIELD edge_id RETURN edge_id ORDER BY EXISTS { MATCH (m) }", .self_locking = false },
        // Anything beside it would run unlocked too: the handler locks, and
        // the procedure refuses.
        .{ .query = "USE GRAPH g; CALL geode.tenant.backfill_edge_tags()", .self_locking = false },
        .{ .query = "CALL geode.tenant.backfill_edge_tags(); CALL geode.tenant.list()", .self_locking = false },
        .{ .query = "CALL geode.tenant.list()", .self_locking = false },
        .{ .query = "CREATE (n:N)", .self_locking = false },
        .{ .query = "MATCH (n) RETURN n", .self_locking = false },
    };
    for (cases) |case| {
        var parsed = try geode.parseGql(case.query, testing.allocator);
        defer parsed.deinit();
        if (query_traits.isSelfLockingProgram(&parsed.program) != case.self_locking) {
            std.debug.print("{s}: expected self_locking = {}\n", .{ case.query, case.self_locking });
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-2733: the backfill refuses a RETURN or ORDER BY, which the executor evaluates against the store after it" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    const legacy = try legacyEdge(st, graph_store.DEFAULT_GRAPH_NAME, 1);
    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);

    // In process no statement lock is held either: the ORDER BY's COUNT {}
    // would walk the store unlocked. The procedure refuses before it changes
    // anything.
    const refused = [_][]const u8{
        "CALL geode.tenant.backfill_edge_tags() YIELD edge_id RETURN edge_id",
        "CALL geode.tenant.backfill_edge_tags() YIELD edge_id RETURN edge_id ORDER BY COUNT { MATCH (m) }",
        "CALL geode.tenant.backfill_edge_tags(true) YIELD edge_id RETURN edge_id ORDER BY EXISTS { MATCH (m) }",
    };
    for (refused) |query| try testing.expectError(error.BackfillProjection, h.run(query));
    try testing.expectEqualStrings(default_tenant, try tagOf(st, legacy));

    // YIELD, LIMIT and OFFSET only pick and count rows: it runs.
    _ = try h.run("CALL geode.tenant.backfill_edge_tags() YIELD edge_id, action LIMIT 5");
    try testing.expectEqualStrings(tenant_a, try tagOf(st, legacy));
}

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

/// `query` through the real gRPC Execute handler, in process.
fn grpcExecute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{
        .session_id = session_id,
        .query = query,
        .params = .empty,
    });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

test "SONNY-2733: over gRPC a lone CALL runs, holding no statement lock; beside another statement it is refused" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    const legacy = try legacyEdge(st, graph_store.DEFAULT_GRAPH_NAME, 1);

    // An anonymous session, allowed everything: the handler's own lock is
    // what is under test, not authorization.
    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);
    const allow_all_was = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(true);
    defer gps.setInsecureAllowAll(allow_all_was);

    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const session_id = try sessions.createSession("", "", null, null, null, false, 0);

    // Beside another statement (the CLI's `-g` prepends USE GRAPH), the
    // handler holds the session graph's write lock, and the procedure
    // refuses to take a second lock.
    {
        const resp = try grpcExecute(ga, session_id, "USE GRAPH default; CALL geode.tenant.backfill_edge_tags()");
        const err = switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| e,
            else => return error.ExpectedRefusal,
        };
        try testing.expectEqualStrings("0A000", err.code);
        try testing.expect(std.mem.indexOf(u8, err.message, "only statement") != null);
        try testing.expectEqualStrings(default_tenant, try tagOf(st, legacy));
    }

    // With a RETURN and an ORDER BY that reads the store, the handler takes
    // its lock (it is not a lone self-locking CALL), and the procedure
    // refuses before it changes anything.
    {
        const resp = try grpcExecute(ga, session_id, "CALL geode.tenant.backfill_edge_tags() YIELD edge_id RETURN edge_id ORDER BY COUNT { MATCH (m) }");
        const err = switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| e,
            else => return error.ExpectedRefusal,
        };
        try testing.expectEqualStrings("0A000", err.code);
        try testing.expect(std.mem.indexOf(u8, err.message, "RETURN or ORDER BY") != null);
        try testing.expectEqualStrings(default_tenant, try tagOf(st, legacy));
    }

    // Alone, it runs: the handler takes no lock, and the procedure takes each
    // graph's in turn.
    {
        const resp = try grpcExecute(ga, session_id, "CALL geode.tenant.backfill_edge_tags()");
        const def = switch (resp.payload orelse return error.MissingPayload) {
            .schema => |d| d,
            .@"error" => |e| {
                std.debug.print("Execute failed: {s}\n", .{e.message});
                return error.ServerError;
            },
            else => return error.UnexpectedPayload,
        };
        const want = [_][]const u8{ "edge_id", "graph", "edge_type", "edge_tenant", "from_tenant", "to_tenant", "action", "reason" };
        try testing.expectEqual(want.len, def.columns.items.len);
        for (want, def.columns.items) |name, column| try testing.expectEqualStrings(name, column.name);
        try testing.expectEqualStrings(tenant_a, try tagOf(st, legacy));
    }
}
