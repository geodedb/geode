// CANARY: REQ=REQ-SONNY-6492-EDGE-PROP-IMAGE-COST; FEATURE="TransactionManagement"; ASPECT=Measurement; STATUS=BENCHED; BENCH=tests/test_sonny6492_edge_prop_image_cost.zig; OWNER=storage; UPDATED=2026-11-13
//
// SONNY-6492 (5): the measured cost of the SONNY-6471 crash-safety fix.
// `publishEdgePropHead` WAL-images the outgoing adjacency page, the source's
// node page and the incoming adjacency page (three 8 KiB pages) in the
// engine transaction of every relationship-property write that moves the
// property chain's head (the first property of a relationship; a write that
// overwrites a slab slot in place moves nothing and images nothing).
//
// Arm A skips the three images (`bench_skip_edge_prop_head_images`, compiled
// only into test binaries); arm B is the shipped path. Each arm has its own
// graph of property-less relationships; one operation sets the first
// property of the next relationship (`StorageAdapter.setEdgeProperty`, the
// call `SET r.p` reaches). Two shapes:
//   - N transactions: every SET commits its own engine transaction;
//   - one transaction: a statement transaction around a batch of SETs.
// The arms run interleaved, batch by batch (perf_gate), so machine load
// cancels out; overhead = (median B - median A) / median A. Twice: with the
// default fsync per commit, and with GEODE_WAL_SYNC=deferred (no fsync), so
// the cost is not hidden behind disk latency. A SET whose relationship's
// source is not on the statement transaction's shard commits its own engine
// transaction even inside the statement (SONNY-2979). WAL bytes are
// the growth of the graph's shard WAL files over the arm's batches.
// No checkpoint runs (none is started in-process), so the WAL grows by
// exactly what the writes log. The executor and network layers above the
// adapter do the same work in both arms: the overhead of a whole query is
// smaller than this figure.
const std = @import("std");
const geode = @import("geode");
const perf_gate = @import("perf_gate");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const edges_per_arm = 6000;
const batch = 100;
const samples = 24;

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

const Arm = struct {
    adapter: *gsa.StorageAdapter,
    graph: []const u8,
    skip_images: bool,
    edges: []Edge,
    next: usize = 0,
    one_txn: bool = false,

    /// The relationships, written in statement transactions of 500 (one
    /// commit each: setup is not measured).
    fn setup(self: *Arm, allocator: std.mem.Allocator) !void {
        const labels = [_][]const u8{"N"};
        self.edges = try allocator.alloc(Edge, edges_per_arm);
        var i: usize = 0;
        while (i < self.edges.len) {
            var stmt: gsa.StatementTxn = undefined;
            try self.adapter.beginStatementTxn(self.graph, &stmt);
            errdefer stmt.abort();
            const end = @min(i + 500, self.edges.len);
            for (self.edges[i..end]) |*e| {
                const a = try self.adapter.createNode(self.graph, &labels);
                const b = try self.adapter.createNode(self.graph, &labels);
                e.* = .{ .from = a, .to = b, .id = try self.adapter.createEdge(self.graph, a, b, "R") };
            }
            try stmt.commit();
            i = end;
        }
    }

    fn walBytes(self: *Arm) !u64 {
        const mg = self.adapter.pinGraph(self.graph) orelse return error.GraphNotOpen;
        defer self.adapter.unpinGraph(mg);
        var total: u64 = 0;
        for (mg.engine.shards) |shard| {
            const p = try std.fmt.allocPrint(std.testing.allocator, "{s}/wal/graph.wal", .{shard.graph_dir.path});
            defer std.testing.allocator.free(p);
            const st = std.Io.Dir.cwd().statFile(io(), p, .{}) catch continue;
            total += st.size;
        }
        return total;
    }

    fn setOne(self: *Arm) !void {
        const e = self.edges[self.next];
        self.next += 1;
        try self.adapter.setEdgeProperty(self.graph, e.from, e.to, e.id, "p", .{ .Int = 1 });
    }

    /// One perf_gate operation: one SET, or (one transaction) the whole
    /// batch's SETs in one statement transaction on the first call.
    fn op(self: *Arm) !u64 {
        gsa.bench_skip_edge_prop_head_images = self.skip_images;
        defer gsa.bench_skip_edge_prop_head_images = false;
        if (!self.one_txn) {
            try self.setOne();
            return self.next;
        }
        var stmt: gsa.StatementTxn = undefined;
        try self.adapter.beginStatementTxn(self.graph, &stmt);
        errdefer stmt.abort();
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
    var a: Arm = .{ .adapter = adapter, .graph = ga, .skip_images = true, .edges = &.{}, .one_txn = one_txn };
    var b: Arm = .{ .adapter = adapter, .graph = gb, .skip_images = false, .edges = &.{}, .one_txn = one_txn };
    try a.setup(allocator);
    defer allocator.free(a.edges);
    try b.setup(allocator);
    defer allocator.free(b.edges);

    var ctx: Ctx = .{ .a = &a, .b = &b };
    // One transaction: one perf_gate operation runs a whole batch of SETs.
    const per_sample: usize = if (one_txn) 1 else batch;
    var sa: [samples]f64 = undefined;
    var sb: [samples]f64 = undefined;
    const wal_a0 = try a.walBytes();
    const wal_b0 = try b.walBytes();
    try perf_gate.interleavedAB(&ctx, Ctx.opA, Ctx.opB, per_sample, &sa, &sb);
    const wal_a = try a.walBytes() - wal_a0;
    const wal_b = try b.walBytes() - wal_b0;
    const ra = perf_gate.robust(&sa);
    const rb = perf_gate.robust(&sb);
    const sets: f64 = @floatFromInt(samples * batch);
    // perf_gate samples are ns per operation; normalise to ns per SET.
    const set_per_op: f64 = if (one_txn) batch else 1;
    std.debug.print(
        "SONNY-6492 (5) {s}: median {d:.0} ns/SET without the head images, {d:.0} ns/SET with them, overhead {d:.1}%; WAL {d:.0} B/SET without, {d:.0} B/SET with (+{d:.0} B/SET)\n",
        .{
            if (one_txn) "one transaction of 100 SETs" else "one transaction per SET",
            ra.median / set_per_op,
            rb.median / set_per_op,
            perf_gate.medianOverhead(ra, rb) * 100.0,
            @as(f64, @floatFromInt(wal_a)) / sets,
            @as(f64, @floatFromInt(wal_b)) / sets,
            (@as(f64, @floatFromInt(wal_b)) - @as(f64, @floatFromInt(wal_a))) / sets,
        },
    );
    // Both arms wrote every SET.
    try std.testing.expectEqual(@as(usize, samples * batch), a.next);
    try std.testing.expectEqual(@as(usize, samples * batch), b.next);
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
}

test "SONNY-6492 (5): WAL bytes and time of the SONNY-6471 relationship-property head images (fsync per commit)" {
    try run("each_commit");
}

// No fsync per commit (GEODE_WAL_SYNC=deferred): the CPU and write cost of the
// images, not hidden behind disk latency.
test "SONNY-6492 (5): WAL bytes and time of the SONNY-6471 relationship-property head images (deferred sync)" {
    if (setenv("GEODE_WAL_SYNC", "deferred", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_WAL_SYNC");
    try run("deferred");
}
