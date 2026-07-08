// benchmarks/bench_edge_bulk_throughput.zig — edge bulk-load throughput repro (task0049).
//
// Reproduces the fresh-store edge bulk-load path the LIVE server takes for
//   MATCH (a:Taxon {id: ?}), (b:Taxon {id: ?}) CREATE (a)-[:PARENT_OF]->(b)
// which routes to the QUIC bulk fast path `executeBulkMatchCreateEdge`
// (src/server/quic_connection_handler.zig:644). That path resolves each
// endpoint with `adapter.lookupNodeByMergeKey` and applies the edge with
// `adapter.bulkInsertEdgeWithIds` (src/storage/graph_storage_adapter.zig:3809 /
// :3847). This bench calls those SAME functions in-process so the per-edge cost
// breakdown (endpoint-seek vs adjacency-append+WAL) is measured directly,
// single-threaded (isolating per-edge cost from cross-connection lock
// serialization, which the code review already established).
//
// Env knobs:
//   EDGE_DIR      base dir for the tmp store   (default /var/tmp/geode-bins/edge-repro)
//   EDGE_M_EDGES  edges to create per point    (default 50000)
//   EDGE_SWEEP    "1" => sweep N in {100k,250k,500k}; else single N=EDGE_N_NODES
//   EDGE_N_NODES  node count for single mode   (default 500000)
//   EDGE_BATCHED  "1" => wrap edges in one session txn (amortize WAL fsync)
//   EDGE_POPULAR  "1" => all edges share one source node (grow one chain: O(degree) probe)
//
// Build (ReleaseFast REQUIRED — Debug inflates latencies ~40-50x):
//   zig build bench-edge-bulk-throughput -Doptimize=ReleaseFast

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn envStr(name: [:0]const u8) ?[]const u8 {
    if (std.c.getenv(name)) |p| {
        const s = std.mem.span(p);
        if (s.len == 0) return null;
        return s;
    }
    return null;
}

fn envUsize(name: [:0]const u8, fallback: usize) usize {
    if (envStr(name)) |s| {
        return std.fmt.parseInt(usize, s, 10) catch fallback;
    }
    return fallback;
}

fn envFlag(name: [:0]const u8) bool {
    if (envStr(name)) |s| return std.mem.eql(u8, s, "1");
    return false;
}

const Point = struct {
    n_nodes: usize,
    m_edges: usize,
    batched: bool,
    popular: bool,
    seed_ns: u64,
    lookup_ns: u64,
    apply_ns: u64,
    total_edge_ns: u64,
};

fn runPoint(
    gpa: std.mem.Allocator,
    dir_base: []const u8,
    n_nodes: usize,
    m_edges: usize,
    batched: bool,
    popular: bool,
) !Point {
    const graph = "default";

    // Fresh store dir per point.
    var path_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "{s}-n{d}-{s}{s}", .{
        dir_base,
        n_nodes,
        if (batched) "batched" else "peredge",
        if (popular) "-pop" else "",
    });
    const fs_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(fs_io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_io, dir);
    defer std.Io.Dir.cwd().deleteTree(fs_io, dir) catch {};

    graph_store.deinitGlobalStore();
    const store = try graph_store.initGlobalStore(gpa, dir);
    defer graph_store.deinitGlobalStore();

    graph_store.registerMergeIndexKey("id");

    const adapter = graph_store.getGlobalAdapter().?;

    // ---- seed nodes ---- (batched in one session txn so node-phase per-write
    // fsync doesn't dominate setup; seeding speed is not what we measure).
    const seed_t0 = nowNs();
    // First node creates the graph so beginSessionTxnLazy can attach.
    {
        const nid0 = try store.createNodeWithGraph(&.{"Taxon"}, graph);
        try store.setNodeProperty(nid0, "id", .{ .Int = 0 });
    }
    try adapter.beginSessionTxnLazy(graph);
    var i: usize = 1;
    while (i < n_nodes) : (i += 1) {
        const nid = try store.createNodeWithGraph(&.{"Taxon"}, graph);
        try store.setNodeProperty(nid, "id", .{ .Int = @intCast(i) });
    }
    try adapter.commitSessionTxn();
    const seed_ns = nowNs() - seed_t0;

    // Batched mode: one session txn covers the whole edge loop so
    // bulkInsertEdgeWithIds does NOT open+commit (fsync) a per-edge statement
    // txn — isolates the WAL-fsync component of per-edge cost.
    if (batched) try adapter.beginSessionTxnLazy(graph);

    // Hold the per-graph exclusive write lock across the loop, exactly like the
    // group-commit coordinator holds it across a batch.
    const lock = graph_store.acquireGraphWriteLock(graph);

    var lookup_ns: u64 = 0;
    var apply_ns: u64 = 0;
    const edge_t0 = nowNs();

    var e: usize = 0;
    var rng: u64 = 0x9E3779B97F4A7C15;
    while (e < m_edges) : (e += 1) {
        // pseudo-random distinct endpoints
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        const src_val: usize = if (popular) 0 else (rng >> 33) % n_nodes;
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        var dst_val: usize = (rng >> 33) % n_nodes;
        if (dst_val == src_val) dst_val = (dst_val + 1) % n_nodes;

        const l0 = nowNs();
        const src = adapter.lookupNodeByMergeKey(graph, "Taxon", "id", .{ .Int = @intCast(src_val) }, error.SourceNodeNotFound) catch continue;
        const dst = adapter.lookupNodeByMergeKey(graph, "Taxon", "id", .{ .Int = @intCast(dst_val) }, error.TargetNodeNotFound) catch continue;
        const l1 = nowNs();
        lookup_ns += l1 - l0;

        _ = adapter.bulkInsertEdgeWithIds(graph, src, dst, "PARENT_OF", &.{}, null) catch continue;
        apply_ns += nowNs() - l1;
    }
    const total_edge_ns = nowNs() - edge_t0;

    graph_store.releaseGraphLock(lock);
    if (batched) try adapter.commitSessionTxn();

    return .{
        .n_nodes = n_nodes,
        .m_edges = m_edges,
        .batched = batched,
        .popular = popular,
        .seed_ns = seed_ns,
        .lookup_ns = lookup_ns,
        .apply_ns = apply_ns,
        .total_edge_ns = total_edge_ns,
    };
}

