// SONNY-6452 (1): stores written with page encryption by graph_storage
// <= 0.4.11 (SONNY-6441) lost the last 16 bytes of every encrypted page
// body: the pager wrote the AES-GCM tag over them. graph_storage 0.4.12
// reads such a page (it has no `PageFlags.encrypted` envelope flag) and
// zeroes that tail, so at geode's 8 KiB pages:
//   - every node in slot 169 of a node page lost `label_count`, `flags` and
//     `txn_stamp`: it reads back live with label_count 0 (a deleted one
//     reappears); a node with nothing else in its record (no labels,
//     properties or edges) reads back as an empty slot, i.e. it is gone;
//   - the last two heads of every `adj_in_dir` page read as "no head": the
//     incoming edges of those destination nodes are invisible;
//   - the last entry of every full v1 chain block (339 entries of 24 bytes:
//     entry 338 ends 8 bytes past the tail start) lost its rel_type and its
//     prop_head: the edge reads with the wrong type and no properties, so a
//     typed MATCH misses it and its properties (including the persisted
//     public id of a pre-inline-id edge) are unreachable (SONNY-6461).
//
// The contract (operator surface, the built geode binary):
//   - `geode storage verify --check tde-page-tail` reads the store files
//     without opening the store and reports, per graph and shard, the pages
//     still in the old envelope and the records they damaged; it exits 1
//     while anything is damaged and changes nothing (two runs agree);
//   - `geode storage repair --tde-page-tail` refuses without
//     `--i-have-a-backup` and without the key; with them it restores what
//     is derivable (label_count from the node's label block, txn_stamp,
//     the incoming-edge directory rebuilt from the outgoing edges, and the
//     lost fields of adjacency entries copied back from the same edge's
//     entry in the other direction's chain), names what is not (liveness of
//     slot-169 nodes, nodes whose whole record was the lost tail, an
//     adjacency entry whose mirror lost the same bytes), rewrites the pages
//     in the current envelope, and a verify afterwards is clean; a second
//     repair changes nothing.
//
// The old on-disk format is produced exactly as graph_storage's own
// regression (tests/tde_page_tail.zig at v0.4.12) does: each page is read
// through the current pager and written back in the legacy envelope
// (`PageEncryption.encryptPage`: write_count + 1, tag over the body tail),
// which is byte for byte what a 0.4.11 pager wrote.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");
const logging = @import("logging");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const StorageAdapter = geode.graph_storage_adapter.StorageAdapter;
const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;
const geode_binary = geode_test_bin.geode_exe;

const tde_key = [_]u8{0x52} ** 32;
const tde_key_hex = "52" ** 32;
const graph = "sonny6452";
const page_size: u32 = 8192;
/// Node records per 8 KiB page; slot 169 ends at the page end.
const nodes_per_page: u64 = 170;
/// Incoming-edge directory heads per 8 KiB page; heads 1018 and 1019 end at the page end.
const heads_per_page: u64 = 1020;
/// Entries of a full v1 chain block at 8 KiB; entry 338 reaches the tail.
const v1_cap: usize = 339;
/// The edge type of the v1-block edges.
const v1_type = "V";

// libc setenv/unsetenv: std.c has no binding for them in this Zig; the
// executor reads GEODE_TDE_KEY through std.c.getenv. The module links libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Env = struct { name: []const u8, value: []const u8 };

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn says(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6452 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8, extra: []const Env) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", cwd);
    for (extra) |e| try env.put(e.name, e.value);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(600), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// One edge of the full v1 block.
const V1Edge = struct { edge_id: u64, dst: u64, w: i64 };

/// What the seeded store holds.
const Seed = struct {
    /// Every node id created (sorted).
    ids: []u64,
    /// The source of the three edges (to 1017, 1018 and 1019).
    src: u64,
    /// The source whose outgoing chain is one full v1 block (same shard as `src`).
    v1_src: u64 = 0,
    /// Its edges in append order; the last one is in the tail slot.
    v1_edges: []V1Edge = &.{},
    /// A slot-169 node with labels N and B and a property.
    labelled: u64 = 169,
    /// A slot-169 node that was labelled and then deleted.
    deleted: u64 = 339,
    /// A slot-169 node with nothing but the lost tail in its record.
    bare: u64 = 509,

    fn deinit(self: Seed) void {
        testing.allocator.free(self.ids);
        testing.allocator.free(self.v1_edges);
    }

    fn has(self: Seed, id: u64) bool {
        return std.sort.binarySearch(u64, self.ids, id, orderU64) != null;
    }
};

fn orderU64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

fn openAdapter(data_dir: []const u8, key: ?[32]u8) !*StorageAdapter {
    return StorageAdapter.init(testing.allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = key,
        .sync_mode = .deferred,
    });
}

/// An empty v1 chain block in `file` of `shard`, as a store written before
/// graph_storage 0.2.24 (GAP-ENT-0024, inline public ids) left a chain head.
fn installEmptyV1Block(shard: *gs.GraphEngine, file: gs.FileId) !u64 {
    const fsm = switch (file) {
        .adj_out => &shard.free_space_adj_out,
        .in_idx => &shard.free_space_in_idx,
        else => unreachable,
    };
    const page = try fsm.allocPage();
    const frame = try shard.buffer_pool.pinNew(file, page);
    const bh = gs.edge.EdgeBlockHeader{ .next_block = 0, .count = 0, .kind = 0, .entry_format = gs.edge.ENTRY_FORMAT_V1, .payload_size = 0, .checksum = 0 };
    @memcpy(frame.dataSlice()[gs.page.PAGE_HEADER_SIZE..][0..@sizeOf(gs.edge.EdgeBlockHeader)], std.mem.asBytes(&bh));
    shard.buffer_pool.unpin(shard.buffer_pool.frameIndex(frame), true);
    return page;
}

