// geode#875 residual (RC-2b): the vector-index BACKFILL blocks every
// EXCLUSIVE-lock writer in the database for its whole duration.
//
// VERIFIED READ-ONLY against this branch before the fix:
//
//   `rebuildPendingIndexes` (src/server/quic_connection_handler.zig:415-429,
//   and its byte-for-byte clone at src/transport/grpc_server.zig:184-195)
//   acquires the per-graph rwlock SHARED at :423 and HOLDS IT across the whole
//   `IndexManager.rebuildAdvancedIndexCounted` call — which drops the index,
//   recreates it EMPTY, and then runs `populateAdvancedIndex`
//   (src/index/index_manager.zig:2055-2088): a full hydrating scan of every
//   persisted node id plus an HNSW insert per row. Measured ~90 s at
//   4 000 nodes x 256 dims. `StorageAdapter.acquireGraphWriteLock`
//   (src/storage/graph_storage_adapter.zig:9902-9938) spins until readers
//   drain, so EVERY unrelated writer — any label, any session — stalls for the
//   entire build. The CREATE INDEX backfill deferral (GAP / see
//   tests/test_create_index_backfill_deferral.zig) moved the scan OUT of the
//   exclusive lock; it did not stop it from pinning a shared lock for ~90 s,
//   which is the same stall for anyone who needs the exclusive one.
//
//   Two further consequences of the current drop-then-repopulate shape:
//     * the index is EMPTY for readers for the whole build window (it is
//       dropped and recreated before a single row is re-inserted), and
//     * there is no window bookkeeping at all, so a concurrent write cannot be
//       captured once the build stops running under a lock.
//
// THE FIX SHAPE this suite pins (mirroring the fts-storage rebuild window,
// src/storage/fts_storage_adapter.zig:522-600, tested by
// tests/test_fts_rebuild.zig): take the SHARED lock only long enough to
// snapshot the id set, hydrate + build a SHADOW `VectorIndexWrapper` with NO
// graph lock held, then swap it in under `rebuild_mutex` — and bracket the
// whole thing with a rebuild window so writes that land mid-build are not lost
// against the snapshot:
//
//   pub fn beginRebuild(self: *IndexManager, index_name: []const u8) !void
//       // error.RebuildInProgress if `index_name` is already rebuilding.
//   pub fn noteWriteDuringRebuild(self: *IndexManager, index_name: []const u8,
//                                 entity_id: u64) bool
//       // true when the id was captured into the pending set (deduped).
//   pub fn endRebuild(self: *IndexManager, index_name: []const u8,
//                     allocator: std.mem.Allocator) ![]u64
//       // clears the flag and returns the drained pending ids (caller frees);
//       // the drain is re-applied via `tryIncrementalInsertForProperty`.
//
// The cross-session WIRE liveness assertion ("an unrelated session writes while
// a 3 000-row x 256-dim backfill is in flight and finishes inside seconds")
// needs two live transport sessions and lives in the harness spec
// create_index_write_liveness.yml. What is asserted HERE is the mechanism that
// liveness depends on, deterministically and without wall-clock timing.
//
// CANARY: REQ=REQ-GEODE-875-NONBLOCKING-BACKFILL; FEATURE="VectorIndex"; ASPECT=RebuildWindowApi; STATUS=TESTED; TEST=tests/test_geode875_nonblocking_backfill.zig; OWNER=index; UPDATED=2026-09-01
// CANARY: REQ=REQ-GEODE-875-NONBLOCKING-BACKFILL; FEATURE="VectorIndex"; ASPECT=IndexQueryableDuringRebuild; STATUS=TESTED; TEST=tests/test_geode875_nonblocking_backfill.zig; OWNER=index; UPDATED=2026-09-01
// CANARY: REQ=REQ-GEODE-875-BACKFILL-REPORTS-COUNT; FEATURE="VectorIndex"; ASPECT=BackfillReturnsIndexedCount; STATUS=TESTED; TEST=tests/test_geode875_nonblocking_backfill.zig; OWNER=index; UPDATED=2026-09-01

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const IndexManager = index_manager.IndexManager;

