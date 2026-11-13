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
        return self.execWithParams(query, &.{}, &.{});
    }

    /// Execute `query` with request-level query parameters bound, exactly as the
    /// transport handler wires them onto the ExecutionContext before dispatch
    /// (query_execution.zig builds the same `query_param_names`/`query_param_values`
    /// arrays at :1566-1601, and executeForBody reads them at
    /// statement_handlers.zig:666-673). This is the seam the FOR..IN
    /// parameter-bound-list bug lives on: the FOR *header* (collection) env and
    /// the per-iteration RETURN env drop these params, so a `$param` collection
    /// resolves to Null.
    pub fn execWithParams(
        self: *Harness,
        query: []const u8,
        names: []const []const u8,
        values: []const Value,
    ) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        self.ctx.query_param_names = names;
        self.ctx.query_param_values = values;
        defer {
            self.ctx.query_param_names = &.{};
            self.ctx.query_param_values = &.{};
        }
        const aa = self.arena.allocator();
        var parsed = geode.parseGqlOptions(query, aa, .{}) catch |err| {
            std.debug.print("\nPARSE FAILED for: {s}\n  error: {any}\n", .{ query, err });
            return error.UnexpectedParseError;
        };
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Row count for a query executed WITH params — honest "did the write land?"
    /// assertion when the read-back itself needs a bound parameter (rare, but
    /// keeps the API symmetric).
    pub fn countRowsParams(self: *Harness, query: []const u8, names: []const []const u8, values: []const Value) !usize {
        const res = try self.execWithParams(query, names, values);
        return res.rows.len;
    }

    /// Collect every Str value projected by a read query. Used to assert that
    /// map-valued loop rows land distinct, non-null string properties.
    pub fn collectStrs(self: *Harness, allocator: std.mem.Allocator, query: []const u8) ![][]const u8 {
        const res = try self.exec(query);
        var out = std.ArrayList([]const u8).empty;
        errdefer out.deinit(allocator);
        for (res.rows) |row| {
            for (row) |value| {
                switch (value) {
                    .Str => |s| try out.append(allocator, try allocator.dupe(u8, s)),
                    else => {},
                }
            }
        }
        const slice = try out.toOwnedSlice(allocator);
        std.mem.sort([]const u8, slice, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        return slice;
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

// SONNY-2463 (review m3): a FOR body whose iterations each return nodes hands
// the accumulator one `OwnedGraphEntities` per iteration, and `absorb` merges
// them into the first. The merged nodes are then freed the first tracker's way
// (`destroy_node`), so `absorb` asserts both trackers free their nodes the
// same way. This drives that merge: each iteration returns one matched node,
// and the result's single tracker must hold both.
//
// SONNY-6449 made the entry point copy a result out of its statement scratch
// arena (`execution.detachFromStatementScratch`), which re-tracks every node
// the rows hold as a copy the result owns in full; so the tracker the caller
// gets is no longer the executor's merged one, and how it frees a node is not
// part of the contract. What is: the statement runs on the strict testing
// allocator, its rows stay readable after the statement returned, every node a
// row holds is tracked by the result, and `deinit` frees each exactly once (a
// tracker the merge dropped leaks; one it kept twice frees twice).
test "SONNY-2463: a FOR body that returns nodes from two iterations merges their trackers" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH for876_merge");
    _ = try h.exec("USE GRAPH for876_merge");
    _ = try h.exec("CREATE (:N876 {k: 1})");
    _ = try h.exec("CREATE (:N876 {k: 2})");
    _ = try h.exec("CREATE (:N876 {k: 3})");

    h.ctx.session_state = &h.session;
    var parsed = try geode.parseGqlOptions("FOR i IN [1, 2] MATCH (n:N876 {k: i}) RETURN n", h.arena.allocator(), .{});
    defer parsed.deinit();
    var res = try execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], h.ctx);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), res.rows.len);
    const entities = res.owned_graph_entities orelse return error.ExpectedTrackedNodes;
    try testing.expectEqual(@as(usize, 2), entities.nodes.items.len);
    for (res.rows, 0..) |row, i| {
        const node = row[0].Node;
        var tracked = false;
        for (entities.nodes.items) |t| tracked = tracked or @intFromPtr(t) == @intFromPtr(node);
        try testing.expect(tracked);
        const k = (node.properties.get("k") orelse return error.NodePropertyMissing).Int;
        try testing.expectEqual(@as(i64, @intCast(i + 1)), k);
    }
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