/// Make an empty v1 block the outgoing chain of `src`.
fn installV1OutHead(shard: *gs.GraphEngine, src: u64) !void {
    const page = try installEmptyV1Block(shard, .adj_out);
    const txn = try shard.beginTxn();
    errdefer shard.abortTxn(txn) catch {};
    var rec = (try shard.getNode(src)) orelse return error.NodeNotFound;
    if (rec.out_head != 0) return error.SourceAlreadyHasEdges;
    rec.out_head = page;
    try shard.putNodeTxn(src, rec, txn);
    try shard.logPagePublic(txn, .adj_out, page);
    try shard.commitTxn(txn);
}

/// Make an empty v1 block the co-located incoming chain of `dst` on `shard`.
fn installV1InHead(shard: *gs.GraphEngine, dst: u64) !void {
    if (try shard.in_head_dir.getHead(dst) != 0) return error.DestinationAlreadyHasEdges;
    const page = try installEmptyV1Block(shard, .in_idx);
    const txn = try shard.beginTxn();
    errdefer shard.abortTxn(txn) catch {};
    const dir_page = try shard.in_head_dir.setHead(dst, page);
    try shard.logPagePublic(txn, .in_dir, dir_page);
    try shard.logPagePublic(txn, .in_idx, page);
    try shard.commitTxn(txn);
}

/// The block header of the first block of `head`'s chain in `file`.
fn chainHeader(shard: *gs.GraphEngine, file: gs.FileId, head: u64) !gs.edge.EdgeBlockHeader {
    const frame = try shard.buffer_pool.pin(file, head);
    defer shard.buffer_pool.unpin(shard.buffer_pool.frameIndex(frame), false);
    return std.mem.bytesToValue(gs.edge.EdgeBlockHeader, frame.dataSlice()[gs.page.PAGE_HEADER_SIZE..][0..@sizeOf(gs.edge.EdgeBlockHeader)]);
}

/// A public id no node or edge of the fixture has (bit 63 clear).
fn legacyPublicId(k: usize) u64 {
    return (@as(u64, 0x5A) << 40) + k;
}

/// Persist a node's public id the way geode does (`persistNodePublicId`),
/// so the executor can return it.
fn persistNodePublicId(adapter: *StorageAdapter, id: u64) !void {
    var buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{x:0>16}", .{(@as(u64, 0x4E) << 40) + id});
    try adapter.setNodeProperty(graph, id, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY, .{ .String = text });
}

/// An edge as geode wrote it before inline public ids (GAP-ENT-0024): an
/// id-less engine edge, its public id persisted as the
/// `__geode_internal_edge_id` property, then the user's property `w`. The
/// caller has turned edge-property slab packing off on the source's shard,
/// as it was before graph_storage 0.2.35 (GAP-0060): a v1 entry holds only a
/// 32-bit property head.
fn createLegacyEdge(adapter: *StorageAdapter, from: u64, to: u64, w: i64, public_id: u64) !u64 {
    const eid = try adapter.createEdge(graph, from, to, v1_type);
    var buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{x:0>16}", .{public_id});
    try adapter.setEdgeProperty(graph, from, to, eid, graph_store.INTERNAL_EDGE_ID_PROPERTY_KEY, .{ .String = text });
    try adapter.setEdgeProperty(graph, from, to, eid, "w", .{ .Int = w });
    return eid;
}

/// Seed a store through geode's StorageAdapter (the engine the server
/// opens): nodes until ids 169, 339, 509, 1017, 1018 and 1019 exist, then
/// give every node but the bare one its persisted public id and label N
/// (the bare one keeps nothing but its tail), give 169 a second label and
/// a property, delete 339, and connect one source to 1017, 1018 and 1019.
/// Then a second source on the same shard gets an outgoing chain that is one
/// full v1 block: 339 pre-inline-id edges of type V, each with a property
/// `w` = its append index, to 339 new nodes labelled N.
fn seedStore(data_dir: []const u8, key: ?[32]u8) !Seed {
    const allocator = testing.allocator;
    const adapter = try openAdapter(data_dir, key);
    defer adapter.deinit();
    var ids: std.ArrayList(u64) = .empty;
    errdefer ids.deinit(allocator);
    const wanted = [_]u64{ 169, 339, 509, 1017, 1018, 1019 };
    var guard: usize = 0;
    while (true) : (guard += 1) {
        if (guard > 8000) return error.SeedIdsNotReached;
        var all = true;
        for (wanted) |w| {
            if (std.mem.indexOfScalar(u64, ids.items, w) == null) all = false;
        }
        if (all) break;
        try ids.append(allocator, try adapter.createNode(graph, &.{}));
    }
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    var seed: Seed = .{ .ids = &.{}, .src = 0 };
    for (ids.items) |id| {
        if (id == seed.bare) continue;
        try persistNodePublicId(adapter, id);
        try adapter.addNodeLabel(graph, id, "N");
    }
    try adapter.addNodeLabel(graph, seed.labelled, "B");
    try adapter.setNodeProperty(graph, seed.labelled, "name", .{ .String = "slot-169" });
    try adapter.deleteNode(graph, seed.deleted);
    // A source that is none of the interesting nodes.
    seed.src = for (ids.items) |id| {
        if (id % nodes_per_page != nodes_per_page - 1 and id != 1017 and id != 1018 and id != 1019) break id;
    } else return error.NoSource;
    for ([_]u64{ 1017, 1018, 1019 }) |dst| _ = try adapter.createEdge(graph, seed.src, dst, "E");

    // The full v1 block. Its source is on src's shard, so the incoming
    // directory pages it writes are the ones already in the report.
    const src_shard = gs.shard_count.shardOfNode(seed.src);
    seed.v1_src = for (ids.items) |id| {
        if (id != seed.src and gs.shard_count.shardOfNode(id) == src_shard and id % nodes_per_page != nodes_per_page - 1 and
            id != seed.deleted and id < 1017) break id;
    } else return error.NoV1Source;
    const mg = try adapter.getOrCreateGraph(graph);
    const shard = mg.shardEngineForNode(seed.v1_src);
    try installV1OutHead(shard, seed.v1_src);
    const slab_packing = shard.config.edge_prop_slab_packing;
    shard.config.edge_prop_slab_packing = false;
    defer shard.config.edge_prop_slab_packing = slab_packing;
    var v1: std.ArrayList(V1Edge) = .empty;
    errdefer v1.deinit(allocator);
    for (0..v1_cap) |k| {
        const d = try adapter.createNode(graph, &.{});
        try persistNodePublicId(adapter, d);
        try adapter.addNodeLabel(graph, d, "N");
        try ids.append(allocator, d);
        const eid = try createLegacyEdge(adapter, seed.v1_src, d, @intCast(k), legacyPublicId(k));
        try v1.append(allocator, .{ .edge_id = eid, .dst = d, .w = @intCast(k) });
    }
    {
        const rec = (try shard.getNode(seed.v1_src)) orelse return error.NodeNotFound;
        const bh = try chainHeader(shard, .adj_out, rec.out_head);
        try testing.expectEqual(gs.edge.ENTRY_FORMAT_V1, bh.entry_format);
        try testing.expectEqual(@as(u16, v1_cap), bh.count);
        try testing.expectEqual(@as(u64, 0), bh.next_block);
        // What each copy of the tail edge holds before the old envelope
        // drops the outgoing one's rel_type and prop_head.
        const last = v1.items[v1.items.len - 1];
        const ix = (try shard.edge_index.get(last.edge_id)) orelse return error.EdgeIndexMissing;
        const in_head = try shard.in_head_dir.getHead(last.dst);
        const mirror = (try shard.adj_in_remote.locateEntry(in_head, last.edge_id)) orelse return error.MirrorMissing;
        std.debug.print("SONNY-6452 fixture: v1 source {d} (shard {d}), tail edge {d} -> {d}: edge index rel_type {d} prop_head {x}; in_idx mirror rel_type {d} prop_head {x}\n", .{ seed.v1_src, src_shard, last.edge_id, last.dst, ix.rel_type, ix.prop_head, mirror.entry.rel_type, mirror.entry.prop_head });
    }
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    seed.ids = try ids.toOwnedSlice(allocator);
    seed.v1_edges = try v1.toOwnedSlice(allocator);
    errdefer seed.deinit();
    try adapter.checkpointAll();
    return seed;
}

