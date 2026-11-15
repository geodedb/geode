// SONNY-6595 item 4: a raft snapshot install on a node that restarted and has
// written nothing since rebuilds its fulltext indexes.
//
// `fts_index_ops.rebuildAllFulltextIndexes` (the snapshot-install hook,
// `raft_snapshot_manager.installSnapshotData`) rebuilt the indexes it found in
// each graph's label -> fulltext index registry (`ManagedGraph.fts_label_index`).
// That registry lives in memory; after a restart it is filled by the first
// write-maintenance hook (`armLabelRegistry`, SONNY-6591). A snapshot
// installed before any write found it empty and rebuilt nothing, so the
// engine kept what it held before the install: a node the snapshot restores
// under an id the engine had tombstoned stayed unsearchable, and a node the
// snapshot drops stayed findable.
//
// Real store, catalog, executor, fts-storage engine and snapshot codec; the
// restart tears the process-global state down and reopens the same data
// directory. No mocks.
//
// CANARY: REQ=REQ-SONNY-6595-FTS-SNAPSHOT-AFTER-RESTART; FEATURE="FullText"; ASPECT=SnapshotRebuildArmsRegistry; STATUS=TESTED; TEST=tests/test_sonny6595_fts_snapshot_restart.zig; OWNER=fts; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const snap_mgr = geode.distributed.raft_snapshot_manager;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        // The snapshot-install hook, as the server registers it at startup.
        execution.fts_index_ops.registerFtsApplyHook();
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = .{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// A clean restart: checkpoint, tear the process-global state down,
    /// reopen the same data directory.
    fn restart(self: *Harness) !void {
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        _ = graph_store.getGlobalStore(self.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(self.allocator) };
    }

    fn run(self: *Harness, query: []const u8) !void {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        r.deinit(aa);
    }

    fn searchCount(self: *Harness, term: []const u8) !usize {
        const aa = self.arena.allocator();
        const gql = try std.fmt.allocPrint(aa, "CALL geode.fts.search('doc_idx', '{s}')", .{term});
        var parsed = try geode.parseGql(gql, aa);
        defer parsed.deinit();
        var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        defer r.deinit(aa);
        return r.rows.len;
    }
};

test "SONNY-6595 item 4: a snapshot installed after a restart, before any write, rebuilds the fulltext indexes" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc {body: 'restored zrestored doc'})");
    try testing.expectEqual(@as(usize, 1), try h.searchCount("zrestored"));

    // The snapshot holds the doc.
    const snap = try snap_mgr.createSnapshotData(a, graph_store.getGlobalStore(a));
    defer a.free(snap.data);

    // Deleted after the snapshot: the engine tombstones its id for good, and
    // a node the snapshot does not hold is written and indexed.
    try h.run("MATCH (d:Doc) DETACH DELETE d");
    try h.run("CREATE (:Doc {body: 'dropped zdropped doc'})");
    try testing.expectEqual(@as(usize, 0), try h.searchCount("zrestored"));
    try testing.expectEqual(@as(usize, 1), try h.searchCount("zdropped"));

    // Restart. Nothing is written after it: the registry is not armed.
    try h.restart();
    try testing.expectEqual(@as(usize, 0), try h.searchCount("zrestored"));
    try testing.expectEqual(@as(usize, 1), try h.searchCount("zdropped"));

    // The install restores the doc under its original id and drops the
    // other one; the hook rebuilds every fulltext index from the store.
    const store = graph_store.getGlobalStore(a);
    try snap_mgr.installSnapshotData(a, store, snap.data, snap.checksum);
    const ids = store.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "Doc") orelse return error.RestoredNodeMissing;
    try testing.expectEqual(@as(usize, 1), ids.len);

    const restored = try h.searchCount("zrestored");
    const dropped = try h.searchCount("zdropped");
    std.debug.print("SONNY-6595 item 4: after the install: zrestored {d} (want 1), zdropped {d} (want 0)\n", .{ restored, dropped });
    try testing.expectEqual(@as(usize, 1), restored);
    try testing.expectEqual(@as(usize, 0), dropped);
}
