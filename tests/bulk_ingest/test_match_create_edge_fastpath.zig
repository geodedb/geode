// Task 12 — MATCH+CREATE edge fast-path parity tests.
//
// Runs the msft-graph edge-hot-path pattern
//
//     MATCH (a:L1 {node_id: v1}), (b:L2 {node_id: v2})
//     CREATE (a)-[:T {props}]->(b)
//
// through both the regular executor and the `bulkInsertEdge` fast path.
// Asserts:
//
//   * Happy path: the fast path creates an edge between the two MERGE-ed
//     endpoints with the correct rel_type and properties.
//   * Parity: executor + bulk-path runs produce semantically identical
//     edges (same endpoints, matching properties).
//   * Error: a MATCH against a non-existent source node returns
//     `error.SourceNodeNotFound` with no partial edge state.
//
// The fast-path call is invoked directly (not through the QUIC handler)
// — the handler integration is covered end-to-end by the msft-graph
// seed workload once `GEODE_BULK_INGEST=1` is in effect.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return try execution.executeProgramWithContext(self.allocator, &parsed.program, self.ctx);
    }
};

fn findNodeByProperty(
    store: *graph_store.GraphStore,
    key: []const u8,
    expected: []const u8,
) ?*graph_store.Node {
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.properties.get(key)) |pv| {
            switch (pv) {
                .String => |s| if (std.mem.eql(u8, s, expected)) return node,
                else => {},
            }
        }
    }
    return null;
}

fn findEdgeBetween(
    store: *graph_store.GraphStore,
    from_id: u64,
    to_id: u64,
    label: []const u8,
) ?*graph_store.Edge {
    var it = store.edges.iterator();
    while (it.next()) |entry| {
        const edge = entry.value_ptr;
        if (edge.from_id == from_id and edge.to_id == to_id and
            std.mem.eql(u8, edge.label, label))
        {
            return edge;
        }
    }
    return null;
}

// ----------------------------------------------------------------------
// Happy path: endpoints exist, fast path creates the edge + properties.
// ----------------------------------------------------------------------

test "bulkInsertEdge creates edge between existing endpoints" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed two endpoint nodes via MERGE (creates + indexes them through
    // the full executor).  Bulk path will then resolve them by
    // (label, node_id) via the merge-prop index.
    var r1 = try h.runQuery("MERGE (n:Widget {node_id: 'widget-alpha'})");
    r1.deinit(testing.allocator);
    var r2 = try h.runQuery("MERGE (n:Gadget {node_id: 'gadget-one'})");
    r2.deinit(testing.allocator);

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    var eprops = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "since", .value = .{ .String = "2020" } },
        .{ .key = "weight", .value = .{ .Int = 5 } },
    };
    const edge_id = try adapter.bulkInsertEdge(
        "default",
        "Widget",
        .{ .String = "widget-alpha" },
        "node_id",
        "Gadget",
        .{ .String = "gadget-one" },
        "node_id",
        "LINKS_TO",
        &eprops,
        null,
    );
    try testing.expect(edge_id != 0);

    const store = graph_store.getGlobalStore(testing.allocator);
    const src = findNodeByProperty(store, "node_id", "widget-alpha") orelse
        return error.SourceNodeMissing;
    const dst = findNodeByProperty(store, "node_id", "gadget-one") orelse
        return error.TargetNodeMissing;

    const edge = findEdgeBetween(store, src.id, dst.id, "LINKS_TO") orelse
        return error.EdgeMissing;
    try testing.expectEqual(edge_id, edge.id);
    try testing.expectEqualStrings("LINKS_TO", edge.label);

    const since_prop = edge.properties.get("since") orelse return error.MissingSince;
    try testing.expectEqualStrings("2020", since_prop.String);
    const weight_prop = edge.properties.get("weight") orelse return error.MissingWeight;
    try testing.expectEqual(@as(i64, 5), weight_prop.Int);
}

// ----------------------------------------------------------------------
// Parity: executor + bulk path produce semantically identical edges.
// ----------------------------------------------------------------------

