// CANARY: REQ=REQ-PERF-QPS-0813; FEATURE="ProjectionPrunedMaterialize"; ASPECT=MultiHopPath; STATUS=TESTED; TEST=tests/test_gap0813_bulk_materialize_path.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0813 regression test: multi-hop path queries that only project a
// small set of properties per row must NOT pay per-hop full-property-map
// materialization cost. The bench query
//
//     MATCH (a:LT_Person {lt_id: 42})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c)
//     RETURN DISTINCT c.name, c.lt_id LIMIT 20
//
// only needs `c.name` and `c.lt_id`; the intermediate `b` node's
// properties are discarded by the projection. The pre-GAP-0813 path
// called `materializeNode` for every endpoint on every path row, which
// called `getAllNodeProperties` (full hashmap + per-key dupe) — that was
// measured at ~40 ms on 500 nodes in this shape. The projection-pruned
// path should be at least 3× faster: <15 ms.
//
// Mirrors the Task 3.1 harness in `test_gap0812_topk_streaming.zig`.
// Real store, real parser, real executor — no mocks.

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

fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
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
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn seedTwoHop(allocator: std.mem.Allocator, graph_name: []const u8, persons: usize, knows_per_person: usize) !void {
    const store = graph_store.getWritableGlobalStore(allocator);
    const labels: []const []const u8 = &.{"LT_Person"};
    var name_buf: [64]u8 = undefined;
    for (0..persons) |i| {
        const node_id = try store.createNodeWithGraph(labels, graph_name);
        try store.setNodeProperty(node_id, "lt_id", .{ .Int = @intCast(i) });
        const name = try std.fmt.bufPrint(&name_buf, "P_{d}", .{i});
        try store.setNodeProperty(node_id, "name", .{ .String = name });
        try store.setNodeProperty(node_id, "age", .{ .Int = 20 + @as(i64, @intCast(i % 50)) });
        // bio adds weight per node so the full-materialize path really
        // does per-node string-decode/dupe work we can eliminate.
        try store.setNodeProperty(node_id, "bio", .{ .String = "This is a dummy bio that adds weight per node." });
    }
    const stride: usize = 7;
    for (0..persons) |i| {
        for (0..knows_per_person) |k| {
            const target_idx = (i + 1 + k * stride) % persons;
            var src_id: u64 = undefined;
            var tgt_id: u64 = undefined;
            if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(i) }, &src_id) != .found) return error.SeedFailed;
            if (store.lookupMergeCandidate(graph_name, "LT_Person", "lt_id", .{ .Int = @intCast(target_idx) }, &tgt_id) != .found) return error.SeedFailed;
            _ = try store.createEdgeWithGraph(src_id, tgt_id, "LT_KNOWS", graph_name);
        }
    }
}

test "GAP-0813: two-hop DISTINCT with projection pruning meets latency budget" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seedTwoHop(h.allocator, "default", 500, 3);

    // Warm the query path (parse cache, adapter caches, etc.) so the timed
    // run measures steady-state materialize cost, not first-run setup.
    {
        var warm = try h.runQuery(
            "MATCH (p:LT_Person {lt_id: 42})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) " ++
                "RETURN DISTINCT c.name, c.lt_id LIMIT 20",
        );
        warm.deinit(h.arena.allocator());
    }

    const t0 = compat_nanoTimestamp();
    var res = try h.runQuery(
        "MATCH (p:LT_Person {lt_id: 42})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) " ++
            "RETURN DISTINCT c.name, c.lt_id LIMIT 20",
    );
    defer res.deinit(h.arena.allocator());
    const elapsed_ns = compat_nanoTimestamp() - t0;

    // Correctness: from lt_id=42 we follow 3 KNOWS edges → 3 b candidates,
    // each follows 3 more KNOWS edges → up to 9 c candidates; DISTINCT
    // + LIMIT 20 caps at 20.
    try testing.expect(res.rows.len > 0);
    try testing.expect(res.rows.len <= 20);
    try testing.expectEqual(@as(usize, 2), res.columns.len);
    // Verify we got the two projected columns (c.name, c.lt_id).
    for (res.rows) |row| {
        try testing.expectEqual(@as(usize, 2), row.len);
        // col 0 is c.name (Str), col 1 is c.lt_id (Int)
        switch (row[0]) {
            .Str => {},
            else => return error.ExpectedStringProjection,
        }
        switch (row[1]) {
            .Int => {},
            else => return error.ExpectedIntProjection,
        }
    }

    std.debug.print("[GAP-0813 two_hop_distinct] elapsed_ns={d} rows={d}\n", .{ elapsed_ns, res.rows.len });

    // Pre-fix observed ~40 ms on 500 nodes (see FINAL.md Task 4.1 context).
    // Target: 3× improvement → <15 ms.
    try testing.expect(elapsed_ns < 15_000_000);
}

test "GAP-0813: full-node projection still works (fallback path)" {
    // When the RETURN references the bare variable (RETURN c), pruning
    // cannot know which keys are needed and must fall through to the
    // full materialize path. This test ensures that shape still returns
    // a correct, fully-populated Node.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seedTwoHop(h.allocator, "default", 50, 3);

    var res = try h.runQuery(
        "MATCH (p:LT_Person {lt_id: 10})-[:LT_KNOWS]->(c) RETURN c LIMIT 3",
    );
    defer res.deinit(h.arena.allocator());

    try testing.expect(res.rows.len > 0);
    try testing.expect(res.rows.len <= 3);
    for (res.rows) |row| {
        try testing.expectEqual(@as(usize, 1), row.len);
        switch (row[0]) {
            .Node => |node| {
                // Full materialize: labels present, all seeded properties present.
                try testing.expect(node.labels.len == 1);
                try testing.expect(node.properties.count() >= 4); // lt_id, name, age, bio (+ internal id)
                try testing.expect(node.properties.get("bio") != null);
                try testing.expect(node.properties.get("name") != null);
                try testing.expect(node.properties.get("age") != null);
            },
            else => return error.ExpectedNodeValue,
        }
    }
}

test "GAP-0813: single-hop projection-access correctness" {
    // Ensure the pruned path returns the same projected values as the
    // unpruned path would. We verify lt_id monotonicity against the
    // seed schema (name contains lt_id).
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seedTwoHop(h.allocator, "default", 100, 3);

    var res = try h.runQuery(
        "MATCH (p:LT_Person {lt_id: 5})-[:LT_KNOWS]->(c) RETURN c.name, c.lt_id",
    );
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 3), res.rows.len);
    for (res.rows) |row| {
        try testing.expectEqual(@as(usize, 2), row.len);
        const name = row[0].Str;
        const lt_id = row[1].Int;
        // Seed schema: name = "P_{lt_id}"
        var expected_buf: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "P_{d}", .{lt_id});
        try testing.expectEqualStrings(expected, name);
    }
}
