// PHASE 1 (edge-engine-direct) — bounded-RSS plateau PROBE (standalone binary).
//
// Ingests K edges (one parent fanning out to K children) through the full
// engine-backed CREATE path with TINY edge + adjacency + node caches, then
// prints the resident edge/adjacency counts and the process MaxRSS. Run it at
// two (or more) values of K with the SAME tiny caps: the resident counts and
// MaxRSS must NOT scale with K — the direct proof of "bounded RSS at scale with
// a small cache" for the edge-body mirror.
//
// Usage: edge_rss_plateau_probe <K> [edge_cap] [adj_cap] [node_cap]
// Prints one CSV line: K,edge_resident,in_adj_resident,out_adj_resident,edge_total,maxrss_kb

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const execution = geode.execution;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn envOr(name: [*:0]const u8, default: []const u8) []const u8 {
    if (std.c.getenv(name)) |v| return std.mem.span(v);
    return default;
}

fn maxRssKb() u64 {
    var usage: std.os.linux.rusage = undefined;
    _ = std.os.linux.getrusage(std.os.linux.rusage.SELF, &usage);
    // ru_maxrss is in kilobytes on Linux.
    return @intCast(usage.maxrss);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Configured via env (PROBE_K / edge+adj+node caps) — avoids std args API
    // churn across Zig versions. Defaults give a quick run.
    const k_str = envOr("PROBE_K", "20000");
    const edge_cap = envOr("GEODE_EDGE_CACHE_ENTRIES_PROBE", "2000");
    const adj_cap = envOr("GEODE_ADJ_CACHE_ENTRIES_PROBE", "2000");
    const node_cap = envOr("GEODE_NODE_CACHE_ENTRIES_PROBE", "0"); // unbounded nodes (isolate edge plateau)

    const K = try std.fmt.parseInt(usize, k_str, 10);

    const edge_cap_z = try allocator.dupeZ(u8, edge_cap);
    const adj_cap_z = try allocator.dupeZ(u8, adj_cap);
    const node_cap_z = try allocator.dupeZ(u8, node_cap);
    _ = setenv("GEODE_EDGE_CACHE_ENTRIES", edge_cap_z.ptr, 1);
    _ = setenv("GEODE_ADJ_CACHE_ENTRIES", adj_cap_z.ptr, 1);
    _ = setenv("GEODE_NODE_CACHE_ENTRIES", node_cap_z.ptr, 1);

    // Fresh data dir under /var/tmp (this box's scratch).
    var buf: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const data_dir = try std.fmt.bufPrintZ(&buf, "/var/tmp/edge_rss_probe_{d}_{d}", .{ pid, K });
    _ = std.os.linux.mkdir(data_dir.ptr, 0o755);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }

    const parent = try store.createNodeWithGraph(&.{"Taxon"}, "default");
    var i: usize = 0;
    while (i < K) : (i += 1) {
        const child = try store.createNodeWithGraph(&.{"Taxon"}, "default");
        _ = try store.createEdgeWithGraph(parent, child, "PARENT_OF", "default");
    }

    const edge_resident = store.edges.residentCount();
    const in_resident = store.incoming_edges.residentCount();
    const out_resident = store.outgoing_edges.residentCount();
    const edge_total = store.getEdgeCount();
    const rss = maxRssKb();

    var out_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&out_buf, "{d},{d},{d},{d},{d},{d}\n", .{ K, edge_resident, in_resident, out_resident, edge_total, rss });
    _ = std.os.linux.write(1, line.ptr, line.len);
}
