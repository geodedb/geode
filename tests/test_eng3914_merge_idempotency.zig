// CANARY: REQ=REQ-ENG-3914-MERGE-GENERAL-PATH-IDEMPOTENCY; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_eng3914_merge_idempotency.zig:1; OWNER=crud_operations; UPDATED=2026-08-25
//
// ENG-3914 — MERGE created DUPLICATES deterministically. This is not a
// concurrency bug: a single-threaded re-run of the exact same statement
// duplicated the row every time (3 passes -> 3x rows).
//
// `graph_store.merge_prop_index` holds exactly ONE node id per
// (graph, label, key, value) — `putOrUpdate` overwrites. The general MERGE
// path probed only `evaluated_props[0]`, so for a multi-property key whose
// FIRST property is SHARED across rows the bucket holds whichever row was
// written last. When the returned candidate failed full verification the code
// fell through with `index_authoritative` still TRUE, which the next line
// reads as "the index proved the node is absent" and uses to SKIP the
// label-scan fallback — straight into the CREATE branch.
//
// The shapes below are the triage's A–E. Each is run three times and must end
// with exactly the rows one pass would produce, with no duplicate keys.

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

    pub fn countRows(self: *Harness, query: []const u8) !usize {
        const res = try self.exec(query);
        return res.rows.len;
    }

    /// Run a two-statement MERGE pair three times and assert the row count is
    /// what ONE pass would have produced, and that each distinct key resolves
    /// to exactly one row.
    fn assertIdempotent(
        self: *Harness,
        merge_a: []const u8,
        merge_b: []const u8,
        count_all: []const u8,
        count_a: []const u8,
        count_b: []const u8,
    ) !void {
        var pass: usize = 0;
        while (pass < 3) : (pass += 1) {
            _ = try self.exec(merge_a);
            _ = try self.exec(merge_b);
        }
        try testing.expectEqual(@as(usize, 1), try self.countRows(count_a));
        try testing.expectEqual(@as(usize, 1), try self.countRows(count_b));
        try testing.expectEqual(@as(usize, 2), try self.countRows(count_all));
    }
};

test "ENG-3914 shape C: multi-prop key, SHARED first prop, non-scalar SET" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_c");
    _ = try h.exec("USE GRAPH eng3914_c");

    // Both rows share tenant='acme', so both hash to the SAME
    // (graph, label, 'tenant', 'acme') bucket in the single-valued merge index.
    // The non-scalar SET keeps the statement off the bulk fast path (which has
    // composite keys and is immune), so this is the general path.
    try h.assertIdempotent(
        "MERGE (n:MC {tenant: 'acme', code: 'a'}) ON CREATE SET n.tags = ['x']",
        "MERGE (n:MC {tenant: 'acme', code: 'b'}) ON CREATE SET n.tags = ['y']",
        "MATCH (n:MC) RETURN n",
        "MATCH (n:MC {tenant: 'acme', code: 'a'}) RETURN n",
        "MATCH (n:MC {tenant: 'acme', code: 'b'}) RETURN n",
    );
}

test "ENG-3914 shape A: single-prop key (control)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_a");
    _ = try h.exec("USE GRAPH eng3914_a");

    try h.assertIdempotent(
        "MERGE (n:MA {code: 'a'}) ON CREATE SET n.tags = ['x']",
        "MERGE (n:MA {code: 'b'}) ON CREATE SET n.tags = ['y']",
        "MATCH (n:MA) RETURN n",
        "MATCH (n:MA {code: 'a'}) RETURN n",
        "MATCH (n:MA {code: 'b'}) RETURN n",
    );
}

test "ENG-3914 shape B: multi-prop key with a UNIQUE first prop (control)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_b");
    _ = try h.exec("USE GRAPH eng3914_b");

    // First property discriminates, so the single-valued index bucket is never
    // shared — this shape was already idempotent and must stay that way.
    try h.assertIdempotent(
        "MERGE (n:MB {code: 'a', tenant: 'acme'}) ON CREATE SET n.tags = ['x']",
        "MERGE (n:MB {code: 'b', tenant: 'acme'}) ON CREATE SET n.tags = ['y']",
        "MATCH (n:MB) RETURN n",
        "MATCH (n:MB {code: 'a'}) RETURN n",
        "MATCH (n:MB {code: 'b'}) RETURN n",
    );
}

test "ENG-3914 shape D: shared first prop with a SCALAR SET" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_d");
    _ = try h.exec("USE GRAPH eng3914_d");

    try h.assertIdempotent(
        "MERGE (n:MD {tenant: 'acme', code: 'a'}) ON CREATE SET n.v = 1",
        "MERGE (n:MD {tenant: 'acme', code: 'b'}) ON CREATE SET n.v = 2",
        "MATCH (n:MD) RETURN n",
        "MATCH (n:MD {tenant: 'acme', code: 'a'}) RETURN n",
        "MATCH (n:MD {tenant: 'acme', code: 'b'}) RETURN n",
    );
}

test "ENG-3914 shape E: shared first prop with NO SET clause" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_e");
    _ = try h.exec("USE GRAPH eng3914_e");

    try h.assertIdempotent(
        "MERGE (n:ME {tenant: 'acme', code: 'a'})",
        "MERGE (n:ME {tenant: 'acme', code: 'b'})",
        "MATCH (n:ME) RETURN n",
        "MATCH (n:ME {tenant: 'acme', code: 'a'}) RETURN n",
        "MATCH (n:ME {tenant: 'acme', code: 'b'}) RETURN n",
    );
}

test "ENG-3914: many rows sharing one first-property value all stay distinct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_many");
    _ = try h.exec("USE GRAPH eng3914_many");

    const codes = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        for (codes) |code| {
            const q = try std.fmt.allocPrint(
                h.arena.allocator(),
                "MERGE (n:MM {{tenant: 'acme', code: '{s}'}}) ON CREATE SET n.tags = ['t']",
                .{code},
            );
            _ = try h.exec(q);
        }
    }

    try testing.expectEqual(@as(usize, codes.len), try h.countRows("MATCH (n:MM) RETURN n"));
    for (codes) |code| {
        const q = try std.fmt.allocPrint(
            h.arena.allocator(),
            "MATCH (n:MM {{tenant: 'acme', code: '{s}'}}) RETURN n",
            .{code},
        );
        try testing.expectEqual(@as(usize, 1), try h.countRows(q));
    }
}

test "ENG-3914: MERGE still MATCHES an existing row rather than always creating" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3914_match");
    _ = try h.exec("USE GRAPH eng3914_match");

    _ = try h.exec("MERGE (n:MX {tenant: 'acme', code: 'a'}) ON CREATE SET n.origin = 'created'");
    // The second MERGE must take the ON MATCH branch, proving the fallback
    // scan resolves the row rather than the statement merely "not duplicating".
    _ = try h.exec("MERGE (n:MX {tenant: 'acme', code: 'a'}) ON MATCH SET n.origin = 'matched'");

    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:MX) RETURN n"));
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:MX {origin: 'matched'}) RETURN n"));
    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:MX {origin: 'created'}) RETURN n"));
}