// ===========================================================================
// FOR..IN PARAMETER-BOUND LIST — the collapse-to-one-null-iteration bug.
//
// Root cause: executeFor evaluates the FOR collection expression in an Env with
// NO request params wired in (statement_handlers.zig:832-836 builds
// `Env{ .names = &.{}, .values = &.{} }`), so a `$param` collection resolves to
// Null (eval.zig:886-893 .Param arm), and a non-conformant "treat non-list as a
// single-item list" fallback (:843-853) turns that Null into ONE iteration with
// the loop var = Null. The same missing-params seam is at the per-iteration
// RETURN env (:895-899), executeForWithBindings' collection + iteration envs
// (:694-700, :760-764), and executeValues (:938-942, :1036-1040).
//
// The write-loss sibling (planned_read_runtime.zig:3714-3742 isStorageNativeQuery
// does not reject q.for_statement, so WITH…FOR…CREATE is served as a plain WITH
// projection and never reaches executeForWithBindings) is exercised on the WIRE
// path only — see ../geode-test-harness/geodetestlab-cli/specs/for_write_body.yml.
// In THIS in-process harness, WITH…FOR routes through executeForWithBindings
// directly (query_execution.zig:2192-2194), so case (e) below exercises the
// param seam in executeForWithBindings' collection env instead.
//
// Per ISO/IEC 39075:2024 `<for item source>` is a `<list value expression>`:
// `FOR n IN $nums` is valid and must iterate the bound list; a non-list/Null
// collection is a TYPE ERROR, never a one-element null iteration. The empty-list
// boundary below pins the minimum conformant contract: zero iterations, and in
// particular NEVER exactly one null row/node.
// ===========================================================================

// Helper: an owned `[]Value` list param (List variant needs a mutable slice).
fn intListValue(allocator: std.mem.Allocator, ints: []const i64) !Value {
    const slice = try allocator.alloc(Value, ints.len);
    for (ints, 0..) |n, i| slice[i] = Value{ .Int = n };
    return Value{ .List = slice };
}

test "for-in-param (a): FOR n IN \\$nums RETURN n projects every bound element" {
    // RC: currently $nums -> Null -> one null iteration -> collectInts == [].
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const nums = try intListValue(aa, &[_]i64{ 10, 20, 30 });
    const res = try h.execWithParams("FOR n IN $nums RETURN n AS v", &[_][]const u8{"nums"}, &[_]Value{nums});
    try testing.expectEqual(@as(usize, 3), res.rows.len);

    var out = std.ArrayList(i64).empty;
    for (res.rows) |row| for (row) |value| switch (value) {
        .Int => |v| try out.append(aa, v),
        else => {},
    };
    std.mem.sort(i64, out.items, {}, std.sort.asc(i64));
    try testing.expectEqualSlices(i64, &[_]i64{ 10, 20, 30 }, out.items);
}

