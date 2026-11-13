// SONNY-6433 item 3: a follower applying a replicated SET or REMOVE drops
// the old text from its full-text indexes, as the leader does.
//
// The fts engine cannot take a word out of one document, so the executor
// (leader or single node) queues every covering index for a rebuild when a
// node loses indexed text (`fts_index_ops.queueRebuildForRemovedText`, a SET
// replacing a string or a REMOVE, SONNY-6368 / SONNY-6421) and rebuilds them
// once at the statement's end (`flushQueuedRebuilds`). A follower applies the committed
// GUPD / GMRG payload with the store mutators directly
// (`cluster_replication.applyUpdatePayload` / `applyMergePayload`): it
// appended the new text but queued nothing, so it kept answering searches
// for the old word the leader no longer finds. The apply now reports lost
// text through the FTS apply seam, and each applied entry ends with the same
// flush, on the apply thread (the follower's only writer: every write on a
// follower is refused, so the fts single-writer contract holds).
//
// Real store, real executor, real fts-storage engine, the real apply
// functions a follower runs (as tests/test_fts_apply_symmetry.zig); no mocks.
//
// CANARY: REQ=REQ-SONNY-6433-FOLLOWER-FTS-REBUILD; FEATURE="DistributedCluster"; ASPECT=FollowerRemovedTextRebuild; STATUS=TESTED; TEST=tests/test_sonny6433_follower_fts_rebuild.zig; OWNER=distributed; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const cr = geode.distributed.cluster_replication;

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], &tmp.sub_path });
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        // The server's one-time registration (src/server/main.zig).
        execution.fts_index_ops.registerFtsApplyHook();

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        var r = try self.runQuery(query);
        r.deinit(self.arena.allocator());
    }

    fn searchCount(self: *Harness, index: []const u8, term: []const u8) !usize {
        const aa = self.arena.allocator();
        const gql = try std.fmt.allocPrint(aa, "CALL geode.fts.search('{s}', '{s}')", .{ index, term });
        var r = try self.runQuery(gql);
        defer r.deinit(aa);
        return r.rows.len;
    }

    /// The one :Doc node.
    fn docId(self: *Harness) !u64 {
        _ = self;
        const store = graph_store.getGlobalStore(testing.allocator);
        const ids = store.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "Doc") orelse return error.DocNodeMissing;
        try testing.expectEqual(@as(usize, 1), ids.len);
        return ids[0];
    }
};

fn expectSearch(h: *Harness, term: []const u8, want: usize) !void {
    const got = try h.searchCount("doc_idx", term);
    if (got != want) std.debug.print("search '{s}' finds {d} documents; expected {d}\n", .{ term, got, want });
    try testing.expectEqual(want, got);
}

test "SONNY-6433: a follower applying a replicated SET drops the replaced text from the index" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc {body: 'stale zraven token'})");
    try expectSearch(&h, "zraven", 1);

    const set_props = [_]cr.Prop{.{ .key = "body", .value = .{ .String = "fresh zosprey token" } }};
    const updates = [_]cr.NodeUpdate{.{ .node_id = try h.docId(), .set_props = &set_props }};
    const payload = try cr.serializeUpdate(a, graph_store.DEFAULT_GRAPH_NAME, &updates);
    defer a.free(payload);
    _ = try cr.applyUpdatePayload(a, graph_store.getGlobalStore(a), payload);

    try expectSearch(&h, "zosprey", 1);
    try expectSearch(&h, "zraven", 0);
    // Words both texts share still find the node.
    try expectSearch(&h, "token", 1);
}

test "SONNY-6433: a follower applying a replicated REMOVE drops the removed text from the index" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc {body: 'removed zheron words', k: 1})");
    try expectSearch(&h, "zheron", 1);

    const removed = [_][]const u8{"body"};
    const updates = [_]cr.NodeUpdate{.{ .node_id = try h.docId(), .remove_props = &removed }};
    const payload = try cr.serializeUpdate(a, graph_store.DEFAULT_GRAPH_NAME, &updates);
    defer a.free(payload);
    _ = try cr.applyUpdatePayload(a, graph_store.getGlobalStore(a), payload);

    try expectSearch(&h, "zheron", 0);
}

// Pinned (already right before the fix): search answers only nodes that
// carry the index's label, so a replicated label removal hides the node.
test "SONNY-6433: a follower applying a replicated label removal drops the node from the label's index" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc:Keep {body: 'labelled zwigeon text'})");
    try expectSearch(&h, "zwigeon", 1);

    const store = graph_store.getGlobalStore(a);
    const ids = store.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "Keep") orelse return error.DocNodeMissing;
    const removed = [_][]const u8{"Doc"};
    const updates = [_]cr.NodeUpdate{.{ .node_id = ids[0], .remove_labels = &removed }};
    const payload = try cr.serializeUpdate(a, graph_store.DEFAULT_GRAPH_NAME, &updates);
    defer a.free(payload);
    _ = try cr.applyUpdatePayload(a, store, payload);

    try expectSearch(&h, "zwigeon", 0);
}

test "SONNY-6433: a follower applying a replicated MERGE ... ON MATCH SET drops the replaced text" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const a = testing.allocator;

    try h.run("CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext");
    try h.run("CREATE (:Doc {k: 1, body: 'merged zcurlew text'})");
    try expectSearch(&h, "zcurlew", 1);

    const props = [_]cr.Prop{.{ .key = "body", .value = .{ .String = "merged zplover text" } }};
    const payload = try cr.serializeMerge(a, graph_store.DEFAULT_GRAPH_NAME, try h.docId(), &props);
    defer a.free(payload);
    _ = try cr.applyMergePayload(a, graph_store.getGlobalStore(a), payload);

    try expectSearch(&h, "zplover", 1);
    try expectSearch(&h, "zcurlew", 0);
}
