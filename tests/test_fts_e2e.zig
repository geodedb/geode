// CANARY: REQ=REQ-GQL-FTS-E2E-001; FEATURE="Fulltext CREATE/DROP + search end-to-end"; ASPECT=E2E; STATUS=TESTED; TEST=tests/test_fts_e2e.zig; OWNER=index; UPDATED=2026-05-30
//
// A4a end-to-end test: drive full-text search entirely through GQL.
//
//   1. CREATE a couple of :Doc nodes with a `body` text property.
//   2. CREATE INDEX doc_body_idx FOR (d:Doc) ON (d.body) USING fulltext
//      — this creates the NAMED fts-storage engine AND backfills the two
//      pre-existing nodes (the path A4a adds; no DML write hook needed).
//   3. CALL geode.fts.search('doc_body_idx', 'fox') YIELD node, score
//      RETURN node, score — assert the fox node is returned and the dog node is
//      not. This is the ISO/IEC 39075:2024 set-returning surface (CALL … YIELD);
//      `node` is the matching node id (Int), `score` the BM25 score (Double).
//   4. DROP INDEX doc_body_idx; assert SHOW INDEXES no longer lists it.
//
// This exercises the real store + real parser + real executor (no mocks),
// mirroring the gap0811 Harness. The BACKFILL path (nodes created BEFORE the
// index) is what this validates — the node create/update/delete maintenance
// hook follows in A4b.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Harness mirrors tests/test_gap0811_aggregation_fastpath.zig.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
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
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "A4a FTS e2e: CREATE INDEX backfills then CALL geode.fts.search finds the matching node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // 1. Seed two Doc nodes BEFORE the index exists (backfill path).
    {
        var r = try h.runQuery("CREATE (:Doc {body: 'the quick brown fox'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE (:Doc {body: 'lazy dog sleeps'})");
        r.deinit(aa);
    }

    // 2. CREATE the fulltext index — backfills both existing nodes.
    {
        var r = try h.runQuery("CREATE INDEX doc_body_idx FOR (d:Doc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // 3. Search for 'fox' via the CALL … YIELD row-set. The fox node must
    //    appear; the dog node must not. One row per hit; columns node/score.
    {
        var res = try h.runQuery(
            "CALL geode.fts.search('doc_body_idx', 'fox') YIELD node, score RETURN node, score",
        );
        defer res.deinit(aa);

        try testing.expectEqual(@as(usize, 1), res.rows.len);
        // Column 0 = node id (Int), column 1 = score (Double > 0).
        try testing.expect(res.rows[0][0] == .Int);
        try testing.expect(res.rows[0][1] == .Double);
        try testing.expect(res.rows[0][1].Double > 0);
    }

    // A node-id sanity check: 'dog' returns exactly the OTHER node (and not the
    // fox node), proving the two documents were indexed independently.
    var fox_id: i64 = -1;
    {
        var res = try h.runQuery(
            "CALL geode.fts.search('doc_body_idx', 'fox') YIELD node, score RETURN node",
        );
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        fox_id = res.rows[0][0].Int;
    }
    {
        var res = try h.runQuery(
            "CALL geode.fts.search('doc_body_idx', 'dog') YIELD node, score RETURN node",
        );
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        const dog_id = res.rows[0][0].Int;
        try testing.expect(dog_id != fox_id);
    }

    // A query term present in NEITHER document returns no rows.
    {
        var res = try h.runQuery(
            "CALL geode.fts.search('doc_body_idx', 'elephant') YIELD node, score RETURN node",
        );
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }
}

test "A4a FTS e2e: DROP INDEX removes the fulltext index from SHOW INDEXES" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    {
        var r = try h.runQuery("CREATE (:Doc {body: 'the quick brown fox'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE INDEX doc_body_idx FOR (d:Doc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // SHOW INDEXES should list doc_body_idx before the drop.
    {
        var res = try h.runQuery("SHOW INDEXES");
        defer res.deinit(aa);
        try testing.expect(showIndexesContains(res, "doc_body_idx"));
    }

    // Drop it.
    {
        var r = try h.runQuery("DROP INDEX doc_body_idx");
        r.deinit(aa);
    }

    // SHOW INDEXES must no longer list it.
    {
        var res = try h.runQuery("SHOW INDEXES");
        defer res.deinit(aa);
        try testing.expect(!showIndexesContains(res, "doc_body_idx"));
    }

    // And a search against the dropped index must not return the fox node:
    // the engine and its facade are gone. The executor either surfaces the
    // `Unsupported` error from the resolver or yields an empty row-set —
    // accept either, since both prove the index was dropped.
    {
        if (h.runQuery(
            "CALL geode.fts.search('doc_body_idx', 'fox') YIELD node, score RETURN node",
        )) |res_ok| {
            var res = res_ok;
            defer res.deinit(aa);
            try testing.expectEqual(@as(usize, 0), res.rows.len);
        } else |err| {
            try testing.expectEqual(error.Unsupported, err);
        }
    }
}

/// Scan a SHOW INDEXES result for a row containing `name` in any string column.
fn showIndexesContains(res: execution.ExecutionResult, name: []const u8) bool {
    for (res.rows) |row| {
        for (row) |cell| {
            switch (cell) {
                .Str => |s| if (std.mem.indexOf(u8, s, name) != null) return true,
                .Text => |s| if (std.mem.indexOf(u8, s, name) != null) return true,
                else => {},
            }
        }
    }
    return false;
}
