// SONNY-6524: graphs whose shard label dictionaries disagree, on graph-storage
// 0.4.15.
//
// Every label id geode writes into a record on any shard is shard 0's: the
// adapter names labels through a view of shard 0's dictionary or through
// `ShardedGraphEngine.getOrAssignLabel`, which returns shard 0's id. Older
// geode and graph-storage left the other shards' dictionaries out of step with
// shard 0's. 0.4.15 refuses to open such a graph (`LabelDictionaryDiverged`)
// when a record on a disagreeing shard uses a disputed id, unless the caller
// asks for `.adopt_shard0` (rewrite shards 1..15 from shard 0).
//
// Each shape is built in process with the engine calls that produced it, not
// by editing bytes:
//   * old ORDER BY path (geode before 49b9f4cf8): `mg.label_dict.getOrCreate`,
//     i.e. `shards[0].label_dict.getOrAssign` (shard 0, memory only);
//   * old facade (graph-storage <= 0.4.14 `ShardedGraphEngine.getOrAssignLabel`):
//     shard 0's `getOrAssignLabel`, then each other shard's own, one after
//     another, each choosing its own next id; stopping early is a broadcast
//     that failed on that shard (0.4.14 left the name in memory);
//   * a name shard 0 lost (graph-storage <= 0.4.13 wrote labels.dict only at
//     checkpoint and went on to the next shard after one failed): shard 0
//     holds the name in memory only, or drops it with the engine's own
//     `LabelDictionary.unassign`, as reloading its older file would;
// and the records are written through the adapter (the bulk CREATE path,
// `createEdge`), which uses shard 0's id as geode always has.
//
// Checked: the default open refuses every shape and writes nothing; geode
// classifies the shape from the 16 files; with GEODE_LABEL_DICT_ADOPT_SHARD0
// naming the graph, geode opens the shift shapes and every node and edge on
// every shard reads back the label it was created with (geode's view and the
// owning shard's own dictionary), and refuses the shapes in which shard 0
// lost a name (graph-storage's `.adopt_shard0` would drop or rename labels
// there, shown on the library directly); a refused graph does not stop other
// graphs in the same adapter, nor a real server, from serving.
//
// CANARY: REQ=REQ-SONNY-6524-LABEL-DICT-SPLIT; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6524_label_dict_split.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const adapter_mod = geode.graph_storage_adapter;
const divergence = geode.label_dict_divergence;
const StorageAdapter = adapter_mod.StorageAdapter;
const SHARD_COUNT = gs.sharded_engine.SHARD_COUNT;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Nodes per label: consecutive node slots go round-robin over the 16
/// shards, so every shard holds some of each label.
const per_label = 32;
const max_nodes = 8 * per_label;
const max_edges = 32;

const Shape = enum {
    /// ORDER BY named X on shard 0 only; Y and R by the old facade.
    order_by_split,
    /// Before 2026-05-29 every name went through the shard 0 view (A, B);
    /// then Y and Z by the old facade.
    view_then_broadcast,
    /// A 0.4.14 broadcast of Y failed on shard 7: shards 7..15 never got it.
    failed_broadcast,
    /// Shard 0 lost Y, which shards 1..15 kept.
    lost_on_shard0,
    /// Shard 0 lost Y, gave its id to Z, then named Y again.
    lost_then_reordered,
    /// Shard 0 lost Y, the ORDER BY path gave its id to X, then Y named again:
    /// the dictionaries of a shift, the old Y nodes carrying X's id.
    lost_then_reused,
};

const Made = struct {
    nodes: [max_nodes]u64 = undefined,
    labels: [max_nodes][]const u8 = undefined,
    n: usize = 0,
    edge_from: [max_edges]u64 = undefined,
    edge_labels: [max_edges][]const u8 = undefined,
    e: usize = 0,

    fn count(m: *const Made, label: []const u8) u64 {
        var c: u64 = 0;
        for (m.labels[0..m.n]) |l| {
            if (std.mem.eql(u8, l, label)) c += 1;
        }
        return c;
    }
};

const test_cfg: gs.GraphConfig = .{ .page_size = 4096, .buffer_pool_pages = 256, .sync_mode = .deferred };