/// The store files a page-encrypting pager writes.
const paged_files = [_]gs.FileId{ .nodes, .adj_out, .adj_in, .props, .var_store, .in_idx, .in_dir };

/// Rewrite every written page of every store file under `data_dir` in the
/// pre-0.4.12 envelope, as a graph_storage 0.4.11 pager would have flushed
/// the same frame: the tag over the last 16 body bytes.
fn rewriteInLegacyEnvelope(data_dir: []const u8, key: [32]u8) !usize {
    const allocator = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), data_dir, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var shard_dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (shard_dirs.items) |d| allocator.free(d);
        shard_dirs.deinit(allocator);
    }
    while (try walker.next(fsIo())) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "nodes.store")) continue;
        const parent = std.fs.path.dirname(entry.path) orelse continue;
        try shard_dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, parent }));
    }
    var rewritten: usize = 0;
    const enc = gs.encryption.PageEncryption.init(key);
    for (shard_dirs.items) |shard_dir| {
        for (paged_files) |fid| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shard_dir, gs.file_manager.FILE_NAMES[@intFromEnum(fid)] });
            defer allocator.free(path);
            const file = std.Io.Dir.cwd().openFile(fsIo(), path, .{ .mode = .read_write }) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer file.close(fsIo());
            var pager = gs.pager.Pager.init(file, page_size);
            pager.encryption = enc;
            pager.file_id = fid;
            const pages = (try file.stat(fsIo())).size / page_size;
            var raw: [page_size]u8 = undefined;
            var frame: [page_size]u8 = undefined;
            var pid: u64 = 0;
            while (pid < pages) : (pid += 1) {
                _ = try file.readPositionalAll(fsIo(), &raw, pid * page_size);
                if (std.mem.allEqual(u8, &raw, 0)) continue;
                try pager.readPage(pid, &frame);
                const wc = gs.page.readWriteCount(&frame) + 1;
                gs.page.writeWriteCount(&frame, wc);
                enc.encryptPage(&frame, pid, @intFromEnum(fid), wc);
                try file.writePositionalAll(fsIo(), &frame, pid * page_size);
                rewritten += 1;
            }
        }
    }
    return rewritten;
}

/// Copy the regular files of `src` into `dst` (same relative paths).
fn copyTree(src: []const u8, dst: []const u8) !void {
    const allocator = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), src, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(fsIo())) |entry| {
        const to = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, entry.path });
        defer allocator.free(to);
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(fsIo(), to),
            .file => {
                if (std.fs.path.dirname(to)) |p| try std.Io.Dir.cwd().createDirPath(fsIo(), p);
                const data = try dir.readFileAlloc(fsIo(), entry.path, allocator, .limited(1 << 30));
                defer allocator.free(data);
                try std.Io.Dir.cwd().writeFile(fsIo(), .{ .sub_path = to, .data = data });
            },
            else => {},
        }
    }
}

/// The ids under `field` across every shard of every graph of a report.
fn reportIds(allocator: std.mem.Allocator, report: std.json.Value, field: []const u8) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(allocator);
    const graphs = report.object.get("graphs") orelse return error.ReportHasNoGraphs;
    for (graphs.array.items) |g| {
        const shards = g.object.get("shards") orelse return error.ReportHasNoShards;
        for (shards.array.items) |s| {
            const list = s.object.get(field) orelse return error.ReportFieldMissing;
            for (list.array.items) |v| try out.append(allocator, @intCast(v.integer));
        }
    }
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
    return out.toOwnedSlice(allocator);
}

/// The report's verdict; a report without one fails the test.
fn reportOk(report: std.json.Value) !bool {
    if (report != .object) return error.ReportNotAnObject;
    const v = report.object.get("tde_page_tail_ok") orelse return error.ReportHasNoVerdict;
    return v.bool;
}

