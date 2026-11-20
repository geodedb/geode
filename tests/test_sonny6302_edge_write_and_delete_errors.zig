// SONNY-6302 regression: no graph-store write reports success when the
// storage engine did not store it, and the callers of the delete primitives
// pass a failed delete on.
//
//   (1) `setEdgeProperty` logged a failed engine write (or a failed slot
//       lookup) at debug level and went on to write the property in memory:
//       the client saw success, memory held a property the engine never
//       stored, and a restart lost it. Now the error is returned and memory
//       is left as it was, as `setNodeProperty` does since SONNY-6268.
//       `removeEdgeProperty` removed the property in memory with an
//       allocation that could fail after the engine had removed it (memory
//       kept what the engine dropped); the removal is now prepared before the
//       engine write.
//   (2) Tenant drop (`CALL geode.tenant.drop(t, true)`) deleted the tenant's
//       rows with the void deletes, which only log a failure, and then removed
//       the tenant and reported success with rows left behind. A failed
//       delete now fails the drop before the tenant is removed; a retry
//       finishes it. The replicated-delete apply (`applyDeletePayload`)
//       reports a failed delete to the raft apply loop instead of counting
//       nothing and returning success.
//   (3) The delete primitives' in-memory removal built index and counter keys
//       for names past 512 bytes on the heap after the engine delete, so an
//       allocation failure there left a deleted node in its label posting (or
//       an edge in its type posting, or a counter high). That room is now
//       reserved before the engine delete.
//
// Engine failures are injected with `graph_store.setAdapterWriteFaultForTesting`
// (the store's call into the real storage adapter returns an error instead of
// writing); allocation failures with a sticky `std.testing.FailingAllocator`
// as the store's allocator, as in tests/test_sonny6268_graph_store_failure_atomicity.zig.
// After each failure: the error is reported, memory reads back as the engine
// does (a fresh store over the same engine, and a reopened engine), and the
// retry succeeds.
//
// CANARY: REQ=REQ-SONNY-6302-WRITE-ERRORS; FEATURE="GraphStoreFailureAtomicity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6302_edge_write_and_delete_errors.zig; OWNER=storage; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const eval = geode.eval;
const execution = geode.execution;
const tenant_registry = geode.tenant_registry;
const user_mgmt = geode.user_management;
const cluster_replication = geode.distributed.cluster_replication;

const T = "default";
const MAX_K: usize = 400;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// A storage engine in a temporary data directory (the global adapter).
const Engine = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,

    fn open() !Engine {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
        errdefer testing.allocator.free(dir);
        _ = setenv("GEODE_WAL_SYNC", "deferred", 1);
        defer _ = unsetenv("GEODE_WAL_SYNC");
        _ = try graph_store.initGlobalAdapter(testing.allocator, dir);
        return .{ .tmp = tmp, .dir = dir };
    }

    /// Close the engine (checkpoint) and open it again from disk.
    fn reopen(self: *Engine) !void {
        graph_store.deinitGlobalAdapter();
        _ = setenv("GEODE_WAL_SYNC", "deferred", 1);
        defer _ = unsetenv("GEODE_WAL_SYNC");
        _ = try graph_store.initGlobalAdapter(testing.allocator, self.dir);
    }

    fn close(self: *Engine) void {
        graph_store.setAdapterWriteFaultForTesting(.none, 0);
        graph_store.deinitGlobalAdapter();
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
};

fn writeValue(out: *std.ArrayList(u8), v: PropertyValue) !void {
    switch (v) {
        .String => |s| try out.print(testing.allocator, "'{s}'", .{s}),
        .Int => |i| try out.print(testing.allocator, "{d}", .{i}),
        .Bool => |b| try out.print(testing.allocator, "{}", .{b}),
        .Null => try out.appendSlice(testing.allocator, "null"),
        else => try out.appendSlice(testing.allocator, "<other>"),
    }
}

