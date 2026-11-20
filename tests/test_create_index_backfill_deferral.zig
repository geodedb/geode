// CANARY: REQ=REQ-ENG-CREATE-INDEX-BACKFILL-OUTSIDE-WRITE-LOCK; FEATURE="AdvancedIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_create_index_backfill_deferral.zig:1; OWNER=index; UPDATED=2026-08-25
//
// CREATE INDEX ran its whole backfill INSIDE the per-graph EXCLUSIVE write
// lock the transport handler holds for a mutating statement, so every
// unrelated write in the database — any label, any session — queued behind a
// full scan of the indexed label (verified >150s of dead air on a large
// graph).
//
// The deferral machinery already existed for the incremental rebuilds
// (ExecutionContext.pending_index_rebuilds, GAP-0511): the QUIC and gRPC
// handlers RELEASE the exclusive lock and only then call rebuildPendingIndexes
// under a SHARED lock. This suite pins that CREATE INDEX now enqueues onto
// that path instead of scanning under the writer lock, and that the backfill
// still lands (the deferral must not silently lose the index contents).
//
// The cross-session liveness assertion ("session B writes a different label
// while session A creates an index and completes within seconds") needs two
// live transport sessions and lives in the harness spec
// create_index_write_liveness.yml. What is asserted HERE is the mechanism the
// liveness depends on, deterministically.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

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
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        // The transport handlers push the context so deferral sites can find
        // the pending-rebuild queue; mirror that here.
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

/// `name` is the runtime key, `<graph>\x1f<index>` (SONNY-6703).
fn vectorIndexDimension(name: []const u8) ?u16 {
    const mgr = index_manager.getGlobalIndexManager() orelse return null;
    const wrapper = mgr.advanced_vector_indexes.get(name) orelse return null;
    // 0 means "no vector has been inserted yet" — the hnsw index is not even
    // allocated until the first insert establishes the dimension.
    return wrapper.dimension;
}

test "CREATE INDEX defers its backfill onto the post-write-lock rebuild queue" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH bkf");
    _ = try h.exec("USE GRAPH bkf");

    // Pre-existing data for the index to backfill.
    _ = try h.exec("CREATE (:BKF {id: 1, emb_b: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");
    _ = try h.exec("CREATE (:BKF {id: 2, emb_b: vectorf32('[0.0, 1.0, 0.0, 0.0]')})");

    // Stand in for the transport handler: install the pending-rebuild queue
    // that the handler drains AFTER releasing the exclusive graph write lock.
    var pending = std.StringHashMap(void).init(testing.allocator);
    defer {
        var it = pending.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        pending.deinit();
    }
    h.ctx.pending_index_rebuilds = &pending;
    h.ctx.pending_index_rebuilds_allocator = testing.allocator;

    _ = try h.exec("CREATE INDEX bkf_idx ON BKF (emb_b) USING vector WITH (metric = 'l2')");

    // The index exists...
    try testing.expect(vectorIndexDimension("bkf\x1fbkf_idx") != null);
    // ...the backfill was ENQUEUED, not run under the writer lock. Before the
    // fix this map stayed empty and the scan happened inline.
    try testing.expectEqual(@as(usize, 1), pending.count());
    try testing.expect(pending.contains("bkf\x1fbkf_idx"));
    // Nothing inserted yet — dimension is still unestablished.
    try testing.expectEqual(@as(u16, 0), vectorIndexDimension("bkf\x1fbkf_idx").?);

    // Draining the queue is what the handler does once the lock is released;
    // the backfill must still land in full.
    const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
    const store = graph_store.getGlobalStore(testing.allocator);
    var it = pending.keyIterator();
    while (it.next()) |k| try mgr.rebuildAdvancedIndex(store, k.*);

    try testing.expectEqual(@as(u16, 4), vectorIndexDimension("bkf\x1fbkf_idx").?);
}

test "with no rebuild queue installed the backfill still runs inline" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH bkf2");
    _ = try h.exec("USE GRAPH bkf2");
    _ = try h.exec("CREATE (:BKF2 {id: 1, emb_c: vectorf32('[1.0, 2.0, 3.0, 4.0]')})");

    // CLI / embedded / test callers hold no transport lock, so there is nobody
    // to unblock and nobody to drain the queue — the backfill must not be
    // silently dropped.
    _ = try h.exec("CREATE INDEX bkf2_idx ON BKF2 (emb_c) USING vector WITH (metric = 'l2')");

    try testing.expectEqual(@as(u16, 4), vectorIndexDimension("bkf2\x1fbkf2_idx").?);
}