/// The number of entries under `field` across every shard of every graph.
fn reportCount(report: std.json.Value, field: []const u8) !u64 {
    var total: u64 = 0;
    const graphs = report.object.get("graphs") orelse return error.ReportHasNoGraphs;
    for (graphs.array.items) |g| {
        for ((g.object.get("shards") orelse return error.ReportHasNoShards).array.items) |s| {
            total += (s.object.get(field) orelse return error.ReportFieldMissing).array.items.len;
        }
    }
    return total;
}

/// The one adjacency entry a report names.
fn onlyAdjacencyEntry(report: std.json.Value) !std.json.Value {
    const graphs = report.object.get("graphs") orelse return error.ReportHasNoGraphs;
    for (graphs.array.items) |g| {
        for ((g.object.get("shards") orelse return error.ReportHasNoShards).array.items) |s| {
            const list = (s.object.get("adjacency_entries") orelse return error.ReportFieldMissing).array.items;
            if (list.len != 0) return list[0];
        }
    }
    return error.NoAdjacencyEntry;
}

/// Old-envelope pages of file `name` summed over every shard of every graph.
fn reportOldPages(report: std.json.Value, name: []const u8) !u64 {
    var total: u64 = 0;
    const graphs = report.object.get("graphs") orelse return error.ReportHasNoGraphs;
    for (graphs.array.items) |g| {
        for ((g.object.get("shards") orelse return error.ReportHasNoShards).array.items) |s| {
            const pages = s.object.get("old_format_pages") orelse return error.ReportFieldMissing;
            total += @intCast((pages.object.get(name) orelse return error.ReportFieldMissing).integer);
        }
    }
    return total;
}

fn expectIds(what: []const u8, got: []const u64, want: []const u64) !void {
    if (!std.mem.eql(u64, got, want)) {
        std.debug.print("SONNY-6452 {s}: got {any}, want {any}\n", .{ what, got, want });
        return error.TestExpectedEqual;
    }
}

/// Parse the single JSON document a command printed on stdout.
fn parseStdout(r: Run, what: []const u8) !std.json.Parsed(std.json.Value) {
    const start = std.mem.indexOfScalar(u8, r.stdout, '{') orelse {
        r.dump(what);
        return error.NoJsonOnStdout;
    };
    return std.json.parseFromSlice(std.json.Value, testing.allocator, std.mem.trimEnd(u8, r.stdout[start..], " \r\n"), .{}) catch |e| {
        r.dump(what);
        return e;
    };
}

/// geode's executor over `data_dir`, opened as the server opens it (the
/// key from GEODE_TDE_KEY), on the fixture's graph.
const Gql = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    /// `live_count_check = false` sets the operator escape hatch
    /// GEODE_DISABLE_HYDRATION_LIVE_COUNT_CHECK=1: the only way geode loads a
    /// graph with a lost node record (REQ-GQL-028 otherwise refuses it).
    fn open(data_dir: []const u8, live_count_check: bool) !Gql {
        if (setenv("GEODE_TDE_KEY", tde_key_hex, 1) != 0) return error.SetenvFailed;
        errdefer _ = unsetenv("GEODE_TDE_KEY");
        if (!live_count_check and setenv("GEODE_DISABLE_HYDRATION_LIVE_COUNT_CHECK", "1", 1) != 0) return error.SetenvFailed;
        errdefer _ = unsetenv("GEODE_DISABLE_HYDRATION_LIVE_COUNT_CHECK");
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, data_dir);
        errdefer {
            execution.cleanupCatalogInstance();
            graph_store.deinitGlobalStore();
            graph_store.setDataDirOverride(testing.allocator, null);
        }
        _ = graph_store.getGlobalStore(testing.allocator);
        if (graph_store.getGlobalAdapter() == null) return error.NoStorageAdapter;
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .session = execution.SessionState.init(testing.allocator),
            .ctx = .{ .catalog = catalog },
        };
    }

    fn close(self: *Gql) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = unsetenv("GEODE_TDE_KEY");
        _ = unsetenv("GEODE_DISABLE_HYDRATION_LIVE_COUNT_CHECK");
        self.arena.deinit();
    }

    /// The rows of `query` (run after `USE GRAPH`), each `a|b`, sorted.
    fn rows(self: *Gql, query: []const u8) ![]const []const u8 {
        const aa = self.arena.allocator();
        self.ctx.session_state = &self.session;
        for ([_][]const u8{ "USE GRAPH " ++ graph, query }, 0..) |q, qi| {
            var parsed = try geode.parseGqlOptions(q, aa, .{});
            defer parsed.deinit();
            const result = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
            if (qi == 0) continue;
            const out = try aa.alloc([]const u8, result.rows.len);
            for (result.rows, out) |row, *o| {
                const cells = try aa.alloc([]const u8, row.len);
                for (row, cells) |cell, *c| c.* = try render(aa, cell);
                o.* = try std.mem.join(aa, "|", cells);
            }
            std.mem.sort([]const u8, out, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            return out;
        }
        unreachable;
    }
};

fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .Str, .Text => |t| try aa.dupe(u8, t),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// What MATCH shows of the v1 block's edges, in both directions.
const V1View = struct {
    out_typed: []const []const u8,
    in_typed: []const []const u8,
    out_sum: []const []const u8,
    in_sum: []const []const u8,
    tail_out: []const []const u8,
    tail_in: []const []const u8,
};

fn viewV1(g: *Gql) !V1View {
    return .{
        .out_typed = try g.rows("MATCH (a)-[r:" ++ v1_type ++ "]->(b) RETURN count(r)"),
        .in_typed = try g.rows("MATCH (b)<-[r:" ++ v1_type ++ "]-(a) RETURN count(r)"),
        .out_sum = try g.rows("MATCH (a)-[r]->(b:N) WHERE r.w >= 0 RETURN count(r), sum(r.w)"),
        .in_sum = try g.rows("MATCH (b:N)<-[r]-(a) WHERE r.w >= 0 RETURN count(r), sum(r.w)"),
        .tail_out = try g.rows("MATCH (a)-[r]->(b) WHERE r.w = 338 RETURN type(r), r.w"),
        .tail_in = try g.rows("MATCH (b)<-[r]-(a) WHERE r.w = 338 RETURN type(r), r.w"),
    };
}