/// An edge's properties as text, sorted by key; "absent" when there is none.
fn renderEdge(store: *GraphStore, graph: []const u8, edge_id: u64) ![]u8 {
    store.ensureGraphHydrated(graph);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    const edge = (try store.getEdgeHydratedChecked(edge_id)) orelse {
        try out.appendSlice(testing.allocator, "absent");
        return out.toOwnedSlice(testing.allocator);
    };
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(testing.allocator);
    var it = edge.properties.iterator();
    while (it.next()) |p| try keys.append(testing.allocator, p.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    try out.print(testing.allocator, "{s}:", .{edge.label});
    for (keys.items) |k| {
        try out.print(testing.allocator, "{s}=", .{k});
        try writeValue(&out, edge.properties.get(k).?);
        try out.appendSlice(testing.allocator, ",");
    }
    return out.toOwnedSlice(testing.allocator);
}

/// Memory against the engine: the edge as `store` has it, then as a fresh
/// store loaded from the same engine reads it back (`store` is replaced by
/// that fresh store, on `allocator`).
fn expectEdge(store: *GraphStore, allocator: std.mem.Allocator, graph: []const u8, edge_id: u64, expected: []const u8) !void {
    const mem = try renderEdge(store, graph, edge_id);
    defer testing.allocator.free(mem);
    store.deinit();
    store.* = try GraphStore.init(allocator);
    try store.loadFromFile();
    const eng = try renderEdge(store, graph, edge_id);
    defer testing.allocator.free(eng);
    if (!std.mem.eql(u8, mem, expected) or !std.mem.eql(u8, eng, expected)) {
        std.debug.print("edge: expected {s}\n  memory: {s}\n  engine: {s}\n", .{ expected, mem, eng });
        return error.EdgeStateMismatch;
    }
}

const Seed = struct { a: u64, b: u64, e: u64 };

fn seedEdge(store: *GraphStore, graph: []const u8) !Seed {
    try store.createGraph(graph);
    const a = try store.createNodeWithGraphAndTenant(&.{"A"}, graph, T);
    const b = try store.createNodeWithGraphAndTenant(&.{"A"}, graph, T);
    const e = try store.createEdgeWithGraphAndTenant(a, b, "R", graph, T);
    try store.setEdgeProperty(e, "w", .{ .Int = 7 });
    try store.setEdgeProperty(e, "name", .{ .String = "x" });
    return .{ .a = a, .b = b, .e = e };
}

test "SONNY-6302: setEdgeProperty reports a failed engine write and keeps memory equal to the engine" {
    var engine = try Engine.open();
    defer engine.close();
    const G = "g6302_set";

    var store = try GraphStore.init(testing.allocator);
    var store_live = true;
    defer if (store_live) store.deinit();
    const s = try seedEdge(&store, G);
    try expectEdge(&store, testing.allocator, G, s.e, "R:name='x',w=7,");

    // A new key and an existing key, each with the engine write failing.
    graph_store.setAdapterWriteFaultForTesting(.set_edge_property, 0);
    const new_key = store.setEdgeProperty(s.e, "fresh", .{ .String = "edge value" });
    const existing_key = store.setEdgeProperty(s.e, "w", .{ .Int = 8 });
    graph_store.setAdapterWriteFaultForTesting(.none, 0);
    if (new_key) |_| {
        std.debug.print("setEdgeProperty(new key) reported success with the engine write failing\n", .{});
        return error.FailureNotReported;
    } else |_| {}
    if (existing_key) |_| {
        std.debug.print("setEdgeProperty(existing key) reported success with the engine write failing\n", .{});
        return error.FailureNotReported;
    } else |_| {}
    try expectEdge(&store, testing.allocator, G, s.e, "R:name='x',w=7,");

    // The retry succeeds and is stored.
    try store.setEdgeProperty(s.e, "fresh", .{ .String = "edge value" });
    try store.setEdgeProperty(s.e, "w", .{ .Int = 8 });
    try expectEdge(&store, testing.allocator, G, s.e, "R:fresh='edge value',name='x',w=8,");

    // And survives the engine's restart.
    store.deinit();
    store_live = false;
    try engine.reopen();
    var reopened = try GraphStore.init(testing.allocator);
    defer reopened.deinit();
    try reopened.loadFromFile();
    const got = try renderEdge(&reopened, G, s.e);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("R:fresh='edge value',name='x',w=8,", got);
}

test "SONNY-6302: removeEdgeProperty with the engine write failing changes nothing" {
    var engine = try Engine.open();
    defer engine.close();
    const G = "g6302_rm";

    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();
    const s = try seedEdge(&store, G);

    _ = eval.takeDeferredLimitError(true);
    graph_store.setAdapterWriteFaultForTesting(.remove_edge_property, 0);
    store.removeEdgeProperty(s.e, "name");
    graph_store.setAdapterWriteFaultForTesting(.none, 0);
    _ = eval.takeDeferredLimitError(true);
    try expectEdge(&store, testing.allocator, G, s.e, "R:name='x',w=7,");

    store.removeEdgeProperty(s.e, "name");
    try expectEdge(&store, testing.allocator, G, s.e, "R:w=7,");
}

test "SONNY-6302: removeEdgeProperty under allocation failure keeps memory equal to the engine" {
    var engine = try Engine.open();
    defer engine.close();
    var name_buf: [32]u8 = undefined;
    var k: usize = 0;
    while (k < MAX_K) : (k += 1) {
        const G = try std.fmt.bufPrint(&name_buf, "g6302_rma_{d}", .{k});
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var store = try GraphStore.init(fa.allocator());
        defer store.deinit();
        const s = try seedEdge(&store, G);
        _ = eval.takeDeferredLimitError(true);

        fa.fail_index = fa.alloc_index + k;
        store.removeEdgeProperty(s.e, "name");
        const induced = fa.has_induced_failure;
        fa.fail_index = std.math.maxInt(usize);
        const recorded = eval.takeDeferredLimitError(true);

        const mem = try renderEdge(&store, G, s.e);
        defer testing.allocator.free(mem);
        store.deinit();
        store = try GraphStore.init(testing.allocator);
        try store.loadFromFile();
        const eng = try renderEdge(&store, G, s.e);
        defer testing.allocator.free(eng);
        if (!std.mem.eql(u8, mem, eng)) {
            std.debug.print("k={d}: after removeEdgeProperty memory has {s}, the engine {s}\n", .{ k, mem, eng });
            return error.MemoryDiffersFromEngine;
        }
        if (induced and std.mem.eql(u8, mem, "R:name='x',w=7,") and recorded == null) {
            std.debug.print("k={d}: removeEdgeProperty did nothing and recorded no failure\n", .{k});
            return error.SilentFailure;
        }
        if (!induced) {
            try testing.expectEqualStrings("R:w=7,", mem);
            return;
        }
        // The retry succeeds.
        store.removeEdgeProperty(s.e, "name");
        try testing.expect(eval.takeDeferredLimitError(true) == null);
        try expectEdge(&store, testing.allocator, G, s.e, "R:w=7,");
    }
    return error.SweepDidNotConverge;
}

// ---------------------------------------------------------------------------
// (3) Long names: the delete primitives' removal cannot fail part way.
// ---------------------------------------------------------------------------

const long_label = "L" ** 600;
const long_type = "T" ** 600;

fn renderLong(store: *GraphStore, graph: []const u8) ![]u8 {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const by_label = if (store.getNodesByLabel(graph, long_label)) |ids| ids.len else 0;
    const by_type = if (store.getEdgeIdsByType(graph, long_type)) |ids| ids.len else 0;
    const label_count = store.countNodesByLabel(graph, long_label, null);
    const type_count = store.countEdgesByTypeForGraph(graph, long_type);
    const labels = try store.listNodeLabels(a, null);
    defer {
        for (labels) |l| a.free(l);
        a.free(labels);
    }
    const types = try store.listEdgeTypes(a, null);
    defer {
        for (types) |t| a.free(t);
        a.free(types);
    }
    const props = try store.listPropertiesForLabel(a, null, long_label);
    defer {
        for (props) |p| a.free(p);
        a.free(props);
    }
    try out.print(a, "resident={d} edges={d} by_label={d} by_type={d} label_count={d} type_count={d} labels={d} types={d} props={d}", .{
        store.nodes.count(), store.edges.count(), by_label, by_type, label_count, type_count, labels.len, types.len, props.len,
    });
    return out.toOwnedSlice(a);
}

fn seedLong(store: *GraphStore, graph: []const u8) !Seed {
    try store.createGraph(graph);
    const a = try store.createNodeWithGraphAndTenant(&.{long_label}, graph, T);
    try store.setNodeProperty(a, "p" ** 300, .{ .Int = 1 });
    const b = try store.createNodeWithGraphAndTenant(&.{long_label}, graph, T);
    const e = try store.createEdgeWithGraphAndTenant(a, b, long_type, graph, T);
    return .{ .a = a, .b = b, .e = e };
}

const LongOp = enum { delete_node, delete_edge };

fn sweepLong(op: LongOp) !void {
    var k: usize = 0;
    while (k < MAX_K) : (k += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var store = try GraphStore.init(fa.allocator());
        defer store.deinit();
        const s = try seedLong(&store, "g6302_long");
        const before = try renderLong(&store, "g6302_long");
        defer testing.allocator.free(before);

        fa.fail_index = fa.alloc_index + k;
        const result = switch (op) {
            .delete_node => store.deleteNodeChecked(s.a),
            .delete_edge => store.deleteEdgeChecked(s.e),
        };
        const induced = fa.has_induced_failure;
        fa.fail_index = std.math.maxInt(usize);

        const after = try renderLong(&store, "g6302_long");
        defer testing.allocator.free(after);
        if (result) |_| {
            // Done: then done in full, as a clean run.
            var clean_fa_store = try GraphStore.init(testing.allocator);
            defer clean_fa_store.deinit();
            const cs = try seedLong(&clean_fa_store, "g6302_long");
            switch (op) {
                .delete_node => try clean_fa_store.deleteNodeChecked(cs.a),
                .delete_edge => try clean_fa_store.deleteEdgeChecked(cs.e),
            }
            const clean = try renderLong(&clean_fa_store, "g6302_long");
            defer testing.allocator.free(clean);
            if (!std.mem.eql(u8, clean, after)) {
                std.debug.print("[{s}] k={d}: reported success but left\n  {s}\n  a clean run leaves\n  {s}\n", .{ @tagName(op), k, after, clean });
                return error.HalfDone;
            }
            if (!induced) return;
        } else |_| {
            if (!std.mem.eql(u8, before, after)) {
                std.debug.print("[{s}] k={d}: the failed delete changed the store\n  before {s}\n  after  {s}\n", .{ @tagName(op), k, before, after });
                return error.StoreChangedByFailedDelete;
            }
        }
    }
    return error.SweepDidNotConverge;
}

test "SONNY-6302: deleting a node with names past 512 bytes cannot fail after the delete started" {
    try sweepLong(.delete_node);
}

test "SONNY-6302: deleting an edge with a type past 512 bytes cannot fail after the delete started" {
    try sweepLong(.delete_edge);
}

// ---------------------------------------------------------------------------
// (2) Callers of the delete primitives.
// ---------------------------------------------------------------------------

const CatalogPtr = @typeInfo(@typeInfo(@TypeOf(execution.ensureCatalogInstance)).@"fn".return_type.?).error_union.payload;

fn countTenantRows(store: *GraphStore, tid: []const u8) ![2]usize {
    const n = try store.getAllNodesForTenant(testing.allocator, tid);
    defer testing.allocator.free(n);
    const e = try store.getAllEdgesForTenant(testing.allocator, tid);
    defer testing.allocator.free(e);
    return .{ n.len, e.len };
}

/// The global store over a data directory, restartable (catalog, store and
/// engine torn down and opened again from disk).
const Server = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    reg: *tenant_registry.TenantRegistry,
    catalog: CatalogPtr,
    store: *GraphStore,

    fn open() !Server {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
        errdefer testing.allocator.free(dir);
        graph_store.setDataDirOverride(testing.allocator, dir);
        const store = graph_store.getGlobalStore(testing.allocator);
        if (graph_store.getGlobalAdapter() == null) return error.NoStorageAdapter;
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const reg = try testing.allocator.create(tenant_registry.TenantRegistry);
        reg.* = tenant_registry.TenantRegistry.init(testing.allocator);
        tenant_registry.setGlobalRegistry(reg);
        return .{ .tmp = tmp, .dir = dir, .reg = reg, .catalog = catalog, .store = store };
    }

    fn restart(self: *Server) !void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        self.store = graph_store.getGlobalStore(testing.allocator);
        if (graph_store.getGlobalAdapter() == null) return error.NoStorageAdapter;
        self.catalog = try execution.ensureCatalogInstance(testing.allocator);
    }

    fn close(self: *Server) void {
        graph_store.setAdapterWriteFaultForTesting(.none, 0);
        tenant_registry.setGlobalRegistry(null);
        self.reg.deinit();
        testing.allocator.destroy(self.reg);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn run(self: *Server, query: []const u8) !void {
        var parsed = try geode.parseGql(query, testing.allocator);
        defer parsed.deinit();
        var ctx = execution.ExecutionContext{ .catalog = self.catalog };
        ctx.role = null;
        ctx.user = null;
        var res = try execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], ctx);
        res.deinit(testing.allocator);
    }
};

