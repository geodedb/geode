// CANARY: REQ=REQ-SONNY-6492-EDGE-PROP-IMAGE-COST; FEATURE="TransactionManagement"; ASPECT=Measurement; STATUS=BENCHED; BENCH=tests/test_sonny6492_edge_prop_image_cost.zig; OWNER=storage; UPDATED=2026-11-15
//
// SONNY-6492 (5), SONNY-6529: the measured cost of a relationship-property
// write. A write that moves the property chain's head (the first property of
// a relationship, or a chain that grows out of its slab slot) rewrites the
// head in both adjacency copies, and graph-storage's `setEdgePropertyTxn`
// (which the adapter calls since SONNY-6529) WAL-images the property page,
// the outgoing adjacency page and the incoming adjacency page in the
// transaction (SONNY-6471: without them a crash lost the property). Before
// SONNY-6529 the adapter rewrote the heads itself and imaged the source's
// node page as well; graph-storage 0.4.16's tail reconcile no longer needs
// it. A write that overwrites a slab slot in place moves nothing and images
// the property page only.
//
// Arm A sets the first property of a property-less relationship (head
// moves); arm B overwrites that property on a relationship that has it (in
// place). Each arm has its own graph; one operation is one SET
// (`StorageAdapter.setEdgeProperty`, the call `SET r.p` reaches). Two
// shapes: every SET in its own engine transaction, and a statement
// transaction around a batch of 100 SETs. The arms run interleaved, batch by
// batch (perf_gate), so machine load cancels out. Twice: with the default
// fsync per commit, and with GEODE_WAL_SYNC=deferred (no fsync), so the cost
// is not hidden behind disk latency. A SET whose relationship's source is
// not on the statement transaction's shard commits its own engine
// transaction even inside the statement (SONNY-2979). WAL bytes are the
// growth of the graph's shard WAL files over the arm's batches. No
// checkpoint runs (none is started in-process), so the WAL grows by exactly
// what the writes log. Then, not interleaved: five properties set on each
// property-less relationship in one `setEdgePropertiesBatch` call (the
// multi-property shape of `SET r = {...}` and bulk edge ingest), per
// relationship. The executor and network layers above the adapter are not
// measured.
const std = @import("std");
const geode = @import("geode");
const perf_gate = @import("perf_gate");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const edges_per_arm = 6000;
const batch = 100;
const samples = 24;
const multi_edges = 2000;

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

const Edge = struct { from: u64, to: u64, id: u64 };

fn createEdges(adapter: *gsa.StorageAdapter, allocator: std.mem.Allocator, graph: []const u8, n: usize, with_prop: bool) ![]Edge {
    const labels = [_][]const u8{"N"};
    const edges = try allocator.alloc(Edge, n);
    errdefer allocator.free(edges);
    var i: usize = 0;
    // Statement transactions of 500 (one commit each: setup is not measured).
    while (i < edges.len) {
        var stmt: gsa.StatementTxn = undefined;
        try adapter.beginStatementTxn(graph, &stmt);
        errdefer stmt.fail();
        const end = @min(i + 500, edges.len);
        for (edges[i..end]) |*e| {
            const a = try adapter.createNode(graph, &labels);
            const b = try adapter.createNode(graph, &labels);
            e.* = .{ .from = a, .to = b, .id = try adapter.createEdge(graph, a, b, "R") };
            if (with_prop) try adapter.setEdgeProperty(graph, e.from, e.to, e.id, "p", .{ .Int = 0 });
        }
        try stmt.commit();
        i = end;
    }
    return edges;
}

fn walBytes(adapter: *gsa.StorageAdapter, graph: []const u8) !u64 {
    const mg = adapter.pinGraph(graph) orelse return error.GraphNotOpen;
    defer adapter.unpinGraph(mg);
    var total: u64 = 0;
    for (mg.engine.shards) |shard| {
        const p = try std.fmt.allocPrint(std.testing.allocator, "{s}/wal/graph.wal", .{shard.graph_dir.path});
        defer std.testing.allocator.free(p);
        const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch continue;
        total += st.size;
    }
    return total;
}

const Arm = struct {
    adapter: *gsa.StorageAdapter,
    graph: []const u8,
    edges: []Edge,
    next: usize = 0,
    one_txn: bool = false,

    fn setOne(self: *Arm) !void {
        const e = self.edges[self.next];
        self.next += 1;
        try self.adapter.setEdgeProperty(self.graph, e.from, e.to, e.id, "p", .{ .Int = 1 });
    }

    /// One perf_gate operation: one SET, or (one transaction) the whole
    /// batch's SETs in one statement transaction on the first call.
    fn op(self: *Arm) !u64 {
        if (!self.one_txn) {
            try self.setOne();
            return self.next;
        }
        var stmt: gsa.StatementTxn = undefined;
        try self.adapter.beginStatementTxn(self.graph, &stmt);
        errdefer stmt.fail();
        for (0..batch) |_| try self.setOne();
        try stmt.commit();
        return self.next;
    }
};

const Ctx = struct {
    a: *Arm,
    b: *Arm,

    fn opA(self: *Ctx) !u64 {
        return self.a.op();
    }

    fn opB(self: *Ctx) !u64 {
        return self.b.op();
    }
};