fn printView(what: []const u8, v: V1View) void {
    std.debug.print("SONNY-6452 MATCH {s}: typed out {s} in {s}; count,sum(w) out {s} in {s}; edge w=338 out {s} in {s}\n", .{
        what,
        if (v.out_typed.len == 1) v.out_typed[0] else "?",
        if (v.in_typed.len == 1) v.in_typed[0] else "?",
        if (v.out_sum.len == 1) v.out_sum[0] else "?",
        if (v.in_sum.len == 1) v.in_sum[0] else "?",
        if (v.tail_out.len == 1) v.tail_out[0] else "(none)",
        if (v.tail_in.len == 1) v.tail_in[0] else "(none)",
    });
}

fn expectRows(what: []const u8, got: []const []const u8, want: []const []const u8) !void {
    var same = got.len == want.len;
    if (same) for (got, want) |g, w| {
        same = same and std.mem.eql(u8, g, w);
    };
    if (!same) {
        std.debug.print("SONNY-6452 {s}: got {d} rows:\n", .{ what, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        std.debug.print("want:\n", .{});
        for (want) |w| std.debug.print("  {s}\n", .{w});
        return error.TestExpectedEqual;
    }
}

fn verify(root: []const u8, data_dir: []const u8, key: bool) !Run {
    const env: []const Env = if (key) &.{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }} else &.{};
    return runGeode(&.{ geode_binary, "storage", "verify", "--check", "tde-page-tail", "--data-dir", data_dir }, root, env);
}

test "SONNY-6452 (1) geode storage verify --check tde-page-tail finds the records an old-envelope store lost, and repair --tde-page-tail restores what is derivable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    var root = try test_scratch.ScratchDir.create("sonny6452-page-tail");
    defer root.remove();
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    const control_dir = try std.fmt.allocPrint(allocator, "{s}/control", .{root.path()});
    defer allocator.free(control_dir);

    const seed = try seedStore(data_dir, tde_key);
    defer seed.deinit();
    try testing.expect(seed.has(seed.labelled) and seed.has(seed.deleted) and seed.has(seed.bare));
    const rewritten = try rewriteInLegacyEnvelope(data_dir, tde_key);
    try testing.expect(rewritten > 0);
    try copyTree(data_dir, control_dir);

    // The fixture reproduces the defect: opened by the current engine with
    // no repair, the slot-169 nodes lost their label count, the deleted one
    // is back, the bare one is gone, and the incoming edges to 1018 and
    // 1019 are invisible (1017's, whose head is not in the tail, are not).
    {
        const adapter = try openAdapter(control_dir, tde_key);
        defer adapter.deinit();
        const mg = try adapter.getOrCreateGraph(graph);
        const rec = (try mg.engine.getNode(seed.labelled)) orelse return error.LabelledNodeMissing;
        try testing.expectEqual(@as(u16, 0), rec.label_count);
        try testing.expect((try mg.engine.getNode(seed.deleted)) != null);
        try testing.expect((try mg.engine.getNode(seed.bare)) == null);
        for ([_]u64{ 1017, 1018, 1019 }, [_]bool{ true, false, false }) |dst, visible| {
            const in = try adapter.getIncomingEdges(graph, dst, allocator);
            defer allocator.free(in);
            var found = false;
            for (in) |e| found = found or e.neighbor == seed.src;
            try testing.expectEqual(visible, found);
        }
        // The v1 block's tail entry lost its rel_type and prop_head.
        const out = try adapter.getOutgoingEdges(graph, seed.v1_src, allocator);
        defer allocator.free(out);
        try testing.expectEqual(v1_cap, out.len);
        const last = seed.v1_edges[seed.v1_edges.len - 1];
        for (out) |e| {
            if (e.edge_id != last.edge_id) continue;
            try testing.expectEqual(@as(u32, 0), e.rel_type);
            try testing.expectEqual(@as(u64, 0), e.prop_head);
        }
    }
    // ... and geode shows it. The lost node keeps the graph from loading at
    // all (its shard counts one more live node than it holds) ...
    {
        var g = try Gql.open(control_dir, true);
        defer g.close();
        try testing.expectError(error.DataCorruption, g.rows("MATCH (n:N) RETURN count(n)"));
    }
    // ... and with that check off, the edge is missing from a typed expand in
    // both directions and its type is wrong.
    {
        var g = try Gql.open(control_dir, false);
        defer g.close();
        const v = try viewV1(&g);
        printView("before repair", v);
        try expectRows("before repair: typed outgoing count", v.out_typed, &.{"338"});
        try expectRows("before repair: typed incoming count", v.in_typed, &.{"338"});
        for ([_][]const []const u8{ v.tail_out, v.tail_in }) |tail| {
            try testing.expect(!(tail.len == 1 and std.mem.eql(u8, tail[0], v1_type ++ "|338")));
        }
    }

    // Expected damage: every created slot-169 node but the bare one has an
    // unknown liveness; the bare one is lost; directory heads 1018/1019.
    var unknown_want: std.ArrayList(u64) = .empty;
    defer unknown_want.deinit(allocator);
    for (seed.ids) |id| {
        if (id % nodes_per_page == nodes_per_page - 1 and id != seed.bare) try unknown_want.append(allocator, id);
    }
    const lost_want = [_]u64{seed.bare};
    const heads_want = [_]u64{ heads_per_page - 2, heads_per_page - 1 };

    // verify, twice: the same report, exit 1, nothing changed.
    var first_report: []u8 = &.{};
    defer allocator.free(first_report);
    for (0..2) |round| {
        const r = try verify(root.path(), data_dir, true);
        defer r.deinit();
        if (r.code != @as(?u8, 1)) r.dump("verify an old-envelope store");
        try testing.expectEqual(@as(?u8, 1), r.code);
        const parsed = try parseStdout(r, "verify an old-envelope store");
        defer parsed.deinit();
        const rep = parsed.value;
        try testing.expect(!(try reportOk(rep)));
        try testing.expect(try reportOldPages(rep, "nodes") > 0);
        try testing.expect(try reportOldPages(rep, "in_dir") > 0);
        const unknown = try reportIds(allocator, rep, "nodes_liveness_unknown");
        defer allocator.free(unknown);
        try expectIds("verify: nodes with unknown liveness", unknown, unknown_want.items);
        const lost = try reportIds(allocator, rep, "nodes_lost");
        defer allocator.free(lost);
        try expectIds("verify: lost nodes", lost, &lost_want);
        const heads = try reportIds(allocator, rep, "in_dir_lost_heads");
        defer allocator.free(heads);
        try expectIds("verify: lost incoming-edge directory heads", heads, &heads_want);
        // geode's 8 KiB v2/v3 chain blocks end before the tail; the full v1
        // block's last entry does not.
        {
            const last = seed.v1_edges[seed.v1_edges.len - 1];
            try testing.expectEqual(@as(u64, 1), try reportCount(rep, "adjacency_entries"));
            const e = try onlyAdjacencyEntry(rep);
            try testing.expectEqualStrings("adj_out", e.object.get("file").?.string);
            try testing.expectEqual(@as(i64, v1_cap - 1), e.object.get("slot").?.integer);
            try testing.expectEqual(@as(i64, @intCast(last.edge_id)), e.object.get("edge_id").?.integer);
            try testing.expectEqual(@as(i64, @intCast(last.dst)), e.object.get("neighbor").?.integer);
        }
        if (round == 0) {
            std.debug.print("SONNY-6452 verify (old envelope): exit {?d}, {d} pages rewritten by the fixture, old_format_pages {d} (nodes {d}, in_dir {d}), liveness unknown {any}, lost {any}, lost heads {any}\n", .{
                r.code,                                                                              rewritten,
                (rep.object.get("old_format_pages") orelse return error.ReportFieldMissing).integer, try reportOldPages(rep, "nodes"),
                try reportOldPages(rep, "in_dir"),                                                   unknown,
                lost,                                                                                heads,
            });
            first_report = try allocator.dupe(u8, r.stdout);
        } else if (!std.mem.eql(u8, first_report, r.stdout)) {
            std.debug.print("SONNY-6452: verify is not read-only, the second report differs:\n{s}\n---\n{s}\n", .{ first_report, r.stdout });
            return error.VerifyChangedTheStore;
        }
    }

    // Without the key the records cannot be read: refuse, name the key.
    {
        const r = try verify(root.path(), data_dir, false);
        defer r.deinit();
        const ok = r.code == @as(?u8, 1) and r.says("GEODE_TDE_KEY");
        if (!ok) r.dump("verify without the key");
        try testing.expect(ok);
    }

    // repair without the backup acknowledgement, or without the key: refused,
    // nothing written (the verify report is unchanged).
    {
        const env = [_]Env{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }};
        const no_ack = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--data-dir", data_dir }, root.path(), &env);
        defer no_ack.deinit();
        const ok1 = no_ack.code == @as(?u8, 2) and no_ack.says("--i-have-a-backup");
        if (!ok1) no_ack.dump("repair without --i-have-a-backup");
        try testing.expect(ok1);
        const no_key = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--i-have-a-backup", "--data-dir", data_dir }, root.path(), &.{});
        defer no_key.deinit();
        const ok2 = no_key.code == @as(?u8, 1) and no_key.says("GEODE_TDE_KEY");
        if (!ok2) no_key.dump("repair without the key");
        try testing.expect(ok2);
        const r = try verify(root.path(), data_dir, true);
        defer r.deinit();
        try testing.expectEqualStrings(first_report, r.stdout);
    }

    // repair: exit 0, names what it could not recover, verify is clean after.
    {
        const env = [_]Env{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }};
        const r = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--i-have-a-backup", "--data-dir", data_dir }, root.path(), &env);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("repair");
        try testing.expectEqual(@as(?u8, 0), r.code);
        const parsed = try parseStdout(r, "repair");
        defer parsed.deinit();
        const repaired = parsed.value.object.get("repaired") orelse return error.RepairReportMissing;
        if (std.mem.indexOf(u8, r.stdout, ",\"repaired\":")) |at| {
            const end = std.mem.indexOfScalarPos(u8, r.stdout, at, '}') orelse r.stdout.len - 1;
            std.debug.print("SONNY-6452 repair: liveness unknown {any}, lost {any}{s}\n", .{ unknown_want.items, lost_want, r.stdout[at .. end + 1] });
        }
        try testing.expectEqual(@as(i64, @intCast(unknown_want.items.len)), (repaired.object.get("nodes_repaired") orelse return error.RepairReportMissing).integer);
        // The bare node's page moved to the current envelope (the node stays
        // absent); the source's shard got its directory rebuilt; nothing was
        // left that the repair could not do.
        const Want = struct { field: []const u8, value: i64, at_least: bool = false };
        for ([_]Want{
            .{ .field = "lost_pages_rewritten", .value = 1 },
            .{ .field = "lost_pages_left", .value = 0 },
            .{ .field = "in_dir_rebuilt_shards", .value = 1, .at_least = true },
            .{ .field = "in_dir_blocked_shards", .value = 0 },
            .{ .field = "adjacency_entries_repaired", .value = 1 },
            .{ .field = "node_count_corrected", .value = 1 },
            .{ .field = "adjacency_entries_unrepaired", .value = 0 },
            .{ .field = "graphs_skipped", .value = 0 },
        }) |want| {
            const got = (repaired.object.get(want.field) orelse return error.RepairReportMissing).integer;
            const good = if (want.at_least) got >= want.value else got == want.value;
            if (!good) std.debug.print("SONNY-6452 repair: {s} = {d}, want {s}{d}\n", .{ want.field, got, if (want.at_least) ">= " else "", want.value });
            try testing.expect(good);
        }
        const before = parsed.value.object.get("before") orelse return error.RepairReportMissing;
        const unknown = try reportIds(allocator, before, "nodes_liveness_unknown");
        defer allocator.free(unknown);
        try expectIds("repair: nodes with unknown liveness", unknown, unknown_want.items);
        const lost = try reportIds(allocator, before, "nodes_lost");
        defer allocator.free(lost);
        try expectIds("repair: lost nodes", lost, &lost_want);
        const after = parsed.value.object.get("after") orelse return error.RepairReportMissing;
        try testing.expect(try reportOk(after));
    }
    {
        const r = try verify(root.path(), data_dir, true);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("verify after repair");
        try testing.expectEqual(@as(?u8, 0), r.code);
        const parsed = try parseStdout(r, "verify after repair");
        defer parsed.deinit();
        try testing.expect(try reportOk(parsed.value));
        try testing.expectEqual(@as(u64, 0), try reportOldPages(parsed.value, "in_dir"));
        try testing.expectEqual(@as(u64, 0), try reportCount(parsed.value, "adjacency_entries"));
    }

    // A second repair finds nothing to do and changes nothing.
    {
        const env = [_]Env{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }};
        const r = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--i-have-a-backup", "--data-dir", data_dir }, root.path(), &env);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("second repair");
        try testing.expectEqual(@as(?u8, 0), r.code);
        const parsed = try parseStdout(r, "second repair");
        defer parsed.deinit();
        const repaired = parsed.value.object.get("repaired") orelse return error.RepairReportMissing;
        var it = repaired.object.iterator();
        while (it.next()) |kv| {
            const zero = switch (kv.value_ptr.*) {
                .integer => |n| n == 0,
                .array => |a| a.items.len == 0,
                else => false,
            };
            if (!zero) std.debug.print("SONNY-6452 second repair: {s} is not zero\n", .{kv.key_ptr.*});
            try testing.expect(zero);
        }
    }

    // The repaired store, opened by the engine.
    {
        const adapter = try openAdapter(data_dir, tde_key);
        defer adapter.deinit();
        const mg = try adapter.getOrCreateGraph(graph);
        const rec = (try mg.engine.getNode(seed.labelled)) orelse return error.LabelledNodeMissing;
        try testing.expectEqual(@as(u16, 2), rec.label_count);
        try testing.expectEqual(@as(u64, 1), rec.txn_stamp);
        // Liveness is not derivable: the deleted node stays live (reported,
        // never guessed); the bare node stays gone.
        try testing.expect((try mg.engine.getNode(seed.deleted)) != null);
        try testing.expect((try mg.engine.getNode(seed.bare)) == null);
        for ([_]u64{ 1017, 1018, 1019 }) |dst| {
            const in = try adapter.getIncomingEdges(graph, dst, allocator);
            defer allocator.free(in);
            var found = false;
            for (in) |e| found = found or e.neighbor == seed.src;
            if (!found) std.debug.print("SONNY-6452: incoming edge {d} -> {d} still invisible after repair\n", .{ seed.src, dst });
            try testing.expect(found);
        }
        // Every other node keeps its label.
        for (seed.ids) |id| {
            if (id == seed.bare or id == seed.deleted) continue;
            const labels = try adapter.getNodeLabels(graph, id, allocator);
            defer {
                for (labels) |l| allocator.free(l);
                allocator.free(labels);
            }
            var has_n = false;
            for (labels) |l| has_n = has_n or std.mem.eql(u8, l, "N");
            if (!has_n) std.debug.print("SONNY-6452: node {d} lost label N\n", .{id});
            try testing.expect(has_n);
        }
        // The v1 tail entry is whole again.
        const shard = mg.shardEngineForNode(seed.v1_src);
        const last = seed.v1_edges[seed.v1_edges.len - 1];
        try shard.ensureDerivedHydrated();
        const ix = (try shard.edge_index.get(last.edge_id)) orelse return error.EdgeIndexMissing;
        try testing.expectEqual(mg.label_dict.getId(v1_type).?, ix.rel_type);
        const out = try adapter.getOutgoingEdges(graph, seed.v1_src, allocator);
        defer allocator.free(out);
        try testing.expectEqual(v1_cap, out.len);
        for (out) |e| {
            if (e.edge_id != last.edge_id) continue;
            try testing.expectEqual(ix.rel_type, e.rel_type);
            try testing.expectEqual(ix.prop_head, e.prop_head);
            try testing.expect(e.prop_head != 0);
        }
    }
    // Through MATCH, in both directions: every edge of the block, its type
    // and its property.
    {
        var g = try Gql.open(data_dir, true);
        defer g.close();
        const v = try viewV1(&g);
        printView("after repair", v);
        const sum = std.fmt.comptimePrint("{d}|{d}", .{ v1_cap, (v1_cap - 1) * v1_cap / 2 });
        try expectRows("after repair: typed outgoing count", v.out_typed, &.{std.fmt.comptimePrint("{d}", .{v1_cap})});
        try expectRows("after repair: typed incoming count", v.in_typed, &.{std.fmt.comptimePrint("{d}", .{v1_cap})});
        try expectRows("after repair: outgoing count, sum(w)", v.out_sum, &.{sum});
        try expectRows("after repair: incoming count, sum(w)", v.in_sum, &.{sum});
        try expectRows("after repair: the tail edge, outgoing", v.tail_out, &.{v1_type ++ "|338"});
        try expectRows("after repair: the tail edge, incoming", v.tail_in, &.{v1_type ++ "|338"});
    }
}

