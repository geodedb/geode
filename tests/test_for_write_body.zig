// CANARY: REQ=REQ-GQL-FOR-WRITE-BODY-876; FEATURE="ForStatement"; ASPECT=WriteBodyComposition; STATUS=TESTED; TEST=tests/test_for_write_body.zig:1; OWNER=parser; UPDATED=2026-08-29
// CANARY: REQ=REQ-GQL-FOR-WRITE-BODY-876-CLASSIFY; FEATURE="ForStatement"; ASPECT=MutationClassification; STATUS=TESTED; TEST=tests/test_for_write_body.zig:1; OWNER=query_traits; UPDATED=2026-08-29
//
// geode#876 — ISO GQL `FOR … IN` cannot compose with write statements.
//
// The parser hard-requires a RETURN immediately after the FOR header
// (`_ = try self.expect(.RETURN);`, src/gql/parser.zig:5814, inside
// parseForStatement 5776-5878), so every data-modifying continuation is a
// syntax error:
//
//     FOR i IN range(1, 4) CREATE (n:T {v: i})
//     → 42601 "expected token 'RETURN', got 'CREATE'"
//
// Three layers are implicated, and all three are asserted here:
//
//   (1) AST — ast.ForStatement (src/gql/ast.zig:834-846) has a NON-optional
//       `return_clause` and no body/continuation field, unlike its sibling
//       ast.ValuesStatement which carries `next_statement` (ast.zig:850).
//
//   (2) EXECUTION — executeFor (src/execution/statement_handlers.zig:615) and
//       executeForWithBindings (:474) both discard the ExecutionContext
//       (`_ = context;`), so a FOR body has no store handle to write through
//       even if it parsed. Every executed assertion below therefore counts
//       PERSISTED NODES via a follow-up MATCH — never the FOR result rows —
//       because a FOR that reports success while writing nothing is exactly
//       the failure mode.
//
//   (3) CLASSIFICATION — query_traits.isMutatingStatement
//       (src/query/query_traits.zig:351) drops `.For` into `else => false`.
//       A write-bodied FOR misclassified as read-only would (a) slip past the
//       read-only-user gate, (b) take the SHARED read lock while mutating
//       shared HashMap/ArrayList state, and (c) bypass the cluster
//       unreplicated-write gate. That is a security/corruption defect, not a
//       cosmetic one, so it gets its own assertions.
//
// Per ISO/IEC 39075:2024 (grammar/ISO_IEC_39075(en).bnf.txt:413, 455, 288) FOR
// is a <primitive query statement>; a <data-modifying statement> may follow it
// and the RETURN is OPTIONAL. Cypher `UNWIND` is explicitly OUT OF SCOPE — it
// is not ISO GQL and is not being added.
//
// CONTROLS that are green today and MUST stay green: `FOR x IN [1,2,3]
// RETURN x`, `FOR i IN range(1,4) RETURN i`, and the WITH ORDINALITY form.
// NOTE on range(): geode's range(start, stop) is HALF-OPEN — range(1,4) is
// [1,2,3]. The control test below pins that so the write-path counts are
// trustworthy.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const Value = geode.value_types.Value;

// The graph_store/catalog instances are process-wide and the build's test
// runner may execute tests in this binary concurrently. Serialize every test
// that touches them. Mirrors tests/test_eng3904_3905_vector_literals.zig.
var test_mutex: std.Io.Mutex = .init;

fn lockStore() void {
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
}

fn unlockStore() void {
    test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
}

// ---------------------------------------------------------------------------
// Parse-only helpers (no global state — safe without the mutex).
// ---------------------------------------------------------------------------

fn expectParseOk(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    switch (result) {
        .Ok => {},
        .Err => |e| {
            std.debug.print("\nPARSE FAILED for: {s}\n  error: {s}\n", .{ src, e.msg });
            return error.UnexpectedParseError;
        },
    }
}

/// Parse and report whether the resulting program is classified as mutating.
/// A parse failure is surfaced loudly rather than folded into `false`, so this
/// helper can never accidentally "prove" a classification via a syntax error.
fn parseAndClassify(src: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    switch (result) {
        .Ok => |res| {
            var program = res.program;
            return query_traits.isMutatingProgram(&program);
        },
        .Err => |e| {
            std.debug.print("\nPARSE FAILED for: {s}\n  error: {s}\n", .{ src, e.msg });
            return error.UnexpectedParseError;
        },
    }
}