test "SONNY-6302: a tenant drop whose delete fails part way fails, leaves a consistent state, and a retry completes it" {
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    var srv = try Server.open();
    defer srv.close();

    try srv.store.createGraph("g6302_t");
    try srv.run("CALL geode.tenant.create('acme6302')");
    {
        const labels = [_][]const u8{"Widget"};
        var prev: ?u64 = null;
        for (0..4) |_| {
            const nid = try srv.store.createNodeWithGraphAndTenant(&labels, "g6302_t", "acme6302");
            if (prev) |p| _ = try srv.store.createEdgeWithGraphAndTenant(p, nid, "LINKS", "g6302_t", "acme6302");
            prev = nid;
        }
    }
    try testing.expectEqual([2]usize{ 4, 3 }, try countTenantRows(srv.store, "acme6302"));

    // The engine refuses the second node delete.
    graph_store.setAdapterWriteFaultForTesting(.delete_node, 1);
    const dropped = srv.run("CALL geode.tenant.drop('acme6302', true)");
    graph_store.setAdapterWriteFaultForTesting(.none, 0);
    if (dropped) |_| {
        const left = try countTenantRows(srv.store, "acme6302");
        std.debug.print("tenant drop reported success with {d} node(s) and {d} edge(s) of the tenant left\n", .{ left[0], left[1] });
        return error.DropReportedSuccessWithRowsLeft;
    } else |_| {}
    // Not dropped: the tenant is still registered, and memory matches the
    // engine after a restart.
    try testing.expect(srv.reg.contains("acme6302"));
    const mem_rows = try countTenantRows(srv.store, "acme6302");
    try testing.expect(mem_rows[0] > 0);
    try srv.restart();
    try testing.expectEqual(mem_rows, try countTenantRows(srv.store, "acme6302"));

    // The retry finishes the drop, durably.
    try srv.run("CALL geode.tenant.drop('acme6302', true)");
    try testing.expect(!srv.reg.contains("acme6302"));
    try testing.expectEqual([2]usize{ 0, 0 }, try countTenantRows(srv.store, "acme6302"));
    try srv.restart();
    try testing.expectEqual([2]usize{ 0, 0 }, try countTenantRows(srv.store, "acme6302"));
}

