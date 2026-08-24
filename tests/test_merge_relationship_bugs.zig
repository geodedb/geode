// Reproduction tests for two confirmed BUG_BROKEN issues in MERGE relationship
// handling.  Each test below FAILS on `main` and will PASS once the fix lands
// in src/execution/crud_operations.zig.
//
// Bug A (REQ=REQ-MERGE-RELPROPS-001 ASPECT=MatchBoundEndpoints):
//     `MATCH (a),(b) MERGE (a)-[:REL]->(b)` returns success but the edge is
//     never created.  Root cause: query_execution.zig:1700-1703 populates
//     `query_param_names`/`query_param_values` from MATCH but does not set
//     `context.bindings`.  The MERGE edge branch (crud_operations.zig:2335)
//     reads `context.bindings`, gets nothing, and returns silently because
//     neither inline labels nor inline props are present on the bound
//     variables.
//
// Bug B (REQ=REQ-MERGE-RELPROPS-001 ASPECT=InlineRelProps / ASPECT=BareSet /
//     ASPECT=OnCreateSet):
//     The MERGE edge branch never iterates `hop.rel.props`, the relationship
//     variable's `m.on_create` SET clauses, or `m.on_match` SET clauses, and
//     it discards the new edge_id from `createEdgeWithGraph`.  All three
//     forms of "set a property on the merged relationship" are silently
//     dropped.
//
// Bug C is the combination of A + B1 — bound endpoints PLUS an inline
// relationship property literal.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

// Serialize tests across this file — the global graph_store/catalog state
// is process-wide, and parallel tests would otherwise stomp each other's
// tmp dirs.  Mirrors the pattern in tests/test_limitations_fixes.zig.
var test_mutex: std.Io.Mutex = .init;

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by
// joining cwd with the relative tmp sub_path.
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
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// Execute a single statement (parses, runs, returns result).
    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(
            self.allocator,
            parsed.program.statements[0],
            self.ctx,
        );
    }

    /// Execute the WHOLE parsed program, exactly as the server does for a
    /// submitted query string (src/execution.zig:executeProgramWithContext).
    /// Chained clauses (`MERGE ... MERGE ... MERGE ...`) currently parse into
    /// several statements, so a statements[0]-only runner would silently skip
    /// most of the query; this runner keeps the test honest regardless of
    /// whether the fix lands in the parser (one statement) or the executor.
    pub fn execProgram(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeProgramWithContext(
            self.allocator,
            &parsed.program,
            self.ctx,
        );
    }

    /// Assert a query is REJECTED (error) rather than silently reporting
    /// success. Used for the fail-loud MERGE endpoint assertion — the whole
    /// point of ENG-3903 is that "00000 + nothing written" is unacceptable.
    pub fn expectRejected(self: *Harness, query: []const u8) !void {
        if (self.execProgram(query)) |res| {
            var r = res;
            r.deinit(self.allocator);
            std.debug.print(
                "\nFAIL: expected `{s}` to be rejected, but it reported success\n",
                .{query},
            );
            return error.ExpectedQueryRejection;
        } else |_| {}
    }
};

fn nodeHasLabel(node: *const graph_store.Node, label: []const u8) bool {
    for (node.labels) |l| {
        if (std.mem.eql(u8, l, label)) return true;
    }
    return false;
}

/// Count nodes carrying the given label across the global store.
fn countLabeledNodes(label: []const u8) usize {
    const store = graph_store.getCurrentGlobalStore() orelse return 0;
    var count: usize = 0;
    var iter = store.nodes.iterator();
    while (iter.next()) |entry| {
        if (nodeHasLabel(entry.value_ptr, label)) count += 1;
    }
    return count;
}

/// Count edges with the given relationship label across the global store on
/// the default graph.  Used in lieu of evaluating `MATCH ... RETURN count(r)`
/// — the count() function may have its own pre-existing limitations and we
/// want this assertion to be trivially correct.
fn countRelEdges(rel_label: []const u8) usize {
    const store = graph_store.getCurrentGlobalStore() orelse return 0;
    var count: usize = 0;
    var iter = store.edges.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.label, rel_label)) count += 1;
    }
    return count;
}

/// Find the FIRST edge with the given relationship label in the store and
/// return its `method` property value.  Returns null if no such edge
/// exists or the property is missing.
fn firstRelEdgeMethod(rel_label: []const u8) ?graph_store.PropertyValue {
    const store = graph_store.getCurrentGlobalStore() orelse return null;
    var iter = store.edges.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.label, rel_label)) continue;
        const props = &entry.value_ptr.properties;
        return props.get("method");
    }
    return null;
}