fn oldOrderBy(mg: *adapter_mod.ManagedGraph, name: []const u8) !void {
    _ = try mg.engine.shards[0].label_dict.getOrAssign(name);
}

fn oldFacade(mg: *adapter_mod.ManagedGraph, name: []const u8, shards: usize) !void {
    _ = try mg.engine.shards[0].getOrAssignLabel(name);
    for (mg.engine.shards[1..shards]) |e| _ = try e.getOrAssignLabel(name);
}

/// Public ids for the nodes written here, clear of any a server minted.
var next_public_id: u64 = 7_000_000_000_000;

/// Through the adapter's bulk CREATE path, with a public id, so a server
/// reading the store sees the nodes. The engine ids of the new nodes are the
/// label's scan after the batch minus its scan before (the scan resolves the
/// label through shard 0's dictionary, whose ids the records carry).
fn nodes(ad: *StorageAdapter, g: []const u8, m: *Made, label: []const u8) !void {
    const before = try ad.getNodesByLabel(g, label, testing.allocator);
    defer testing.allocator.free(before);
    for (0..per_label) |_| {
        next_public_id += 1;
        _ = try ad.bulkInsertNodeWithReservedId(g, next_public_id, &.{label}, &.{});
    }
    const after = try ad.getNodesByLabel(g, label, testing.allocator);
    defer testing.allocator.free(after);
    var added: usize = 0;
    for (after) |id| {
        if (std.mem.indexOfScalar(u64, before, id) != null) continue;
        m.nodes[m.n] = id;
        m.labels[m.n] = label;
        m.n += 1;
        added += 1;
    }
    try testing.expectEqual(@as(usize, per_label), added);
}

fn edges(ad: *StorageAdapter, g: []const u8, m: *Made, label: []const u8) !void {
    // From nodes on every shard to the first node.
    for (m.nodes[0..max_edges]) |from| {
        _ = try ad.createEdge(g, from, m.nodes[0], label);
        m.edge_from[m.e] = from;
        m.edge_labels[m.e] = label;
        m.e += 1;
    }
}

fn build(ad: *StorageAdapter, g: []const u8, shape: Shape, m: *Made) !void {
    const mg = try ad.getOrCreateGraph(g);
    switch (shape) {
        .order_by_split => {
            try oldFacade(mg, "A", SHARD_COUNT);
            try nodes(ad, g, m, "A");
            try oldOrderBy(mg, "X");
            try oldFacade(mg, "Y", SHARD_COUNT);
            try nodes(ad, g, m, "Y");
            try nodes(ad, g, m, "X");
            try oldFacade(mg, "R", SHARD_COUNT);
            try edges(ad, g, m, "R");
        },
        .view_then_broadcast => {
            try oldOrderBy(mg, "A");
            try oldOrderBy(mg, "B");
            try nodes(ad, g, m, "A");
            try nodes(ad, g, m, "B");
            try oldFacade(mg, "Y", SHARD_COUNT);
            try nodes(ad, g, m, "Y");
            try oldFacade(mg, "Z", SHARD_COUNT);
            try nodes(ad, g, m, "Z");
        },
        .failed_broadcast => {
            try oldFacade(mg, "A", SHARD_COUNT);
            try nodes(ad, g, m, "A");
            try oldFacade(mg, "Y", 7);
            try nodes(ad, g, m, "Y");
            try oldFacade(mg, "Z", SHARD_COUNT);
            try nodes(ad, g, m, "Z");
        },
        .lost_on_shard0 => {
            try oldFacade(mg, "A", SHARD_COUNT);
            try nodes(ad, g, m, "A");
            _ = try mg.engine.shards[0].label_dict.getOrAssign("Y");
            for (mg.engine.shards[1..]) |e| _ = try e.getOrAssignLabel("Y");
            try nodes(ad, g, m, "Y");
        },
        .lost_then_reordered => {
            try oldFacade(mg, "A", SHARD_COUNT);
            try nodes(ad, g, m, "A");
            try oldFacade(mg, "Y", SHARD_COUNT);
            try nodes(ad, g, m, "Y");
            mg.engine.shards[0].label_dict.unassign("Y", mg.engine.shards[0].label_dict.getId("Y").?);
            try oldFacade(mg, "Z", SHARD_COUNT);
            try nodes(ad, g, m, "Z");
            try oldFacade(mg, "Y", SHARD_COUNT);
            try nodes(ad, g, m, "Y");
        },
        .lost_then_reused => {
            try oldFacade(mg, "A", SHARD_COUNT);
            try nodes(ad, g, m, "A");
            try oldFacade(mg, "Y", SHARD_COUNT);
            try nodes(ad, g, m, "Y");
            mg.engine.shards[0].label_dict.unassign("Y", mg.engine.shards[0].label_dict.getId("Y").?);
            try oldOrderBy(mg, "X");
            try nodes(ad, g, m, "X");
            try oldFacade(mg, "Y", SHARD_COUNT);
            try nodes(ad, g, m, "Y");
        },
    }
}

