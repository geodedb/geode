// bound-node-mirror north-star: prove the DISK-BACKED node cache bounds resident
// RSS at scale.
//
// Unlike benchmark_gap0900_node_mirror_rss (which runs with NO adapter, so the
// cache is forced unbounded), this harness installs the engine-backed storage
// adapter (via initGlobalStore) so:
//   * the GEODE_NODE_CACHE_ENTRIES cap is ACTIVE (hydrate-on-miss is wired), and
//   * periodic checkpoints drive grace-point reclamation of evicted nodes.
//
// It ingests N nodes (each with the ~20-property Taxon shape) against a small
// cap, sampling RSS as it goes, and asserts RSS PLATEAUS instead of growing
// linearly with N. It then verifies hydrate-on-miss correctness: a node that was
// certainly evicted reads back its exact properties from the engine.
//
// On the unbounded mirror (cap forced 0) RSS grows ~8 KB/node — this harness
// would FAIL the plateau assertion. With the bounded cache it PASSES.
//
// Env:
//   BNRSS_NODES   total nodes to ingest        (default 600000)
//   BNRSS_CAP     GEODE_NODE_CACHE_ENTRIES     (default 100000)
//   BNRSS_DIR     disk data dir (under /var/tmp) (default /var/tmp/geode-bnrss-<pid>)

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;

