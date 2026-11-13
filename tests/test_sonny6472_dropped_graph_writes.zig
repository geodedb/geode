// SONNY-6472 (2): a write racing a DROP GRAPH never creates the graph again.
//
// The adapter's write entry points (`createNode`, the bulk insert and MERGE
// helpers, `pinOrCreateGraph`) find their graph through `getOrCreateGraph`,
// which created any graph it did not have. A write that reached it after a
// DROP GRAPH (it resolved the name, then the drop ran) brought the dropped
// graph back, with a fresh engine and files, for whoever wrote. It now
// answers GraphNotFound for a name dropped since the adapter opened; CREATE
// GRAPH (`StorageAdapter.createGraph`, through `GraphStore.createGraph`)
// creates it afresh. Lazy creation of a name never dropped stays.
//
// The writers (`createNode`, `bulkInsertNodeWithReservedId`, and
// `pinOrCreateGraph` alone) run on their own threads against the real
// engine-backed adapter while the main thread drops the graph through
// `GraphStore.dropGraph`; each shape repeats the race.
//
// CANARY: REQ=REQ-SONNY-6472-NO-RESURRECT; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6472_dropped_graph_writes.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;
const PropKV = gsa.StorageAdapter.PropKV;

const G = "g6472";
const rounds = 24;
const writers = 4;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Shape = enum { create_node, bulk_insert_node, pin_or_create };

const Writer = struct {
    adapter: *gsa.StorageAdapter,
    store: *graph_store.GraphStore,
    shape: Shape,
    stop: *std.atomic.Value(bool),
    /// Errors other than GraphNotFound (none expected).
    other_errors: std.atomic.Value(usize) = .init(0),
    writes: std.atomic.Value(usize) = .init(0),

    fn noteErr(self: *Writer, err: anyerror) void {
        if (err != error.GraphNotFound) {
            std.debug.print("SONNY-6472 (2) writer {s}: {s}\n", .{ @tagName(self.shape), @errorName(err) });
            _ = self.other_errors.fetchAdd(1, .monotonic);
        }
    }

    fn go(self: *Writer) void {
        const labels = [_][]const u8{"W"};
        while (!self.stop.load(.acquire)) {
            if (self.shape == .create_node) {
                // As the executor writes: under the graph's write lock, which
                // a drop waits for and which fails with GraphNotFound once
                // the graph is gone (SONNY-3122).
                const mg = self.adapter.acquireGraphWriteLockCancelable(G, std.math.maxInt(u64)) catch |err| {
                    self.noteErr(err);
                    continue;
                };
                defer self.adapter.releaseGraphWriteLock(mg);
                _ = self.adapter.createNode(G, &labels) catch |err| {
                    self.noteErr(err);
                    continue;
                };
                _ = self.writes.fetchAdd(1, .monotonic);
                continue;
            }
            // The bulk writers hold a pin on the graph they start on
            // (SONNY-3028), as their coordinator does: a drop during the write
            // frees nothing under it. The write itself then looks its graph
            // up by name, which is the race.
            const pinned = self.adapter.pinOrCreateGraph(G) catch |err| {
                self.noteErr(err);
                continue;
            };
            defer self.adapter.unpinGraph(pinned);
            switch (self.shape) {
                .create_node => unreachable,
                .bulk_insert_node => _ = self.adapter.bulkInsertNodeWithReservedId(G, self.store.reserveNodeId(), &labels, &.{}) catch |err| {
                    self.noteErr(err);
                    continue;
                },
                .pin_or_create => {},
            }
            _ = self.writes.fetchAdd(1, .monotonic);
        }
    }
};

test "SONNY-6472 (2): a write racing a DROP GRAPH fails with GraphNotFound and never creates the graph again; CREATE GRAPH does" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const io = std.Io.Threaded.global_single_threaded.io();

    var resurrected: usize = 0;
    for (std.enums.values(Shape)) |shape| {
        for (0..rounds) |round| {
            try store.createGraph(G);
            var stop = std.atomic.Value(bool).init(false);
            var ws: [writers]Writer = undefined;
            var ts: [writers]std.Thread = undefined;
            for (&ws, &ts) |*w, *t| {
                w.* = .{ .adapter = adapter, .store = store, .shape = shape, .stop = &stop };
                t.* = try std.Thread.spawn(.{}, Writer.go, .{w});
            }
            // Let the writers get going, then drop the graph under them.
            while (ws[0].writes.load(.monotonic) < 4) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            try store.dropGraph(G);
            // Writers keep writing after the drop: none may bring it back.
            try std.Io.sleep(io, .fromMilliseconds(20), .awake);
            stop.store(true, .release);
            for (ts) |t| t.join();
            for (ws) |w| try std.testing.expectEqual(@as(usize, 0), w.other_errors.load(.monotonic));
            if (adapter.graphExists(G)) {
                resurrected += 1;
                std.debug.print("SONNY-6472 (2) {s} round {d}: the dropped graph exists again\n", .{ @tagName(shape), round });
                // Leave the next round a clean slate.
                try store.createGraph(G);
                try store.dropGraph(G);
            }
            // After the race, a write fails and still creates nothing.
            const labels = [_][]const u8{"W"};
            if (!adapter.graphExists(G)) {
                try std.testing.expectError(error.GraphNotFound, adapter.createNode(G, &labels));
                try std.testing.expect(!adapter.graphExists(G));
            }
        }
    }

    // CREATE GRAPH creates a dropped name afresh: empty, and writable.
    try store.createGraph(G);
    try std.testing.expect(adapter.graphExists(G));
    const fresh = try adapter.scanAllNodes(G, allocator);
    defer allocator.free(fresh);
    try std.testing.expectEqual(@as(usize, 0), fresh.len);
    const labels = [_][]const u8{"W"};
    _ = try adapter.createNode(G, &labels);

    // A name never dropped is still created by its first write.
    _ = try adapter.createNode("g6472_lazy", &labels);
    try std.testing.expect(adapter.graphExists("g6472_lazy"));

    if (resurrected > 0) return error.DroppedGraphCreatedAgainByAWrite;
}