test "SONNY-6452 (1) an adjacency entry whose mirror lost the same bytes is reported unrepaired with its reason, and left as it is" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    var root = try test_scratch.ScratchDir.create("sonny6452-mirror-tail");
    defer root.remove();
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);

    // 339 parallel pre-inline-id edges a -> b, both of whose chains are one
    // v1 block: the outgoing and the incoming chain receive the same
    // appends, so the last edge is in the tail slot of both full blocks.
    var a: u64 = 0;
    var last_edge: u64 = 0;
    {
        const adapter = try openAdapter(data_dir, tde_key);
        defer adapter.deinit();
        a = try adapter.createNode(graph, &.{});
        const b = try adapter.createNode(graph, &.{});
        for ([_]u64{ a, b }) |id| {
            try persistNodePublicId(adapter, id);
            try adapter.addNodeLabel(graph, id, "N");
        }
        const mg = try adapter.getOrCreateGraph(graph);
        const shard = mg.shardEngineForNode(a);
        try installV1OutHead(shard, a);
        try installV1InHead(shard, b);
        const slab_packing = shard.config.edge_prop_slab_packing;
        shard.config.edge_prop_slab_packing = false;
        defer shard.config.edge_prop_slab_packing = slab_packing;
        for (0..v1_cap) |k| last_edge = try createLegacyEdge(adapter, a, b, @intCast(k), legacyPublicId(k));
        const out_bh = try chainHeader(shard, .adj_out, ((try shard.getNode(a)) orelse return error.NodeNotFound).out_head);
        const in_bh = try chainHeader(shard, .in_idx, try shard.in_head_dir.getHead(b));
        for ([_]gs.edge.EdgeBlockHeader{ out_bh, in_bh }) |bh| {
            try testing.expectEqual(gs.edge.ENTRY_FORMAT_V1, bh.entry_format);
            try testing.expectEqual(@as(u16, v1_cap), bh.count);
        }
        try adapter.checkpointAll();
    }
    try testing.expect(try rewriteInLegacyEnvelope(data_dir, tde_key) > 0);

    // Twice: the same answer, nothing written to the entries.
    const env = [_]Env{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }};
    for (0..2) |round| {
        const r = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--i-have-a-backup", "--data-dir", data_dir }, root.path(), &env);
        defer r.deinit();
        const parsed = try parseStdout(r, "repair (mirror in the tail)");
        defer parsed.deinit();
        if (round == 0) std.debug.print("SONNY-6452 repair (mirror in the tail): exit {?d}\n{s}\n", .{ r.code, r.stdout });
        const ok = r.code == @as(?u8, 1) and r.says("not repairable");
        if (!ok) r.dump("repair (mirror in the tail)");
        try testing.expect(ok);
        const repaired = parsed.value.object.get("repaired") orelse return error.RepairReportMissing;
        try testing.expectEqual(@as(i64, 0), (repaired.object.get("adjacency_entries_repaired") orelse return error.RepairReportMissing).integer);
        try testing.expectEqual(@as(i64, 2), (repaired.object.get("adjacency_entries_unrepaired") orelse return error.RepairReportMissing).integer);
        const issues = (repaired.object.get("adjacency_unrepaired") orelse return error.RepairReportMissing).array.items;
        try testing.expectEqual(@as(usize, 2), issues.len);
        var files = [_]bool{ false, false };
        for (issues) |is| {
            try testing.expectEqualStrings("mirror_in_tail", is.object.get("reason").?.string);
            try testing.expectEqual(@as(i64, @intCast(last_edge)), is.object.get("edge_id").?.integer);
            try testing.expectEqual(@as(i64, v1_cap - 1), is.object.get("slot").?.integer);
            const file = is.object.get("file").?.string;
            if (std.mem.eql(u8, file, "adj_out")) files[0] = true;
            if (std.mem.eql(u8, file, "in_idx")) files[1] = true;
        }
        try testing.expect(files[0] and files[1]);
        // The shard's incoming directory is not rebuilt over a damaged outgoing entry.
        try testing.expectEqual(@as(i64, 1), (repaired.object.get("in_dir_blocked_shards") orelse return error.RepairReportMissing).integer);
        const after = parsed.value.object.get("after") orelse return error.RepairReportMissing;
        try testing.expect(!(try reportOk(after)));
        try testing.expectEqual(@as(u64, 2), try reportCount(after, "adjacency_entries"));
    }
    const adapter = try openAdapter(data_dir, tde_key);
    defer adapter.deinit();
    const out = try adapter.getOutgoingEdges(graph, a, allocator);
    defer allocator.free(out);
    try testing.expectEqual(v1_cap, out.len);
    for (out) |e| {
        if (e.edge_id != last_edge) continue;
        try testing.expectEqual(@as(u32, 0), e.rel_type);
        try testing.expectEqual(@as(u64, 0), e.prop_head);
    }
}

