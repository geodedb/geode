// SONNY-1218 (GEO-UP-006) reproduction / regression.
//
// `src/server/node_scan_stream.zig` is the engine-direct streaming fast path
// both transports (`quic_connection_handler.zig`'s `.rows` arm and
// `grpc_server.zig`'s `.rows` arm) try FIRST for a single-node-pattern MATCH
// whose RETURN list is entirely bare variable / property references. It reads
// ONLY the persisted storage adapter (`graph_store.getGlobalAdapter()`).
//
// DEFECT: on an IN-MEMORY deployment (server started WITHOUT `--data-dir`, so
// `global_adapter` is null — see the comment at src/graph_store.zig:1788) the
// `.node` and `.projection` arms of `prepare` had NO adapter guard, and
// `collectMatchingSlotIds` returned an EMPTY slot slice for a null adapter.
// The transports therefore served a SUCCESSFUL (`status_class 00000`) response
// with ZERO rows instead of declining to the executor, which holds the correct
// in-memory answer. A silent wrong answer on the single most common GQL shape.
//
// The `.count` arm at prepare's unfiltered precompute already declined
// (`else return null`), which is why `MATCH (n:L) RETURN count(n)` was right
// while `MATCH (n:L) RETURN n.p` was empty — but a FILTERED count (WHERE or
// inline `{prop: val}`) skipped that precompute and fell into the same empty
// slot collection, so it answered 0.
//
// FIX: one shared guard (`adapterCanServeEngineDirect`) consulted by BOTH
// `prepare` (all three projection modes) and `isEligible` (so the transports'
// snapshot-clone-skip decision stays in agreement with what `prepare` will do).
//
// These tests drive the REAL transport decision sequence via `transportRows`
// below — try `node_scan_stream.prepare`, fall back to the executor when it
// declines — so they fail RED against the pre-fix engine exactly the way the
// wire did, and they assert the WITH-adapter fast path still engages (via the
// `getNodesMaterializedTotal` observability counter) so the fix cannot be
// "achieved" by disabling the fast path outright.
//
// CANARY: REQ=REQ-SONNY-1218-INMEM-SCAN; FEATURE="EngineDirectNodeScanDecline"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1218_in_memory_node_scan.zig; OWNER=engine; UPDATED=2026-09-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Server-shaped harness. `persisted = false` reproduces `geode serve` WITHOUT
/// `--data-dir` (the in-memory deployment): no data-dir override, so
/// `getGlobalAdapter()` stays null. `persisted = true` is the `--data-dir`
/// deployment every pre-existing node_scan_stream harness pins on.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator, persisted: bool) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);

        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer {
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }

        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
            graph_store.setDataDirOverride(allocator, data_dir.?);
        }

        _ = graph_store.getGlobalStore(allocator);

        // Fail LOUD rather than silently testing the wrong deployment shape:
        // a stray GEODE_DATA_DIR in the environment would otherwise turn the
        // in-memory reproduction into a persisted run that cannot fail.
        if (persisted) {
            if (graph_store.getGlobalAdapter() == null) return error.ExpectedPersistedAdapter;
        } else {
            if (graph_store.getGlobalAdapter() != null) return error.ExpectedInMemoryDeployment;
        }

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
        if (self.data_dir) |d| self.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

const Outcome = struct {
    result: execution.ExecutionResult,
    /// true when the engine-direct stream served the rows, false when it
    /// declined and the executor did.
    via_stream: bool,
};

/// Mirrors the `.rows` dispatch both transports run (quic_connection_handler.zig
/// ~:7484, grpc_server.zig ~:2604): try `node_scan_stream.prepare` first and
/// serve its page when it returns a stream; otherwise fall through to the
/// executor. `query_arena` must outlive the returned result — the stream
/// borrows `column_name` from the parsed AST.
fn transportRows(
    h: *Harness,
    aa: std.mem.Allocator,
    query_arena: *std.heap.ArenaAllocator,
    src: []const u8,
) !Outcome {
    const q = try parseQuery(query_arena, src);

    if (try node_scan_stream.prepare(aa, q, h.ctx, &.{}, &.{}, &.{})) |prepared| {
        var stream = prepared;
        defer stream.deinit();
        const page = try stream.buildNextPage(aa, 128);
        return .{ .result = page.result, .via_stream = true };
    }

    return .{ .result = try h.runQuery(src), .via_stream = false };
}

fn seedPeople(h: *Harness, n: usize) !void {
    const aa = h.arena.allocator();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const q = try std.fmt.allocPrint(aa, "CREATE (:Person {{name: 'p{d}', team: 'blue'}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
}

// -------------------------------------------------------------------
// Test 1 — THE DEFECT: property projection on an in-memory deployment.
// `MATCH (n:Person) RETURN n.name` must return the created rows, not an
// empty success.
// -------------------------------------------------------------------
test "SONNY-1218: in-memory MATCH (n:Person) RETURN n.name returns rows" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seedPeople(&h, 3);

    const aa = h.arena.allocator();
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    var outcome = try transportRows(&h, aa, &qa, "MATCH (n:Person) RETURN n.name");
    defer outcome.result.deinit(aa);

    // The engine-direct stream can only read the persisted adapter, which does
    // not exist here — it MUST decline so the executor answers.
    try testing.expect(!outcome.via_stream);
    try testing.expectEqual(@as(usize, 3), outcome.result.rows.len);
    for (outcome.result.rows) |row| {
        try testing.expect(row[0] == .Str);
        try testing.expect(std.mem.startsWith(u8, row[0].Str, "p"));
    }
}