test "SONNY-6302: a replicated delete whose engine delete fails reports it and applies the rest" {
    var engine = try Engine.open();
    defer engine.close();
    const G = "g6302_repl";
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();
    try store.createGraph(G);
    const a = try store.createNodeWithGraphAndTenant(&.{"A"}, G, T);
    const b = try store.createNodeWithGraphAndTenant(&.{"A"}, G, T);
    const c = try store.createNodeWithGraphAndTenant(&.{"A"}, G, T);
    const e1 = try store.createEdgeWithGraphAndTenant(a, b, "R", G, T);
    const e2 = try store.createEdgeWithGraphAndTenant(b, c, "R", G, T);

    const payload = try cluster_replication.serializeDelete(testing.allocator, G, &.{ e1, e2 }, &.{});
    defer testing.allocator.free(payload);

    // The engine refuses the first edge delete.
    graph_store.setAdapterWriteFaultForTesting(.delete_edge, 0);
    const first = cluster_replication.applyDeletePayload(testing.allocator, &store, payload);
    graph_store.setAdapterWriteFaultForTesting(.none, 0);
    if (first) |n| {
        std.debug.print("applyDeletePayload reported success ({d} removed) with the engine delete failing\n", .{n});
        return error.FailureNotReported;
    } else |_| {}
    // Neither edge was deleted (each delete failed).
    try testing.expect((try store.getEdgeHydratedChecked(e1)) != null);
    try testing.expect((try store.getEdgeHydratedChecked(e2)) != null);

    // Only the first delete fails: the second edge is still deleted.
    graph_store.setAdapterWriteFaultForTesting(.delete_edge, 1);
    const second = cluster_replication.applyDeletePayload(testing.allocator, &store, payload);
    graph_store.setAdapterWriteFaultForTesting(.none, 0);
    if (second) |n| {
        std.debug.print("applyDeletePayload reported success ({d} removed) with an engine delete failing\n", .{n});
        return error.FailureNotReported;
    } else |_| {}
    try testing.expect((try store.getEdgeHydratedChecked(e1)) == null);
    try testing.expect((try store.getEdgeHydratedChecked(e2)) != null);

    // The re-apply (a retry, or the replay after a restart) completes it.
    try testing.expectEqual(@as(usize, 1), try cluster_replication.applyDeletePayload(testing.allocator, &store, payload));
    try testing.expect((try store.getEdgeHydratedChecked(e2)) == null);
}
