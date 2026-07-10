// CANARY: REQ=REQ-GAP-0922-FTS-NUMERIC-PROPERTY-REJECT; FEATURE="FullText"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0922_fts_numeric_property.zig:1; OWNER=fts; UPDATED=2026-07-10
//
// Regression test for GAP-0922: "fulltext index on a numeric property
// silently accepted".
//
// `CREATE INDEX ... ON L(int_prop) USING fulltext` was accepted, built an
// index that matched nothing, and issued no diagnostic. Now, when every
// existing value of the indexed property is non-string, DDL is rejected with
// error.FulltextRequiresTextProperty (SQLSTATE 42804) BEFORE the catalog row
// is written (so a rejected index never appears in SHOW INDEXES). A text
// property still works, and an index-first CREATE (no rows yet) is allowed.

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

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = try graph_store.initGlobalStore(allocator, data_dir);

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
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn indexCount(self: *Harness) usize {
        const cat = self.ctx.catalog;
        const idxs = cat.listAllIndexes(self.allocator) catch return 0;
        defer self.allocator.free(idxs);
        return idxs.len;
    }
};

test "GAP-0922: fulltext index on an exclusively-numeric property is rejected" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Seed integer-scored nodes (no string property).
    _ = try h.exec("CREATE (:P8Num {id: 1, score: 10})");
    _ = try h.exec("CREATE (:P8Num {id: 2, score: 20})");

    const before = h.indexCount();
    try testing.expectError(
        error.FulltextRequiresTextProperty,
        h.exec("CREATE INDEX p8_num_idx ON P8Num (score) USING fulltext"),
    );
    // The rejected index must NOT have been registered in the catalog.
    try testing.expectEqual(before, h.indexCount());
}

test "GAP-0922: fulltext index on a text property still works" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE (:P8Doc {id: 1, body: 'the quick brown fox'})");
    _ = try h.exec("CREATE (:P8Doc {id: 2, body: 'lazy dog sleeps'})");

    var res = try h.exec("CREATE INDEX p8_txt_idx ON P8Doc (body) USING fulltext");
    res.deinit(h.allocator);
}

test "GAP-0922: index-first fulltext CREATE (no rows yet) is allowed" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // No nodes of the label exist — the type cannot be judged, so allow it.
    var res = try h.exec("CREATE INDEX p8_empty_idx ON P8Empty (body) USING fulltext");
    res.deinit(h.allocator);
}