fn expectMethodEquals(rel_label: []const u8, expected: []const u8) !void {
    const got = firstRelEdgeMethod(rel_label) orelse {
        std.debug.print("\nFAIL: no :{s} edge with `method` property found in store; expected '{s}'\n", .{ rel_label, expected });
        return error.MissingMethodProperty;
    };
    switch (got) {
        .String => |s| {
            if (!std.mem.eql(u8, s, expected)) {
                std.debug.print("\nFAIL: r.method = '{s}'; expected '{s}'\n", .{ s, expected });
                return error.WrongMethodValue;
            }
        },
        else => {
            std.debug.print("\nFAIL: r.method has non-string variant {any}\n", .{got});
            return error.WrongMethodVariant;
        },
    }
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=MatchBoundEndpoints; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-05-06
test "merge: MATCH-bound endpoints create edge" {
    // Bug A: `MATCH (a),(b) MERGE (a)-[:REL]->(b)` succeeds (status 00000)
    // but no edge is actually created.  This test FAILS on main with
    // edge count == 0; passes after the fix with edge count == 1.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (:Foo {id: 1})");
        r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:Bar {id: 2})");
        r.deinit(allocator);
    }

    {
        var r = try h.exec("MATCH (a:Foo {id: 1}), (b:Bar {id: 2}) MERGE (a)-[:REL]->(b)");
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), countRelEdges("REL"));
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=InlineRelProps; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-05-06
test "merge: inline relationship property is persisted" {
    // Bug B1: inline properties on the relationship pattern are dropped —
    // edge is created but `r.method` is null/missing.  FAILS on main;
    // passes after the fix when the MERGE edge branch iterates
    // `hop.rel.props` and applies them to the new edge.
    //
    // Endpoint nodes are pre-seeded with CREATE so the MERGE finds them by
    // label+id and only has to create the edge — that exercises the same
    // code path as the user-reported reproduction.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (:Foo {id: 1})");
        r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:Bar {id: 2})");
        r.deinit(allocator);
    }

    {
        var r = try h.exec("MERGE (a:Foo {id: 1})-[:REL {method: 'x'}]->(b:Bar {id: 2})");
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), countRelEdges("REL"));
    try expectMethodEquals("REL", "x");
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=BareSetOnRelationship; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-05-06
test "merge: bare SET on relationship variable is persisted" {
    // Bug B2: `MERGE ...-[r:REL]->... SET r.method = 'x'` drops the SET
    // assignment — edge created but `r.method` is null/missing.  FAILS
    // on main; passes after the fix when bare-SET (and `m.on_create` /
    // `m.on_match`) are evaluated against the merged relationship
    // variable.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (:Foo {id: 1})");
        r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:Bar {id: 2})");
        r.deinit(allocator);
    }

    {
        var r = try h.exec("MERGE (a:Foo {id: 1})-[r:REL]->(b:Bar {id: 2}) SET r.method = 'x'");
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), countRelEdges("REL"));
    try expectMethodEquals("REL", "x");
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=OnCreateSetRelationship; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-05-06
test "merge: ON CREATE SET on relationship variable is persisted" {
    // Bug B3: `MERGE ...-[r:REL]->... ON CREATE SET r.method = 'x'`
    // drops the ON CREATE SET — edge created but `r.method` is
    // null/missing.  FAILS on main; passes after the fix when the
    // MERGE edge branch consumes `m.on_create` for the rel variable
    // when an edge is freshly created.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (:Foo {id: 1})");
        r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:Bar {id: 2})");
        r.deinit(allocator);
    }

    {
        var r = try h.exec("MERGE (a:Foo {id: 1})-[r:REL]->(b:Bar {id: 2}) ON CREATE SET r.method = 'x'");
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), countRelEdges("REL"));
    try expectMethodEquals("REL", "x");
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=MatchBoundEndpointsWithInlineRelProps; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-05-06
test "merge: MATCH-bound endpoints create edge with inline property" {
    // Bug C: combined form of Bug A + Bug B1.  Endpoints are bound by
    // a preceding MATCH (so `context.bindings`/query_param_values must
    // resolve them) AND there is an inline relationship property
    // literal (so `hop.rel.props` must be iterated against the new
    // edge).  Both bugs must be fixed for this test to pass: edge
    // count == 1 AND `r.method == 'x'`.  FAILS on main with edge
    // count == 0.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (:Foo {id: 1})");
        r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:Bar {id: 2})");
        r.deinit(allocator);
    }

    {
        var r = try h.exec("MATCH (a:Foo {id: 1}), (b:Bar {id: 2}) MERGE (a)-[:REL {method: 'x'}]->(b)");
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), countRelEdges("REL"));
    try expectMethodEquals("REL", "x");
}