/// The 16 labels.dict files of a graph, concatenated, to compare before and
/// after an open.
fn dictBytes(allocator: std.mem.Allocator, data_dir: []const u8, uuid: [16]u8) ![]u8 {
    const root_hex = std.fmt.bytesToHex(uuid, .lower);
    const root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, &root_hex });
    defer allocator.free(root);
    const manifest = try gs.shard_manifest.readFromDir(allocator, root);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (manifest.per_shard_uuids) |su| {
        const hex = std.fmt.bytesToHex(su, .lower);
        const p = try std.fmt.allocPrint(allocator, "{s}/graphs/{s}/labels.dict", .{ root, &hex });
        defer allocator.free(p);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io(), p, allocator, .limited(1 << 20));
        defer allocator.free(bytes);
        try out.appendSlice(allocator, bytes);
        try out.append(allocator, 0xFF);
    }
    return out.toOwnedSlice(allocator);
}

/// Labels of a node the way geode reads them, through `name_of`.
fn nodeLabel(eng: *gs.ShardedGraphEngine, node: u64, dict: *const gs.label_dict.LabelDictionary, buf: *[4]u32) !?[]const u8 {
    const shard = eng.shards[gs.shard_count.shardOfNode(node)];
    const rec = (try eng.getNode(node)) orelse return error.NodeNotFound;
    const ids = try shard.label_store.getLabels(rec.label_head, testing.allocator);
    defer testing.allocator.free(ids);
    if (ids.len != 1) return error.NotOneLabel;
    buf[0] = ids[0];
    return dict.getName(ids[0]);
}

/// Nodes on the library-opened engine whose label, read through their own
/// shard's dictionary or through shard 0's, is not the one they were created
/// with.
fn wrongLabels(eng: *gs.ShardedGraphEngine, m: *const Made) !usize {
    var wrong: usize = 0;
    for (m.nodes[0..m.n], m.labels[0..m.n]) |node, want| {
        var buf: [4]u32 = undefined;
        const owner = eng.shards[gs.shard_count.shardOfNode(node)];
        for ([_]*const gs.label_dict.LabelDictionary{ &owner.label_dict, &eng.shards[0].label_dict }) |d| {
            const got = try nodeLabel(eng, node, d, &buf);
            if (got == null or !std.mem.eql(u8, got.?, want)) wrong += 1;
        }
    }
    return wrong;
}

fn tmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

const graph = "g6524";
const good = "good6524";

fn setAdopt(value: ?[*:0]const u8) void {
    if (value) |v| _ = setenv(divergence.adopt_env, v, 1) else _ = unsetenv(divergence.adopt_env);
}

/// Build `shape` in graph `graph` (and a healthy graph next to it), close,
/// and return the graph's uuid.
fn buildStore(allocator: std.mem.Allocator, path: []const u8, shape: Shape, m: *Made) ![16]u8 {
    const ad = try StorageAdapter.init(allocator, path, test_cfg);
    defer ad.deinit();
    _ = try ad.createNode(good, &.{"Healthy"});
    try build(ad, graph, shape, m);
    return ad.getGraphUuid(graph) orelse error.GraphNotFound;
}

