// CANARY: REQ=REQ-GAP-0912-VARLEN-ENDPOINT-UNIFY; FEATURE="VariableLengthPaths"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0912_0913_varlen_semantics.zig:1; OWNER=execution; UPDATED=2026-07-10
//
// Regression tests for:
//
//   GAP-0912 — "same-variable path endpoints not unified at match time".
//   `MATCH p = (n {id:'F'})-[:R*]->(n)` over an acyclic chain returned paths
//   whose endpoints differ (["F","G"], ["F","H"], ["F","G","H"]), breaking
//   the cycle-detection idiom `(n)-[*]-(n) WHERE length(p) > 0` (non-cycles
//   reported as cycles). Reusing one variable at both ends must constrain
//   start == end.
//
//   GAP-0913 — "aggregate over a variable-length pattern silently drops
//   WHERE". `count(p)` over a var-length pattern ignored the attached WHERE
//   clause (the non-aggregated `RETURN p` respected it), returning wrong
//   counts.
//
// Note on path modes: the engine's default (historical) mode is ACYCLIC, so
// finding a real directed cycle requires the explicit SIMPLE mode — the
// positive-control test below spells `MATCH SIMPLE p = ...`.

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

    fn firstInt(res: execution.ExecutionResult) !i64 {
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        return switch (res.rows[0][0]) {
            .Int => |i| i,
            else => error.ExpectedInt,
        };
    }
};

// Acyclic chain F -> G -> H over :R. (Two statements: multi-hop CREATE
// patterns only materialize their first hop on this engine, so the second
// edge is wired via MATCH ... CREATE.)
fn seedChain(h: *Harness, graph: []const u8) !void {
    var buf: [128]u8 = undefined;
    _ = try h.exec(try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{graph}));
    _ = try h.exec(try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph}));
    _ = try h.exec("CREATE (:V {id: 'F'})-[:R]->(:V {id: 'G'})");
    _ = try h.exec("MATCH (g:V {id: 'G'}) CREATE (g)-[:R]->(:V {id: 'H'})");
}

test "GAP-0912: (n)-[*]->(n) over an acyclic chain returns no rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChain(&h, "gap0912a");

    // Bare `*` is 1..inf on this engine, so there is no valid same-endpoint
    // path in an acyclic graph. Before the fix this returned the
    // endpoint-mismatched paths F->G, F->G->H.
    const res = try h.exec("MATCH p = (n:V {id: 'F'})-[:R*]->(n) RETURN length(p) AS len");
    try testing.expectEqual(@as(usize, 0), res.rows.len);
}

test "GAP-0912: cycle-detection idiom no longer reports non-cycles" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChain(&h, "gap0912b");

    const res = try h.exec("MATCH p = (n:V {id: 'F'})-[:R*]->(n) WHERE length(p) > 0 RETURN count(p) AS cycles");
    try testing.expectEqual(@as(i64, 0), try Harness.firstInt(res));
}

test "GAP-0912: a real directed cycle is still found under SIMPLE mode, exactly once" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH gap0912c");
    _ = try h.exec("USE GRAPH gap0912c");
    _ = try h.exec("CREATE (:W {id: 'X'})-[:C]->(:W {id: 'Y'})");
    _ = try h.exec("MATCH (y:W {id: 'Y'}), (x:W {id: 'X'}) CREATE (y)-[:C]->(x)");

    // SIMPLE allows revisiting only the start node, so X->Y->X qualifies.
    // Before the fix this also counted X->Y (endpoints differ) as a "cycle".
    const res = try h.exec("MATCH SIMPLE p = (n:W {id: 'X'})-[:C*]->(n) WHERE length(p) > 0 RETURN count(p) AS cycles");
    try testing.expectEqual(@as(i64, 1), try Harness.firstInt(res));
}

test "GAP-0913: count() over a var-length pattern honors WHERE" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChain(&h, "gap0913a");

    // Filter matches nothing: count must be 0 (it silently ignored the WHERE
    // and returned the unfiltered path count before the fix).
    const res = try h.exec("MATCH p = (a:V {id: 'F'})-[:R*]->(b) WHERE b.id = 'ZZZ' RETURN count(p) AS c");
    try testing.expectEqual(@as(i64, 0), try Harness.firstInt(res));
}

test "GAP-0913: count() over a var-length pattern keeps matching rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChain(&h, "gap0913b");

    // Exactly one path from F ends at H (F->G->H).
    const res = try h.exec("MATCH p = (a:V {id: 'F'})-[:R*]->(b) WHERE b.id = 'H' RETURN count(p) AS c");
    try testing.expectEqual(@as(i64, 1), try Harness.firstInt(res));
}

test "GAP-0913: unfiltered var-length count is unchanged" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChain(&h, "gap0913c");

    // Paths from F with bare `*` (1..inf): F->G and F->G->H.
    const res = try h.exec("MATCH p = (a:V {id: 'F'})-[:R*]->(b) RETURN count(p) AS c");
    try testing.expectEqual(@as(i64, 2), try Harness.firstInt(res));
}

test "GAP-0913: non-aggregated var-length WHERE stays correct (control)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChain(&h, "gap0913d");

    const res = try h.exec("MATCH p = (a:V {id: 'F'})-[:R*]->(b) WHERE b.id = 'ZZZ' RETURN p");
    try testing.expectEqual(@as(usize, 0), res.rows.len);
}