// -------------------------------------------------------------------
// Test 2 — node projection (`RETURN n`) on an in-memory deployment.
// -------------------------------------------------------------------
test "SONNY-1218: in-memory MATCH (n:Person) RETURN n returns nodes" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seedPeople(&h, 2);

    const aa = h.arena.allocator();
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    var outcome = try transportRows(&h, aa, &qa, "MATCH (n:Person) RETURN n");
    defer outcome.result.deinit(aa);

    try testing.expect(!outcome.via_stream);
    try testing.expectEqual(@as(usize, 2), outcome.result.rows.len);
}

// -------------------------------------------------------------------
// Test 3 — inline-map predicate + projection, the exact shape the Go
// driver's integration suite issues after a CREATE.
// -------------------------------------------------------------------
test "SONNY-1218: in-memory inline-map predicate projection returns its row" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seedPeople(&h, 3);

    const aa = h.arena.allocator();
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    var outcome = try transportRows(&h, aa, &qa, "MATCH (n:Person {name: 'p1'}) RETURN n.team");
    defer outcome.result.deinit(aa);

    try testing.expect(!outcome.via_stream);
    try testing.expectEqual(@as(usize, 1), outcome.result.rows.len);
    try testing.expect(outcome.result.rows[0][0] == .Str);
    try testing.expectEqualStrings("blue", outcome.result.rows[0][0].Str);
}

// -------------------------------------------------------------------
// Test 4 — the count arm stays correct on an in-memory deployment, both
// unfiltered (already guarded pre-fix) and FILTERED (answered 0 pre-fix,
// because the filtered path skipped the precompute's adapter guard and
// tallied the empty slot list).
// -------------------------------------------------------------------
test "SONNY-1218: in-memory count is correct unfiltered and filtered" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seedPeople(&h, 4);

    const aa = h.arena.allocator();
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    var unfiltered = try transportRows(&h, aa, &qa, "MATCH (n:Person) RETURN count(n) AS c");
    defer unfiltered.result.deinit(aa);
    try testing.expect(!unfiltered.via_stream);
    try testing.expectEqual(@as(usize, 1), unfiltered.result.rows.len);
    try testing.expectEqual(@as(i64, 4), unfiltered.result.rows[0][0].Int);

    var qa2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa2.deinit();
    var filtered = try transportRows(&h, aa, &qa2, "MATCH (n:Person) WHERE n.team = 'blue' RETURN count(n) AS c");
    defer filtered.result.deinit(aa);
    try testing.expect(!filtered.via_stream);
    try testing.expectEqual(@as(usize, 1), filtered.result.rows.len);
    try testing.expectEqual(@as(i64, 4), filtered.result.rows[0][0].Int);
}

// -------------------------------------------------------------------
// Test 5 — `isEligible` agrees with `prepare`. The transports use it to
// decide whether to SKIP the O(graph) snapshot clone; if it said "yes"
// while `prepare` declines, the executor fallback would run without the
// snapshot it needs and the bug would simply move.
// -------------------------------------------------------------------
test "SONNY-1218: isEligible declines every shape without a storage adapter" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Person) RETURN n.name")));
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Person) RETURN n")));
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Person) RETURN count(n)")));
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Person {team: 'blue'}) RETURN n.name")));
}

// -------------------------------------------------------------------
// Test 6 — WITH a storage adapter the fast path STILL ENGAGES and is
// still correct. Without this, "return null always" would pass tests 1-5
// while silently deleting the whole engine-direct read optimization.
//
// Observable proof that the stream (not the executor) produced the rows:
// `via_stream`, plus the path's own `getNodesMaterializedTotal` counter —
// the lazy per-page `materializeNode` the executor never calls.
// -------------------------------------------------------------------
test "SONNY-1218: with a storage adapter the engine-direct fast path still serves the scan" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try seedPeople(&h, 3);

    const aa = h.arena.allocator();
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    try testing.expect(node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Person) RETURN n.name")));

    var qa2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa2.deinit();
    node_scan_stream.resetNodesMaterializedTotal();
    var outcome = try transportRows(&h, aa, &qa2, "MATCH (n:Person) RETURN n.name");
    defer outcome.result.deinit(aa);

    try testing.expect(outcome.via_stream);
    try testing.expect(node_scan_stream.getNodesMaterializedTotal() > 0);
    try testing.expectEqual(@as(usize, 3), outcome.result.rows.len);
    for (outcome.result.rows) |row| {
        try testing.expect(row[0] == .Str);
        try testing.expect(std.mem.startsWith(u8, row[0].Str, "p"));
    }
}