fn expectRefused(allocator: std.mem.Allocator, path: []const u8) !void {
    const ad = try StorageAdapter.init(allocator, path, test_cfg);
    defer ad.deinit();
    try testing.expectError(error.LabelDictionaryDiverged, ad.getNodesByLabel(graph, "A", allocator));
    try testing.expectError(error.LabelDictionaryDiverged, ad.createNode(graph, &.{"A"}));
    // The other graph in the same adapter opens and serves.
    const before = try ad.countNodesByLabel(good, "Healthy");
    try testing.expect(before >= 1);
    _ = try ad.createNode(good, &.{"Healthy"});
    try testing.expectEqual(before + 1, try ad.countNodesByLabel(good, "Healthy"));
}

fn adoptableShape(shape: Shape) !void {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);
    setAdopt(null);
    defer setAdopt(null);

    var m: Made = .{};
    const uuid = try buildStore(allocator, path, shape, &m);
    const before = try dictBytes(allocator, path, uuid);
    defer allocator.free(before);

    // Default: refused, nothing written, and geode names the shape.
    try expectRefused(allocator, path);
    const after_refusal = try dictBytes(allocator, path, uuid);
    defer allocator.free(after_refusal);
    try testing.expectEqualSlices(u8, before, after_refusal);
    try testing.expectEqual(divergence.Shape.shift, try divergence.classify(allocator, path, uuid, null));

    // The operator names the graph: geode opens it, adopting shard 0's names.
    setAdopt(graph ++ ",other");
    {
        const ad = try StorageAdapter.init(allocator, path, test_cfg);
        defer ad.deinit();
        var wrong: usize = 0;
        for (m.nodes[0..m.n], m.labels[0..m.n]) |node, want| {
            const got = try ad.getNodeLabels(graph, node, allocator);
            defer {
                for (got) |s| allocator.free(s);
                allocator.free(got);
            }
            if (got.len != 1 or !std.mem.eql(u8, got[0], want)) wrong += 1;
        }
        for ([_][]const u8{ "A", "B", "X", "Y", "Z" }) |label| {
            const c = try ad.countNodesByLabel(graph, label);
            if (c != m.count(label)) {
                std.debug.print("{s}: label {s} counts {d}, {d} created\n", .{ @tagName(shape), label, c, m.count(label) });
                wrong += 1;
            }
        }
        const mg = try ad.lookupManagedGraph(graph);
        wrong += try wrongLabels(mg.engine, &m);
        for (m.edge_from[0..m.e], m.edge_labels[0..m.e]) |from, want| {
            const out = try ad.getOutgoingEdges(graph, from, allocator);
            defer allocator.free(out);
            const owner = mg.engine.shards[gs.shard_count.shardOfNode(from)];
            for (out) |e| {
                const a = mg.label_dict.getString(e.rel_type) orelse "";
                const b = owner.label_dict.getName(e.rel_type) orelse "";
                if (!std.mem.eql(u8, a, want) or !std.mem.eql(u8, b, want)) wrong += 1;
            }
            if (out.len != 1) wrong += 1;
        }
        // Every shard now has shard 0's dictionary.
        for (mg.engine.shards[1..]) |s| {
            if (s.label_dict.count() != mg.engine.shards[0].label_dict.count()) wrong += 1;
        }
        std.debug.print("SONNY-6524 {s}: {d} nodes, {d} edges, {d} wrong after the adopting open\n", .{ @tagName(shape), m.n, m.e, wrong });
        try testing.expectEqual(@as(usize, 0), wrong);
    }

    // Repaired on disk: opens without the knob.
    setAdopt(null);
    const ad = try StorageAdapter.init(allocator, path, test_cfg);
    defer ad.deinit();
    const ys = try ad.getNodesByLabel(graph, m.labels[m.n - 1], allocator);
    defer allocator.free(ys);
    try testing.expectEqual(m.count(m.labels[m.n - 1]), ys.len);
}

test "SONNY-6524: ORDER BY split: refused by default; adopted on request, every node and edge keeps its label" {
    try adoptableShape(.order_by_split);
}

test "SONNY-6524: names given through the shard 0 view, then broadcast: adopted on request, every node keeps its label" {
    try adoptableShape(.view_then_broadcast);
}

test "SONNY-6524: a 0.4.14 broadcast that failed on shard 7: adopted on request, every node keeps its label" {
    try adoptableShape(.failed_broadcast);
}