fn report(p: Point) void {
    const m: f64 = @floatFromInt(p.m_edges);
    const eps: f64 = m / (@as(f64, @floatFromInt(p.total_edge_ns)) / 1e9);
    const lookup_us: f64 = (@as(f64, @floatFromInt(p.lookup_ns)) / m) / 1e3;
    const apply_us: f64 = (@as(f64, @floatFromInt(p.apply_ns)) / m) / 1e3;
    const total_us: f64 = (@as(f64, @floatFromInt(p.total_edge_ns)) / m) / 1e3;
    const seed_s: f64 = @as(f64, @floatFromInt(p.seed_ns)) / 1e9;
    std.debug.print(
        "N={d:>7} M={d:>7} {s:<8}{s:<5} | edges/s={d:>9.0} | per-edge us: lookup={d:>7.2} apply={d:>7.2} total={d:>7.2} | seed={d:.1}s\n",
        .{
            p.n_nodes,                               p.m_edges,
            if (p.batched) "batched" else "peredge", if (p.popular) "pop" else "",
            eps,                                     lookup_us,
            apply_us,                                total_us,
            seed_s,
        },
    );
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    const dir_base = envStr("EDGE_DIR") orelse "/var/tmp/geode-bins/edge-repro";
    const m_edges = envUsize("EDGE_M_EDGES", 50000);
    const sweep = envFlag("EDGE_SWEEP");
    const batched = envFlag("EDGE_BATCHED");
    const popular = envFlag("EDGE_POPULAR");

    std.debug.print("=== edge bulk-load throughput repro (task0049) — live bulk-fast-path functions ===\n", .{});

    if (sweep) {
        // O(n) detection: same M edges at growing N. Run BOTH per-edge-txn and
        // batched so the WAL-fsync component is visible.
        const ns = [_]usize{ 100_000, 250_000, 500_000 };
        std.debug.print("-- per-edge-txn (each edge = one statement txn + WAL fsync) --\n", .{});
        for (ns) |n| report(try runPoint(gpa, dir_base, n, m_edges, false, false));
        std.debug.print("-- batched (one session txn for all edges; fsync amortized) --\n", .{});
        for (ns) |n| report(try runPoint(gpa, dir_base, n, m_edges, true, false));
        std.debug.print("-- popular-parent (all edges share source id=0; O(degree) chain) --\n", .{});
        report(try runPoint(gpa, dir_base, 250_000, m_edges, true, true));
    } else {
        const n = envUsize("EDGE_N_NODES", 500_000);
        report(try runPoint(gpa, dir_base, n, m_edges, batched, popular));
    }

    std.debug.print("=== done ===\n", .{});
}