/// Every decl the non-blocking rebuild window needs. Kept as one comptime
/// predicate so the red failure below names the whole missing seam at once.
const has_window_api = @hasDecl(IndexManager, "beginRebuild") and
    @hasDecl(IndexManager, "noteWriteDuringRebuild") and
    @hasDecl(IndexManager, "endRebuild");

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Mirrors tests/test_create_index_backfill_deferral.zig: real store, real
/// catalog, real parser, real executor. The context is PUSHED so every
/// deferral / index-maintenance site sees it exactly as the transport handler
/// arranges it.
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
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn run(self: *Harness, query: []const u8) !void {
        _ = try self.exec(query);
    }

    pub fn nodeId(self: *Harness, query: []const u8) !u64 {
        const res = try self.exec(query);
        if (res.rows.len == 0 or res.rows[0].len == 0) return error.NoNodeId;
        return switch (res.rows[0][0]) {
            .Int => |i| @intCast(i),
            .BigInt => |i| @intCast(i),
            else => error.ExpectedNodeId,
        };
    }
};

fn mgr() *IndexManager {
    return index_manager.getGlobalIndexManager().?;
}

/// Number of entity ids currently resident in the named vector index.
fn indexedCount(name: []const u8) !usize {
    const wrapper = mgr().advanced_vector_indexes.get(name) orelse return error.IndexNotFound;
    return wrapper.ids.count();
}

fn indexContains(name: []const u8, id: u64) !bool {
    const wrapper = mgr().advanced_vector_indexes.get(name) orelse return error.IndexNotFound;
    return wrapper.contains(id);
}

fn seed(h: *Harness, label: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [160]u8 = undefined;
        try h.run(try std.fmt.bufPrint(
            &buf,
            "CREATE (:{s} {{i: {d}, emb: vectorf32([{d}.0, 0.0, 0.0, 0.0])}})",
            .{ label, i, i },
        ));
    }
}

// ===========================================================================
// 1. THE REGRESSION TEST — the rebuild-window API exists and behaves.
//    RED today: IndexManager has no beginRebuild/noteWriteDuringRebuild/
//    endRebuild at all, so the whole non-blocking (shadow-build) rebuild is
//    unimplementable and the backfill keeps a shared graph lock pinned for its
//    entire duration.
// ===========================================================================
test "geode#875 RC-2b: a rebuild window queues concurrent writes and refuses a second rebuild" {
    if (comptime !has_window_api) {
        // FIXER SEAM REQUIRED — see the file header for the exact signatures.
        return error.MissingNonBlockingRebuildApi;
    } else {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH nbf");
        try h.run("USE GRAPH nbf");
        try seed(&h, "NbfDoc", 6);
        try h.run("CREATE INDEX nbf_idx ON NbfDoc (emb) USING vector WITH (metric = 'l2')");
        try testing.expectEqual(@as(usize, 6), try indexedCount("nbf_idx"));

        // Arm the window (what the non-blocking rebuild does before it snapshots
        // the id set and starts building the shadow index).
        try mgr().beginRebuild("nbf_idx");

        // A SECOND rebuild of the same index is refused rather than two builds
        // racing for the same swap slot.
        try testing.expectError(error.RebuildInProgress, mgr().beginRebuild("nbf_idx"));

        // A live write landing inside the window must be captured. Deduped: the
        // same id noted twice drains once.
        try testing.expect(mgr().noteWriteDuringRebuild("nbf_idx", 4242));
        _ = mgr().noteWriteDuringRebuild("nbf_idx", 4242);

        // The index is NOT dropped-then-empty for the duration of the build:
        // readers still see every pre-existing row (that is the whole point of
        // building into a shadow wrapper instead of in place).
        try testing.expectEqual(@as(usize, 6), try indexedCount("nbf_idx"));

        const drained = try mgr().endRebuild("nbf_idx", testing.allocator);
        defer testing.allocator.free(drained);
        try testing.expectEqual(@as(usize, 1), drained.len);
        try testing.expectEqual(@as(u64, 4242), drained[0]);

        // Window closed: notes are no longer captured, and a fresh rebuild is
        // allowed again.
        try testing.expect(!mgr().noteWriteDuringRebuild("nbf_idx", 5150));
        try mgr().beginRebuild("nbf_idx");
        const leftover = try mgr().endRebuild("nbf_idx", testing.allocator);
        defer testing.allocator.free(leftover);
        try testing.expectEqual(@as(usize, 0), leftover.len);
    }
}