/// Shapes in which shard 0 lost a name: geode refuses them even when asked,
/// and graph-storage's `.adopt_shard0` would give nodes a wrong label.
fn lostShape(shape: Shape, want: std.meta.Tag(divergence.Shape)) !void {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);
    setAdopt(null);
    defer setAdopt(null);

    var m: Made = .{};
    const uuid = try buildStore(allocator, path, shape, &m);
    const before = try dictBytes(allocator, path, uuid);
    defer allocator.free(before);
    try testing.expectEqual(want, std.meta.activeTag(try divergence.classify(allocator, path, uuid, null)));

    try expectRefused(allocator, path);
    setAdopt(graph);
    try expectRefused(allocator, path);
    const after = try dictBytes(allocator, path, uuid);
    defer allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);

    // Why: graph-storage's own adoption, on the library directly.
    var cfg = test_cfg;
    cfg.data_dir = path;
    cfg.label_dict_divergence = .adopt_shard0;
    const eng = try gs.ShardedGraphEngine.open(allocator, path, uuid, cfg);
    defer eng.close() catch {};
    const wrong = try wrongLabels(eng, &m);
    std.debug.print("SONNY-6524 {s}: graph-storage .adopt_shard0 leaves {d} node label reads wrong\n", .{ @tagName(shape), wrong });
    try testing.expect(wrong > 0);
}

test "SONNY-6524: shard 0 lost a name the other shards kept: refused even when asked" {
    try lostShape(.lost_on_shard0, .missing_on_shard0);
}

test "SONNY-6524: shard 0 lost a name and gave its id to another: refused even when asked" {
    try lostShape(.lost_then_reordered, .order_differs);
}

test "SONNY-6524: shard 0 lost a name, the ORDER BY path reused its id: indistinguishable from a shift, so not adopted by default" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);
    setAdopt(null);

    var m: Made = .{};
    const uuid = try buildStore(allocator, path, .lost_then_reused, &m);
    // The dictionaries look like an ORDER BY split...
    try testing.expectEqual(divergence.Shape.shift, try divergence.classify(allocator, path, uuid, null));
    // ...so without the operator's say-so it stays closed...
    try expectRefused(allocator, path);
    // ...because adopting shard 0 reads the old Y nodes as X.
    var cfg = test_cfg;
    cfg.data_dir = path;
    cfg.label_dict_divergence = .adopt_shard0;
    const eng = try gs.ShardedGraphEngine.open(allocator, path, uuid, cfg);
    defer eng.close() catch {};
    const wrong = try wrongLabels(eng, &m);
    std.debug.print("SONNY-6524 lost_then_reused: .adopt_shard0 leaves {d} node label reads wrong\n", .{wrong});
    try testing.expect(wrong > 0);
}

// ---------------------------------------------------------------------------
// A real server: a refused graph does not stop the others.
// ---------------------------------------------------------------------------

const Server = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir, "--persist-interval", "300" }, env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.handle.child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            _ = self.handle.child.wait(self.handle.threaded.io()) catch {};
            self.handle.child.id = null;
        }
        self.handle.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        client.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

const Reply = struct {
    count: ?i64 = null,
    failed: bool = false,
    message: [512]u8 = undefined,
    len: usize = 0,

    fn text(r: *const Reply) []const u8 {
        return r.message[0..r.len];
    }
};