test "for-in-param (b): FOR row IN \\$rows CREATE persists one node per element" {
    // RC: currently $rows -> Null -> one iteration with row=Null -> a single
    // node with NULL props. Read back EXACTLY two nodes with distinct, non-null
    // props (asserted via a follow-up MATCH, not via the FOR result rows).
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    _ = try h.exec("CREATE GRAPH forparam_rows");
    _ = try h.exec("USE GRAPH forparam_rows");

    var m0 = std.StringHashMap(Value).init(aa);
    try m0.put("k", Value{ .Int = 1 });
    try m0.put("v", Value{ .Str = "a" });
    var m1 = std.StringHashMap(Value).init(aa);
    try m1.put("k", Value{ .Int = 2 });
    try m1.put("v", Value{ .Str = "b" });

    const rows_slice = try aa.alloc(Value, 2);
    rows_slice[0] = Value{ .Map = m0 };
    rows_slice[1] = Value{ .Map = m1 };
    const rows_param = Value{ .List = rows_slice };

    _ = try h.execWithParams(
        "FOR row IN $rows CREATE (n:PRow {k: row.k, v: row.v})",
        &[_][]const u8{"rows"},
        &[_]Value{rows_param},
    );

    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:PRow) RETURN n"));
    const ks = try h.collectInts(aa, "MATCH (n:PRow) RETURN n.k AS k");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2 }, ks);
    const vs = try h.collectStrs(aa, "MATCH (n:PRow) RETURN n.v AS v");
    try testing.expectEqual(@as(usize, 2), vs.len);
    try testing.expect(!std.mem.eql(u8, vs[0], vs[1])); // distinct, non-null
}

test "for-in-param (c): per-iteration RETURN env resolves an outer \\$param" {
    // Defect 2: the per-iteration RETURN env (statement_handlers.zig:895-899)
    // drops request params, so $x -> Null. Collection is an inline list so only
    // the RETURN env is under test. Expect px=99 on both rows -> ints [1,2,99,99].
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const got = try blk: {
        const res = try h.execWithParams("FOR i IN [1, 2] RETURN i AS i, $x AS px", &[_][]const u8{"x"}, &[_]Value{Value{ .Int = 99 }});
        var out = std.ArrayList(i64).empty;
        for (res.rows) |row| for (row) |value| switch (value) {
            .Int => |v| try out.append(aa, v),
            else => {},
        };
        std.mem.sort(i64, out.items, {}, std.sort.asc(i64));
        break :blk out.toOwnedSlice(aa);
    };
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 99, 99 }, got);
}

test "for-in-param (d): FOR n IN \\$missing (empty list) writes/returns nothing" {
    // RC boundary + non-conformant fallback: an empty-list collection must yield
    // ZERO iterations, never exactly one null row. Currently $missing -> Null (params
    // not wired) -> the "non-list => single item" fallback mints ONE null row.
    // Contract chosen: zero rows (and in no case exactly one null row).
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const empty = Value{ .List = try aa.alloc(Value, 0) };
    const res = try h.execWithParams("FOR n IN $missing RETURN n AS v", &[_][]const u8{"missing"}, &[_]Value{empty});
    try testing.expectEqual(@as(usize, 0), res.rows.len);
}

test "for-in-param (e): WITH … FOR n IN \\$nums CREATE persists one node per element" {
    // Write-loss guard (defect 2) + collection-env params (defect 1b): even
    // in-process, executeQueryWithContext calls planned_read_runtime.executeIfSupported
    // (query_execution.zig:1744/1762) BEFORE the WITH…FOR branch, and
    // isStorageNativeQuery (planned_read_runtime.zig:3714-3742) does NOT reject a
    // q.for_statement (chains.len==0 => returns true at :3737, unlike the 4 sibling
    // gates), so this is served as a plain WITH projection and the FOR body never
    // runs — ZERO nodes written. Once the guard routes it to executeForWithBindings,
    // that path's collection env (statement_handlers.zig:694-700) must also carry
    // params so $nums resolves. Expect three nodes with n in {1,2,3} and w=1.
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    _ = try h.exec("CREATE GRAPH forparam_withfor");
    _ = try h.exec("USE GRAPH forparam_withfor");

    const nums = try intListValue(aa, &[_]i64{ 1, 2, 3 });
    _ = try h.execWithParams(
        "WITH 1 AS w FOR n IN $nums CREATE (:WF {n: n, w: w})",
        &[_][]const u8{"nums"},
        &[_]Value{nums},
    );

    try testing.expectEqual(@as(usize, 3), try h.countRows("MATCH (n:WF) RETURN n"));
    const ns = try h.collectInts(aa, "MATCH (x:WF) RETURN x.n AS n");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3 }, ns);
    const ws = try h.collectInts(aa, "MATCH (x:WF) RETURN x.w AS w");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 1, 1 }, ws);
}