test "bulkInsertEdge parity with executor path — labels/props/direction" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed four endpoint nodes — two pairs, one per path.
    var r1 = try h.runQuery("MERGE (n:Widget {node_id: 'exec-src'})");
    r1.deinit(testing.allocator);
    var r2 = try h.runQuery("MERGE (n:Gadget {node_id: 'exec-dst'})");
    r2.deinit(testing.allocator);
    var r3 = try h.runQuery("MERGE (n:Widget {node_id: 'bulk-src'})");
    r3.deinit(testing.allocator);
    var r4 = try h.runQuery("MERGE (n:Gadget {node_id: 'bulk-dst'})");
    r4.deinit(testing.allocator);

    // Path A: executor.
    var exec_r = try h.runQuery(
        "MATCH (a:Widget {node_id: 'exec-src'}), (b:Gadget {node_id: 'exec-dst'}) " ++
            "CREATE (a)-[:LINKS_TO {since: '2020'}]->(b)",
    );
    exec_r.deinit(testing.allocator);

    // Path B: bulk.
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    var bulk_props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "since", .value = .{ .String = "2020" } },
    };
    _ = try adapter.bulkInsertEdge(
        "default",
        "Widget",
        .{ .String = "bulk-src" },
        "node_id",
        "Gadget",
        .{ .String = "bulk-dst" },
        "node_id",
        "LINKS_TO",
        &bulk_props,
        null,
    );

    // Both edges must now exist with matching structure.
    const store = graph_store.getGlobalStore(testing.allocator);
    const exec_src = findNodeByProperty(store, "node_id", "exec-src") orelse return error.ExecSrcMissing;
    const exec_dst = findNodeByProperty(store, "node_id", "exec-dst") orelse return error.ExecDstMissing;
    const bulk_src = findNodeByProperty(store, "node_id", "bulk-src") orelse return error.BulkSrcMissing;
    const bulk_dst = findNodeByProperty(store, "node_id", "bulk-dst") orelse return error.BulkDstMissing;

    const exec_edge = findEdgeBetween(store, exec_src.id, exec_dst.id, "LINKS_TO") orelse
        return error.ExecEdgeMissing;
    const bulk_edge = findEdgeBetween(store, bulk_src.id, bulk_dst.id, "LINKS_TO") orelse
        return error.BulkEdgeMissing;

    // Labels identical.
    try testing.expectEqualStrings("LINKS_TO", exec_edge.label);
    try testing.expectEqualStrings("LINKS_TO", bulk_edge.label);

    // Property parity: both must have `since = '2020'`.
    const exec_since = exec_edge.properties.get("since") orelse return error.ExecMissingSince;
    const bulk_since = bulk_edge.properties.get("since") orelse return error.BulkMissingSince;
    try testing.expectEqualStrings("2020", exec_since.String);
    try testing.expectEqualStrings("2020", bulk_since.String);

    // Direction: edge.from_id is the `User` endpoint, edge.to_id is the `Device`.
    try testing.expectEqual(exec_src.id, exec_edge.from_id);
    try testing.expectEqual(exec_dst.id, exec_edge.to_id);
    try testing.expectEqual(bulk_src.id, bulk_edge.from_id);
    try testing.expectEqual(bulk_dst.id, bulk_edge.to_id);
}

// ----------------------------------------------------------------------
// Error path: source lookup fails with SourceNodeNotFound, no partial state.
// ----------------------------------------------------------------------

test "bulkInsertEdge returns SourceNodeNotFound when source is missing" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Only seed the target — source is absent.
    var r = try h.runQuery("MERGE (n:Gadget {node_id: 'only-target'})");
    r.deinit(testing.allocator);

    const store = graph_store.getGlobalStore(testing.allocator);
    const edges_before = store.edges.count();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    var eprops = [_]adapter_mod.StorageAdapter.PropKV{};
    const res = adapter.bulkInsertEdge(
        "default",
        "Widget",
        .{ .String = "missing-user" },
        "node_id",
        "Gadget",
        .{ .String = "only-target" },
        "node_id",
        "LINKS_TO",
        &eprops,
        null,
    );
    try testing.expectError(error.SourceNodeNotFound, res);

    // No edge should have been created.
    const edges_after = store.edges.count();
    try testing.expectEqual(edges_before, edges_after);
}

test "bulkInsertEdge returns TargetNodeNotFound when target is missing" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Only seed the source.
    var r = try h.runQuery("MERGE (n:Widget {node_id: 'only-source'})");
    r.deinit(testing.allocator);

    const store = graph_store.getGlobalStore(testing.allocator);
    const edges_before = store.edges.count();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    var eprops = [_]adapter_mod.StorageAdapter.PropKV{};
    const res = adapter.bulkInsertEdge(
        "default",
        "Widget",
        .{ .String = "only-source" },
        "node_id",
        "Gadget",
        .{ .String = "missing-device" },
        "node_id",
        "LINKS_TO",
        &eprops,
        null,
    );
    try testing.expectError(error.TargetNodeNotFound, res);

    const edges_after = store.edges.count();
    try testing.expectEqual(edges_before, edges_after);
}