// ---------------------------------------------------------------------------
// Execution harness (mirrors tests/test_eng3913_where_delete.zig).
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
        var parsed = geode.parseGqlOptions(query, aa, .{}) catch |err| {
            std.debug.print("\nPARSE FAILED for: {s}\n  error: {any}\n", .{ query, err });
            return error.UnexpectedParseError;
        };
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Row count of a read query — the honest "did the write land?" assertion.
    pub fn countRows(self: *Harness, query: []const u8) !usize {
        const res = try self.exec(query);
        return res.rows.len;
    }

    /// Collect every Int value projected by a read query, sorted ascending.
    /// Asserts on the VALUES written, not just the node count, so a FOR that
    /// creates the right number of nodes with the wrong (or NULL) property
    /// still fails.
    pub fn collectInts(self: *Harness, allocator: std.mem.Allocator, query: []const u8) ![]i64 {
        const res = try self.exec(query);
        var out = std.ArrayList(i64).empty;
        errdefer out.deinit(allocator);
        for (res.rows) |row| {
            for (row) |value| {
                switch (value) {
                    .Int => |i| try out.append(allocator, i),
                    else => {},
                }
            }
        }
        const slice = try out.toOwnedSlice(allocator);
        std.mem.sort(i64, slice, {}, std.sort.asc(i64));
        return slice;
    }
};

// ===========================================================================
// REGRESSION (the bug): a FOR header followed by a data-modifying statement
// must PARSE. These are the minimal reproducers for geode#876.
// ===========================================================================

test "geode#876 regression: FOR … CREATE parses" {
    // The exact reproducer from the issue. Today:
    //   42601 "expected token 'RETURN', got 'CREATE'"
    try expectParseOk("FOR i IN range(1, 4) CREATE (n:T876 {v: i})");
}

test "geode#876 regression: FOR over a list literal … CREATE parses" {
    try expectParseOk("FOR i IN [1, 2, 3] CREATE (n:T876 {v: i})");
}

test "geode#876 regression: FOR … MERGE parses" {
    try expectParseOk("FOR i IN [1, 2] MERGE (n:M876 {v: i})");
}

test "geode#876 regression: FOR … WITH ORDINALITY … CREATE parses" {
    // The ordinality/offset binding must remain usable by the write body.
    try expectParseOk("FOR c IN ['a', 'b'] WITH ORDINALITY k CREATE (n:O876 {name: c, ord: k})");
    try expectParseOk("FOR c IN ['a', 'b'] WITH OFFSET k CREATE (n:F876 {name: c, off: k})");
}

test "geode#876 regression: FOR … MATCH … SET parses" {
    // The broadest composition named in the issue: FOR feeding a MATCH-scoped
    // SET. Same parser gate, same 42601.
    try expectParseOk("FOR i IN [1, 2] MATCH (n:S876 {k: i}) SET n.v = i");
}

test "geode#876 regression: FOR … CREATE … RETURN parses" {
    // A trailing RETURN after the write body — the ISO <data-modifying
    // statement> followed by an optional <result statement>. Mirrors the
    // already-supported `CREATE (n:L) RETURN n` shape.
    try expectParseOk("CREATE (n:R876 {v: 1}) RETURN n"); // control: works today
    try expectParseOk("FOR x IN [1, 2, 3] CREATE (n:R876 {v: x}) RETURN n");
}

// ===========================================================================
// CONTROLS: the read-only FOR forms are green today and must stay green.
// ===========================================================================

test "geode#876 control: FOR … RETURN still parses and projects every element" {
    try expectParseOk("FOR x IN [1, 2, 3] RETURN x AS x");
    try expectParseOk("FOR i IN range(1, 4) RETURN i AS i");
    try expectParseOk("FOR x IN [1, 2, 3] WITH ORDINALITY k RETURN x AS x, k AS k");
    try expectParseOk("FOR x IN [1, 2, 3] RETURN x AS x ORDER BY x DESC LIMIT 2");
}

test "geode#876 control: range(start, stop) is half-open, so range(1,4) is [1,2,3]" {
    // Pins the semantics the write-path node counts below depend on. If this
    // ever flips to inclusive, the executed assertions must be re-based rather
    // than silently drifting.
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = try h.collectInts(arena.allocator(), "FOR i IN range(1, 4) RETURN i AS i");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3 }, got);
}

// ===========================================================================
// EXECUTED: the write body must actually persist nodes. Every assertion reads
// back through a follow-up MATCH, so a no-op FOR cannot pass.
// ===========================================================================

test "geode#876: FOR … CREATE persists exactly one node per element with the bound value" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try h.exec("CREATE GRAPH for876_create");
    _ = try h.exec("USE GRAPH for876_create");

    _ = try h.exec("FOR i IN range(1, 4) CREATE (n:T876 {v: i})");

    // Exactly three nodes, carrying exactly the loop values 1, 2, 3.
    try testing.expectEqual(@as(usize, 3), try h.countRows("MATCH (n:T876) RETURN n"));
    const vs = try h.collectInts(arena.allocator(), "MATCH (n:T876) RETURN n.v AS v");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3 }, vs);
}