test "for-in-param (e-inline): WITH … FOR n IN [inline] RETURN projects every element" {
    // Write-loss guard, inline collection (no param seam). Proves the
    // isStorageNativeQuery routing defect in isolation: executeQueryWithContext
    // hands this to planned_read_runtime.executeIfSupported (query_execution.zig:1744/1762),
    // isStorageNativeQuery returns true for the chains.len==0 + for_statement shape,
    // so the FOR is dropped and only the single WITH projection row comes back.
    // Must yield 3 rows once the guard rejects q.for_statement.
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.exec("WITH 1 AS w FOR n IN [1, 2, 3] RETURN n AS v, w AS w");
    try testing.expectEqual(@as(usize, 3), res.rows.len);
}

test "for-in-param (f): VALUES (\\$x, 2) AS (a, b) binds the outer param" {
    // Defect 3: executeValues evaluates row exprs in an empty env
    // (statement_handlers.zig:938-942), so $x -> Null and a=null. Expect a=5,b=2.
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.execWithParams("VALUES ($x, 2) AS (a, b)", &[_][]const u8{"x"}, &[_]Value{Value{ .Int = 5 }});
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(usize, 2), res.rows[0].len);

    var a_val: ?i64 = null;
    var b_val: ?i64 = null;
    for (res.columns, 0..) |col, i| {
        if (std.mem.eql(u8, col, "a")) a_val = switch (res.rows[0][i]) {
            .Int => |v| v,
            else => null,
        };
        if (std.mem.eql(u8, col, "b")) b_val = switch (res.rows[0][i]) {
            .Int => |v| v,
            else => null,
        };
    }
    try testing.expectEqual(@as(?i64, 5), a_val);
    try testing.expectEqual(@as(?i64, 2), b_val);
}

// ===========================================================================
// REGRESSION GUARDS — body params ALREADY work and must stay green after the
// fix. `$param` inside the FOR BODY resolves via executeForBody's param
// forwarding (statement_handlers.zig:666-673); the fix to the header/collection
// and RETURN envs must not regress these.
// ===========================================================================

test "for-in-param guard: FOR i IN [inline] CREATE with a body \\$param stays green" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    _ = try h.exec("CREATE GRAPH forparam_bodyguard");
    _ = try h.exec("USE GRAPH forparam_bodyguard");

    _ = try h.execWithParams("FOR i IN [1, 2] CREATE (:PB {i: i, px: $x})", &[_][]const u8{"x"}, &[_]Value{Value{ .Int = 99 }});

    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:PB) RETURN n"));
    const is = try h.collectInts(aa, "MATCH (n:PB) RETURN n.i AS i");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2 }, is);
    const pxs = try h.collectInts(aa, "MATCH (n:PB) RETURN n.px AS px");
    try testing.expectEqualSlices(i64, &[_]i64{ 99, 99 }, pxs);
}

test "for-in-param guard: FOR row IN [inline maps] CREATE stays green" {
    lockStore();
    defer unlockStore();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    _ = try h.exec("CREATE GRAPH forparam_inlinemaps");
    _ = try h.exec("USE GRAPH forparam_inlinemaps");

    _ = try h.exec("FOR row IN [{k: 1, v: 10}, {k: 2, v: 20}] CREATE (:IM {k: row.k, v: row.v})");

    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:IM) RETURN n"));
    const ks = try h.collectInts(aa, "MATCH (n:IM) RETURN n.k AS k");
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2 }, ks);
    const vs = try h.collectInts(aa, "MATCH (n:IM) RETURN n.v AS v");
    try testing.expectEqualSlices(i64, &[_]i64{ 10, 20 }, vs);
}
