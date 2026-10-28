// GAP-0869 end-to-end: phrase / proximity full-text search driven entirely
// through GQL against the REAL persisted fts-storage index.
//
//   1. CREATE :Doc nodes with a `body` text property (real nodes, no mocks).
//   2. CREATE INDEX ... USING fulltext — creates the named fts-storage engine
//      and backfills the existing nodes (positions persisted per term).
//   3. CALL geode.fts.phrase('idx', '<phrase>') — only documents with the
//      terms at ADJACENT raw-token ordinals match.
//   4. CALL geode.fts.proximity('idx', '<terms>', <distance>) — only
//      documents where every distinct term falls inside the token window.
//
// Harness mirrors tests/test_fts_e2e.zig (real store + real parser + real
// executor — no mocks).
//
// CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=GQL-E2E; STATUS=TESTED; TEST=tests/test_gap0869_fts_advanced.zig; OWNER=index; UPDATED=2026-06-10

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

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

test "GAP-0869 GQL e2e: geode.fts.phrase matches only adjacent-term documents" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // Two real docs containing the SAME terms; only one has them adjacent.
    {
        var r = try h.runQuery("CREATE (:Doc {body: 'the quick brown fox jumps high'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE (:Doc {body: 'brown quick fox runs'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE INDEX adv_body_idx FOR (d:Doc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // Bag-of-words search cannot tell the docs apart (both match)...
    var adjacent_id: i64 = -1;
    {
        var res = try h.runQuery("CALL geode.fts.search('adv_body_idx', 'quick brown fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 2), res.rows.len);
    }

    // ...but the phrase procedure matches ONLY the adjacent-term doc.
    {
        var res = try h.runQuery("CALL geode.fts.phrase('adv_body_idx', 'quick brown fox')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expect(res.rows[0][0] == .Int);
        try testing.expect(res.rows[0][1] == .Double);
        try testing.expect(res.rows[0][1].Double > 0);
        adjacent_id = res.rows[0][0].Int;
    }

    // The phrase doc must be the one whose body actually contains the
    // adjacent phrase: searching the discriminating term 'jumps' (present
    // only in the adjacent doc) yields the same node id.
    {
        var res = try h.runQuery("CALL geode.fts.search('adv_body_idx', 'jumps')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(adjacent_id, res.rows[0][0].Int);
    }

    // A phrase present in neither document yields no rows.
    {
        var res = try h.runQuery("CALL geode.fts.phrase('adv_body_idx', 'fox quick')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }
}

test "GAP-0869 GQL e2e: geode.fts.proximity honors the token window" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // Tokens: geode@0 supports@1 fast@2 positional@3 queries@4.
    {
        var r = try h.runQuery("CREATE (:Doc {body: 'geode supports fast positional queries'})");
        r.deinit(aa);
    }
    {
        var r = try h.runQuery("CREATE INDEX prox_body_idx FOR (d:Doc) ON (d.body) USING fulltext");
        r.deinit(aa);
    }

    // span(geode, queries) == 4: inside a distance-4 window...
    {
        var res = try h.runQuery("CALL geode.fts.proximity('prox_body_idx', 'geode queries', 4)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expect(res.rows[0][1].Double > 0);
    }
    // ...but outside a distance-3 window.
    {
        var res = try h.runQuery("CALL geode.fts.proximity('prox_body_idx', 'geode queries', 3)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }

    // YIELD projection works on the new procedures too.
    {
        var res = try h.runQuery(
            "CALL geode.fts.proximity('prox_body_idx', 'geode queries', 4) YIELD score",
        );
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(@as(usize, 1), res.columns.len);
    }

    // Fewer than two distinct terms is a hard arg error, not a silent empty set.
    {
        const r = h.runQuery("CALL geode.fts.proximity('prox_body_idx', 'geode', 4)");
        try testing.expectError(error.InvalidArgs, r);
    }
}
