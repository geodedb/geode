// GAP-0900 Layer-3 (Fix 3) A/B harness: measure the legacy in-memory
// GraphStore node-mirror footprint per node.
//
// Builds N nodes directly in the GraphStore mirror (no storage adapter
// installed, so setNodeProperty populates ONLY the in-memory mirror — exactly
// the structure this fix targets), each with the ~20-property Taxon shape from
// the batch ingest. Reports MaxRSS delta and bytes/node so the same binary run
// on `main` (StringHashMap mirror) vs `gap0900-l3-node-mirror`
// (CompactPropertyMap mirror) yields a directly comparable bytes/node figure.
//
// Usage: benchmark_gap0900_node_mirror_rss [node_count]   (default 200000)

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;

fn rssBytes() u64 {
    // statm field 2 (resident pages) * page size. Use raw syscalls — Zig 0.16
    // removed std.fs.openFileAbsolute.
    const fd = std.os.linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
    const ifd: isize = @bitCast(fd);
    if (ifd < 0) return 0;
    const ufd: i32 = @intCast(fd);
    defer _ = std.os.linux.close(ufd);
    var buf: [256]u8 = undefined;
    const rc = std.os.linux.read(ufd, &buf, buf.len);
    const irc: isize = @bitCast(rc);
    if (irc <= 0) return 0;
    const n: usize = @intCast(rc);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next() orelse return 0; // size
    const res = it.next() orelse return 0; // resident
    const pages = std.fmt.parseInt(u64, std.mem.trim(u8, res, " \n"), 10) catch return 0;
    return pages * 4096;
}

fn out(bytes: []const u8) void {
    _ = std.os.linux.write(1, bytes.ptr, bytes.len);
}

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// The 20 Taxon property keys from the fishbase / CoL batch ingest shape.
const taxon_keys = [_][]const u8{
    "taxon_id",         "scientific_name", "canonical_name", "authority",
    "rank",             "status",          "kingdom",        "phylum",
    "class",            "order",           "family",         "genus",
    "specific_epithet", "is_marine",       "is_freshwater",  "is_brackish",
    "is_extinct",       "source",          "run_id",         "name_according_to",
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // Node count from GAP0900_BENCH_NODES env (default 200k), avoiding the
    // Zig-version-specific argv API.
    const node_count: usize = blk: {
        if (std.c.getenv("GAP0900_BENCH_NODES")) |raw_z| {
            const raw = std.mem.span(raw_z);
            break :blk std.fmt.parseInt(usize, raw, 10) catch 200_000;
        }
        break :blk 200_000;
    };

    // Fresh in-memory store, NO storage adapter — isolates the mirror.
    graph_store.deinitGlobalStore();
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();

    const rss_before = rssBytes();
    const t_start = nowNs();

    var valbuf: [96]u8 = undefined;
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const node_id = try store.createNodeWithGraph(&[_][]const u8{"Taxon"}, "divelife");
        for (taxon_keys, 0..) |key, ki| {
            // Distinct, realistic-length string values per node/key.
            const val = try std.fmt.bufPrint(&valbuf, "{s}-{d}-{d}", .{ key, node_id, ki });
            try store.setNodeProperty(node_id, key, .{ .String = val });
        }
    }

    const elapsed_ns = nowNs() - t_start;
    const rss_after = rssBytes();
    const delta = if (rss_after > rss_before) rss_after - rss_before else 0;
    const count = store.getNodeCount();

    var obuf: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&obuf,
        \\GAP0900_NODE_MIRROR_RSS nodes={d} count_nodes={d} props_per_node={d}
        \\  rss_before={d} rss_after={d} rss_delta_bytes={d}
        \\  bytes_per_node={d:.1} build_ms={d}
        \\
    , .{
        node_count,
        count,
        taxon_keys.len,
        rss_before,
        rss_after,
        delta,
        @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(node_count)),
        elapsed_ns / std.time.ns_per_ms,
    });
    out(line);

    // Correctness spot-check: a non-merge property reads back correctly from the
    // mirror (proves the compact store round-trips under the same path A/B uses).
    const probe_id = try store.createNodeWithGraph(&[_][]const u8{"Taxon"}, "divelife");
    try store.setNodeProperty(probe_id, "scientific_name", .{ .String = "Probe testus" });
    const got = store.getNodeProperty(probe_id, "scientific_name");
    if (got == null or got.? != .String or !std.mem.eql(u8, got.?.String, "Probe testus")) {
        out("GAP0900_NODE_MIRROR_RSS CORRECTNESS_FAIL\n");
        return error.CorrectnessCheckFailed;
    }
    out("GAP0900_NODE_MIRROR_RSS correctness_ok=1\n");
}