// ---------------------------------------------------------------------------
// ENG-3903 — silent data loss on CHAINED / COMMA-SEPARATED MERGE
//
// Reported reproduction (returns SQLSTATE 00000, creates 2 nodes and ZERO
// relationships — a silent write loss):
//
//     MERGE (a:MT {name:'a'})
//     MERGE (b:MT {name:'b'})
//     MERGE (a)-[:REL {type:'x'}]->(b)
//
// Two layers:
//   (a) parseMergeStatement (src/gql/parser.zig:4676-4741) parses exactly ONE
//       MERGE clause, so the 2nd and 3rd MERGE become separate statements and
//       the variables a/b are not in scope for the third one;
//   (b) the executeMerge edge branch (src/execution/crud_operations.zig:
//       3201-3333) resolves endpoints only from `context.bindings` or from
//       inline labels/props. Bare `(a)` / `(b)` resolve to null, the guard at
//       :3285 skips edge creation, and :3334-3341 still commits and returns an
//       empty SUCCESS result.
//   (c) executeMerge only ever looks at `chains[0]`, so the comma form
//       `MERGE (a:MX {name:'a'}), (b:MX {name:'b'})` creates only node 'a'.
//
// Working control (already green today, must stay green):
//     MATCH (a:MT {name:'a'}), (b:MT {name:'b'}) MERGE (a)-[:REL {type:'x'}]->(b)
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=ChainedMergeEndpoints; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-08-24
test "merge: chained MERGE node/node/relationship creates the relationship (ENG-3903)" {
    // FAILS on v0.8.5: 2 nodes are created, the relationship count is 0 and
    // the query still reports SQLSTATE 00000 (silent data loss).
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    const q =
        "MERGE (a:MT3903 {name:'a'}) MERGE (b:MT3903 {name:'b'}) MERGE (a)-[:REL3903 {type:'x'}]->(b)";

    {
        var r = try h.execProgram(q);
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 2), countLabeledNodes("MT3903"));
    try testing.expectEqual(@as(usize, 1), countRelEdges("REL3903"));

    // MERGE is idempotent: re-running the identical query must not duplicate
    // the nodes or the relationship.
    {
        var r = try h.execProgram(q);
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 2), countLabeledNodes("MT3903"));
    try testing.expectEqual(@as(usize, 1), countRelEdges("REL3903"));
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=ChainedMergeControl; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-08-24
test "merge: MATCH-bound control for the ENG-3903 shape stays idempotent" {
    // Control (green today): the same end state expressed with MATCH + MERGE.
    // Guards against a fix that "repairs" the chained form by breaking this.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.exec("CREATE (:MC3903 {name: 'a'})");
        r.deinit(allocator);
    }
    {
        var r = try h.exec("CREATE (:MC3903 {name: 'b'})");
        r.deinit(allocator);
    }

    const q = "MATCH (a:MC3903 {name:'a'}), (b:MC3903 {name:'b'}) MERGE (a)-[:RELC3903 {type:'x'}]->(b)";
    {
        var r = try h.execProgram(q);
        r.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 1), countRelEdges("RELC3903"));

    {
        var r = try h.execProgram(q);
        r.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 1), countRelEdges("RELC3903"));
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=CommaSeparatedMergeChains; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-08-24
test "merge: comma-separated MERGE pattern creates every chain (ENG-3903c)" {
    // FAILS on v0.8.5: only node 'a' is created — executeMerge reads chains[0]
    // and drops the remaining chains while still reporting success.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.execProgram("MERGE (a:MX3903 {name:'a'}), (b:MX3903 {name:'b'})");
        r.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 2), countLabeledNodes("MX3903"));

    // Idempotent: re-running must not create duplicates.
    {
        var r = try h.execProgram("MERGE (a:MX3903 {name:'a'}), (b:MX3903 {name:'b'})");
        r.deinit(allocator);
    }
    try testing.expectEqual(@as(usize, 2), countLabeledNodes("MX3903"));
}

// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=UnresolvableEndpointFailsLoud; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-08-24
test "merge: unresolvable relationship endpoint is rejected, not silently skipped (ENG-3903)" {
    // Post-fix semantics: if an endpoint variable of a MERGE relationship
    // pattern cannot be resolved (not bound by a preceding clause, no label /
    // property to match or create on), the statement must FAIL LOUDLY.
    // On v0.8.5 the guard at crud_operations.zig:3285 skips edge creation and
    // the statement still returns SQLSTATE 00000 with no edge written — the
    // exact silent-data-loss shape ENG-3903 reports.
    test_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try h.expectRejected("MERGE (zz3903)-[:RELZ3903 {type:'x'}]->(yy3903)");

    // And nothing must have been written by the rejected statement.
    try testing.expectEqual(@as(usize, 0), countRelEdges("RELZ3903"));
}