fn measure(adapter: *gsa.StorageAdapter, allocator: std.mem.Allocator, one_txn: bool, tag: []const u8) !void {
    var ga_buf: [32]u8 = undefined;
    var gb_buf: [32]u8 = undefined;
    const ga = try std.fmt.bufPrint(&ga_buf, "ga_{s}", .{tag});
    const gb = try std.fmt.bufPrint(&gb_buf, "gb_{s}", .{tag});
    const store = graph_store.getGlobalStore(allocator);
    try store.createGraph(ga);
    try store.createGraph(gb);
    var a: Arm = .{ .adapter = adapter, .graph = ga, .edges = try createEdges(adapter, allocator, ga, edges_per_arm, false), .one_txn = one_txn };
    defer allocator.free(a.edges);
    var b: Arm = .{ .adapter = adapter, .graph = gb, .edges = try createEdges(adapter, allocator, gb, edges_per_arm, true), .one_txn = one_txn };
    defer allocator.free(b.edges);

    var ctx: Ctx = .{ .a = &a, .b = &b };
    // One transaction: one perf_gate operation runs a whole batch of SETs.
    const per_sample: usize = if (one_txn) 1 else batch;
    var sa: [samples]f64 = undefined;
    var sb: [samples]f64 = undefined;
    const wal_a0 = try walBytes(adapter, ga);
    const wal_b0 = try walBytes(adapter, gb);
    try perf_gate.interleavedAB(&ctx, Ctx.opA, Ctx.opB, per_sample, &sa, &sb);
    const wal_a = try walBytes(adapter, ga) - wal_a0;
    const wal_b = try walBytes(adapter, gb) - wal_b0;
    const ra = perf_gate.robust(&sa);
    const rb = perf_gate.robust(&sb);
    const sets: f64 = @floatFromInt(samples * batch);
    // perf_gate samples are ns per operation; normalise to ns per SET.
    const set_per_op: f64 = if (one_txn) batch else 1;
    std.debug.print(
        "SONNY-6492 (5) {s}: median {d:.0} ns/SET moving the head (first property), {d:.0} ns/SET in place (overwrite); WAL {d:.0} B/SET moving the head, {d:.0} B/SET in place\n",
        .{
            if (one_txn) "one transaction of 100 SETs" else "one transaction per SET",
            ra.median / set_per_op,
            rb.median / set_per_op,
            @as(f64, @floatFromInt(wal_a)) / sets,
            @as(f64, @floatFromInt(wal_b)) / sets,
        },
    );
    // Both arms wrote every SET, and every SET is read back.
    try std.testing.expectEqual(@as(usize, samples * batch), a.next);
    try std.testing.expectEqual(@as(usize, samples * batch), b.next);
    for ([_]*Arm{ &a, &b }) |arm| {
        for (arm.edges[0..arm.next]) |e| {
            const v = (try adapter.getEdgeProperty(arm.graph, e.from, e.id, "p", allocator)) orelse return error.PropertyMissing;
            try std.testing.expectEqual(@as(i64, 1), v.int);
        }
    }
}

/// Five properties per relationship in one `setEdgePropertiesBatch` call.
fn measureMulti(adapter: *gsa.StorageAdapter, allocator: std.mem.Allocator) !void {
    const g = "gm";
    try graph_store.getGlobalStore(allocator).createGraph(g);
    const edges = try createEdges(adapter, allocator, g, multi_edges, false);
    defer allocator.free(edges);
    const entries = [_]gsa.StorageAdapter.BatchPropertyEntry{
        .{ .key = "a", .value = .{ .Int = 1 } },
        .{ .key = "b", .value = .{ .Int = 2 } },
        .{ .key = "c", .value = .{ .String = "ccccccccccccccccccccccccccccccccc" } },
        .{ .key = "d", .value = .{ .Float = 4.5 } },
        .{ .key = "e", .value = .{ .Bool = true } },
    };
    const wal0 = try walBytes(adapter, g);
    const t0 = std.Io.Clock.Timestamp.now(io(), .awake).raw.nanoseconds;
    for (edges) |e| try adapter.setEdgePropertiesBatch(g, e.id, &entries);
    const ns: u64 = @intCast(std.Io.Clock.Timestamp.now(io(), .awake).raw.nanoseconds - t0);
    const wal = try walBytes(adapter, g) - wal0;
    const n: f64 = @floatFromInt(edges.len);
    std.debug.print("SONNY-6492 (5) five properties per relationship (setEdgePropertiesBatch, one engine transaction each): {d:.0} ns/relationship, WAL {d:.0} B/relationship\n", .{
        @as(f64, @floatFromInt(ns)) / n,
        @as(f64, @floatFromInt(wal)) / n,
    });
    for (edges) |e| {
        const v = (try adapter.getEdgeProperty(g, e.from, e.id, "e", allocator)) orelse return error.PropertyMissing;
        try std.testing.expect(v.bool);
    }
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn run(sync: []const u8) !void {
    const allocator = std.testing.allocator;
    std.debug.print("SONNY-6492 (5) WAL sync {s}:\n", .{sync});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    _ = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    try measure(adapter, allocator, false, "n");
    try measure(adapter, allocator, true, "one");
    try measureMulti(adapter, allocator);
}

test "SONNY-6492 (5): WAL bytes and time of a relationship-property SET (fsync per commit)" {
    try run("each_commit");
}

// No fsync per commit (GEODE_WAL_SYNC=deferred): the CPU and write cost of the
// images, not hidden behind disk latency.
test "SONNY-6492 (5): WAL bytes and time of a relationship-property SET (deferred sync)" {
    if (setenv("GEODE_WAL_SYNC", "deferred", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_WAL_SYNC");
    try run("deferred");
}
