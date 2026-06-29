// Covered OPTIONAL MATCH left-outer engine-direct regression tests.
//
// GOAL
// ====
// The common single-chain shape
//   MATCH (p {bound}) OPTIONAL MATCH (p)-[:R]->(c) RETURN ...
// must be served ENGINE-DIRECT (storage-native planned-read path) with correct
// openCypher left-outer semantics, WITHOUT the whole-graph deep clone the
// legacy optional executor relies on in the transport path.
//
// OBSERVABLES
// ===========
// - graph_store.getCloneNodesTotal() delta == 0 for the covered shape (no
//   whole-graph clone). It also stays 0 in this in-process harness for the
//   legacy fallback (the legacy executor reads the live store directly), so it
//   acts as a guard, not the RED discriminator.
// - planned_read_runtime.getPathRowsMaterialized() > 0 proves the storage-native
//   (engine-direct) path produced the rows. The legacy executor never
//   increments this counter, so it is the RED discriminator: 0 before the fix,
//   > 0 after.
//
// LEFT-OUTER CORRECTNESS BAR
// ==========================
// - parent with N children -> N rows (one per optional match)
// - parent with 0 children -> exactly ONE row, optional bindings NULL.
//
// CANARY: REQ=REQ-READ-OPTIONAL-LEFTOUTER-ENGINE-DIRECT; FEATURE="OptionalMatchEngineDirect"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_optional_match_engine_direct.zig; OWNER=execution; UPDATED=2026-06-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// Harness (mirrors tests/test_multichain_hashjoin.zig)
// ---------------------------------------------------------------------------

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

    pub fn exec(self: *Harness, query: []const u8) !void {
        var r = try self.runQuery(query);
        r.deinit(self.arena.allocator());
    }

    // p1 -> {c1, c2}; p2 -> {} (childless). All :T nodes carry a `k` string key.
    pub fn seed(self: *Harness) !void {
        try self.exec(
            "CREATE (p1:T {k:'p1'}), (c1:T {k:'c1'}), (c2:T {k:'c2'}), (p2:T {k:'p2'}), " ++
                "(p1)-[:R]->(c1), (p1)-[:R]->(c2)",
        );
    }
};

fn strEq(v: Value, expected: []const u8) bool {
    return switch (v) {
        .Str => |s| std.mem.eql(u8, s, expected),
        else => false,
    };
}

fn isNull(v: Value) bool {
    return switch (v) {
        .Null => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Test 1: parent WITH children -> N rows, engine-direct, no clone.
// ---------------------------------------------------------------------------
test "covered OPTIONAL MATCH (parent with children) is engine-direct, N rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T) RETURN p.k, c.k");
    defer r.deinit(h.arena.allocator());

    // p1 has two children -> two rows.
    try testing.expectEqual(@as(usize, 2), r.rows.len);

    // Both rows are (p1, c?) with c in {c1, c2}, no duplicates.
    var saw_c1 = false;
    var saw_c2 = false;
    for (r.rows) |row| {
        try testing.expect(row.len >= 2);
        try testing.expect(strEq(row[0], "p1"));
        if (strEq(row[1], "c1")) saw_c1 = true;
        if (strEq(row[1], "c2")) saw_c2 = true;
    }
    try testing.expect(saw_c1 and saw_c2);

    // No whole-graph clone.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    // Engine-direct path produced the rows (RED before fix: 0).
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 2: parent WITHOUT children -> exactly ONE row, optional bindings NULL.
// ---------------------------------------------------------------------------
test "covered OPTIONAL MATCH (childless parent) emits one NULL-filled row" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (p:T {k:'p2'}) OPTIONAL MATCH (p)-[:R]->(c:T) RETURN p.k, c.k");
    defer r.deinit(h.arena.allocator());

    // Exactly one row, with c.k NULL.
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expect(r.rows[0].len >= 2);
    try testing.expect(strEq(r.rows[0][0], "p2"));
    try testing.expect(isNull(r.rows[0][1]));

    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}