test "geode#876: FOR … CREATE over an EMPTY collection writes nothing" {
    // Boundary case: the loop body must not run once for an empty list (the
    // current executeFor "treat a non-list as a single-item list" fallback is
    // exactly the kind of thing that would mint a spurious node here).
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH for876_empty");
    _ = try h.exec("USE GRAPH for876_empty");

    _ = try h.exec("FOR i IN [] CREATE (n:E876 {v: i})");

    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:E876) RETURN n"));
}

test "geode#876: FOR … MERGE is idempotent across repeated executions" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try h.exec("CREATE GRAPH for876_merge");
    _ = try h.exec("USE GRAPH for876_merge");

    _ = try h.exec("FOR i IN [1, 2] MERGE (n:M876 {v: i})");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:M876) RETURN n"));

    // Second run must MATCH the existing nodes, not duplicate them.
    _ = try h.exec("FOR i IN [1, 2] MERGE (n:M876 {v: i})");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:M876) RETURN n"));

    const vs = try h.collectInts(arena.allocator(), "MATCH (n:M876) RETURN n.v AS v");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2 }, vs);
}

test "geode#876: WITH ORDINALITY binds a 1-based counter usable by the write body" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try h.exec("CREATE GRAPH for876_ord");
    _ = try h.exec("USE GRAPH for876_ord");

    _ = try h.exec("FOR c IN ['a', 'b', 'c'] WITH ORDINALITY k CREATE (n:O876 {name: c, ord: k})");

    try testing.expectEqual(@as(usize, 3), try h.countRows("MATCH (n:O876) RETURN n"));
    const ords = try h.collectInts(arena.allocator(), "MATCH (n:O876) RETURN n.ord AS ord");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3 }, ords);
}

test "geode#876: WITH OFFSET binds a 0-based counter usable by the write body" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try h.exec("CREATE GRAPH for876_off");
    _ = try h.exec("USE GRAPH for876_off");

    _ = try h.exec("FOR c IN ['a', 'b', 'c'] WITH OFFSET k CREATE (n:F876 {name: c, off: k})");

    try testing.expectEqual(@as(usize, 3), try h.countRows("MATCH (n:F876) RETURN n"));
    const offs = try h.collectInts(arena.allocator(), "MATCH (n:F876) RETURN n.off AS off");
    try testing.expectEqualSlices(i64, &[_]i64{ 0, 1, 2 }, offs);
}

test "geode#876: FOR … MATCH … SET updates exactly the matched rows" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try h.exec("CREATE GRAPH for876_set");
    _ = try h.exec("USE GRAPH for876_set");
    _ = try h.exec("CREATE (:S876 {k: 1, v: 0})");
    _ = try h.exec("CREATE (:S876 {k: 2, v: 0})");
    _ = try h.exec("CREATE (:S876 {k: 3, v: 0})");

    _ = try h.exec("FOR i IN [1, 2] MATCH (n:S876 {k: i}) SET n.v = i");

    // k=1 → v=1, k=2 → v=2, k=3 untouched at v=0. No node is added or lost.
    try testing.expectEqual(@as(usize, 3), try h.countRows("MATCH (n:S876) RETURN n"));
    const vs = try h.collectInts(arena.allocator(), "MATCH (n:S876) RETURN n.v AS v");
    try testing.expectEqualSlices(i64, &[_]i64{ 0, 1, 2 }, vs);
}

// ===========================================================================
// CLASSIFICATION: a write-bodied FOR MUST be classified as mutating.
// Getting this wrong is a security + concurrency defect (read-only user gate,
// exclusive write lock, cluster unreplicated-write gate all key off it).
// ===========================================================================

test "geode#876: isMutatingProgram is TRUE for FOR … CREATE" {
    try testing.expect(try parseAndClassify("FOR i IN range(1, 4) CREATE (n:T876 {v: i})"));
}

test "geode#876: isMutatingProgram is TRUE for FOR … MERGE" {
    try testing.expect(try parseAndClassify("FOR i IN [1, 2] MERGE (n:M876 {v: i})"));
}

test "geode#876: isMutatingProgram is TRUE for FOR … MATCH … SET" {
    try testing.expect(try parseAndClassify("FOR i IN [1, 2] MATCH (n:S876 {k: i}) SET n.v = i"));
}

test "geode#876 control: isMutatingProgram stays FALSE for a read-only FOR … RETURN" {
    // Must NOT over-classify: promoting every FOR to mutating would force the
    // exclusive write lock on read-only loops and regress concurrency.
    try testing.expect(!(try parseAndClassify("FOR x IN [1, 2, 3] RETURN x AS x")));
    try testing.expect(!(try parseAndClassify("FOR i IN range(1, 4) WITH ORDINALITY k RETURN i AS i, k AS k")));
}