fn ask(client: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !Reply {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    var out: Reply = .{};
    if (r.error_code) |code| {
        out.failed = true;
        const s = std.fmt.bufPrint(&out.message, "{s} {s}", .{ code, r.error_message orelse "" }) catch out.message[0..];
        out.len = s.len;
    } else if (r.rows.len == 1 and r.rows[0].len > 0) switch (r.rows[0][0]) {
        .int => |v| out.count = v,
        else => {},
    };
    return out;
}

fn countOn(client: *util.QuicProtoClient, allocator: std.mem.Allocator, g: []const u8, q: []const u8) !Reply {
    var qb: [160]u8 = undefined;
    const use = try ask(client, allocator, try std.fmt.bufPrint(&qb, "USE GRAPH {s}", .{g}));
    if (use.failed) {
        std.debug.print("SONNY-6524 server: USE GRAPH {s} -> {s}\n", .{ g, use.text() });
        return use;
    }
    return ask(client, allocator, q);
}

test "SONNY-6524: a real server serves its other graphs while a diverged graph is refused" {
    const allocator = testing.allocator;
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6524-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io(), data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    setAdopt(null);

    {
        var server = try Server.start(allocator, data_dir, &.{});
        defer server.stop(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        for ([_][]const u8{ "CREATE GRAPH okg", "CREATE GRAPH shiftg", "CREATE GRAPH lostg", "USE GRAPH okg" }) |q| {
            const r = try ask(&client, allocator, q);
            if (r.failed) {
                std.debug.print("{s}: {s}\n", .{ q, r.text() });
                return error.QueryFailed;
            }
        }
        for (0..10) |_| _ = try ask(&client, allocator, "CREATE (:Ok)");
    }
    // The diverged shapes, written in process into two of the server's graphs.
    var m_shift: Made = .{};
    var m_lost: Made = .{};
    {
        const ad = try StorageAdapter.init(allocator, data_dir, .{ .data_dir = data_dir });
        defer ad.deinit();
        try build(ad, "shiftg", .order_by_split, &m_shift);
        try build(ad, "lostg", .lost_on_shard0, &m_lost);
    }

    var refused_shapes: usize = 0;
    {
        var server = try Server.start(allocator, data_dir, &.{});
        defer server.stop(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        for ([_][]const u8{ "shiftg", "lostg" }) |g| {
            for ([_][]const u8{ "MATCH (n) RETURN count(n) AS c", "MATCH (n:A) RETURN count(n) AS c", "CREATE (:New)" }) |q| {
                const r = try countOn(&client, allocator, g, q);
                std.debug.print("SONNY-6524 server, {s}: {s} -> {s}{s}\n", .{ g, q, if (r.failed) "refused: " else "ANSWERED ", r.text() });
                if (r.failed and std.mem.indexOf(u8, r.text(), "LabelDictionaryDiverged") != null) refused_shapes += 1;
            }
            // The healthy graph, from another session. (The session whose
            // current graph is the refused one cannot USE GRAPH away from it:
            // the SONNY-6523 program gate checks the session's current graph.)
            var other = try server.connect(allocator);
            defer other.deinit();
            const ok = try countOn(&other, allocator, "okg", "MATCH (n:Ok) RETURN count(n) AS c");
            std.debug.print("SONNY-6524 server, okg after {s}: {s}{?d}\n", .{ g, ok.text(), ok.count });
            try testing.expectEqual(@as(?i64, 10), ok.count);
        }
    }
    try testing.expectEqual(@as(usize, 6), refused_shapes);

    // The operator names both graphs: the shift opens with its labels, the
    // graph whose shard 0 lost a name stays refused.
    {
        var server = try Server.start(allocator, data_dir, &.{divergence.adopt_env ++ "=shiftg,lostg"});
        defer server.stop(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        for ([_][]const u8{ "A", "X", "Y" }) |label| {
            var qb: [96]u8 = undefined;
            const r = try countOn(&client, allocator, "shiftg", try std.fmt.bufPrint(&qb, "MATCH (n:{s}) RETURN count(n) AS c", .{label}));
            std.debug.print("SONNY-6524 server adopted shiftg: {s} -> {s}{?d} (created {d})\n", .{ label, r.text(), r.count, m_shift.count(label) });
            try testing.expectEqual(@as(?i64, @intCast(m_shift.count(label))), r.count);
        }
        var other = try server.connect(allocator);
        defer other.deinit();
        const lost = try countOn(&other, allocator, "lostg", "MATCH (n) RETURN count(n) AS c");
        std.debug.print("SONNY-6524 server lostg with the knob: {s}\n", .{lost.text()});
        try testing.expect(lost.failed and std.mem.indexOf(u8, lost.text(), "LabelDictionaryDiverged") != null);
        var third = try server.connect(allocator);
        defer third.deinit();
        const ok = try countOn(&third, allocator, "okg", "MATCH (n:Ok) RETURN count(n) AS c");
        try testing.expectEqual(@as(?i64, 10), ok.count);
    }
}