test "SONNY-6452 (1) a plaintext store has nothing to check and needs no key" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    var root = try test_scratch.ScratchDir.create("sonny6452-plain");
    defer root.remove();
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    const seed = try seedStore(data_dir, null);
    defer seed.deinit();
    const r = try verify(root.path(), data_dir, false);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("verify a plaintext store");
    try testing.expectEqual(@as(?u8, 0), r.code);
    const parsed = try parseStdout(r, "verify a plaintext store");
    defer parsed.deinit();
    try testing.expect(try reportOk(parsed.value));
    try testing.expectEqual(@as(u64, 0), try reportOldPages(parsed.value, "nodes"));
}

test "SONNY-6452 (1) page envelope classification: unwritten, plaintext (CRC), header-tag flag, legacy (flag clear, CRC mismatch)" {
    const tpt = geode.tde_page_tail;
    var page = [_]u8{0} ** page_size;
    try testing.expectEqual(tpt.Envelope.unwritten, tpt.classify(&page));
    page[100] = 7;
    std.mem.writeInt(u32, page[16..20], gs.page.computeChecksum(page[gs.page.PAGE_HEADER_SIZE..]), .little);
    try testing.expectEqual(tpt.Envelope.plaintext, tpt.classify(&page));
    page[100] = 8;
    try testing.expectEqual(tpt.Envelope.legacy, tpt.classify(&page));
    page[gs.page.FLAGS_OFFSET] |= gs.page.FLAG_HEADER_TAG;
    try testing.expectEqual(tpt.Envelope.header_tag, tpt.classify(&page));
}