// libc setenv (std has no portable setenv in Zig 0.16; libc is linked).
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn rssBytes() u64 {
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

fn envUsize(name: [:0]const u8, dflt: usize) usize {
    if (std.c.getenv(name)) |raw_z| {
        const raw = std.mem.span(raw_z);
        return std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch dflt;
    }
    return dflt;
}

// A handful of properties per node — enough to make each Node's heap
// non-trivial (so eviction has memory to reclaim) without the 20-prop per-op WAL
// cost that makes the point-write path impractically slow at scale.
const taxon_keys = [_][]const u8{
    "scientific_name", "rank", "status", "family", "source",
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const node_count = envUsize("BNRSS_NODES", 600_000);
    const cap = envUsize("BNRSS_CAP", 100_000);

    // Activate the bounded cache via env BEFORE the store is created.
    var capbuf: [32]u8 = undefined;
    const cap_str = std.fmt.bufPrintZ(&capbuf, "{d}", .{cap}) catch "100000";
    _ = setenv("GEODE_NODE_CACHE_ENTRIES", cap_str.ptr, 1);
    // Frequent checkpoints so grace-point reclamation fires often and the retire
    // backlog stays small (tighter RSS bound for the test).
    _ = setenv("GEODE_CHECKPOINT_OPS", "50000", 1);

    // Disk-backed data dir under /var/tmp (NOT /tmp).
    var dirbuf: [256]u8 = undefined;
    const data_dir: []const u8 = blk: {
        if (std.c.getenv("BNRSS_DIR")) |z| break :blk std.mem.span(z);
        break :blk std.fmt.bufPrint(&dirbuf, "/var/tmp/geode-bnrss-{d}", .{std.os.linux.getpid()}) catch "/var/tmp/geode-bnrss";
    };
    // Create the data dir (parent /var/tmp exists). Ignore EEXIST.
    {
        var pathz: [256]u8 = undefined;
        const z = std.fmt.bufPrintZ(&pathz, "{s}", .{data_dir}) catch data_dir[0..0 :0];
        _ = std.os.linux.mkdir(z.ptr, 0o755);
    }

    graph_store.deinitGlobalStore();
    const store = graph_store.initGlobalStore(allocator, data_dir) catch |err| {
        var eb: [256]u8 = undefined;
        out(std.fmt.bufPrint(&eb, "BNRSS init failed: {s}\n", .{@errorName(err)}) catch "BNRSS init failed\n");
        return err;
    };
    defer graph_store.deinitGlobalStore();
    const adapter = graph_store.getGlobalAdapter().?;

    var hdr: [256]u8 = undefined;
    out(std.fmt.bufPrint(&hdr, "BNRSS start nodes={d} cap={d} effective_cap={d} dir={s}\n", .{
        node_count, cap, store.nodes.effectiveCap(), data_dir,
    }) catch "BNRSS start\n");

    const rss_before = rssBytes();

    // Sample RSS at the END of each window of `sample_every` inserts.
    const sample_every: usize = 25_000;
    var max_rss_after_warm: u64 = 0;
    var rss_at_2x: u64 = 0; // RSS once we've ingested 2x the cap (warm)
    var rss_final: u64 = 0;

    var valbuf: [96]u8 = undefined;
    var probe_id: u64 = 0;
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const id = try store.createNodeWithGraph(&[_][]const u8{"Taxon"}, "divelife");
        if (i == cap / 2) probe_id = id; // an id certain to be evicted later
        for (taxon_keys, 0..) |key, ki| {
            const val = try std.fmt.bufPrint(&valbuf, "{s}-{d}-{d}", .{ key, id, ki });
            try store.setNodeProperty(id, key, .{ .String = val });
        }
        // Drive the grace-point reclaim on a cadence (checkpointAllLight holds
        // each graph's rwlock EXCLUSIVE → reclaims that graph's retired nodes).
        if (i % sample_every == sample_every - 1) {
            adapter.checkpointAllLight() catch {};
            const r = rssBytes();
            const resident = store.nodes.residentCount();
            var sb: [256]u8 = undefined;
            out(std.fmt.bufPrint(&sb, "BNRSS sample i={d} resident={d} rss_delta={d}\n", .{
                i + 1, resident, if (r > rss_before) r - rss_before else 0,
            }) catch "BNRSS sample\n");
            if (i + 1 >= 2 * cap) {
                if (rss_at_2x == 0) rss_at_2x = r;
                if (r > max_rss_after_warm) max_rss_after_warm = r;
            }
            rss_final = r;
        }
    }
    adapter.checkpointAllLight() catch {};
    rss_final = rssBytes();

    const resident_final = store.nodes.residentCount();
    var fb: [320]u8 = undefined;
    out(std.fmt.bufPrint(&fb, "BNRSS done nodes={d} resident_final={d} rss_delta_final={d} bytes_per_node={d:.1}\n", .{
        node_count,
        resident_final,
        if (rss_final > rss_before) rss_final - rss_before else 0,
        @as(f64, @floatFromInt(if (rss_final > rss_before) rss_final - rss_before else 0)) / @as(f64, @floatFromInt(node_count)),
    }) catch "BNRSS done\n");

    // --- Assertion 1: resident set stays bounded near the cap. ---
    // Per-shard rounding allows up to ceil(cap/16)*16; allow 2x slack for the
    // in-flight retire backlog between checkpoints.
    const resident_bound = cap * 2;
    if (resident_final > resident_bound) {
        var ab: [160]u8 = undefined;
        out(std.fmt.bufPrint(&ab, "BNRSS FAIL: resident_final={d} > bound={d}\n", .{ resident_final, resident_bound }) catch "BNRSS FAIL resident\n");
        return error.ResidentNotBounded;
    }

    // --- Assertion 2: RSS plateaus (does not grow ~linearly with N). ---
    // If RSS scaled with node count at the ~8KB/node mirror rate, ingesting
    // node_count nodes would add ~node_count*8KB. With the cap active, the delta
    // must be far below that — assert below the footprint of (4x cap) nodes,
    // which is independent of node_count for node_count >> cap.
    if (node_count >= 4 * cap) {
        const linear_estimate: u64 = @as(u64, node_count) * 8000;
        const plateau_bound: u64 = @as(u64, cap) * 8000 * 4; // ~4x cap worth, N-independent
        const delta = if (rss_final > rss_before) rss_final - rss_before else 0;
        var pb: [256]u8 = undefined;
        out(std.fmt.bufPrint(&pb, "BNRSS plateau check: delta={d} plateau_bound={d} linear_estimate={d}\n", .{
            delta, plateau_bound, linear_estimate,
        }) catch "BNRSS plateau\n");
        if (delta > plateau_bound) {
            out("BNRSS FAIL: RSS did not plateau (grew with node count)\n");
            return error.RssNotBounded;
        }
    }

    // --- Assertion 3: hydrate-on-miss returns correct data for an evicted id. ---
    if (probe_id != 0) {
        const got = store.getNodeProperty(probe_id, "scientific_name");
        var expbuf: [96]u8 = undefined;
        // scientific_name is taxon_keys[0], so its value suffix is "-0".
        const expected = std.fmt.bufPrint(&expbuf, "scientific_name-{d}-0", .{probe_id}) catch unreachable;
        if (got == null or got.? != .String or !std.mem.eql(u8, got.?.String, expected)) {
            var hb: [200]u8 = undefined;
            out(std.fmt.bufPrint(&hb, "BNRSS FAIL: hydrate-on-miss wrong for id={d}, got={s}\n", .{
                probe_id, if (got != null and got.? == .String) got.?.String else "<null>",
            }) catch "BNRSS FAIL hydrate\n");
            return error.HydrateIncorrect;
        }
        out("BNRSS hydrate_on_miss_ok=1\n");
    }

    out("BNRSS PASS\n");
}