// ===========================================================================
// 2. NO LOST WRITE — a node written through the REAL execution path while a
//    rebuild window is armed is captured by the window, so the drain can
//    re-apply it to the freshly swapped-in index. Without this, a shadow build
//    from a pre-write snapshot silently drops the row.
// ===========================================================================
test "geode#875 RC-2b: a real write during the rebuild window is captured by the drain" {
    if (comptime !has_window_api) {
        return error.MissingNonBlockingRebuildApi;
    } else {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH nbf_write");
        try h.run("USE GRAPH nbf_write");
        try seed(&h, "NbfW", 4);
        try h.run("CREATE INDEX nbfw_idx ON NbfW (emb) USING vector WITH (metric = 'l2')");

        try mgr().beginRebuild("nbfw_idx");

        // A genuine statement — the same chokepoint every node property write
        // passes through (execution/property_mutation.zig setNodePropertyFromValue).
        try h.run("CREATE (:NbfW {i: 99, emb: vectorf32([99.0, 0.0, 0.0, 0.0])})");
        const written = try h.nodeId("MATCH (n:NbfW {i: 99}) RETURN id(n)");

        const drained = try mgr().endRebuild("nbfw_idx", testing.allocator);
        defer testing.allocator.free(drained);

        var found = false;
        for (drained) |id| {
            if (id == written) {
                if (found) return error.WriteDuringRebuildQueuedTwice;
                found = true;
            }
        }
        if (!found) {
            std.debug.print(
                "\n[geode#875 RC-2b] node {d} was written while index 'nbfw_idx' was rebuilding but the window drained {d} id(s) and none of them was it — a shadow build from the pre-write snapshot loses this row\n",
                .{ written, drained.len },
            );
            return error.WriteDuringRebuildNotCaptured;
        }
    }
}

// ===========================================================================
// 3. RC-5 (cheap) — the counted backfill reports an ACCURATE count. The real
//    residual is the two `catch {}` drain call sites
//    (quic_connection_handler.zig:428, grpc_server.zig:194) that discard both
//    the count and the error; this pins the value they must stop discarding.
// ===========================================================================
test "geode#875 RC-5: rebuildAdvancedIndexCounted reports the rows it actually indexed" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH nbf_count");
    try h.run("USE GRAPH nbf_count");
    try seed(&h, "NbfC", 7);
    // One extra node carrying the label but NO indexable vector property: it
    // must not be counted.
    try h.run("CREATE (:NbfC {i: 900})");
    try h.run("CREATE INDEX nbfc_idx ON NbfC (emb) USING vector WITH (metric = 'l2')");

    const store = graph_store.getGlobalStore(testing.allocator);
    const indexed = try mgr().rebuildAdvancedIndexCounted(store, "nbfc_idx");
    try testing.expectEqual(@as(usize, 7), indexed);
    try testing.expectEqual(@as(usize, 7), try indexedCount("nbfc_idx"));

    // A rebuild of an index that does not exist reports zero rather than
    // pretending to have indexed something.
    try testing.expectEqual(@as(usize, 0), try mgr().rebuildAdvancedIndexCounted(store, "no_such_idx"));

    // Sanity: the backfilled rows really are addressable in the index.
    const first = try h.nodeId("MATCH (n:NbfC {i: 3}) RETURN id(n)");
    try testing.expect(try indexContains("nbfc_idx", first));
}
