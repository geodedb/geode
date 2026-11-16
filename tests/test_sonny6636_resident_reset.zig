// SONNY-6636 (1): after a graph's files are swapped for restored ones, the
// running store forgets what it held of the old graph.
//
// `StorageAdapter.commitGraphRestore` puts a restored graph's files in place
// while the server runs, but `GraphStore` keeps the graph's resident state:
// nodes and edges, label postings and counts, MERGE entries and the IdMap.
// Hydration re-inserts idempotently and removes nothing, so the old graph's
// nodes stayed visible beside the restored ones, and a MERGE matched a node
// on a value it no longer has. `GraphStore.resetGraphAfterRestore` drops
// them and registers the graph for a build from the new files.
//
// Driven on the real engine-backed global store: a graph is written in one
// data directory, read (hydrated) in another, and the first one's files are
// restored into the second through the adapter's swap, under the store's
// write lock, as the Raft restore does. Both shapes run: a graph restored
// under a uuid new here, and one restored under its own uuid after the source
// moved on (a node's MERGE key changed there).
//
// CANARY: REQ=REQ-SONNY-6636-RESIDENT-RESET; FEATURE="Raft Snapshot Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6636_resident_reset.zig; OWNER=storage; UPDATED=2026-11-16

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const GraphStore = graph_store.GraphStore;
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();

const G = "g6636reset";
const OLD = "Old6636";
const NEW = "New6636";
const KNOWS = "KNOWS6636";

fn open(a: std.mem.Allocator, dir: []const u8) !*GraphStore {
    const store = try graph_store.initGlobalStore(a, dir);
    try store.loadFromFile();
    return store;
}

fn close() void {
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
}

fn copyTree(a: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer d.close(io);
    try std.Io.Dir.cwd().createDirPath(io, dst);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, ".geode.lock")) continue;
        const s = try std.fmt.allocPrint(a, "{s}/{s}", .{ src, e.name });
        defer a.free(s);
        const t = try std.fmt.allocPrint(a, "{s}/{s}", .{ dst, e.name });
        defer a.free(t);
        switch (e.kind) {
            .directory => try copyTree(a, s, t),
            .file => try std.Io.Dir.copyFile(std.Io.Dir.cwd(), s, std.Io.Dir.cwd(), t, io, .{}),
            else => {},
        }
    }
}

/// Graph `G` of the closed data directory `source`: its uuid and its files.
const Source = struct { uuid: [16]u8, dir: []u8 };

fn sourceOf(a: std.mem.Allocator, source: []const u8) !Source {
    _ = try open(a, source);
    defer close();
    const uuid = GraphStore.getGraphUuid(G) orelse return error.SourceGraphMissing;
    const hex = std.fmt.bytesToHex(uuid, .lower);
    return .{ .uuid = uuid, .dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ source, &hex }) };
}

/// Restore `src` into the running store's graph `G` as the Raft restore
/// does: swap the files, then reset the resident state, under the store's
/// write lock.
fn restoreLive(store: *GraphStore, src: Source) !void {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    graph_store.acquireStoreWriteLock();
    defer graph_store.releaseStoreWriteLock();
    var r = try adapter.beginGraphRestore(&.{.{ .name = G, .uuid = src.uuid }});
    defer r.deinit();
    try copyTree(testing.allocator, src.dir, r.staged_dirs[0]);
    try adapter.commitGraphRestore(&r);
    try store.resetGraphAfterRestore(G);
}

fn mergeHolder(store: *GraphStore, label: []const u8, name: []const u8) ?u64 {
    var id: u64 = 0;
    return switch (store.lookupMergeCandidate(G, label, "name", .{ .String = name }, &id)) {
        .found => id,
        else => null,
    };
}

fn nameOf(store: *GraphStore, node_id: u64) !?[]const u8 {
    const v = (try store.getNodePropertyOrError(node_id, "name")) orelse return null;
    return switch (v) {
        .String => |s| s,
        else => error.NotAString,
    };
}

test "SONNY-6636 (1): a graph restored under a uuid new here shows only the restored nodes, edges and MERGE keys, also after a restart" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-reset-new");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const target = try std.fmt.allocPrint(a, "{s}/target", .{root.path()});
    defer a.free(target);
    const source = try std.fmt.allocPrint(a, "{s}/source", .{root.path()});
    defer a.free(source);

    var new_ids: [3]u64 = undefined;
    {
        const store = try open(a, source);
        defer close();
        try store.createGraph(G);
        for (&new_ids, 0..) |*id, i| {
            id.* = try store.createNodeWithGraph(&.{NEW}, G);
            const name = try std.fmt.allocPrint(a, "new{d}", .{i});
            defer a.free(name);
            try store.setNodeProperty(id.*, "name", .{ .String = name });
        }
    }
    const src = try sourceOf(a, source);
    defer a.free(src.dir);

    const store = try open(a, target);
    var closed = false;
    defer if (!closed) close();
    try store.createGraph(G);
    const o1 = try store.createNodeWithGraph(&.{OLD}, G);
    const o2 = try store.createNodeWithGraph(&.{OLD}, G);
    try store.setNodeProperty(o1, "name", .{ .String = "old1" });
    _ = try store.createEdgeWithGraph(o1, o2, KNOWS, G);
    try testing.expectEqual(@as(usize, 2), store.countNodesByLabel(G, OLD, null));
    try testing.expectEqual(@as(usize, 1), store.countEdgesByTypeForGraph(G, KNOWS));
    try testing.expectEqual(@as(?u64, o1), mergeHolder(store, OLD, "old1"));

    try restoreLive(store, src);

    const old_n = store.countNodesByLabel(G, OLD, null);
    const new_n = store.countNodesByLabel(G, NEW, null);
    const edges_n = store.countEdgesByTypeForGraph(G, KNOWS);
    std.debug.print("SONNY-6636 (1) new uuid: after the live restore g has {d} {s}, {d} {s}, {d} {s} edges\n", .{ old_n, OLD, new_n, NEW, edges_n, KNOWS });
    try testing.expectEqual(@as(usize, 0), old_n);
    try testing.expectEqual(@as(usize, 3), new_n);
    try testing.expectEqual(@as(usize, 0), edges_n);
    try testing.expectEqual(@as(?u64, null), mergeHolder(store, OLD, "old1"));
    try testing.expectEqual(@as(?[]const u8, null), try nameOf(store, o1));
    for (new_ids, 0..) |id, i| {
        const want = try std.fmt.allocPrint(a, "new{d}", .{i});
        defer a.free(want);
        try testing.expectEqualStrings(want, (try nameOf(store, id)).?);
        try testing.expectEqual(@as(?u64, id), mergeHolder(store, NEW, want));
    }
    try testing.expectEqual(src.uuid, GraphStore.getGraphUuid(G).?);

    // Writes land in the restored graph and survive a restart with it.
    const added = try store.createNodeWithGraph(&.{NEW}, G);
    try testing.expectEqual(@as(usize, 4), store.countNodesByLabel(G, NEW, null));
    close();
    closed = true;
    {
        const reopened = try open(a, target);
        defer close();
        try testing.expectEqual(@as(usize, 0), reopened.countNodesByLabel(G, OLD, null));
        try testing.expectEqual(@as(usize, 4), reopened.countNodesByLabel(G, NEW, null));
        try testing.expectEqual(@as(usize, 0), reopened.countEdgesByTypeForGraph(G, KNOWS));
        try testing.expect(try reopened.nodeExistsForUndo(added));
    }
}

test "SONNY-6636 (1): a graph restored under its own uuid after the source changed a node's MERGE key matches the node only on its new value" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6636-reset-own");
    defer root.remove();
    defer graph_store.setDataDirOverride(a, null);
    const target = try std.fmt.allocPrint(a, "{s}/target", .{root.path()});
    defer a.free(target);
    const source = try std.fmt.allocPrint(a, "{s}/source", .{root.path()});
    defer a.free(source);

    // Both directories start from the same graph (one replica's files).
    var x: u64 = 0;
    {
        const store = try open(a, target);
        defer close();
        try store.createGraph(G);
        x = try store.createNodeWithGraph(&.{OLD}, G);
        try store.setNodeProperty(x, "name", .{ .String = "a" });
    }
    try copyTree(a, target, source);
    // The source moves on: x is renamed and a node is added.
    {
        const store = try open(a, source);
        defer close();
        try store.setNodeProperty(x, "name", .{ .String = "b" });
        _ = try store.createNodeWithGraph(&.{NEW}, G);
    }
    const src = try sourceOf(a, source);
    defer a.free(src.dir);

    const store = try open(a, target);
    defer close();
    try testing.expectEqual(src.uuid, GraphStore.getGraphUuid(G).?);
    try testing.expectEqual(@as(?u64, x), mergeHolder(store, OLD, "a"));
    try testing.expectEqual(@as(usize, 0), store.countNodesByLabel(G, NEW, null));

    try restoreLive(store, src);

    const holder_a = mergeHolder(store, OLD, "a");
    std.debug.print("SONNY-6636 (1) own uuid: after the live restore MERGE name 'a' finds {?d}, 'b' finds {?d}; {s} = {d}\n", .{ holder_a, mergeHolder(store, OLD, "b"), NEW, store.countNodesByLabel(G, NEW, null) });
    try testing.expectEqual(@as(?u64, null), holder_a);
    try testing.expectEqual(@as(?u64, x), mergeHolder(store, OLD, "b"));
    try testing.expectEqualStrings("b", (try nameOf(store, x)).?);
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, OLD, null));
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel(G, NEW, null));
}
